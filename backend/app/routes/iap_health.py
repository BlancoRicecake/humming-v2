"""GET /health/iap-notifications — are store notifications still arriving?

App Store Server Notifications and Play RTDN were silently absent from launch
until 2026-10-05 (no URL in App Store Connect; the Pub/Sub subscription had
expired) and nobody noticed for months. A scheduled GitHub Actions job polls
this endpoint daily and fails — emailing the repo owner — on a 503.

A store is *stale* only when its newest notification is older than
``IAP_NOTIFICATION_MAX_AGE_DAYS`` **and** something has happened since that
must have produced a notification: a subscription reached its expiry
(renewal or lapse) or a new purchase started. A low-volume store going quiet
with nothing to report is not an outage, so it does not alert.

Kept separate from ``/health``: Fly's machine health check hits ``/health``
and must never depend on Supabase.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Iterable, Optional

import anyio
from fastapi import APIRouter, Response

from ..deps import _parse_ts, require_supabase
from ..settings import get_settings

router = APIRouter(tags=["health"])

STORES = ("app_store", "play_store")
# A notification for an expiry/renewal can lag the expiry itself; don't count
# an event as "owed" until this long after it happened.
EVENT_SETTLE = timedelta(hours=6)


def _iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.isoformat() if dt else None


def assess_store(last_notification_at: Optional[datetime], subscriptions: Iterable[dict],
                 now: datetime, max_age: timedelta) -> dict:
    """Pure staleness decision for one store (see module docstring)."""
    since = last_notification_at or datetime.min.replace(tzinfo=timezone.utc)
    settled = now - EVENT_SETTLE
    owed = None
    for row in subscriptions:
        for key in ("expires_at", "original_purchase_at"):
            ts = _parse_ts(row.get(key))
            if ts and since < ts <= settled and (owed is None or ts > owed):
                owed = ts
    age = (now - last_notification_at) if last_notification_at else None
    stale = owed is not None and (age is None or age > max_age)
    return {
        "last_notification_at": _iso(last_notification_at),
        "age_days": round(age.total_seconds() / 86400, 2) if age else None,
        "latest_event_owing_notification": _iso(owed),
        "stale": stale,
    }


def _collect(now: datetime, max_age: timedelta) -> dict:
    sb = require_supabase()
    stores = {}
    for store in STORES:
        last = (
            sb.table("iap_notifications").select("received_at").eq("store", store)
            .order("received_at", desc=True).limit(1).execute()
        )
        last_rows = getattr(last, "data", None) or []
        last_at = _parse_ts(last_rows[0]["received_at"]) if last_rows else None
        subs = (
            sb.table("subscriptions").select("expires_at,original_purchase_at")
            .eq("store", store).execute()
        )
        stores[store] = assess_store(last_at, getattr(subs, "data", None) or [], now, max_age)
    return stores


@router.get("/health/iap-notifications")
async def iap_notifications_health(response: Response) -> dict:
    # async + thread offload for the same reason as /health (Sentry wrapper)
    # and because the Supabase client is synchronous.
    max_age = timedelta(days=get_settings().iap_notification_max_age_days)
    now = datetime.now(timezone.utc)
    stores = await anyio.to_thread.run_sync(_collect, now, max_age)
    stale = [s for s, v in stores.items() if v["stale"]]
    if stale:
        response.status_code = 503
    return {"ok": not stale, "stale": stale, "max_age_days": max_age.days, "stores": stores}
