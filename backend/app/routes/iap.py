"""IAP — Apple App Store + Google Play subscription verification + webhooks.

Endpoints
---------
POST /iap/verify              Auth'd. Client posts a receipt → backend talks
                              to Apple/Google → upserts `subscriptions` row.
GET  /iap/status              Auth'd. Server-side entitlement verdict —
                              the ONLY thing the client should trust.
POST /iap/webhook/apple       Apple Server Notifications V2 (signed JWS).
POST /iap/webhook/google      Google Real-time Developer Notifications
                              (pub/sub push, shared secret / OIDC).

Trust model
-----------
* Apple JWS payloads are accepted only when their ``x5c`` chain validates
  up to the pinned Apple Root CA (``app.apple_jws``). There is no
  unverified fallback.
* A subscription row is **bound to the store transaction** (Apple
  ``originalTransactionId`` / Google ``purchaseToken``, unique per store —
  migration 002). Webhooks resolve the user through that binding, so
  renewals / expiries / refunds land on the right row even though the
  client never told the store who the user is. If a receipt that is
  already bound to account A is verified by account B (same Apple ID,
  new Supabase account), the entitlement is *transferred*: A is expired,
  B becomes active — one receipt, one Pro account at a time.
* Out-of-order events are ignored via ``last_event_at`` (Apple
  ``signedDate`` / Google ``eventTimeMillis``).

Idempotency
-----------
Each notification carries a unique id (Apple ``notificationUUID``, Google
Pub/Sub ``message.messageId``). We persist it in ``iap_notifications`` and
mark ``processed_at`` only after the subscription row was updated, so a
transient failure (DB hiccup, store API 5xx) leaves the row unprocessed and
the store's redelivery is handled instead of short-circuited.

Crypto details intentionally kept dependency-light: pyjwt + cryptography +
httpx against the official Apple / Google REST endpoints.
"""
from __future__ import annotations

import base64
import json
import logging
import secrets
import threading
import time
from collections import deque
from datetime import datetime, timezone
from typing import Any, Dict, Optional, Tuple

import anyio
import httpx
from fastapi import APIRouter, Depends, HTTPException, Request

from ..apple_jws import AppleJWSError, decode_apple_jws
from ..deps import (
    CurrentUser,
    fetch_subscription,
    get_current_user,
    require_supabase,
    subscription_is_pro,
)
from ..models import IapStatusResponse, IapVerifyRequest, IapVerifyResponse, SubStatus
from ..settings import get_settings

logger = logging.getLogger("humming.iap")
router = APIRouter(prefix="/iap", tags=["iap"])

# Apple App Store Server API endpoints.
APPLE_PROD = "https://api.storekit.itunes.apple.com"
APPLE_SANDBOX = "https://api.storekit-sandbox.itunes.apple.com"

# Apple notification types that end the entitlement regardless of expiresDate.
_APPLE_TERMINAL = {"EXPIRED", "REVOKE", "REFUND", "GRACE_PERIOD_EXPIRED", "REFUND_DECLINED"}


# --- helpers ----------------------------------------------------------------
def _ms_to_dt(ms: Optional[int]) -> Optional[datetime]:
    if not ms:
        return None
    try:
        return datetime.fromtimestamp(int(ms) / 1000.0, tz=timezone.utc)
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: Optional[datetime]) -> Optional[str]:
    return dt.isoformat() if dt else None


def _parse_ts(v) -> Optional[datetime]:
    if not v:
        return None
    if isinstance(v, datetime):
        return v if v.tzinfo else v.replace(tzinfo=timezone.utc)
    try:
        dt = datetime.fromisoformat(str(v).replace("Z", "+00:00"))
        return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def _rows(res) -> list:
    return list(getattr(res, "data", None) or [])


# --- per-user throttle for /verify (outbound store call per request) --------
_verify_hits: Dict[str, deque] = {}
_verify_lock = threading.Lock()


def _throttle_verify(user_id: str, per_minute: int) -> None:
    if per_minute <= 0:
        return
    now = time.monotonic()
    with _verify_lock:
        q = _verify_hits.setdefault(user_id, deque())
        while q and now - q[0] > 60.0:
            q.popleft()
        if len(q) >= per_minute:
            raise HTTPException(429, "too many verify requests")
        q.append(now)
        if len(_verify_hits) > 10_000:  # bound memory on a busy day
            for k in [k for k, v in _verify_hits.items() if not v or now - v[-1] > 60.0]:
                _verify_hits.pop(k, None)


# --- notification idempotency -----------------------------------------------
def _record_notification(sb, notification_id: str, store: str, payload: dict) -> str:
    """Register a notification. Returns ``"new"``, ``"retry"`` (seen before
    but never finished processing) or ``"duplicate"`` (already processed)."""
    try:
        sb.table("iap_notifications").insert({
            "notification_id": notification_id,
            "store": store,
            "payload": payload,
        }).execute()
        return "new"
    except Exception as e:
        msg = str(e).lower()
        if not ("duplicate" in msg or "unique" in msg or "23505" in msg):
            logger.exception("notification record failed")
            raise
    res = (
        sb.table("iap_notifications")
        .select("processed_at")
        .eq("notification_id", notification_id)
        .limit(1)
        .execute()
    )
    rows = _rows(res)
    if rows and rows[0].get("processed_at"):
        return "duplicate"
    return "retry"


def _mark_notification(sb, notification_id: str, *, error: Optional[str] = None) -> None:
    try:
        patch: Dict[str, Any] = {"error": error}
        if error is None:
            patch["processed_at"] = _now_utc().isoformat()
        sb.table("iap_notifications").update(patch).eq("notification_id", notification_id).execute()
    except Exception:
        logger.exception("notification mark failed (%s)", notification_id)


# --- subscription persistence ------------------------------------------------
# Columns added by migration 002. Used to degrade gracefully (with a loud log)
# if the code is deployed before the migration runs.
_V2_COLUMNS = frozenset({
    "original_transaction_id", "transaction_id", "purchase_token",
    "environment", "last_event_at",
})


def _is_missing_column_error(e: Exception) -> bool:
    msg = str(e).lower()
    # PostgREST: PGRST204 "Could not find the 'x' column"; Postgres: 42703.
    return ("pgrst204" in msg or "42703" in msg
            or ("column" in msg and ("does not exist" in msg or "could not find" in msg)))


def _find_by_binding(sb, store: str, column: str, value: Optional[str]) -> Optional[dict]:
    if not value:
        return None
    try:
        res = (
            sb.table("subscriptions")
            .select("*")
            .eq("store", store)
            .eq(column, value)
            .limit(1)
            .execute()
        )
    except Exception as e:
        if not _is_missing_column_error(e):
            raise
        logger.error("subscriptions.%s missing — apply migration 002 (%s)", column, e)
        return None
    rows = _rows(res)
    return rows[0] if rows else None


def _release_binding(sb, row: dict, *, reason: str) -> None:
    """Expire ``row`` and drop its store binding so the same transaction can
    be bound to another user without violating the unique index."""
    sb.table("subscriptions").update({
        "status": "expired",
        "cancel_reason": reason,
        "original_transaction_id": None,
        "purchase_token": None,
        "updated_at": _now_utc().isoformat(),
    }).eq("user_id", row["user_id"]).execute()


def _upsert_subscription(sb, *, user_id: str, store: str, product_id: str,
                        status: SubStatus, expires_at: Optional[datetime],
                        trial_ends_at: Optional[datetime] = None,
                        original_purchase_at: Optional[datetime] = None,
                        last_renewed_at: Optional[datetime] = None,
                        cancel_reason: Optional[str] = None,
                        original_transaction_id: Optional[str] = None,
                        transaction_id: Optional[str] = None,
                        purchase_token: Optional[str] = None,
                        environment: Optional[str] = None,
                        event_at: Optional[datetime] = None,
                        allow_transfer: bool = True) -> Tuple[dict, str]:
    """Write the subscription row for ``user_id``.

    Returns ``(row, outcome)`` with outcome one of ``"written"``,
    ``"stale"`` (an event newer than ``event_at`` was already applied) or
    ``"transferred"`` (the binding was moved from another user).
    """
    outcome = "written"
    binding_col = "original_transaction_id" if store == "app_store" else "purchase_token"
    binding_val = original_transaction_id if store == "app_store" else purchase_token

    # Receipt already bound to a *different* user → transfer (or refuse).
    other = _find_by_binding(sb, store, binding_col, binding_val)
    if other and other.get("user_id") != user_id:
        if not allow_transfer:
            raise HTTPException(409, "receipt is linked to another account")
        logger.warning("iap: transferring %s %s from user %s to %s",
                       store, binding_col, other.get("user_id"), user_id)
        _release_binding(sb, other, reason="transferred")
        outcome = "transferred"

    # Out-of-order guard: never let an older event overwrite a newer one.
    existing = fetch_subscription(sb, user_id)
    if existing and event_at:
        prev = _parse_ts(existing.get("last_event_at"))
        if prev and prev > event_at:
            logger.info("iap: stale event for user %s (%s < %s) — ignored",
                        user_id, event_at.isoformat(), prev.isoformat())
            return existing, "stale"

    row: Dict[str, Any] = {
        "user_id": user_id,
        "store": store,
        "product_id": product_id,
        "status": status,
        "expires_at": _iso(expires_at),
        "trial_ends_at": _iso(trial_ends_at),
        "original_purchase_at": _iso(original_purchase_at),
        "last_renewed_at": _iso(last_renewed_at),
        "cancel_reason": cancel_reason,
        "original_transaction_id": original_transaction_id,
        "transaction_id": transaction_id,
        "purchase_token": purchase_token,
        "environment": environment,
        "last_event_at": _iso(event_at),
        "updated_at": _now_utc().isoformat(),
    }
    # Strip Nones so we don't clobber existing values on partial updates —
    # except the fields that must always be (re)written.
    always = {"status", "user_id", "store", "product_id", "cancel_reason", "updated_at"}
    row = {k: v for k, v in row.items() if v is not None or k in always}
    try:
        sb.table("subscriptions").upsert(row, on_conflict="user_id").execute()
    except Exception as e:
        if not _is_missing_column_error(e):
            raise
        # Migration 002 has not been applied to this database yet. Rather than
        # failing every purchase (which is what a deploy-before-migrate would
        # otherwise do to paying users), write the pre-002 column set and shout
        # in the logs. The binding columns are what webhooks need, so run
        # `supabase db push` and the next verify backfills them.
        logger.error(
            "subscriptions is missing the 002 columns — writing legacy fields only. "
            "Apply backend/migrations/002_iap_transaction_binding.sql now: %s", e)
        legacy = {k: v for k, v in row.items() if k not in _V2_COLUMNS}
        sb.table("subscriptions").upsert(legacy, on_conflict="user_id").execute()
        return legacy, outcome
    return row, outcome


# --- Apple ------------------------------------------------------------------
def _apple_jwt() -> str:
    """Build the ES256 JWT used to authenticate with Apple's App Store Server
    API. ``iss`` is the Team ID (NOT the ASC API issuer UUID), ``kid`` is the
    subscription key id, ``aud`` is the literal ``appstoreconnect-v1``.

    See https://developer.apple.com/documentation/appstoreserverapi/generating_tokens_for_api_requests.
    """
    import jwt as pyjwt
    s = get_settings()
    kid = s.resolve_apple_key_id()
    iss = s.resolve_apple_issuer()
    pk = s.resolve_apple_private_key()
    if not (kid and iss and pk and s.apple_bundle_id):
        raise HTTPException(503, "Apple StoreKit not configured (team_id/key_id/private_key/bundle_id required)")
    now = int(time.time())
    headers = {"alg": "ES256", "kid": kid, "typ": "JWT"}
    payload = {
        "iss": iss,
        "iat": now,
        "exp": now + 60 * 30,  # 30 min — Apple allows up to 60
        "aud": "appstoreconnect-v1",
        "bid": s.apple_bundle_id,
    }
    return pyjwt.encode(payload, pk, algorithm="ES256", headers=headers)


async def _apple_lookup_transaction(transaction_id: str) -> dict:
    """Call App Store Server API. Try production first, fall back to sandbox
    on 404 (TransactionIdNotFoundError) per Apple's recommended strategy."""
    token = _apple_jwt()
    headers = {"Authorization": f"Bearer {token}"}
    s = get_settings()
    order = (APPLE_PROD, APPLE_SANDBOX) if s.apple_environment != "sandbox" else (APPLE_SANDBOX, APPLE_PROD)
    last_status: int = 0
    last_body: str = ""
    async with httpx.AsyncClient(timeout=15.0) as client:
        for base in order:
            url = f"{base}/inApps/v1/transactions/{transaction_id}"
            r = await client.get(url, headers=headers)
            if r.status_code == 200:
                return r.json()
            last_status, last_body = r.status_code, r.text[:200]
            if r.status_code not in (401, 404):
                break
    logger.warning("Apple lookup %s failed: %s %s", transaction_id, last_status, last_body)
    raise HTTPException(502 if last_status >= 500 else 400, "apple verify failed")


def _trusted_roots():
    from .. import apple_jws as _aj
    s = get_settings()
    if s.apple_root_ca_pem:
        return _aj._load_trusted_roots([s.apple_root_ca_pem])
    return None  # module default (Apple Root CA G3)


def _decode_apple_jws_verified(jws_str: str) -> dict:
    """Decode + verify an Apple signed JWS against the pinned Apple root.

    Raises 400 on any verification failure. Never decodes unverified.
    """
    try:
        return decode_apple_jws(jws_str, trusted_roots=_trusted_roots())
    except AppleJWSError as e:
        logger.warning("Apple JWS rejected: %s", e)
        raise HTTPException(400, "apple jws signature invalid")


def _apple_check_environment(tx: dict) -> str:
    """Return the transaction environment; refuse sandbox when configured to."""
    s = get_settings()
    env = str(tx.get("environment") or "")
    if env.lower() == "sandbox" and s.is_production and not s.apple_accept_sandbox:
        raise HTTPException(400, "apple: sandbox transactions are not accepted")
    return env or "Production"


def _apple_status(tx: dict, renewal: Optional[dict] = None,
                  notif_type: Optional[str] = None,
                  now: Optional[datetime] = None) -> Tuple[SubStatus, Optional[datetime]]:
    """Derive (status, effective expiry) from a transaction (+ renewal info)."""
    now = now or _now_utc()
    renewal = renewal or {}
    expires_at = _ms_to_dt(tx.get("expiresDate"))

    if tx.get("revocationDate") is not None:
        return "expired", expires_at
    if notif_type in _APPLE_TERMINAL:
        return "expired", expires_at

    grace_end = _ms_to_dt(renewal.get("gracePeriodExpiresDate"))
    if expires_at and expires_at < now:
        if grace_end and grace_end > now:
            # Billing grace period (configured in ASC): keep access, extend
            # the effective expiry so the client's predicate holds.
            return "active", grace_end
        return "expired", expires_at

    if renewal.get("autoRenewStatus") == 0:
        return "cancelled", expires_at
    if tx.get("offerType") == 1:  # 1 = introductory offer (free trial)
        return "trial", expires_at
    return "active", expires_at


async def _apple_verify_receipt_legacy(receipt_b64: str) -> Optional[dict]:
    """Legacy StoreKit 1 verifyReceipt fallback using shared secret.

    Tries production then sandbox per Apple's docs.
    """
    s = get_settings()
    if not s.apple_shared_secret:
        return None
    body = {"receipt-data": receipt_b64, "password": s.apple_shared_secret,
            "exclude-old-transactions": True}
    async with httpx.AsyncClient(timeout=15.0) as client:
        for base in ("https://buy.itunes.apple.com/verifyReceipt",
                     "https://sandbox.itunes.apple.com/verifyReceipt"):
            r = await client.post(base, json=body)
            if r.status_code != 200:
                continue
            data = r.json()
            status = data.get("status")
            if status == 0:
                return data
            # 21007 = sandbox receipt sent to prod → retry sandbox
            if status == 21007 and base.startswith("https://buy"):
                continue
            logger.warning("verifyReceipt status=%s", status)
            return None
    return None


# --- Google -----------------------------------------------------------------
def _google_access_token_sync() -> str:
    """Mint a short-lived OAuth2 token for androidpublisher scope using the
    service account JSON in settings. Blocking (google-auth) — run off-loop."""
    s = get_settings()
    if not s.google_service_account_json:
        raise HTTPException(503, "Google service account not configured")
    try:
        from google.oauth2 import service_account
        from google.auth.transport.requests import Request as GAuthRequest
    except ImportError as e:
        raise HTTPException(500, f"google-auth not installed: {e}")
    info = json.loads(s.google_service_account_json)
    creds = service_account.Credentials.from_service_account_info(
        info, scopes=["https://www.googleapis.com/auth/androidpublisher"]
    )
    creds.refresh(GAuthRequest())
    return creds.token


async def _google_access_token() -> str:
    return await anyio.to_thread.run_sync(_google_access_token_sync)


async def _google_verify_subscription(product_id: str, purchase_token: str) -> dict:
    s = get_settings()
    if not s.google_package_name:
        raise HTTPException(503, "Google package name not configured")
    token = await _google_access_token()
    url = (
        f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
        f"{s.google_package_name}/purchases/subscriptions/{product_id}/tokens/{purchase_token}"
    )
    async with httpx.AsyncClient(timeout=15.0) as client:
        r = await client.get(url, headers={"Authorization": f"Bearer {token}"})
        if r.status_code != 200:
            logger.warning("Google verify %s → %s %s", product_id, r.status_code, r.text[:200])
            raise HTTPException(502 if r.status_code >= 500 else 400, "google verify failed")
        return r.json()


def _google_status(sub: dict, now: Optional[datetime] = None) -> Tuple[SubStatus, Optional[datetime]]:
    """Map Google subscription resource → our SubStatus.

    paymentState: 0 = pending, 1 = paid, 2 = free trial, 3 = pending deferred upgrade.
    cancelReason: 0 = user cancelled, 1 = system, 2 = replaced, 3 = developer.
    expiryTimeMillis: ms epoch.

    ``paymentState`` absent means the subscription is no longer active
    (Google omits it for expired/cancelled-and-lapsed subscriptions).
    """
    now = now or _now_utc()
    expiry = _ms_to_dt(int(sub.get("expiryTimeMillis") or 0) or None)
    pay = sub.get("paymentState")
    cancel = sub.get("cancelReason") is not None
    if expiry and expiry < now:
        return "expired", expiry
    if pay is None or pay == 0:
        # Not (yet) paid: pending payment is NOT an entitlement.
        return "expired", expiry
    if pay == 2:
        return "trial", expiry
    if cancel:
        return "cancelled", expiry
    return "active", expiry


# --- routes -----------------------------------------------------------------
@router.get("/status", response_model=IapStatusResponse)
async def status(user: CurrentUser = Depends(get_current_user)):
    """Server-side entitlement verdict. The client must use ``pro`` from here
    (not the raw ``status`` string) to gate Pro features."""
    sb = require_supabase()
    try:
        row = fetch_subscription(sb, user.id)
    except Exception:
        logger.exception("subscription lookup failed")
        raise HTTPException(500, "subscription lookup failed")
    now = _now_utc()
    return IapStatusResponse(
        pro=subscription_is_pro(row, now),
        status=(row or {}).get("status"),
        product_id=(row or {}).get("product_id"),
        store=(row or {}).get("store"),
        expires_at=_parse_ts((row or {}).get("expires_at")),
        trial_ends_at=_parse_ts((row or {}).get("trial_ends_at")),
        environment=(row or {}).get("environment"),
        server_time=now,
    )


@router.post("/verify", response_model=IapVerifyResponse)
async def verify(payload: IapVerifyRequest, user: CurrentUser = Depends(get_current_user)):
    """Validate a fresh receipt from the client and persist subscription state.

    For Apple, ``receipt_data`` is the transactionId (StoreKit 2) or the
    signed JWS. For Google, it's a JSON string ``{"productId": "...",
    "purchaseToken": "..."}``.
    """
    sb = require_supabase()
    s = get_settings()
    _throttle_verify(user.id, s.iap_verify_per_minute)

    if payload.store == "app_store":
        raw = payload.receipt_data.strip()
        tx: dict = {}
        # Heuristic: StoreKit 2 transactionId is short numeric; legacy receipt
        # is a long base64 blob (>200 chars and no dots).
        looks_like_jws = raw.count(".") == 2
        looks_like_txid = raw.isdigit() and len(raw) <= 30
        logger.info("iap verify user=%s len=%d jws=%s txid=%s",
                    user.id, len(raw), looks_like_jws, looks_like_txid)
        legacy_path = False
        if looks_like_jws:
            # StoreKit 2 JWS — verified locally against Apple's pinned root.
            tx = _decode_apple_jws_verified(raw)
        elif looks_like_txid:
            info = await _apple_lookup_transaction(raw)
            signed = info.get("signedTransactionInfo")
            if not signed:
                raise HTTPException(400, "apple: no signedTransactionInfo")
            tx = _decode_apple_jws_verified(signed)
        else:
            legacy = await _apple_verify_receipt_legacy(raw)
            if not legacy:
                raise HTTPException(400, "apple: legacy verifyReceipt failed")
            latest = (legacy.get("latest_receipt_info") or [{}])[-1]
            legacy_path = True
            tx = {
                "productId": latest.get("product_id"),
                "bundleId": (legacy.get("receipt") or {}).get("bundle_id"),
                "expiresDate": int(latest.get("expires_date_ms", 0)) or None,
                "originalPurchaseDate": int(latest.get("original_purchase_date_ms", 0)) or None,
                "purchaseDate": int(latest.get("purchase_date_ms", 0)) or None,
                "offerType": 1 if latest.get("is_trial_period") == "true" else 0,
                "originalTransactionId": latest.get("original_transaction_id"),
                "transactionId": latest.get("transaction_id"),
                "environment": (legacy.get("environment") or "Production"),
                "revocationDate": (int(latest["cancellation_date_ms"])
                                   if latest.get("cancellation_date_ms") else None),
            }

        if s.apple_bundle_id and tx.get("bundleId") and tx["bundleId"] != s.apple_bundle_id:
            raise HTTPException(400, "apple: bundleId mismatch")
        environment = _apple_check_environment(tx)

        product_id = tx.get("productId") or payload.product_id or ""
        allowed = s.accepted_apple_product_ids()
        if allowed and product_id and product_id not in allowed:
            raise HTTPException(400, "apple: unknown productId")
        if tx.get("type") not in (None, "Auto-Renewable Subscription"):
            raise HTTPException(400, "apple: not a subscription transaction")
        if not tx.get("expiresDate"):
            raise HTTPException(400, "apple: transaction has no expiry")
        orig_tx = str(tx.get("originalTransactionId") or "") or None
        if not orig_tx and not legacy_path:
            raise HTTPException(400, "apple: transaction has no originalTransactionId")

        status_v, expires_at = _apple_status(tx)
        original = _ms_to_dt(tx.get("originalPurchaseDate"))
        purchase = _ms_to_dt(tx.get("purchaseDate"))
        is_trial = status_v == "trial"
        _upsert_subscription(
            sb, user_id=user.id, store="app_store", product_id=product_id,
            status=status_v, expires_at=expires_at,
            trial_ends_at=expires_at if is_trial else None,
            original_purchase_at=original, last_renewed_at=purchase,
            original_transaction_id=orig_tx,
            transaction_id=str(tx.get("transactionId") or "") or None,
            environment=environment,
            event_at=_ms_to_dt(tx.get("signedDate")),
        )
        return IapVerifyResponse(
            status=status_v, product_id=product_id, expires_at=expires_at,
            trial_ends_at=expires_at if is_trial else None, store="app_store",
            pro=subscription_is_pro({"status": status_v, "expires_at": expires_at}),
        )

    # Google
    try:
        body = json.loads(payload.receipt_data)
    except Exception:
        raise HTTPException(400, "google: receipt_data must be JSON with productId+purchaseToken")
    product_id = body.get("productId") or payload.product_id or ""
    purchase_token = body.get("purchaseToken")
    if not (product_id and purchase_token):
        raise HTTPException(400, "google: productId/purchaseToken required")
    sub = await _google_verify_subscription(product_id, purchase_token)
    if sub.get("paymentState") == 0:
        # Pending (e.g. deferred payment / SCA). Nothing to grant yet; the
        # RTDN webhook will land once payment completes.
        raise HTTPException(409, "google: payment pending")
    status_v, expires_at = _google_status(sub)
    trial_end = expires_at if sub.get("paymentState") == 2 else None
    original = _ms_to_dt(int(sub.get("startTimeMillis") or 0) or None)
    cancel_reason = str(sub.get("cancelReason")) if sub.get("cancelReason") is not None else None
    _upsert_subscription(
        sb, user_id=user.id, store="play_store", product_id=product_id,
        status=status_v, expires_at=expires_at, trial_ends_at=trial_end,
        original_purchase_at=original, last_renewed_at=original,
        cancel_reason=cancel_reason,
        purchase_token=str(purchase_token),
        transaction_id=str(sub.get("orderId") or "") or None,
    )
    return IapVerifyResponse(
        status=status_v, product_id=product_id, expires_at=expires_at,
        trial_ends_at=trial_end, store="play_store",
        pro=subscription_is_pro({"status": status_v, "expires_at": expires_at}),
    )


# --- webhooks ---------------------------------------------------------------
@router.post("/webhook/apple")
async def apple_webhook(request: Request):
    """Apple Server Notifications V2.

    Body: ``{"signedPayload": "<JWS>"}``. The outer payload and the inner
    ``signedTransactionInfo`` / ``signedRenewalInfo`` are each chain-verified.
    The user is resolved from the transaction's ``originalTransactionId``
    binding (fallback: ``appAccountToken``).
    """
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(400, "invalid json")
    signed = (body or {}).get("signedPayload")
    if not signed:
        raise HTTPException(400, "missing signedPayload")
    payload = _decode_apple_jws_verified(signed)
    notif_id = payload.get("notificationUUID")
    notif_type = payload.get("notificationType")
    subtype = payload.get("subtype")
    if not notif_id:
        raise HTTPException(400, "missing notificationUUID")

    s = get_settings()
    data = payload.get("data") or {}
    pl_bundle = data.get("bundleId")
    if s.apple_bundle_id and pl_bundle and pl_bundle != s.apple_bundle_id:
        raise HTTPException(400, "apple webhook: bundleId mismatch")

    sb = require_supabase()
    state = _record_notification(sb, notif_id, "app_store", payload)
    if state == "duplicate":
        return {"ok": True, "duplicate": True}

    signed_tx = data.get("signedTransactionInfo")
    signed_renew = data.get("signedRenewalInfo")
    if not signed_tx:
        logger.info("apple webhook %s/%s without signedTransactionInfo", notif_type, subtype)
        _mark_notification(sb, notif_id)
        return {"ok": True}

    try:
        tx = _decode_apple_jws_verified(signed_tx)
        renew = _decode_apple_jws_verified(signed_renew) if signed_renew else {}
        environment = _apple_check_environment(tx)

        orig_tx = str(tx.get("originalTransactionId") or "") or None
        bound = _find_by_binding(sb, "app_store", "original_transaction_id", orig_tx)
        user_id = (bound or {}).get("user_id") or tx.get("appAccountToken")
        if not user_id:
            logger.warning("apple webhook %s: originalTransactionId %s not bound to a user "
                           "(user has not re-verified since 002) — skipped", notif_type, orig_tx)
            _mark_notification(sb, notif_id, error="no_user")
            return {"ok": True, "skipped": "no_user"}

        status_v, expires_at = _apple_status(tx, renew, notif_type)
        row, outcome = _upsert_subscription(
            sb, user_id=user_id, store="app_store",
            product_id=tx.get("productId") or (bound or {}).get("product_id") or "",
            status=status_v, expires_at=expires_at,
            trial_ends_at=expires_at if status_v == "trial" else None,
            last_renewed_at=_ms_to_dt(tx.get("purchaseDate")),
            cancel_reason=(f"{notif_type}/{subtype}" if subtype else notif_type)
            if status_v in ("cancelled", "expired") else None,
            original_transaction_id=orig_tx,
            transaction_id=str(tx.get("transactionId") or "") or None,
            environment=environment,
            event_at=_ms_to_dt(payload.get("signedDate")) or _ms_to_dt(tx.get("signedDate")),
            allow_transfer=False,
        )
    except HTTPException as e:
        _mark_notification(sb, notif_id, error=f"{e.status_code}: {e.detail}")
        raise
    except Exception as e:
        _mark_notification(sb, notif_id, error=str(e)[:500])
        logger.exception("apple webhook processing failed")
        raise HTTPException(500, "webhook processing failed")
    _mark_notification(sb, notif_id)
    return {"ok": True, "status": status_v, "outcome": outcome}


def _verify_pubsub_oidc(token: str, audience: str, expected_email: Optional[str]) -> None:
    """Verify a Pub/Sub push OIDC bearer token (blocking — run off-loop).

    Validates the Google signature, expiry, and audience. When
    ``expected_email`` is set, also pins the authorized service account.
    Raises HTTPException(403) on any failure.
    """
    try:
        from google.oauth2 import id_token as google_id_token
        from google.auth.transport import requests as google_auth_requests
    except ImportError as e:  # pragma: no cover — google-auth is in requirements
        raise HTTPException(500, f"google-auth not installed: {e}")
    try:
        claims = google_id_token.verify_oauth2_token(
            token, google_auth_requests.Request(), audience=audience
        )
    except Exception as e:
        logger.warning("google webhook OIDC verify failed: %s", e)
        raise HTTPException(403, "invalid OIDC token")
    if expected_email:
        if not claims.get("email_verified", False):
            raise HTTPException(403, "OIDC email not verified")
        if claims.get("email") != expected_email:
            logger.warning("google webhook OIDC email mismatch: %s", claims.get("email"))
            raise HTTPException(403, "unauthorized service account")


async def _authenticate_google_webhook(request: Request) -> None:
    """Authenticate a Pub/Sub push before any processing. Raises on failure.

    Accepts a request that satisfies any configured mechanism:
    - ``IAP_WEBHOOK_SECRET`` — shared secret via ``?token=`` or the
      ``X-Webhook-Token`` header (constant-time compared).
    - ``GOOGLE_PUBSUB_AUDIENCE`` — the SA-signed OIDC bearer token Pub/Sub
      attaches (optionally pinned to ``GOOGLE_PUBSUB_SA_EMAIL``).

    Fails CLOSED when neither is configured — in every environment. The
    endpoint mutates subscription state, so an open webhook is an
    account-takeover vector; local testing sets IAP_WEBHOOK_SECRET.
    """
    s = get_settings()
    secret = s.iap_webhook_secret
    audience = s.google_pubsub_audience

    if not secret and not audience:
        logger.error(
            "google webhook BLOCKED: configure IAP_WEBHOOK_SECRET or "
            "GOOGLE_PUBSUB_AUDIENCE to authenticate Pub/Sub pushes")
        raise HTTPException(403, "webhook authentication not configured")

    if secret:
        provided = request.query_params.get("token") or request.headers.get("x-webhook-token") or ""
        if secrets.compare_digest(provided.encode(), secret.encode()):
            return
        if not audience:  # secret was the only mechanism → reject
            raise HTTPException(403, "invalid webhook token")

    if audience:
        authz = request.headers.get("authorization", "")
        if authz[:7].lower() != "bearer ":
            raise HTTPException(401, "missing OIDC bearer token")
        token = authz[7:].strip()
        await anyio.to_thread.run_sync(
            _verify_pubsub_oidc, token, audience, s.google_pubsub_sa_email)


@router.post("/webhook/google")
async def google_webhook(request: Request):
    """Google Real-time Developer Notifications via Pub/Sub push.

    Body:
    ```
    {"message": {"data": "<base64 JSON>", "messageId": "..."}, "subscription": "..."}
    ```
    The push is authenticated first (see ``_authenticate_google_webhook``).
    The user is resolved through the ``purchase_token`` binding (fallbacks:
    ``linkedPurchaseToken`` for plan changes, then
    ``obfuscatedExternalAccountId`` set by the client at purchase time).
    """
    await _authenticate_google_webhook(request)
    try:
        envelope = await request.json()
    except Exception:
        raise HTTPException(400, "invalid json")
    msg = (envelope or {}).get("message") or {}
    msg_id = msg.get("messageId")
    raw = msg.get("data")
    if not (msg_id and raw):
        raise HTTPException(400, "invalid pubsub envelope")
    try:
        data = json.loads(base64.b64decode(raw).decode("utf-8"))
    except Exception:
        raise HTTPException(400, "invalid pubsub data")

    sb = require_supabase()
    state = _record_notification(sb, msg_id, "play_store", data)
    if state == "duplicate":
        return {"ok": True, "duplicate": True}

    sub_n = data.get("subscriptionNotification") or {}
    purchase_token = sub_n.get("purchaseToken")
    product_id = sub_n.get("subscriptionId")
    if not (purchase_token and product_id):
        logger.info("google webhook without subscriptionNotification (test push?)")
        _mark_notification(sb, msg_id)
        return {"ok": True}

    try:
        detail = await _google_verify_subscription(product_id, purchase_token)
        status_v, expires_at = _google_status(detail)
        bound = _find_by_binding(sb, "play_store", "purchase_token", str(purchase_token))
        if not bound and detail.get("linkedPurchaseToken"):
            bound = _find_by_binding(sb, "play_store", "purchase_token",
                                     str(detail["linkedPurchaseToken"]))
        user_id = ((bound or {}).get("user_id")
                   or detail.get("obfuscatedExternalAccountId")
                   or detail.get("externalAccountId"))
        if not user_id:
            logger.warning("google webhook: purchaseToken not bound to a user — skipped")
            _mark_notification(sb, msg_id, error="no_user")
            return {"ok": True, "skipped": "no_user"}
        row, outcome = _upsert_subscription(
            sb, user_id=user_id, store="play_store", product_id=product_id,
            status=status_v, expires_at=expires_at,
            trial_ends_at=expires_at if status_v == "trial" else None,
            cancel_reason=str(detail.get("cancelReason")) if detail.get("cancelReason") is not None else None,
            purchase_token=str(purchase_token),
            transaction_id=str(detail.get("orderId") or "") or None,
            event_at=_ms_to_dt(int(data.get("eventTimeMillis") or 0) or None),
            allow_transfer=False,
        )
    except HTTPException as e:
        _mark_notification(sb, msg_id, error=f"{e.status_code}: {e.detail}")
        raise
    except Exception as e:
        _mark_notification(sb, msg_id, error=str(e)[:500])
        logger.exception("google webhook processing failed")
        raise HTTPException(500, "webhook processing failed")
    _mark_notification(sb, msg_id)
    return {"ok": True, "status": status_v, "outcome": outcome}
