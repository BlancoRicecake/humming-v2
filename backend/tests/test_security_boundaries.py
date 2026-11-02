import base64
import json
from types import SimpleNamespace
import uuid

import jwt
import pytest
from fastapi import HTTPException

from app import deps,analyze
from app.settings import get_settings
from tests.iap_fixtures import hs256_token


def b64(value):return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip('=')


@pytest.mark.parametrize('algorithm',[[],{},1,True,None])
def test_malformed_algorithm_is_401_not_server_error(algorithm):
    token=b64({'alg':algorithm})+'.'+b64({'sub':'synthetic'})+'.eA'
    with pytest.raises(HTTPException) as result:deps.decode_supabase_jwt(token)
    assert result.value.status_code==401


def test_configured_project_rejects_missing_or_wrong_issuer(monkeypatch):
    secret='synthetic-issuer-fixture-key-at-least-32-bytes'
    monkeypatch.setenv('SUPABASE_JWT_SECRET',secret)
    monkeypatch.setenv('SUPABASE_URL','https://expected.example')
    get_settings.cache_clear()
    try:
        uid=str(uuid.uuid4())
        for extra in ({},{'iss':'https://other.example/auth/v1'}):
            with pytest.raises(HTTPException) as error:deps.decode_supabase_jwt(hs256_token(secret,uid,**extra))
            assert error.value.status_code==401
        assert deps.decode_supabase_jwt(hs256_token(secret,uid,iss='https://expected.example/auth/v1'))['sub']==uid
    finally:get_settings.cache_clear()


def test_untrusted_jwks_exception_is_not_logged(monkeypatch,caplog):
    class Keys:
        def get_signing_key_from_jwt(self,token):raise jwt.PyJWKClientError('private-attacker-kid')
    monkeypatch.setattr(deps,'_get_supabase_jwks_client',lambda:Keys())
    token=b64({'alg':'RS256','kid':'private-attacker-kid'})+'.'+b64({'sub':'synthetic'})+'.eA'
    with pytest.raises(HTTPException):deps.decode_supabase_jwt(token)
    assert 'private-attacker-kid' not in caplog.text


@pytest.mark.parametrize('issuer,accepted',[('https://expected.example/auth/v1',True),('https://other.example/auth/v1',False)])
def test_asymmetric_project_issuer_and_signature(monkeypatch,issuer,accepted):
    from cryptography.hazmat.primitives.asymmetric import rsa
    key=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    monkeypatch.setenv('SUPABASE_URL','https://expected.example');get_settings.cache_clear()
    class Keys:
        def get_signing_key_from_jwt(self,token):return SimpleNamespace(key=key.public_key())
    monkeypatch.setattr(deps,'_get_supabase_jwks_client',lambda:Keys())
    claims={'sub':str(uuid.uuid4()),'role':'authenticated','aud':'authenticated','iss':issuer,'exp':4102444800}
    try:
        token=jwt.encode(claims,key,algorithm='RS256')
        if accepted:assert deps.decode_supabase_jwt(token)['sub']==claims['sub']
        else:
            with pytest.raises(HTTPException) as error:deps.decode_supabase_jwt(token)
            assert error.value.status_code==401
        other=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        with pytest.raises(HTTPException):deps.decode_supabase_jwt(jwt.encode(claims,other,algorithm='RS256'))
    finally:get_settings.cache_clear()


def test_decode_failure_does_not_return_or_log_uploaded_bytes_or_stderr(monkeypatch,caplog):
    def run(*args,**kwargs):return SimpleNamespace(returncode=1,stdout=b'',stderr=b'PRIVATE_UPLOAD_MARKER file:///private-server-path')
    monkeypatch.setattr(analyze.subprocess,'run',run)
    with pytest.raises(HTTPException) as error:analyze._ffmpeg_decode_to_pcm(b'PRIVATE_UPLOAD_MARKER')
    assert error.value.status_code==400
    assert 'PRIVATE_UPLOAD' not in caplog.text+str(error.value.detail)
    assert 'private-server-path' not in caplog.text+str(error.value.detail)
