"""Priority analysis queue (app/priority.py) and its wiring into the heavy routes."""
from __future__ import annotations

import asyncio
import io
import logging
import time
import uuid
import wave

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app import main as main_mod
from app import priority
from app.priority import FREE, PRO, PriorityGate, resolve_tier
from app.settings import get_settings
from tests.iap_fixtures import hs256_token

SECRET = "test-jwt-secret-please-ignore"


def run(coro):
    return asyncio.run(coro)


async def _job(gate, tier, log, hold=0.0, name=None):
    """Take a slot, note the start order and wait, hold the slot for `hold` s."""
    t0 = asyncio.get_running_loop().time()
    async with gate.slot(tier):
        log.append((name or tier, asyncio.get_running_loop().time() - t0))
        await asyncio.sleep(hold)


async def _settle():
    for _ in range(5):
        await asyncio.sleep(0)


# --- queue behaviour ------------------------------------------------------------
def test_idle_gate_starts_every_tier_immediately():
    async def scenario():
        gate = PriorityGate("t", slots=2, pro_reserved=1, free_max_wait=5)
        log = []
        await _job(gate, FREE, log)
        await _job(gate, PRO, log)
        return log

    log = run(scenario())
    assert [name for name, _ in log] == [FREE, PRO]
    assert all(wait < 0.1 for _, wait in log)


def test_busy_gate_serves_pro_before_earlier_free():
    async def scenario():
        gate = PriorityGate("t", slots=1, pro_reserved=0, free_max_wait=5)
        log = []
        holder = asyncio.create_task(_job(gate, FREE, log, hold=0.1, name="holder"))
        await _settle()
        free = asyncio.create_task(_job(gate, FREE, log, name="free"))  # queued first
        await _settle()
        pro = asyncio.create_task(_job(gate, PRO, log, name="pro"))
        await asyncio.gather(holder, free, pro)
        return log

    assert [name for name, _ in run(scenario())] == ["holder", "pro", "free"]


def test_reserved_slot_lets_pro_skip_a_free_backlog():
    async def scenario():
        gate = PriorityGate("t", slots=2, pro_reserved=1, free_max_wait=5)
        log = []
        busy = asyncio.create_task(_job(gate, FREE, log, hold=0.3, name="free1"))
        await _settle()
        queued = asyncio.create_task(_job(gate, FREE, log, name="free2"))  # waits: slot 2 is Pro's
        await _settle()
        pro = asyncio.create_task(_job(gate, PRO, log, name="pro"))
        await asyncio.sleep(0.05)
        started = [name for name, _ in log]
        await asyncio.gather(busy, queued, pro)
        return started, log

    started, log = run(scenario())
    assert started == ["free1", "pro"]
    assert dict(log)["pro"] < 0.1


def test_free_request_is_served_within_max_wait_despite_pro_stream():
    async def scenario():
        gate = PriorityGate("t", slots=1, pro_reserved=0, free_max_wait=0.2)
        log = []
        holder = asyncio.create_task(_job(gate, PRO, log, hold=0.3, name="holder"))
        await _settle()
        free = asyncio.create_task(_job(gate, FREE, log, name="free"))
        pros = []
        for i in range(3):  # Pro requests keep arriving after the free one
            await asyncio.sleep(0.05)
            pros.append(asyncio.create_task(_job(gate, PRO, log, hold=0.1, name=f"pro{i}")))
        await asyncio.gather(holder, free, *pros)
        return log

    log = run(scenario())
    order = [name for name, _ in log]
    assert order[:2] == ["holder", "free"]  # promoted past its max wait, ahead of newer Pro
    assert dict(log)["free"] < 0.2 + 0.3


def test_free_request_takes_idle_reserved_slot_after_max_wait():
    async def scenario():
        gate = PriorityGate("t", slots=2, pro_reserved=1, free_max_wait=0.1)
        log = []
        busy = asyncio.create_task(_job(gate, FREE, log, hold=1.0, name="free1"))
        await _settle()
        await _job(gate, FREE, log, name="free2")  # no release needed
        busy.cancel()
        return log

    wait = dict(run(scenario()))["free2"]
    # Started around its max wait (Windows timers can fire ~15 ms early) and long
    # before the busy job (1 s) released anything.
    assert 0.08 <= wait < 0.5


def test_cancelled_waiter_frees_its_place():
    async def scenario():
        gate = PriorityGate("t", slots=1, pro_reserved=0, free_max_wait=5)
        log = []
        holder = asyncio.create_task(_job(gate, PRO, log, hold=0.05, name="holder"))
        await _settle()
        gone = asyncio.create_task(_job(gate, PRO, log, name="gone"))
        await _settle()
        gone.cancel()
        await asyncio.gather(holder, return_exceptions=True)
        await _job(gate, FREE, log, name="after")
        return gate, log

    gate, log = run(scenario())
    assert [name for name, _ in log] == ["holder", "after"]
    assert gate.in_use == 0 and gate.waiting == 0


def test_free_always_keeps_one_slot():
    gate = PriorityGate("t", slots=1, pro_reserved=3, free_max_wait=5)
    assert gate.pro_reserved == 0


# --- tier resolution ------------------------------------------------------------
class _Req:
    def __init__(self, token=None):
        self.headers = {"authorization": f"Bearer {token}"} if token else {}


@pytest.fixture
def jwt_env(monkeypatch):
    monkeypatch.setenv("SUPABASE_JWT_SECRET", SECRET)
    get_settings.cache_clear()
    priority._tier_cache.clear()
    yield
    priority._tier_cache.clear()
    get_settings.cache_clear()


def _token():
    return hs256_token(SECRET, str(uuid.uuid4()))


def test_tier_follows_server_side_pro_check(jwt_env, monkeypatch):
    monkeypatch.setattr(priority, "user_is_pro", lambda uid: True)
    assert run(resolve_tier(_Req(_token()))) == PRO
    monkeypatch.setattr(priority, "user_is_pro", lambda uid: False)
    assert run(resolve_tier(_Req(_token()))) == FREE


def test_signed_out_or_bad_token_is_free(jwt_env, monkeypatch):
    monkeypatch.setattr(priority, "user_is_pro", lambda uid: True)
    assert run(resolve_tier(_Req())) == FREE
    assert run(resolve_tier(_Req("not-a-jwt"))) == FREE


@pytest.mark.parametrize("failure", [
    HTTPException(503, "supabase not configured"),
    RuntimeError("network down"),
    "slow",
])
def test_failed_pro_lookup_is_free(jwt_env, monkeypatch, failure):
    monkeypatch.setattr(priority, "_TIER_LOOKUP_TIMEOUT_SEC", 0.05)

    def lookup(uid):
        if failure == "slow":
            time.sleep(0.3)
            return True
        raise failure

    monkeypatch.setattr(priority, "user_is_pro", lookup)
    assert run(resolve_tier(_Req(_token()))) == FREE


# --- metrics --------------------------------------------------------------------
def test_wait_is_logged_and_sent_without_user_identity(monkeypatch, caplog):
    sent = []
    monkeypatch.setattr(priority._sentry_metrics, "distribution",
                        lambda name, value, unit=None, attributes=None: sent.append((name, unit, attributes)))
    caplog.set_level(logging.INFO, logger="humming.priority")
    run(_job(PriorityGate("dsp", slots=1, pro_reserved=0, free_max_wait=5), PRO, []))

    assert sent == [("priority_queue.wait", "millisecond", {"queue": "dsp", "tier": PRO, "promoted": False})]
    line = next(r.getMessage() for r in caplog.records if r.name == "humming.priority")
    assert "queue=dsp tier=pro wait_ms=" in line


# --- route wiring ---------------------------------------------------------------
def _wav() -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(16000)
        w.writeframes(b"\x00\x00" * 1600)
    return buf.getvalue()


def test_analyze_goes_through_gate_and_survives_failed_pro_lookup(jwt_env, monkeypatch):
    seen = []
    real_slot = main_mod._dsp_gate.slot

    def spy(tier):
        seen.append(tier)
        return real_slot(tier)

    def broken_lookup(uid):
        raise HTTPException(503, "supabase not configured")

    def fake_analyze(raw, opts):
        raise HTTPException(422, "stub analysis")

    monkeypatch.setattr(main_mod._dsp_gate, "slot", spy)
    monkeypatch.setattr(priority, "user_is_pro", broken_lookup)
    monkeypatch.setattr(main_mod, "analyze_audio", fake_analyze)

    with TestClient(main_mod.app) as client:
        r = client.post("/analyze", files={"audio": ("a.wav", _wav(), "audio/wav")},
                        headers={"Authorization": f"Bearer {_token()}"})
    assert r.status_code == 422, r.text  # reached the analysis, not a 5xx from the queue
    assert seen == [FREE]
