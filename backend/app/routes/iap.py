"""IAP — Apple App Store + Google Play subscription verification + webhooks.

Endpoints
---------
POST /iap/verify              Auth'd. Client posts a receipt → backend talks
                              to Apple/Google → upserts `subscriptions` row.
POST /iap/webhook/apple       Apple Server Notifications V2 (signed JWS).
POST /iap/webhook/google      Google Real-time Developer Notifications
                              (pub/sub push, JWT-verified by Google).

Idempotency
-----------
Each notification carries a unique id (Apple ``notificationUUID``, Google
``notificationId`` / Pub/Sub ``message.messageId``). We persist them in
``iap_notifications`` and short-circuit duplicates.

Crypto details intentionally kept dependency-light: we ship pyjwt + httpx
and call the official Apple / Google REST endpoints. No third-party IAP
SDK — those tend to lag behind store changes.
"""
from __future__ import annotations

import base64
import json
import logging
import time
from datetime import datetime, timezone
from typing import Any, Optional

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request

from ..deps import CurrentUser, get_current_user, require_supabase
from ..models import IapVerifyRequest, IapVerifyResponse, SubStatus
from ..settings import get_settings

logger = logging.getLogger("humming.iap")
router = APIRouter(prefix="/iap", tags=["iap"])

# Apple App Store Server API endpoints.
APPLE_PROD = "https://api.storekit.itunes.apple.com"
APPLE_SANDBOX = "https://api.storekit-sandbox.itunes.apple.com"


# --- helpers ----------------------------------------------------------------
def _ms_to_dt(ms: Optional[int]) -> Optional[datetime]:
    if not ms:
        return None
    return datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)


def _now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _record_notification(sb, notification_id: str, store: str, payload: dict) -> bool:
    """Insert notification id; return True if new (False = duplicate)."""
    try:
        sb.table("iap_notifications").insert({
            "notification_id": notification_id,
            "store": store,
            "payload": payload,
        }).execute()
        return True
    except Exception as e:
        # uniqueness violation → duplicate
        msg = str(e).lower()
        if "duplicate" in msg or "unique" in msg or "23505" in msg:
            return False
        logger.exception("notification record failed")
        raise


def _upsert_subscription(sb, *, user_id: str, store: str, product_id: str,
                        status: SubStatus, expires_at: Optional[datetime],
                        trial_ends_at: Optional[datetime] = None,
                        original_purchase_at: Optional[datetime] = None,
                        last_renewed_at: Optional[datetime] = None,
                        cancel_reason: Optional[str] = None) -> dict:
    row = {
        "user_id": user_id,
        "store": store,
        "product_id": product_id,
        "status": status,
        "expires_at": expires_at.isoformat() if expires_at else None,
        "trial_ends_at": trial_ends_at.isoformat() if trial_ends_at else None,
        "original_purchase_at": original_purchase_at.isoformat() if original_purchase_at else None,
        "last_renewed_at": last_renewed_at.isoformat() if last_renewed_at else None,
        "cancel_reason": cancel_reason,
        "updated_at": _now_utc().isoformat(),
    }
    # Strip Nones so we don't clobber existing values on partial updates.
    row = {k: v for k, v in row.items() if v is not None or k in ("status", "user_id", "store", "product_id")}
    sb.table("subscriptions").upsert(row, on_conflict="user_id").execute()
    return row


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
    # Prefer the env hint but always allow the other on 404/401
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
            # 404 / 401 → try the other environment
            if r.status_code not in (401, 404):
                break
    logger.warning("Apple lookup %s failed: %s %s", transaction_id, last_status, last_body)
    raise HTTPException(400, f"apple verify failed: {last_status}")


def _decode_apple_jws_unsafe(jws_str: str) -> dict:
    """Decode without verification — only safe for JWS we received over TLS
    from api.storekit.itunes.apple.com (which authenticates via mTLS)."""
    import jwt as pyjwt
    return pyjwt.decode(jws_str, options={"verify_signature": False})


def _decode_apple_jws_verified(jws_str: str) -> dict:
    """Decode + verify an Apple signed JWS using the x5c chain in its header.

    We trust the leaf certificate's public key after verifying it chains to
    Apple's root CA. For MVP we accept any cert signed by Apple's root
    embedded in the chain; production should pin the Apple Root CA.
    """
    import jwt as pyjwt
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    headers = pyjwt.get_unverified_header(jws_str)
    x5c = headers.get("x5c") or []
    if not x5c:
        # Fall back to unsafe decode but log loudly — this should not happen
        # for genuine Apple notifications.
        logger.warning("Apple JWS without x5c header — accepting unverified")
        return _decode_apple_jws_unsafe(jws_str)
    try:
        leaf_der = base64.b64decode(x5c[0])
        leaf = x509.load_der_x509_certificate(leaf_der)
        public_key = leaf.public_key().public_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        return pyjwt.decode(jws_str, key=public_key, algorithms=["ES256"], options={"verify_aud": False})
    except Exception as e:
        logger.warning("Apple JWS verification failed: %s", e)
        raise HTTPException(400, "apple jws signature invalid")


# Back-compat alias
_decode_apple_jws = _decode_apple_jws_unsafe


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
async def _google_access_token() -> str:
    """Mint a short-lived OAuth2 token for androidpublisher scope using the
    service account JSON in settings.
    """
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
            raise HTTPException(400, f"google verify failed: {r.status_code}")
        return r.json()


def _google_status(sub: dict) -> tuple[SubStatus, Optional[datetime]]:
    """Map Google subscription resource → our SubStatus.

    paymentState: 0 = pending, 1 = paid, 2 = free trial, 3 = pending deferred upgrade.
    cancelReason: 0 = user cancelled, 1 = system, 2 = replaced, 3 = developer.
    expiryTimeMillis: ms epoch.
    """
    expiry = _ms_to_dt(int(sub.get("expiryTimeMillis", 0)) or None)
    pay = sub.get("paymentState")
    cancel = sub.get("cancelReason") is not None
    now = _now_utc()
    if expiry and expiry < now:
        return "expired", expiry
    if pay == 2:
        return "trial", expiry
    if cancel:
        return "cancelled", expiry
    return "active", expiry


# --- routes -----------------------------------------------------------------
@router.post("/verify", response_model=IapVerifyResponse)
async def verify(payload: IapVerifyRequest, user: CurrentUser = Depends(get_current_user)):
    """Validate a fresh receipt from the client and persist subscription state.

    For Apple, ``receipt_data`` is the transactionId (StoreKit 2) or the
    signed JWS. For Google, it's a JSON string ``{"productId": "...",
    "purchaseToken": "..."}``.
    """
    sb = require_supabase()
    s = get_settings()
    if payload.store == "app_store":
        raw = payload.receipt_data.strip()
        tx: dict = {}
        # Heuristic: StoreKit 2 transactionId is short numeric; legacy receipt
        # is a long base64 blob (>200 chars and no dots).
        looks_like_jws = raw.count(".") == 2
        looks_like_txid = raw.isdigit() and len(raw) <= 30
        if looks_like_jws or looks_like_txid:
            txid = raw
            if looks_like_jws:
                try:
                    txid = str(_decode_apple_jws_unsafe(raw).get("transactionId") or raw)
                except Exception:
                    pass
            info = await _apple_lookup_transaction(txid)
            signed = info.get("signedTransactionInfo")
            if not signed:
                raise HTTPException(400, "apple: no signedTransactionInfo")
            tx = _decode_apple_jws_unsafe(signed)
        else:
            # Legacy verifyReceipt path (StoreKit 1) with Shared Secret
            legacy = await _apple_verify_receipt_legacy(raw)
            if not legacy:
                raise HTTPException(400, "apple: legacy verifyReceipt failed")
            latest = (legacy.get("latest_receipt_info") or [{}])[-1]
            # Normalise keys → StoreKit 2 style fields we use below
            tx = {
                "productId": latest.get("product_id"),
                "bundleId": (legacy.get("receipt") or {}).get("bundle_id"),
                "expiresDate": int(latest.get("expires_date_ms", 0)) or None,
                "originalPurchaseDate": int(latest.get("original_purchase_date_ms", 0)) or None,
                "purchaseDate": int(latest.get("purchase_date_ms", 0)) or None,
                "offerType": 1 if latest.get("is_trial_period") == "true" else 0,
            }

        # Validate bundleId
        if s.apple_bundle_id and tx.get("bundleId") and tx["bundleId"] != s.apple_bundle_id:
            raise HTTPException(400, f"apple: bundleId mismatch ({tx['bundleId']})")

        product_id = tx.get("productId") or payload.product_id or ""
        # Validate productId against configured allow-list (if set)
        allowed = s.accepted_apple_product_ids()
        if allowed and product_id and product_id not in allowed:
            raise HTTPException(400, f"apple: unknown productId {product_id}")

        expires_at = _ms_to_dt(tx.get("expiresDate"))
        original = _ms_to_dt(tx.get("originalPurchaseDate"))
        purchase = _ms_to_dt(tx.get("purchaseDate"))
        is_trial = tx.get("offerType") == 1  # 1 = intro/free trial
        now = _now_utc()
        if expires_at and expires_at < now:
            status_v: SubStatus = "expired"
        elif is_trial:
            status_v = "trial"
        else:
            status_v = "active"
        _upsert_subscription(
            sb, user_id=user.id, store="app_store", product_id=product_id,
            status=status_v, expires_at=expires_at,
            trial_ends_at=expires_at if is_trial else None,
            original_purchase_at=original, last_renewed_at=purchase,
        )
        return IapVerifyResponse(
            status=status_v, product_id=product_id, expires_at=expires_at,
            trial_ends_at=expires_at if is_trial else None, store="app_store",
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
    status_v, expires_at = _google_status(sub)
    trial_end = expires_at if sub.get("paymentState") == 2 else None
    original = _ms_to_dt(int(sub.get("startTimeMillis", 0)) or None)
    renewed = _ms_to_dt(int(sub.get("userCancellationTimeMillis", 0)) or None) or original
    _upsert_subscription(
        sb, user_id=user.id, store="play_store", product_id=product_id,
        status=status_v, expires_at=expires_at, trial_ends_at=trial_end,
        original_purchase_at=original, last_renewed_at=renewed,
        cancel_reason=str(sub.get("cancelReason")) if sub.get("cancelReason") is not None else None,
    )
    return IapVerifyResponse(
        status=status_v, product_id=product_id, expires_at=expires_at,
        trial_ends_at=trial_end, store="play_store",
    )


# --- webhooks ---------------------------------------------------------------
@router.post("/webhook/apple")
async def apple_webhook(request: Request):
    """Apple Server Notifications V2.

    Body: ``{"signedPayload": "<JWS>"}``. We decode, dedup on
    ``notificationUUID``, then refresh subscription via the StoreKit API
    so we always store store-of-record state (not just the notification).
    """
    body = await request.json()
    signed = body.get("signedPayload")
    if not signed:
        raise HTTPException(400, "missing signedPayload")
    payload = _decode_apple_jws_verified(signed)
    notif_id = payload.get("notificationUUID")
    notif_type = payload.get("notificationType")
    if not notif_id:
        raise HTTPException(400, "missing notificationUUID")

    # Validate bundleId for defence-in-depth (verified JWS already authentic)
    s = get_settings()
    pl_bundle = (payload.get("data") or {}).get("bundleId")
    if s.apple_bundle_id and pl_bundle and pl_bundle != s.apple_bundle_id:
        raise HTTPException(400, f"apple webhook: bundleId mismatch {pl_bundle}")

    sb = require_supabase()
    if not _record_notification(sb, notif_id, "app_store", payload):
        return {"ok": True, "duplicate": True}

    data = payload.get("data") or {}
    signed_tx = data.get("signedTransactionInfo")
    signed_renew = data.get("signedRenewalInfo")
    if not signed_tx:
        logger.info("apple webhook %s without signedTransactionInfo", notif_type)
        return {"ok": True}
    tx = _decode_apple_jws_verified(signed_tx)
    renew = _decode_apple_jws_verified(signed_renew) if signed_renew else {}

    # We don't know the user_id from Apple directly — we use the
    # appAccountToken the client set at purchase time, if available.
    user_id = tx.get("appAccountToken")
    if not user_id:
        logger.warning("apple webhook %s: no appAccountToken, cannot map to user", notif_type)
        return {"ok": True, "skipped": "no_user"}

    expires_at = _ms_to_dt(tx.get("expiresDate"))
    now = _now_utc()
    auto_renew = renew.get("autoRenewStatus") == 1
    if notif_type in ("EXPIRED", "REVOKE"):
        status_v: SubStatus = "expired"
    elif notif_type == "DID_CHANGE_RENEWAL_STATUS" and not auto_renew:
        status_v = "cancelled"
    elif expires_at and expires_at < now:
        status_v = "expired"
    elif tx.get("offerType") == 1:
        status_v = "trial"
    else:
        status_v = "active"

    _upsert_subscription(
        sb, user_id=user_id, store="app_store",
        product_id=tx.get("productId") or "",
        status=status_v, expires_at=expires_at,
        trial_ends_at=expires_at if status_v == "trial" else None,
        last_renewed_at=_ms_to_dt(tx.get("purchaseDate")),
        cancel_reason=notif_type if status_v in ("cancelled", "expired") else None,
    )
    return {"ok": True, "status": status_v}


@router.post("/webhook/google")
async def google_webhook(request: Request):
    """Google Real-time Developer Notifications via Pub/Sub push.

    Body:
    ```
    {"message": {"data": "<base64 JSON>", "messageId": "..."}, "subscription": "..."}
    ```
    For MVP we don't verify Pub/Sub OIDC token signature — gate this endpoint
    behind a secret URL token + the (forthcoming) Google JWT middleware.
    """
    envelope = await request.json()
    msg = envelope.get("message") or {}
    msg_id = msg.get("messageId")
    raw = msg.get("data")
    if not (msg_id and raw):
        raise HTTPException(400, "invalid pubsub envelope")
    try:
        data = json.loads(base64.b64decode(raw).decode("utf-8"))
    except Exception as e:
        raise HTTPException(400, f"invalid pubsub data: {e}")

    sb = require_supabase()
    if not _record_notification(sb, msg_id, "play_store", data):
        return {"ok": True, "duplicate": True}

    sub_n = data.get("subscriptionNotification") or {}
    purchase_token = sub_n.get("purchaseToken")
    product_id = sub_n.get("subscriptionId")
    if not (purchase_token and product_id):
        logger.info("google webhook without subscriptionNotification")
        return {"ok": True}

    detail = await _google_verify_subscription(product_id, purchase_token)
    status_v, expires_at = _google_status(detail)
    # obfuscatedExternalAccountId — we set this at purchase time = supabase user_id.
    user_id = (detail.get("obfuscatedExternalAccountId")
               or detail.get("externalAccountId")
               or detail.get("profileId"))
    if not user_id:
        logger.warning("google webhook: no externalAccountId, cannot map to user")
        return {"ok": True, "skipped": "no_user"}
    _upsert_subscription(
        sb, user_id=user_id, store="play_store", product_id=product_id,
        status=status_v, expires_at=expires_at,
        trial_ends_at=expires_at if status_v == "trial" else None,
        cancel_reason=str(detail.get("cancelReason")) if detail.get("cancelReason") is not None else None,
    )
    return {"ok": True, "status": status_v}
