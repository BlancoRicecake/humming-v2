"""GET /health/cloud — public cloud readiness for the app's release gate.

Ready only when every part a customer's backup depends on answers: the feature
and write switches, the cleanup worker switch, R2 configured, migration 006
(lifecycle) and 008 (cleanup health) present, and the worker healthy. No
counts, ids, keys or URLs; only known alert codes.
"""
import pytest
from fastapi.testclient import TestClient

from app import cloud_monitor, deps
from app.main import app
from app.routes import health
from app.settings import get_settings


@pytest.fixture
def client(monkeypatch):
    s = get_settings()
    for name, value in {
        'cloud_sync_enabled': True,
        'cloud_backup_writes_enabled': True,
        'cloud_cleanup_enabled': True,
        'r2_access_key_id': 'k', 'r2_secret_access_key': 's',
        'r2_endpoint': 'https://r2.example.test', 'r2_bucket': 'b',
    }.items():
        monkeypatch.setattr(s, name, value)
    monkeypatch.setattr(health, '_cloud_cache', None)
    monkeypatch.setattr(deps, 'require_supabase', lambda: object())
    return TestClient(app)


def _health(monkeypatch, report=None, error=None):
    calls = []

    def fake(sb):
        calls.append(sb)
        if error:
            raise error
        return report

    monkeypatch.setattr(cloud_monitor, 'health', fake)
    return calls


def test_ready_when_every_part_answers(client, monkeypatch):
    _health(monkeypatch, {'healthy': True, 'alerts': [], 'pending_jobs': 3})
    body = client.get('/health/cloud').json()
    assert body['ready'] is True
    assert body['contract'] == 1 and body['lifecycle_db'] and body['cleanup_healthy']
    # aggregate counts and anything else from the DB report never leave
    assert 'pending_jobs' not in body
    assert set(body) == {'contract', 'version', 'sync_enabled', 'writes_enabled', 'cleanup_enabled',
                         'storage_configured', 'lifecycle_db', 'cleanup_healthy', 'alerts', 'ready'}


def test_feature_off_is_not_ready_and_never_touches_the_db(client, monkeypatch):
    monkeypatch.setattr(get_settings(), 'cloud_sync_enabled', False)
    calls = _health(monkeypatch, {'healthy': True, 'alerts': []})
    body = client.get('/health/cloud').json()
    assert body['ready'] is False and body['lifecycle_db'] is False
    assert calls == []


@pytest.mark.parametrize('switch', ['cloud_backup_writes_enabled', 'cloud_cleanup_enabled', 'r2_bucket'])
def test_any_missing_part_is_not_ready(client, monkeypatch, switch):
    monkeypatch.setattr(get_settings(), switch, None if switch == 'r2_bucket' else False)
    _health(monkeypatch, {'healthy': True, 'alerts': []})
    assert client.get('/health/cloud').json()['ready'] is False


def test_missing_migrations_report_unavailable_without_details(client, monkeypatch):
    # 006/008 absent: the RPC call fails (PGRST202 etc.); nothing of it leaks
    _health(monkeypatch, error=RuntimeError('PGRST202 function public.cloud_cleanup_health not found secret-ish'))
    body = client.get('/health/cloud').json()
    assert body['ready'] is False and body['lifecycle_db'] is False
    assert body['alerts'] == ['cloud_health_unavailable']
    assert 'PGRST' not in str(body) and 'secret' not in str(body)


def test_unhealthy_worker_is_not_ready_and_only_known_codes_show(client, monkeypatch):
    _health(monkeypatch, {'healthy': False, 'alerts': ['scheduled_worker_stale', 'user 1234 key abc']})
    body = client.get('/health/cloud').json()
    assert body['ready'] is False and body['lifecycle_db'] is True
    assert body['alerts'] == ['scheduled_worker_stale']


def test_the_db_check_is_cached(client, monkeypatch):
    calls = _health(monkeypatch, {'healthy': True, 'alerts': []})
    for _ in range(5):
        client.get('/health/cloud')
    assert len(calls) == 1
