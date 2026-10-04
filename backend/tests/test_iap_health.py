"""/health/iap-notifications — alert only when a notification is owed and late."""
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.routes import iap_health
from tests.iap_fixtures import FakeSupabase

NOW = datetime(2026, 10, 20, 12, 0, tzinfo=timezone.utc)
FIVE_DAYS = timedelta(days=5)


def iso(dt):
    return dt.isoformat()


def test_recent_notification_is_fresh():
    r = iap_health.assess_store(NOW - timedelta(days=1), [{"expires_at": iso(NOW - timedelta(days=2))}],
                                NOW, FIVE_DAYS)
    assert r["stale"] is False


def test_quiet_store_without_owed_events_does_not_alert():
    # Last notification 9 days ago, but nothing expired or started since.
    last = NOW - timedelta(days=9)
    subs = [{"expires_at": iso(NOW + timedelta(days=12)), "original_purchase_at": iso(last - timedelta(days=20))}]
    assert iap_health.assess_store(last, subs, NOW, FIVE_DAYS)["stale"] is False


def test_owed_renewal_without_notification_alerts_after_max_age():
    last = NOW - timedelta(days=6)
    owed = NOW - timedelta(days=3)
    r = iap_health.assess_store(last, [{"expires_at": iso(owed)}], NOW, FIVE_DAYS)
    assert r["stale"] is True and r["latest_event_owing_notification"] == iso(owed)


def test_owed_event_but_within_max_age_does_not_alert_yet():
    last = NOW - timedelta(days=4)
    r = iap_health.assess_store(last, [{"expires_at": iso(NOW - timedelta(days=2))}], NOW, FIVE_DAYS)
    assert r["stale"] is False


def test_new_purchase_counts_as_owed_event():
    last = NOW - timedelta(days=7)
    r = iap_health.assess_store(last, [{"original_purchase_at": iso(NOW - timedelta(days=1))}], NOW, FIVE_DAYS)
    assert r["stale"] is True


def test_event_inside_settle_window_is_not_yet_owed():
    last = NOW - timedelta(days=7)
    r = iap_health.assess_store(last, [{"expires_at": iso(NOW - timedelta(hours=1))}], NOW, FIVE_DAYS)
    assert r["stale"] is False


def test_never_received_with_owed_event_alerts():
    r = iap_health.assess_store(None, [{"expires_at": iso(NOW - timedelta(days=1))}], NOW, FIVE_DAYS)
    assert r["stale"] is True and r["last_notification_at"] is None


@pytest.fixture
def db(monkeypatch):
    fake = FakeSupabase()
    monkeypatch.setattr(iap_health, "require_supabase", lambda: fake)
    return fake


def test_endpoint_returns_503_naming_the_stale_store(db):
    now = datetime.now(timezone.utc)
    db.tables["iap_notifications"] = [
        {"notification_id": "a1", "store": "app_store", "received_at": iso(now - timedelta(hours=3))},
        {"notification_id": "p1", "store": "play_store", "received_at": iso(now - timedelta(days=8))},
        {"notification_id": "p0", "store": "play_store", "received_at": iso(now - timedelta(days=30))},
    ]
    db.tables["subscriptions"] = [
        {"user_id": "u1", "store": "app_store", "expires_at": iso(now - timedelta(days=1))},
        {"user_id": "u2", "store": "play_store", "expires_at": iso(now - timedelta(days=2))},
    ]
    from app.main import app
    with TestClient(app) as c:
        r = c.get("/health/iap-notifications")
    assert r.status_code == 503
    body = r.json()
    assert body["stale"] == ["play_store"] and body["stores"]["app_store"]["stale"] is False
    assert body["stores"]["play_store"]["age_days"] > 7.9


def test_endpoint_ok_when_nothing_is_owed(db):
    now = datetime.now(timezone.utc)
    db.tables["iap_notifications"] = [{"notification_id": "a1", "store": "app_store", "received_at": iso(now)}]
    db.tables["subscriptions"] = []
    from app.main import app
    with TestClient(app) as c:
        r = c.get("/health/iap-notifications")
    assert r.status_code == 200 and r.json()["ok"] is True
