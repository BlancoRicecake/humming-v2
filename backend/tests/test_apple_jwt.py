"""App Store Server API JWT claims.

Apple rejects a Team ID in ``iss`` with 401; production ran that way from
launch until 2026-10-04 because the tests only exercised mocked responses.
"""
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi import HTTPException

from app.routes.iap import _apple_jwt
from app.settings import get_settings

ISSUER = "57246542-96fe-1a63-e053-0824d011072a"


@pytest.fixture
def apple_env(monkeypatch):
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    monkeypatch.setenv("APPLE_IAP_PRIVATE_KEY", pem)
    monkeypatch.setenv("APPLE_IAP_KEY_ID", "ABC123DEFG")
    monkeypatch.setenv("APPLE_BUNDLE_ID", "com.example.humtrack")
    monkeypatch.setenv("APPLE_TEAM_ID", "TEAM123456")
    get_settings.cache_clear()
    yield key
    get_settings.cache_clear()


def test_jwt_uses_issuer_uuid_not_team_id(apple_env, monkeypatch):
    monkeypatch.setenv("APPLE_ISSUER_ID", ISSUER)
    get_settings.cache_clear()
    token = _apple_jwt()
    claims = jwt.decode(token, apple_env.public_key(), algorithms=["ES256"], audience="appstoreconnect-v1")
    assert claims["iss"] == ISSUER
    assert claims["bid"] == "com.example.humtrack"
    assert jwt.get_unverified_header(token)["kid"] == "ABC123DEFG"


def test_missing_issuer_is_not_configured_even_with_team_id(apple_env, monkeypatch):
    monkeypatch.delenv("APPLE_ISSUER_ID", raising=False)
    get_settings.cache_clear()
    with pytest.raises(HTTPException) as exc:
        _apple_jwt()
    assert exc.value.status_code == 503
