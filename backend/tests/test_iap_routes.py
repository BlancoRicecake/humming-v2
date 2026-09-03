"""/iap/verify, /iap/status, /iap/webhook/* against an in-memory Supabase.

Covers the 2026-09 hardening: forged receipts, transaction binding /
transfer, expiry-aware entitlement, webhook user mapping + idempotency +
ordering, Google pending payments, webhook auth.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app import deps
from app.routes import iap as iap_mod
from app.settings import get_settings

from tests.iap_fixtures import (
    FakeAppleChain, FakeSupabase, apple_tx, b64json, hs256_token, ms,
    self_signed_attacker_jws,
)

SECRET = "test-jwt-secret-please-ignore"
USER_A = str(uuid.uuid4())
USER_B = str(uuid.uuid4())


@pytest.fixture(scope="module")
def chain():
    return FakeAppleChain()


@pytest.fixture
def env(monkeypatch, chain):
    monkeypatch.setenv("SUPABASE_JWT_SECRET", SECRET)
    monkeypatch.setenv("APPLE_ROOT_CA_PEM", chain.root_pem)
    monkeypatch.setenv("APPLE_BUNDLE_ID", "com.example.humtrack")
    monkeypatch.setenv("IAP_WEBHOOK_SECRET", "hook-secret")
    monkeypatch.setenv("ENV", "production")
    monkeypatch.delenv("APPLE_ACCEPT_SANDBOX", raising=False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def db(monkeypatch, env):
    fake = FakeSupabase()
    monkeypatch.setattr(iap_mod, "require_supabase", lambda: fake)
    iap_mod._verify_hits.clear()
    return fake


@pytest.fixture
def client():
    from app.main import app
    with TestClient(app) as c:
        yield c


def auth(user=USER_A):
    return {"Authorization": f"Bearer {hs256_token(SECRET, user)}"}


def verify_apple(client, jws, user=USER_A):
    return client.post("/iap/verify", json={"store": "app_store", "receipt_data": jws}, headers=auth(user))


# --- /verify (Apple) --------------------------------------------------------
def test_forged_self_signed_receipt_rejected(client, db):
    r = verify_apple(client, self_signed_attacker_jws(apple_tx()))
    assert r.status_code == 400
    assert db.sub(USER_A) is None


def test_valid_receipt_grants_pro_and_binds_transaction(client, db, chain):
    r = verify_apple(client, chain.sign(apple_tx()))
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["status"] == "active" and j["pro"] is True
    row = db.sub(USER_A)
    assert row["original_transaction_id"] == "1000000000000001"
    assert row["environment"] == "Production"
    assert row["expires_at"]


def test_expired_receipt_is_not_pro(client, db, chain):
    r = verify_apple(client, chain.sign(apple_tx(expires_in_days=-1)))
    assert r.status_code == 200
    assert r.json()["status"] == "expired" and r.json()["pro"] is False


def test_revoked_receipt_is_not_pro(client, db, chain):
    tx = apple_tx(revocationDate=ms(datetime.now(timezone.utc)), revocationReason=0)
    r = verify_apple(client, chain.sign(tx))
    assert r.json()["status"] == "expired" and r.json()["pro"] is False


def test_trial_receipt(client, db, chain):
    r = verify_apple(client, chain.sign(apple_tx(offerType=1, expires_in_days=7)))
    assert r.json()["status"] == "trial" and r.json()["pro"] is True
    assert r.json()["trial_ends_at"]


def test_receipt_without_expiry_rejected(client, db, chain):
    tx = apple_tx(); tx.pop("expiresDate")
    assert verify_apple(client, chain.sign(tx)).status_code == 400


def test_bundle_mismatch_rejected(client, db, chain):
    assert verify_apple(client, chain.sign(apple_tx(bundleId="com.evil"))).status_code == 400


def test_sandbox_rejected_when_configured(client, db, chain, monkeypatch):
    monkeypatch.setenv("APPLE_ACCEPT_SANDBOX", "0"); get_settings.cache_clear()
    r = verify_apple(client, chain.sign(apple_tx(environment="Sandbox")))
    assert r.status_code == 400
    monkeypatch.setenv("APPLE_ACCEPT_SANDBOX", "1"); get_settings.cache_clear()
    r = verify_apple(client, chain.sign(apple_tx(environment="Sandbox")))
    assert r.status_code == 200 and db.sub(USER_A)["environment"] == "Sandbox"


def test_same_receipt_on_second_account_transfers_entitlement(client, db, chain):
    """One receipt → one Pro account. Re-verifying from a new Supabase account
    (same Apple ID, e.g. different sign-in provider) moves Pro over."""
    jws = chain.sign(apple_tx())
    assert verify_apple(client, jws, USER_A).status_code == 200
    assert verify_apple(client, jws, USER_B).status_code == 200
    a, b = db.sub(USER_A), db.sub(USER_B)
    assert b["status"] == "active" and b["original_transaction_id"] == "1000000000000001"
    assert a["status"] == "expired" and a["cancel_reason"] == "transferred"
    assert a.get("original_transaction_id") is None
    assert not deps.subscription_is_pro(a) and deps.subscription_is_pro(b)


def test_verify_requires_auth(client, db, chain):
    r = client.post("/iap/verify", json={"store": "app_store", "receipt_data": chain.sign(apple_tx())})
    assert r.status_code == 401


def test_verify_throttled_per_user(client, db, chain, monkeypatch):
    monkeypatch.setenv("IAP_VERIFY_PER_MINUTE", "2"); get_settings.cache_clear()
    jws = chain.sign(apple_tx())
    assert verify_apple(client, jws).status_code == 200
    assert verify_apple(client, jws).status_code == 200
    assert verify_apple(client, jws).status_code == 429


# --- /status ----------------------------------------------------------------
def test_status_no_subscription(client, db):
    r = client.get("/iap/status", headers=auth())
    assert r.status_code == 200 and r.json()["pro"] is False and r.json()["status"] is None


def test_status_cancelled_is_pro_until_expiry(client, db):
    future = (datetime.now(timezone.utc) + timedelta(days=3)).isoformat()
    past = (datetime.now(timezone.utc) - timedelta(days=3)).isoformat()
    db.tables["subscriptions"].append({"user_id": USER_A, "store": "app_store", "product_id": "p",
                                       "status": "cancelled", "expires_at": future})
    assert client.get("/iap/status", headers=auth()).json()["pro"] is True
    db.sub(USER_A)["expires_at"] = past
    assert client.get("/iap/status", headers=auth()).json()["pro"] is False


def test_status_active_but_past_expiry_is_not_pro(client, db):
    past = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
    db.tables["subscriptions"].append({"user_id": USER_A, "store": "play_store", "product_id": "p",
                                       "status": "active", "expires_at": past})
    j = client.get("/iap/status", headers=auth()).json()
    assert j["pro"] is False and j["status"] == "active"


# --- Apple webhook ----------------------------------------------------------
def notif(chain, tx, *, ntype="DID_RENEW", subtype=None, renewal=None, nid=None):
    payload = {
        "notificationType": ntype,
        "notificationUUID": nid or str(uuid.uuid4()),
        "signedDate": ms(datetime.now(timezone.utc)),
        "data": {
            "bundleId": "com.example.humtrack",
            "environment": tx.get("environment", "Production"),
            "signedTransactionInfo": chain.sign(tx),
        },
    }
    if subtype:
        payload["subtype"] = subtype
    if renewal is not None:
        payload["data"]["signedRenewalInfo"] = chain.sign(renewal)
    return {"signedPayload": chain.sign(payload)}


def test_apple_webhook_expires_bound_user(client, db, chain):
    assert verify_apple(client, chain.sign(apple_tx())).status_code == 200
    r = client.post("/iap/webhook/apple", json=notif(chain, apple_tx(expires_in_days=-1), ntype="EXPIRED"))
    assert r.status_code == 200, r.text
    assert db.sub(USER_A)["status"] == "expired"
    assert db.tables["iap_notifications"][0]["processed_at"]


def test_apple_webhook_refund_revokes(client, db, chain):
    verify_apple(client, chain.sign(apple_tx()))
    r = client.post("/iap/webhook/apple", json=notif(
        chain, apple_tx(revocationDate=ms(datetime.now(timezone.utc))), ntype="REFUND"))
    assert r.status_code == 200
    assert db.sub(USER_A)["status"] == "expired" and not deps.subscription_is_pro(db.sub(USER_A))


def test_apple_webhook_renewal_extends(client, db, chain):
    verify_apple(client, chain.sign(apple_tx(expires_in_days=1)))
    before = db.sub(USER_A)["expires_at"]
    r = client.post("/iap/webhook/apple", json=notif(chain, apple_tx(expires_in_days=31, txid="1000000000000003")))
    assert r.status_code == 200
    assert db.sub(USER_A)["expires_at"] > before and db.sub(USER_A)["transaction_id"] == "1000000000000003"


def test_apple_webhook_autorenew_off_is_cancelled_but_pro(client, db, chain):
    verify_apple(client, chain.sign(apple_tx()))
    r = client.post("/iap/webhook/apple", json=notif(
        chain, apple_tx(), ntype="DID_CHANGE_RENEWAL_STATUS", subtype="AUTO_RENEW_DISABLED",
        renewal={"autoRenewStatus": 0, "originalTransactionId": "1000000000000001"}))
    assert r.status_code == 200
    row = db.sub(USER_A)
    assert row["status"] == "cancelled" and deps.subscription_is_pro(row)


def test_apple_webhook_grace_period_keeps_pro(client, db, chain):
    verify_apple(client, chain.sign(apple_tx()))
    grace_end = datetime.now(timezone.utc) + timedelta(days=10)
    r = client.post("/iap/webhook/apple", json=notif(
        chain, apple_tx(expires_in_days=-1), ntype="DID_FAIL_TO_RENEW", subtype="GRACE_PERIOD",
        renewal={"autoRenewStatus": 1, "gracePeriodExpiresDate": ms(grace_end), "isInBillingRetryPeriod": True}))
    assert r.status_code == 200
    row = db.sub(USER_A)
    assert row["status"] == "active" and deps.subscription_is_pro(row)


def test_apple_webhook_unbound_transaction_falls_back_to_app_account_token(client, db, chain):
    r = client.post("/iap/webhook/apple", json=notif(chain, apple_tx(user_uuid=USER_B, orig="777")))
    assert r.status_code == 200 and r.json().get("status") == "active"
    assert db.sub(USER_B)["original_transaction_id"] == "777"


def test_apple_webhook_unknown_user_is_skipped_and_retryable(client, db, chain):
    r = client.post("/iap/webhook/apple", json=notif(chain, apple_tx(orig="999")))
    assert r.status_code == 200 and r.json()["skipped"] == "no_user"
    n = db.tables["iap_notifications"][0]
    assert n.get("processed_at") is None and n["error"] == "no_user"


def test_apple_webhook_duplicate_after_processing_short_circuits(client, db, chain):
    verify_apple(client, chain.sign(apple_tx()))
    body = notif(chain, apple_tx(expires_in_days=-1), ntype="EXPIRED", nid="dup-1")
    assert client.post("/iap/webhook/apple", json=body).json().get("status") == "expired"
    assert client.post("/iap/webhook/apple", json=body).json() == {"ok": True, "duplicate": True}


def test_apple_webhook_stale_event_ignored(client, db, chain):
    verify_apple(client, chain.sign(apple_tx()))
    old = datetime.now(timezone.utc) - timedelta(days=2)
    stale = notif(chain, apple_tx(expires_in_days=-1), ntype="EXPIRED")
    # backdate the outer signedDate below the verify's event time
    inner = {**apple_tx(expires_in_days=-1)}
    payload = {"notificationType": "EXPIRED", "notificationUUID": "stale-1", "signedDate": ms(old),
               "data": {"bundleId": "com.example.humtrack", "signedTransactionInfo": chain.sign(inner)}}
    r = client.post("/iap/webhook/apple", json={"signedPayload": chain.sign(payload)})
    assert r.status_code == 200 and r.json()["outcome"] == "stale"
    assert db.sub(USER_A)["status"] == "active"


def test_apple_webhook_forged_rejected(client, db, chain):
    verify_apple(client, chain.sign(apple_tx()))
    forged = self_signed_attacker_jws({"notificationType": "EXPIRED", "notificationUUID": "x",
                                       "data": {"signedTransactionInfo": self_signed_attacker_jws(apple_tx())}})
    assert client.post("/iap/webhook/apple", json={"signedPayload": forged}).status_code == 400
    assert db.sub(USER_A)["status"] == "active"


def test_apple_webhook_never_transfers_between_users(client, db, chain):
    """A notification for a bound transaction must not be redirected by an
    attacker-controlled appAccountToken — the binding wins."""
    verify_apple(client, chain.sign(apple_tx()), USER_A)
    r = client.post("/iap/webhook/apple", json=notif(chain, apple_tx(user_uuid=USER_B, expires_in_days=60)))
    assert r.status_code == 200
    assert db.sub(USER_B) is None and db.sub(USER_A)["status"] == "active"


# --- Google -----------------------------------------------------------------
@pytest.fixture
def google(monkeypatch):
    calls = {}

    async def fake_verify(product_id, token):
        calls["last"] = (product_id, token)
        return calls["resource"]

    monkeypatch.setattr(iap_mod, "_google_verify_subscription", fake_verify)
    return calls


def gsub(**over):
    now = datetime.now(timezone.utc)
    d = {"startTimeMillis": str(ms(now - timedelta(days=1))),
         "expiryTimeMillis": str(ms(now + timedelta(days=30))),
         "paymentState": 1, "orderId": "GPA.1", "acknowledgementState": 1}
    d.update(over)
    return d


def verify_google(client, user=USER_A, token="tok-1"):
    return client.post("/iap/verify", json={
        "store": "play_store",
        "receipt_data": '{"productId": "humtrack_pro_monthly_v2", "purchaseToken": "%s"}' % token,
    }, headers=auth(user))


def test_google_verify_active(client, db, google):
    google["resource"] = gsub()
    r = verify_google(client)
    assert r.status_code == 200 and r.json()["pro"] is True
    assert db.sub(USER_A)["purchase_token"] == "tok-1"


def test_google_pending_payment_not_granted(client, db, google):
    google["resource"] = gsub(paymentState=0)
    assert verify_google(client).status_code == 409
    assert db.sub(USER_A) is None


def test_google_missing_payment_state_is_expired(client, db, google):
    r = gsub(); r.pop("paymentState"); google["resource"] = r
    assert verify_google(client).json()["pro"] is False


def test_google_cancelled_still_pro_until_expiry(client, db, google):
    google["resource"] = gsub(cancelReason=0)
    j = verify_google(client).json()
    assert j["status"] == "cancelled" and j["pro"] is True


def google_push(token="tok-1", ntype=13, **over):
    data = {"version": "1.0", "packageName": "com.example.humtrack",
            "eventTimeMillis": str(ms(datetime.now(timezone.utc))),
            "subscriptionNotification": {"version": "1.0", "notificationType": ntype,
                                         "purchaseToken": token, "subscriptionId": "humtrack_pro_monthly_v2"}}
    data.update(over)
    return {"message": {"data": b64json(data), "messageId": str(uuid.uuid4())}, "subscription": "s"}


def test_google_webhook_requires_secret(client, db, google):
    google["resource"] = gsub()
    assert client.post("/iap/webhook/google", json=google_push()).status_code == 403
    assert client.post("/iap/webhook/google?token=wrong", json=google_push()).status_code == 403


def test_google_webhook_fails_closed_without_any_auth_config(client, db, google, monkeypatch):
    monkeypatch.delenv("IAP_WEBHOOK_SECRET"); monkeypatch.setenv("ENV", "dev"); get_settings.cache_clear()
    assert client.post("/iap/webhook/google", json=google_push()).status_code == 403


def test_google_webhook_expires_bound_user(client, db, google):
    google["resource"] = gsub()
    assert verify_google(client).status_code == 200
    google["resource"] = gsub(expiryTimeMillis=str(ms(datetime.now(timezone.utc) - timedelta(hours=1))))
    r = client.post("/iap/webhook/google?token=hook-secret", json=google_push(ntype=13))
    assert r.status_code == 200, r.text
    assert db.sub(USER_A)["status"] == "expired"


def test_google_webhook_plan_change_follows_linked_token(client, db, google):
    google["resource"] = gsub()
    verify_google(client, token="old-tok")
    google["resource"] = gsub(linkedPurchaseToken="old-tok", expiryTimeMillis=str(ms(datetime.now(timezone.utc) + timedelta(days=365))))
    r = client.post("/iap/webhook/google?token=hook-secret", json=google_push(token="new-tok"))
    assert r.status_code == 200 and r.json()["status"] == "active"
    assert db.sub(USER_A)["purchase_token"] == "new-tok"


def test_google_webhook_upstream_failure_leaves_notification_retryable(client, db, google, monkeypatch):
    async def boom(*_a):
        from fastapi import HTTPException
        raise HTTPException(502, "google verify failed")
    monkeypatch.setattr(iap_mod, "_google_verify_subscription", boom)
    body = google_push()
    assert client.post("/iap/webhook/google?token=hook-secret", json=body).status_code == 502
    n = db.tables["iap_notifications"][0]
    assert n.get("processed_at") is None
    # redelivery is processed, not short-circuited as a duplicate
    google["resource"] = gsub()
    monkeypatch.setattr(iap_mod, "_google_verify_subscription", google_fixture_verify(google))
    r = client.post("/iap/webhook/google?token=hook-secret", json=body)
    assert r.status_code == 200 and "duplicate" not in r.json()


def google_fixture_verify(calls):
    async def fake_verify(product_id, token):
        return calls["resource"]
    return fake_verify
