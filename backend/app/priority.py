"""Priority analysis: bounded concurrency with a Pro-first queue.

Heavy DSP / render endpoints share a few CPU+RAM slots (1 GB VM). Each gate:

- runs at most ``slots`` jobs at once;
- keeps ``pro_reserved`` of them for Pro — free requests use only
  ``slots - pro_reserved`` unless they have waited ``free_max_wait`` seconds;
- serves waiters in this order: free requests past their max wait, then Pro,
  then free (FIFO within each group). A free request is never refused: past its
  max wait it may take any slot, ahead of Pro, but the slot cap still holds.

When the server is idle every request starts at once, whatever its tier.

Tier comes from the same server-side check as GET /iap/status
(``deps.user_is_pro``). No/invalid token, or a failed lookup, means "free" —
the queue must never stop a request from being served.
"""
from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from dataclasses import dataclass
from typing import AsyncIterator, Dict, List, Optional, Tuple

from fastapi import HTTPException, Request

from .auth import extract_user_id
from .deps import user_is_pro

try:
    import sentry_sdk.metrics as _sentry_metrics
except ImportError:  # sentry-sdk is optional
    _sentry_metrics = None

logger = logging.getLogger("humming.priority")

PRO = "pro"
FREE = "free"

_TIER_TTL_SEC = 60.0
_TIER_LOOKUP_TIMEOUT_SEC = 2.0
_TIER_CACHE_MAX = 10_000
_tier_cache: Dict[str, Tuple[float, str]] = {}


async def resolve_tier(request: Request) -> str:
    """"pro" or "free" for the caller. Never raises."""
    auth = request.headers.get("authorization")
    if not auth:
        return FREE
    try:
        user_id = extract_user_id(auth, tag="priority")
    except HTTPException:
        return FREE
    now = time.monotonic()
    hit = _tier_cache.get(user_id)
    if hit and hit[0] > now:
        return hit[1]
    try:
        pro = await asyncio.wait_for(
            asyncio.to_thread(user_is_pro, user_id), _TIER_LOOKUP_TIMEOUT_SEC
        )
    except Exception as e:  # HTTPException (503/500), timeout, network …
        logger.warning("priority: tier lookup failed (%s) — serving as free", type(e).__name__)
        return FREE
    tier = PRO if pro else FREE
    if len(_tier_cache) >= _TIER_CACHE_MAX:
        _tier_cache.clear()
    _tier_cache[user_id] = (now + _TIER_TTL_SEC, tier)
    return tier


@dataclass(eq=False)
class _Waiter:
    tier: str
    arrived: float
    fut: "asyncio.Future[None]"
    promoted: bool = False


class PriorityGate:
    def __init__(self, name: str, *, slots: int, pro_reserved: int, free_max_wait: float):
        self.name = name
        self.slots = max(1, slots)
        # Free always keeps at least one slot of its own.
        self.pro_reserved = min(max(0, pro_reserved), self.slots - 1)
        self.free_max_wait = max(0.0, free_max_wait)
        self.in_use = 0
        self._waiters: List[_Waiter] = []

    @property
    def waiting(self) -> int:
        return len(self._waiters)

    def _limit(self, w: _Waiter) -> int:
        if w.tier == PRO or w.promoted:
            return self.slots
        return self.slots - self.pro_reserved

    def _head(self) -> Optional[_Waiter]:
        for group in (lambda w: w.promoted, lambda w: w.tier == PRO, lambda w: True):
            for w in self._waiters:
                if group(w):
                    return w
        return None

    def _dispatch(self) -> None:
        # Strict head-of-line: if the highest-priority waiter cannot start,
        # nobody behind it can (their limit is never higher).
        while True:
            w = self._head()
            if w is None or self.in_use >= self._limit(w):
                return
            self._waiters.remove(w)
            self.in_use += 1
            w.fut.set_result(None)

    def _release(self) -> None:
        self.in_use -= 1
        self._dispatch()

    async def _acquire(self, tier: str) -> _Waiter:
        loop = asyncio.get_running_loop()
        w = _Waiter(tier, loop.time(), loop.create_future())
        self._waiters.append(w)
        self._dispatch()
        try:
            if tier == FREE and not w.fut.done():
                await asyncio.wait({w.fut}, timeout=self.free_max_wait)
                if not w.fut.done():
                    w.promoted = True
                    self._dispatch()
            await w.fut
        except BaseException:  # client went away while queued
            if w.fut.done() and not w.fut.cancelled():
                self._release()
            else:
                self._waiters.remove(w)
                w.fut.cancel()
            raise
        return w

    @contextlib.asynccontextmanager
    async def slot(self, tier: str) -> AsyncIterator[None]:
        w = await self._acquire(tier)
        wait = asyncio.get_running_loop().time() - w.arrived
        _record(self, tier, wait, w.promoted)
        try:
            yield
        finally:
            self._release()


def _record(gate: PriorityGate, tier: str, wait: float, promoted: bool) -> None:
    """Per-request wait time by tier. No user identifiers."""
    logger.info(
        "priority: queue=%s tier=%s wait_ms=%d promoted=%s in_use=%d waiting=%d",
        gate.name, tier, wait * 1000, promoted, gate.in_use, gate.waiting,
    )
    if _sentry_metrics is None:
        return
    try:
        _sentry_metrics.distribution(
            "priority_queue.wait",
            wait * 1000,
            unit="millisecond",
            attributes={"queue": gate.name, "tier": tier, "promoted": promoted},
        )
    except Exception:  # metrics must never fail a request — the log line is enough
        logger.debug("priority: sentry metric failed", exc_info=True)
