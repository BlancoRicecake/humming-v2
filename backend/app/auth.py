"""Shared Supabase JWT verification.

`routes/account.py` 의 검증 로직을 별도 모듈로 추출. account.py 외에도
cloud-sync 신규 엔드포인트에서 동일 패턴이 필요해서 DRY 만든다.

Supabase 토큰은 두 가지 알고리즘이 공존:
- HS256: legacy / dev. `SUPABASE_JWT_SECRET` 으로 검증.
- ES256/RS256/EdDSA: 신규 asymmetric. JWKS endpoint 에서 공개키 fetch.

`SUPABASE_JWT_SECRET` 미설정 + HS256 인 경우 검증 skip (dev fallback) —
account.py 와 동일 동작 유지.
"""
from __future__ import annotations

import logging
import os
from typing import Optional

import jwt as pyjwt
from fastapi import HTTPException
from jwt import PyJWKClient

log = logging.getLogger("humming.auth")

_jwks_client: Optional[PyJWKClient] = None


def _get_jwks_client() -> Optional[PyJWKClient]:
    global _jwks_client
    if _jwks_client is None:
        url = os.environ.get("SUPABASE_URL", "").rstrip("/")
        if not url:
            return None
        _jwks_client = PyJWKClient(
            f"{url}/auth/v1/.well-known/jwks.json",
            cache_keys=True,
            lifespan=3600,
        )
    return _jwks_client


def extract_user_id(auth_header: Optional[str], *, tag: str = "auth") -> str:
    """Validate Supabase JWT bearer token, return user_id (sub claim).

    Raises 401/403/500 HTTPException — matches `routes/account.py` behaviour.
    `tag` is only used for log lines so different callers can be told apart.
    """
    if not auth_header or not auth_header.lower().startswith("bearer "):
        log.warning("%s: missing or malformed Authorization header", tag)
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = auth_header.split(" ", 1)[1].strip()

    try:
        unverified_header = pyjwt.get_unverified_header(token)
    except Exception as e:
        log.warning("%s: cannot read header: %s", tag, e)
        raise HTTPException(status_code=401, detail="malformed token") from e
    alg = unverified_header.get("alg", "HS256")

    try:
        if alg in ("ES256", "RS256", "EdDSA"):
            jwks = _get_jwks_client()
            if jwks is None:
                raise HTTPException(status_code=500, detail="SUPABASE_URL not set")
            signing_key = jwks.get_signing_key_from_jwt(token).key
            payload = pyjwt.decode(
                token, signing_key, algorithms=[alg], options={"verify_aud": False}
            )
        elif alg == "HS256":
            jwt_secret = os.environ.get("SUPABASE_JWT_SECRET", "")
            if not jwt_secret:
                payload = pyjwt.decode(token, options={"verify_signature": False})
            else:
                payload = pyjwt.decode(
                    token, jwt_secret, algorithms=["HS256"], options={"verify_aud": False}
                )
        else:
            log.warning("%s: unsupported alg=%s", tag, alg)
            raise HTTPException(status_code=401, detail=f"unsupported alg {alg}")
    except pyjwt.ExpiredSignatureError as e:
        log.warning("%s: token expired", tag)
        raise HTTPException(status_code=401, detail="token expired") from e
    except pyjwt.InvalidSignatureError as e:
        log.warning("%s: invalid signature (alg=%s)", tag, alg)
        raise HTTPException(status_code=401, detail="invalid signature") from e
    except pyjwt.PyJWTError as e:
        log.warning("%s: jwt error (alg=%s): %s", tag, alg, e)
        raise HTTPException(status_code=401, detail=f"invalid token: {e}") from e

    role = payload.get("role")
    if role != "authenticated":
        log.warning("%s: rejecting role=%s", tag, role)
        raise HTTPException(
            status_code=403,
            detail=f"requires authenticated user (role={role})",
        )
    sub = payload.get("sub")
    if not sub:
        log.warning("%s: token has no sub claim", tag)
        raise HTTPException(status_code=401, detail="token has no sub")
    return str(sub)
