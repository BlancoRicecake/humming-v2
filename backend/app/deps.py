"""Shared FastAPI dependencies — Supabase, R2, auth.

Each accessor is lazy and ``@lru_cache``d so that a backend booted without
the relevant env vars (e.g. local DSP dev) still starts. Routes that
require the resource will 503 at request time instead of import time.

JWT verification lives here (single implementation — ``app.auth`` delegates
to it). It **fails closed**: an HS256 token with no ``SUPABASE_JWT_SECRET``
configured is rejected, never decoded unverified.
"""
from __future__ import annotations

import logging
from datetime import datetime, timezone
from functools import lru_cache
from typing import Optional

from fastapi import Depends, Header, HTTPException, status

from .settings import get_settings

logger = logging.getLogger("humming.deps")


# --- Supabase ---------------------------------------------------------------
@lru_cache
def get_supabase():
    """Service-role Supabase client. Bypasses RLS — use with care."""
    s = get_settings()
    if not (s.supabase_url and s.supabase_service_role_key):
        return None
    try:
        from supabase import create_client
    except ImportError as e:  # pragma: no cover
        raise RuntimeError(f"supabase-py not installed: {e}")
    return create_client(s.supabase_url, s.supabase_service_role_key)


def require_supabase():
    client = get_supabase()
    if client is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "supabase not configured")
    return client


# --- R2 ---------------------------------------------------------------------
@lru_cache
def get_r2_client():
    s = get_settings()
    if not (s.r2_access_key_id and s.r2_secret_access_key and s.r2_endpoint and s.r2_bucket):
        return None
    try:
        import boto3
        from botocore.config import Config
    except ImportError as e:  # pragma: no cover
        raise RuntimeError(f"boto3 not installed: {e}")
    return boto3.client(
        "s3",
        endpoint_url=s.r2_endpoint,
        aws_access_key_id=s.r2_access_key_id,
        aws_secret_access_key=s.r2_secret_access_key,
        config=Config(signature_version="s3v4", region_name="auto"),
    )


def require_r2():
    client = get_r2_client()
    if client is None:
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE, "R2 not configured")
    return client


# --- Auth -------------------------------------------------------------------
class CurrentUser(dict):
    """Lightweight wrapper around decoded JWT claims."""

    @property
    def id(self) -> str:
        return self.get("sub") or self.get("user_id") or ""

    @property
    def email(self) -> Optional[str]:
        return self.get("email")


# Supabase issues user tokens with aud=authenticated and role=authenticated.
# anon-key tokens (role=anon) and service-role tokens must never pass as a user.
_USER_AUDIENCE = "authenticated"
_ASYMMETRIC_ALGS = ("RS256", "ES256", "EdDSA")
_LEEWAY_SEC = 30


@lru_cache
def _get_supabase_jwks_client():
    """Cached JWKS client pointing at Supabase Auth's public keys endpoint.

    Supabase 2024+ rotated to asymmetric (RS256/ES256) signing keys for all
    new projects. Tokens carry `kid` and must be verified against the
    project's published JWKS, not the legacy HS256 shared secret. We keep
    HS256 support for older projects (requires SUPABASE_JWT_SECRET).
    """
    s = get_settings()
    if not s.supabase_url:
        return None
    try:
        from jwt import PyJWKClient
    except ImportError:
        return None
    jwks_url = f"{s.supabase_url.rstrip('/')}/auth/v1/.well-known/jwks.json"
    return PyJWKClient(jwks_url, cache_keys=True, lifespan=3600, timeout=10)


def decode_supabase_jwt(token: str, *, tag: str = "auth") -> dict:
    """Verify a Supabase user JWT and return its claims.

    Raises HTTPException(401) for any token problem, 503 when the server has
    no way to verify the presented algorithm. Error details are deliberately
    generic — the specific reason is logged, not returned.
    """
    s = get_settings()
    try:
        import jwt as pyjwt
    except ImportError as e:  # pragma: no cover
        raise HTTPException(500, f"pyjwt not installed: {e}")

    try:
        header = pyjwt.get_unverified_header(token)
    except Exception as e:
        logger.warning("%s: malformed token header: %s", tag, e)
        raise HTTPException(401, "invalid token")
    alg = (header.get("alg") or "").strip()
    if alg.upper() in ("RS256", "ES256"):
        alg = alg.upper()

    options = {"require": ["exp", "sub"]}
    try:
        if alg in _ASYMMETRIC_ALGS:
            jwks = _get_supabase_jwks_client()
            if jwks is None:
                raise HTTPException(503, "auth not configured (SUPABASE_URL missing)")
            signing_key = jwks.get_signing_key_from_jwt(token).key
            claims = pyjwt.decode(
                token, signing_key, algorithms=[alg], audience=_USER_AUDIENCE,
                leeway=_LEEWAY_SEC, options=options,
            )
        elif alg == "HS256":
            if not s.supabase_jwt_secret:
                # Fail CLOSED. Decoding without a signature check would let
                # anyone mint a token for any user id.
                logger.error("%s: HS256 token but SUPABASE_JWT_SECRET is unset — rejecting", tag)
                raise HTTPException(503, "auth not configured (SUPABASE_JWT_SECRET missing)")
            claims = pyjwt.decode(
                token, s.supabase_jwt_secret, algorithms=["HS256"], audience=_USER_AUDIENCE,
                leeway=_LEEWAY_SEC, options=options,
            )
        else:
            logger.warning("%s: unsupported alg=%r", tag, alg)
            raise HTTPException(401, "invalid token")
    except HTTPException:
        raise
    except pyjwt.ExpiredSignatureError:
        raise HTTPException(401, "token expired")
    except Exception as e:  # signature, audience, claims, JWKS fetch …
        logger.warning("%s: token rejected (alg=%s): %s", tag, alg, e)
        raise HTTPException(401, "invalid token")

    if claims.get("role") != _USER_AUDIENCE:
        logger.warning("%s: rejecting role=%r", tag, claims.get("role"))
        raise HTTPException(403, "requires an authenticated user")
    if not claims.get("sub"):
        raise HTTPException(401, "invalid token")
    return claims


def _bearer_token(authorization: Optional[str]) -> str:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(None, 1)[1].strip() if len(authorization.split(None, 1)) > 1 else ""
    if not token:
        raise HTTPException(401, "missing bearer token")
    return token


def get_current_user(authorization: Optional[str] = Header(None)) -> CurrentUser:
    claims = decode_supabase_jwt(_bearer_token(authorization))
    return CurrentUser(claims)


def get_optional_user(authorization: Optional[str] = Header(None)) -> Optional[CurrentUser]:
    if not authorization:
        return None
    try:
        return get_current_user(authorization)
    except HTTPException:
        return None


# --- Subscription gate (Pro) ------------------------------------------------
# "cancelled" = auto-renew turned off; still entitled until expires_at.
PRO_STATUSES = {"trial", "active", "cancelled"}


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


def subscription_is_pro(row: Optional[dict], now: Optional[datetime] = None) -> bool:
    """Single source of truth for "does this subscription row grant Pro".

    Entitled when the status is one of PRO_STATUSES and the subscription has
    not passed ``expires_at``. Rows without an expiry (legacy) are trusted on
    status alone — every store path written since 002 sets expires_at.
    """
    if not row or row.get("status") not in PRO_STATUSES:
        return False
    exp = _parse_ts(row.get("expires_at"))
    if exp is None:
        return True
    return exp > (now or datetime.now(timezone.utc))


def fetch_subscription(sb, user_id: str) -> Optional[dict]:
    res = (
        sb.table("subscriptions")
        .select("*")
        .eq("user_id", user_id)
        .limit(1)
        .execute()
    )
    rows = getattr(res, "data", None) or []
    return rows[0] if rows else None


def require_pro(user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
    sb = require_supabase()
    try:
        row = fetch_subscription(sb, user.id)
    except Exception:
        logger.exception("subscription lookup failed")
        raise HTTPException(500, "subscription lookup failed")
    if not subscription_is_pro(row):
        raise HTTPException(402, "Pro subscription required")
    return user
