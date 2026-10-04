"""reconcile_subscriptions must judge Apple rows by the subscription's latest
transaction, never the stored point-in-time (trial) transaction."""
import asyncio
from datetime import datetime, timedelta, timezone

import pytest

from app.routes import iap as iap_mod
from tests.iap_fixtures import ms
from tools import reconcile_subscriptions as rec


def _run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


def test_converted_trial_is_active_not_expired(monkeypatch):
    now = datetime.now(timezone.utc)
    seen = {}

    async def by_subscription(otid):
        seen["otid"] = otid
        return ({"transactionId": "222", "originalTransactionId": otid, "productId": "humtrack_pro_monthly_v2",
                 "expiresDate": ms(now + timedelta(days=25)), "purchaseDate": ms(now - timedelta(days=5))},
                {"autoRenewStatus": 1})

    async def by_transaction(_txid):
        raise AssertionError("must not look up the stored point-in-time transaction")

    monkeypatch.setattr(iap_mod, "_apple_lookup_subscription", by_subscription)
    monkeypatch.setattr(iap_mod, "_apple_lookup_transaction", by_transaction)
    row = {"store": "app_store", "status": "trial", "original_transaction_id": "111",
           "transaction_id": "111", "expires_at": (now - timedelta(days=5)).isoformat()}
    status, expires_at, tx = _run(rec._check_apple(row))
    assert seen["otid"] == "111"
    assert status == "active" and expires_at > now and tx["transactionId"] == "222"


def test_auto_renew_off_is_cancelled(monkeypatch):
    now = datetime.now(timezone.utc)

    async def by_subscription(otid):
        return ({"transactionId": "9", "originalTransactionId": otid, "expiresDate": ms(now + timedelta(days=3))},
                {"autoRenewStatus": 0})
    monkeypatch.setattr(iap_mod, "_apple_lookup_subscription", by_subscription)
    status, _, _ = _run(rec._check_apple({"store": "app_store", "original_transaction_id": "1"}))
    assert status == "cancelled"


def test_unbound_row_is_unaddressable():
    assert _run(rec._check_apple({"store": "app_store", "transaction_id": "5"})) == (None, None, None)
