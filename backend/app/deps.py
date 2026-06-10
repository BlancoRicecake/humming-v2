"""Shared FastAPI dependencies — Supabase, R2, auth.

Each accessor is lazy and ``@lru_cache``d so that a backend booted without
the relevant env vars (e.g. local DSP dev) still starts. Routes that
require the resource will 503 at request time instead of import time.
"""
from __future__ import annotations

import json
import logging
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


@lru_cache
def _get_supabase_jwks_client():
    """Cached JWKS client pointing at Supabase Auth's public keys endpoint.

    Supabase 2024+ rotated to asymmetric (RS256/ES256) signing keys for all
    new projects. Tokens carry `kid` and must be verified against the
    project's published JWKS, not the legacy HS256 shared secret. We keep
    HS256 support as a fallback so older projects keep working.
    """
    s = get_settings()
    if not s.supabase_url:
        return None
    try:
        from jwt import PyJWKClient
    except ImportError:
        return None
    # Supabase publishes JWKS at <project>/auth/v1/.well-known/jwks.json
    jwks_url = f"{s.supabase_url.rstrip('/')}/auth/v1/.well-known/jwks.json"
    return PyJWKClient(jwks_url, cache_keys=True, lifespan=3600)


def _decode_supabase_jwt(token: str) -> dict:
    s = get_settings()
    try:
        import jwt as pyjwt
    except ImportError as e:  # pragma: no cover
        raise HTTPException(500, f"pyjwt not installed: {e}")

    # Read header to detect algorithm so we can route between HS256 (legacy
    # shared secret) and RS256/ES256 (Supabase JWKS).
    try:
        header = pyjwt.get_unverified_header(token)
    except Exception as e:
        raise HTTPException(401, f"invalid token header: {e}")
    alg = (header.get("alg") or "").upper()

    if alg in ("RS256", "ES256"):
        jwks = _get_supabase_jwks_client()
        if jwks is None:
            raise HTTPException(503, "JWKS client not configured (SUPABASE_URL missing)")
        try:
            signing_key = jwks.get_signing_key_from_jwt(token).key
            return pyjwt.decode(
                token,
                signing_key,
                algorithms=[alg],
                options={"verify_aud": False},
            )
        except Exception as e:
            raise HTTPException(401, f"invalid token: {e}")

    # HS256 (legacy shared secret) path.
    if not s.supabase_jwt_secret:
        logger.warning("SUPABASE_JWT_SECRET unset — decoding without signature verification")
        try:
            return pyjwt.decode(token, options={"verify_signature": False})
        except Exception as e:
            raise HTTPException(401, f"invalid token: {e}")
    try:
        return pyjwt.decode(
            token,
            s.supabase_jwt_secret,
            algorithms=["HS256"],
            audience="authenticated",
            options={"verify_aud": False},
        )
    except Exception as e:
        raise HTTPException(401, f"invalid token: {e}")


def get_current_user(authorization: Optional[str] = Header(None)) -> CurrentUser:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    token = authorization.split(None, 1)[1].strip()
    claims = _decode_supabase_jwt(token)
    if not (claims.get("sub") or claims.get("user_id")):
        raise HTTPException(401, "token missing sub")
    return CurrentUser(claims)


def get_optional_user(authorization: Optional[str] = Header(None)) -> Optional[CurrentUser]:
    if not authorization:
        return None
    try:
        return get_current_user(authorization)
    except HTTPException:
        return None


# --- Subscription gate (Pro) ------------------------------------------------
PRO_STATUSES = {"trial", "active", "cancelled"}  # cancelled = until expires_at


def require_pro(user: CurrentUser = Depends(get_current_user)) -> CurrentUser:
    sb = require_supabase()
    try:
        res = sb.table("subscriptions").select("status,expires_at").eq("user_id", user.id).maybe_single().execute()
    except Exception as e:
        logger.exception("subscription lookup failed")
        raise HTTPException(500, f"subscription lookup failed: {e}")
    row = getattr(res, "data", None)
    if not row or row.get("status") not in PRO_STATUSES:
        raise HTTPException(402, "Pro subscription required")
    return user
