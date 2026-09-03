"""JWT verification (app.deps / app.auth) must fail closed."""
from __future__ import annotations

import uuid

import jwt as pyjwt
import pytest
from fastapi import HTTPException

from app.auth import extract_user_id
from app.deps import decode_supabase_jwt, subscription_is_pro
from app.settings import get_settings

from tests.iap_fixtures import hs256_token

SECRET = "unit-test-secret"
UID = str(uuid.uuid4())


@pytest.fixture
def secret(monkeypatch):
    monkeypatch.setenv("SUPABASE_JWT_SECRET", SECRET)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def no_secret(monkeypatch):
    monkeypatch.delenv("SUPABASE_JWT_SECRET", raising=False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def test_valid_hs256(secret):
    assert decode_supabase_jwt(hs256_token(SECRET, UID))["sub"] == UID
    assert extract_user_id(f"Bearer {hs256_token(SECRET, UID)}") == UID


def test_unsigned_token_rejected_when_secret_unset(no_secret):
    """The old code decoded HS256 tokens WITHOUT signature verification when
    SUPABASE_JWT_SECRET was missing — anyone could become any user."""
    forged = pyjwt.encode({"sub": UID, "role": "authenticated", "aud": "authenticated", "exp": 4102444800},
                          "attacker", algorithm="HS256")
    with pytest.raises(HTTPException) as e:
        decode_supabase_jwt(forged)
    assert e.value.status_code in (401, 503)


def test_wrong_secret_rejected(secret):
    with pytest.raises(HTTPException) as e:
        decode_supabase_jwt(hs256_token("other", UID))
    assert e.value.status_code == 401


def test_alg_none_rejected(secret):
    tok = pyjwt.encode({"sub": UID, "role": "authenticated", "aud": "authenticated", "exp": 4102444800},
                       key=None, algorithm="none")
    with pytest.raises(HTTPException) as e:
        decode_supabase_jwt(tok)
    assert e.value.status_code == 401


def test_expired_rejected(secret):
    with pytest.raises(HTTPException) as e:
        decode_supabase_jwt(hs256_token(SECRET, UID, exp_in=-3600))
    assert e.value.status_code == 401


def test_anon_role_rejected(secret):
    with pytest.raises(HTTPException) as e:
        decode_supabase_jwt(hs256_token(SECRET, UID, role="anon", aud="authenticated"))
    assert e.value.status_code == 403


def test_wrong_audience_rejected(secret):
    with pytest.raises(HTTPException) as e:
        decode_supabase_jwt(hs256_token(SECRET, UID, aud="other"))
    assert e.value.status_code == 401


def test_missing_sub_rejected(secret):
    tok = pyjwt.encode({"role": "authenticated", "aud": "authenticated", "exp": 4102444800}, SECRET, algorithm="HS256")
    with pytest.raises(HTTPException):
        decode_supabase_jwt(tok)


def test_bearer_header_parsing(secret):
    for bad in (None, "", "Basic abc", "Bearer", "Bearer "):
        with pytest.raises(HTTPException) as e:
            extract_user_id(bad)
        assert e.value.status_code == 401


def test_error_detail_is_generic(secret):
    with pytest.raises(HTTPException) as e:
        decode_supabase_jwt(hs256_token("other", UID))
    assert "Signature" not in e.value.detail and e.value.detail == "invalid token"


def test_subscription_is_pro_predicate():
    from datetime import datetime, timedelta, timezone
    fut = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
    past = (datetime.now(timezone.utc) - timedelta(days=1)).isoformat()
    assert subscription_is_pro({"status": "active", "expires_at": fut})
    assert subscription_is_pro({"status": "trial", "expires_at": fut})
    assert subscription_is_pro({"status": "cancelled", "expires_at": fut})
    assert not subscription_is_pro({"status": "cancelled", "expires_at": past})
    assert not subscription_is_pro({"status": "active", "expires_at": past})
    assert not subscription_is_pro({"status": "expired", "expires_at": fut})
    assert subscription_is_pro({"status": "active", "expires_at": None})  # legacy row
    assert not subscription_is_pro(None)
