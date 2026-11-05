import sys
import uuid

import httpx
import pytest

from app.cloud_provider_check import ProviderCheck, main
from tests.iap_fixtures import hs256_token


def checker():
    users = [str(uuid.uuid4()), str(uuid.uuid4())]
    tokens = [hs256_token('provider-fixture-secret-not-production', u) for u in users]
    return ProviderCheck('https://api.example.invalid', tokens, ','.join(users))


def test_default_plan_never_constructs_a_network_client(monkeypatch, capsys):
    monkeypatch.setattr(sys, 'argv', ['cloud_provider_check', '--api-url', 'https://api.example.invalid'])
    def forbidden(*a, **k): pytest.fail('plan attempted a network client')
    monkeypatch.setattr(httpx, 'Client', forbidden)
    main()
    assert '"network_used": false' in capsys.readouterr().out


def test_live_check_refuses_accounts_not_explicitly_isolated():
    u = str(uuid.uuid4())
    token = hs256_token('provider-fixture-secret-not-production', u)
    with pytest.raises(ValueError, match='two explicitly allowed'):
        ProviderCheck('https://api.example.invalid', [token, token], u)


def test_signed_url_and_transport_details_never_escape_a_failure():
    check = checker()
    check.storage.close()
    secret = 'DO-NOT-LOG-SIGNATURE'
    def fail(request): raise RuntimeError(str(request.url))
    check.storage = httpx.Client(transport=httpx.MockTransport(fail))
    try:
        with pytest.raises(RuntimeError) as caught:
            check.object_request('PUT', 'https://fixture.r2.cloudflarestorage.com/key?signature=' + secret, data=b'x')
        assert secret not in str(caught.value)
        with pytest.raises(RuntimeError, match='Unapproved'):
            check.object_request('GET', 'https://unapproved.example/key?signature=' + secret)
    finally:
        check.storage.close()
        check.api.close()
