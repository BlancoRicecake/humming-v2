"""Lifecycle acceptance on real PostgreSQL; the object store is FakeR2.

No production credentials or customer objects. Verify transaction fences,
durable retries, Auth cascade survival, bounded scans and late upload audits.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import threading
from datetime import timedelta
from types import SimpleNamespace
import uuid

import pytest
from fastapi import HTTPException

from app import cloud_lifecycle as lifecycle, storage_r2
from app.cloud_quota import new_backup_key
from tests.cloud_fixtures import PG_URI, PgSupabase
from tests.test_cloud_backup import client, env, cloud, db_uri  # shared real-PG fixtures

pytestmark = pytest.mark.skipif(not PG_URI, reason='CLOUD_TEST_PG_URI not set')


def sql(cloud, statement, params=()):
    with cloud.sb.connect() as c:
        cursor = c.execute(statement, params)
        rows = cursor.fetchall() if cursor.description else []
        return SimpleNamespace(fetchone=lambda: rows[0] if rows else None, rowcount=cursor.rowcount)


def due(cloud, uid):
    sql(cloud, "update cloud_accounts set next_sweep_at=now()-interval '1 second',claim_until=null where user_id=%s", [uid])


def jobs(cloud, uid):
    return cloud.sb.table('cloud_delete_jobs').select('*').eq('user_id', uid).execute().data


def test_periodic_cleanup_without_another_project_operation_preserves_refs_and_unknowns(cloud):
    u = cloud.user()
    cloud.backup(u, 'p', b'current', absent=True)
    current = cloud.current(u, 'p')['meta']['key']
    old = f'vocals/{u}/never-opened/up-{"a" * 32}.humtrack'
    young = f'vocals/{u}/never-opened/up-{"b" * 32}.humtrack'
    unknown = f'vocals/{u}/old-format/customer.wav'
    cloud.r2.put(old, b'orphan', age=timedelta(hours=30))
    cloud.r2.put(young, b'working')
    cloud.r2.put(unknown, b'keep unknown', age=timedelta(days=10))
    stats = lifecycle.tick(cloud.sb, apply=True)
    assert stats['deleted'] >= 1
    assert cloud.r2.data(old) is None
    assert cloud.r2.data(current) == b'current'
    assert cloud.r2.data(young) == b'working' and cloud.r2.data(unknown) == b'keep unknown'
    measured = cloud.c.get('/storage/usage', headers=cloud.h(u)).json()['used_bytes']
    cached = cloud.sb.table('cloud_quota').select('used_bytes').eq('user_id', u).maybe_single().execute().data['used_bytes']
    assert cached == measured


def test_new_writes_fail_closed_without_scheduled_cleanup(cloud, monkeypatch):
    from app.settings import get_settings
    u = cloud.user()
    cloud.backup(u, 'p', b'protected', absent=True)
    monkeypatch.setenv('CLOUD_CLEANUP_ENABLED', 'false')
    get_settings.cache_clear()
    rejected = cloud.presign(u, 'new', 3)
    assert rejected.status_code == 503 and rejected.json()['detail']['error'] == 'cloud_cleanup_not_enabled'
    assert cloud.c.get('/projects', headers=cloud.h(u)).status_code == 200
    assert cloud.c.delete('/projects/p', headers=cloud.h(u)).status_code == 204


def test_failed_deletion_survives_restart_and_retries_without_a_client(cloud, monkeypatch):
    u = cloud.user()
    _, first = cloud.backup(u, 'p', b'old', absent=True)
    old = cloud.current(u, 'p')['meta']['key']
    real = cloud.r2.delete_objects
    monkeypatch.setattr(cloud.r2, 'delete_objects', lambda **kw: {'Errors': [{'Key': x['Key']} for x in kw['Delete']['Objects']]})
    _, result = cloud.backup(u, 'p', b'new', expected=first.json()['updated_at'])
    assert result.status_code == 200 and jobs(cloud, u)
    current = cloud.current(u, 'p')['meta']['key']
    assert cloud.r2.data(old) == b'old' and cloud.r2.data(current) == b'new'
    monkeypatch.setattr(cloud.r2, 'delete_objects', real)
    sql(cloud, 'update cloud_delete_jobs set next_attempt_at=now()-interval \'1 second\' where user_id=%s', [u])
    restarted = PgSupabase(cloud.sb.uri)
    stats = lifecycle.tick(restarted, apply=True)
    assert stats['failed'] == 0 and not jobs(cloud, u)
    assert cloud.r2.data(old) is None and cloud.r2.data(current) == b'new'


def test_missing_delete_acknowledgement_is_not_success(cloud, monkeypatch):
    u = cloud.user()
    cloud.backup(u, 'p', b'keep until confirmed', absent=True)
    key = cloud.current(u, 'p')['meta']['key']
    monkeypatch.setattr(cloud.r2, 'delete_objects', lambda **kw: {})
    r = cloud.c.delete('/projects/p', headers=cloud.h(u))
    assert r.status_code == 503
    assert cloud.r2.data(key) is not None and jobs(cloud, u)


def test_dry_run_mutates_neither_database_nor_objects(cloud, monkeypatch):
    u = cloud.user()
    lifecycle.ensure_account(cloud.sb, u)
    old = f'vocals/{u}/p/up-{"a" * 32}.humtrack'
    cloud.r2.put(old, b'orphan', age=timedelta(days=3))
    before = cloud.sb.table('cloud_accounts').select('*').eq('user_id', u).execute().data
    original = dict(cloud.r2.objects)
    monkeypatch.setattr(lifecycle, 'delete_auth_user', lambda *_: pytest.fail('dry-run attempted Auth deletion'))
    stats = lifecycle.tick(cloud.sb)
    assert stats['dry_run'] and stats['queued'] == 0
    assert before == cloud.sb.table('cloud_accounts').select('*').eq('user_id', u).execute().data
    assert original == cloud.r2.objects and not jobs(cloud, u)


def prepared_copy(cloud, u, pid='p'):
    up = cloud.upload(u, pid, b'copy bytes')
    final = new_backup_key(u, pid)
    lifecycle.begin_commit(cloud.sb, u, pid, up['key'], final)
    cloud.r2.put(final, b'copy bytes', age=timedelta(days=2))
    return up, final


def publish(cloud, u, key):
    return cloud.sb.rpc('commit_cloud_project', {'p_user_id': u, 'p_project_id': 'p', 'p_title': 't',
        'p_meta': cloud.meta(key, b'copy bytes'), 'p_size_bytes': 10,
        'p_expected_updated_at': None, 'p_expect_absent': True}).execute().data


def test_expired_copy_cannot_publish_after_gc_or_after_a_late_copy(cloud):
    u = cloud.user()
    _, key = prepared_copy(cloud, u)
    sql(cloud, "update cloud_object_leases set lease_until=now()-interval '1 second' where object_key=%s", [key])
    lifecycle.tick(cloud.sb, apply=True)
    assert cloud.r2.data(key) is None
    cloud.r2.put(key, b'copy bytes')  # a slow provider copy finally finishes
    assert publish(cloud, u, key)['status'] == 'upload_expired'
    assert cloud.current(u, 'p') is None
    cloud.r2.put(key, b'copy bytes', age=timedelta(days=2))
    due(cloud, u)
    lifecycle.tick(cloud.sb, apply=True)
    assert cloud.r2.data(key) is None


def test_current_copy_and_live_copy_lease_are_never_swept(cloud):
    u = cloud.user()
    up, key = prepared_copy(cloud, u)
    lifecycle.tick(cloud.sb, apply=True)
    assert cloud.r2.data(key) == b'copy bytes'
    assert cloud.r2.data(up['key']) == b'copy bytes'
    assert publish(cloud, u, key)['status'] == 'ok'
    sql(cloud, "update cloud_object_leases set lease_until=now()-interval '2 days' where object_key=%s", [key])
    due(cloud, u)
    lifecycle.tick(cloud.sb, apply=True)
    assert cloud.r2.data(key) == b'copy bytes'


def test_gc_and_commit_serialise_under_the_same_account_fence(cloud):
    for expired in [False, True]:
        u = cloud.user()
        _, key = prepared_copy(cloud, u)
        if expired:
            sql(cloud, "update cloud_object_leases set lease_until=now()-interval '1 second' where object_key=%s", [key])
        with ThreadPoolExecutor(2) as pool:
            commit = pool.submit(publish, cloud, u, key)
            gc = pool.submit(lifecycle.enqueue, cloud.sb, u, [key], reason='orphan')
            result, queued = commit.result(timeout=10), gc.result(timeout=10)
        lifecycle.execute_deletes(cloud.sb, u, queued)
        if result['status'] == 'ok':
            assert cloud.r2.data(key) == b'copy bytes'
            assert cloud.current(u, 'p')['meta']['key'] == key
        else:
            assert result['status'] == 'upload_expired'
            assert cloud.current(u, 'p') is None


def remove_auth(cloud, uid):
    assert sql(cloud, 'select delete_requested_at is not null from cloud_accounts where user_id=%s', [uid]).fetchone()[0]
    sql(cloud, 'delete from auth.users where id=%s', [uid])
    return True


def test_account_request_survives_auth_cascade_blocks_writes_and_removes_late_put(cloud, monkeypatch):
    from app.routes import account
    u = cloud.user()
    up, _ = cloud.backup(u, 'p', b'voice', absent=True)
    monkeypatch.setattr(account, 'require_supabase', lambda: cloud.sb)
    monkeypatch.setattr(lifecycle, 'delete_auth_user', lambda sb, uid: remove_auth(cloud, uid))
    response = cloud.c.delete('/account', headers={**cloud.h(u), 'X-Account-Deletion-Receipt': 'pending-v1'})
    assert response.status_code == 202 and response.json()['status'] == 'deletion_pending'
    assert sql(cloud, 'select count(*) from auth.users where id=%s', [u]).fetchone()[0] == 0
    assert cloud.presign(u, 'new', 5).status_code == 410
    assert cloud.c.get('/projects', headers=cloud.h(u)).status_code == 410
    sql(cloud, "update cloud_accounts set purge_after=now()-interval '1 second' where user_id=%s", [u])
    for _ in range(2):
        due(cloud, u)
        lifecycle.tick(cloud.sb, apply=True)
    assert not [k for k in cloud.r2.objects if k.startswith(f'vocals/{u}/')]
    state = cloud.sb.table('cloud_accounts').select('*').eq('user_id', u).maybe_single().execute().data
    assert state['purged_at'] and state['delete_requested_at']
    # A PUT accepted before expiry may finish after the first empty audit.
    assert cloud.r2.client_put(up['url'], b'voice', up['headers']) == 200
    due(cloud, u)
    lifecycle.tick(cloud.sb, apply=True)
    assert not [k for k in cloud.r2.objects if k.startswith(f'vocals/{u}/')]


def test_auth_failure_retries_from_persisted_request(cloud, monkeypatch):
    u = cloud.user()
    cloud.backup(u, 'p', b'voice', absent=True)
    calls = []
    def flaky(sb, uid):
        calls.append(uid)
        return remove_auth(cloud, uid) if len(calls) >= 2 else False
    monkeypatch.setattr(lifecycle, 'delete_auth_user', flaky)
    lifecycle.request_account_deletion(cloud.sb, u)
    assert sql(cloud, 'select count(*) from auth.users where id=%s', [u]).fetchone()[0] == 1
    sql(cloud, "update cloud_accounts set auth_retry_at=now()-interval '1 second' where user_id=%s", [u])
    due(cloud, u)
    lifecycle.tick(PgSupabase(cloud.sb.uri), apply=True)
    assert len(calls) == 2
    assert sql(cloud, 'select auth_deleted_at is not null from cloud_accounts where user_id=%s', [u]).fetchone()[0]


def test_empty_deleted_account_drops_filename_leases_only_after_grace(cloud):
    u = cloud.user()
    # A rejected/cancelled PUT may leave a lease without ever creating an object.
    assert cloud.presign(u, 'never_uploaded', 5).status_code == 200
    sql(cloud, 'delete from auth.users where id=%s', [u])
    due(cloud, u)
    lifecycle.tick(cloud.sb, apply=True, only_user_id=u)
    assert sql(cloud, 'select count(*) from cloud_object_leases where user_id=%s', [u]).fetchone()[0] == 1
    sql(cloud, "update cloud_accounts set purge_after=now()-interval '1 second' where user_id=%s", [u])
    due(cloud, u)
    lifecycle.tick(cloud.sb, apply=True, only_user_id=u)
    assert sql(cloud, 'select count(*) from cloud_object_leases where user_id=%s', [u]).fetchone()[0] == 0
    assert sql(cloud, 'select purged_at is not null from cloud_accounts where user_id=%s', [u]).fetchone()[0]


def test_legacy_client_gets_success_only_after_auth_deletion_is_confirmed(cloud, monkeypatch):
    from app.routes import account
    u = cloud.user()
    monkeypatch.setattr(account, 'require_supabase', lambda: cloud.sb)
    monkeypatch.setattr(lifecycle, 'delete_auth_user', lambda *_: False)
    response = cloud.c.delete('/account', headers=cloud.h(u))
    assert response.status_code == 503
    assert sql(cloud, 'select delete_requested_at is not null from cloud_accounts where user_id=%s', [u]).fetchone()[0]
    sql(cloud, 'delete from auth.users where id=%s', [u])
    assert cloud.c.delete('/account', headers=cloud.h(u)).status_code == 204


def test_auth_delete_outside_the_new_route_creates_a_durable_tombstone(cloud):
    u = cloud.user()
    key = f'vocals/{u}/legacy/old-vocal.wav'
    cloud.r2.put(key, b'legacy bytes')
    sql(cloud, 'delete from auth.users where id=%s', [u])
    state = cloud.sb.table('cloud_accounts').select('*').eq('user_id', u).maybe_single().execute().data
    assert state['delete_requested_at'] and state['auth_deleted_at']
    due(cloud, u)
    lifecycle.tick(cloud.sb, apply=True, only_user_id=u)
    assert cloud.r2.data(key) is None


def test_listing_failure_never_marks_deletion_complete(cloud, monkeypatch):
    u = cloud.user()
    lifecycle.ensure_account(cloud.sb, u)
    monkeypatch.setattr(lifecycle, 'delete_auth_user', lambda *_: True)
    lifecycle.request_account_deletion(cloud.sb, u)
    sql(cloud, "update cloud_accounts set purge_after=now()-interval '1 second' where user_id=%s", [u])
    due(cloud, u)
    def broken(*a, **k): raise RuntimeError('provider unavailable')
    monkeypatch.setattr(storage_r2, 'list_objects_page', broken)
    assert lifecycle.tick(cloud.sb, apply=True)['errors'] >= 1
    assert sql(cloud, 'select purged_at from cloud_accounts where user_id=%s', [u]).fetchone()[0] is None


def test_scanner_is_bounded_and_progresses_across_pages(cloud):
    u = cloud.user()
    lifecycle.ensure_account(cloud.sb, u)
    for i in range(7):
        cloud.r2.put(f'vocals/{u}/p/up-{i:032x}.humtrack', b'x', age=timedelta(days=2))
    first = lifecycle.tick(cloud.sb, apply=True, max_objects=3)
    assert first['objects'] <= 3
    for _ in range(4):
        due(cloud, u)
        lifecycle.tick(cloud.sb, apply=True, max_objects=3)
    assert not [k for k in cloud.r2.objects if k.startswith(f'vocals/{u}/')]


def test_lifecycle_tables_rpc_and_unleased_alias_are_private(cloud):
    import psycopg
    with cloud.sb.connect() as c:
        for role in ['anon', 'authenticated']:
            c.execute(f'set role {role}')
            for table in ['cloud_accounts', 'cloud_object_leases', 'cloud_delete_jobs']:
                with pytest.raises(psycopg.Error): c.execute(f'select * from {table}')
            with pytest.raises(psycopg.Error):
                c.execute("select cloud_lifecycle('request_delete', %s::uuid, '{}')", [str(uuid.uuid4())])
            c.execute('reset role')
        assert not c.execute("select has_function_privilege('service_role', 'public.commit_cloud_project_unleased(uuid,text,text,jsonb,bigint,timestamptz,boolean)', 'execute')").fetchone()[0]


def test_migration_can_be_reapplied_without_wrapping_the_wrapper(cloud):
    script = Path(__file__).resolve().parents[1] / 'migrations/006_cloud_lifecycle.sql'
    with cloud.sb.connect() as c:
        c.execute(script.read_text(encoding='utf-8'))
    u = cloud.user()
    _, key = prepared_copy(cloud, u)
    assert publish(cloud, u, key)['status'] == 'ok'


def test_migration_seeds_existing_project_accounts_without_losing_their_copy(cloud):
    from psycopg.types.json import Jsonb
    u = cloud.user()
    current = new_backup_key(u, 'legacy')
    old = f'vocals/{u}/legacy/up-{"a" * 32}.humtrack'
    cloud.r2.put(current, b'existing', age=timedelta(days=3))
    cloud.r2.put(old, b'orphan', age=timedelta(days=3))
    sql(cloud, 'insert into cloud_projects(user_id,project_id,title,meta) values(%s,%s,%s,%s)',
        [u, 'legacy', 'Legacy fixture', Jsonb({'key': current})])
    script = Path(__file__).resolve().parents[1] / 'migrations/006_cloud_lifecycle.sql'
    with cloud.sb.connect() as c:
        c.execute(script.read_text(encoding='utf-8'))
    lifecycle.tick(cloud.sb, apply=True, only_user_id=u)
    assert cloud.r2.data(current) == b'existing' and cloud.r2.data(old) is None


def test_provider_returning_another_account_key_fails_closed(cloud, monkeypatch):
    a, b = cloud.user(), cloud.user()
    lifecycle.ensure_account(cloud.sb, a)
    key = f'vocals/{b}/p/up-{"a" * 32}.humtrack'
    cloud.r2.put(key, b'other account', age=timedelta(days=2))
    original = storage_r2.list_objects_page
    monkeypatch.setattr(storage_r2, 'list_objects_page', lambda prefix, **kw: original(f'vocals/{b}/', **kw))
    result = lifecycle.tick(cloud.sb, apply=True, only_user_id=a)
    assert result['errors'] == 1
    assert cloud.r2.data(key) == b'other account' and not jobs(cloud, a)


def test_second_worker_skips_an_active_delete_claim_without_false_failure(cloud, monkeypatch):
    u = cloud.user()
    lifecycle.ensure_account(cloud.sb, u)
    key = f'vocals/{u}/p/up-{"a" * 32}.humtrack'
    cloud.r2.put(key, b'orphan', age=timedelta(days=2))
    lifecycle.enqueue(cloud.sb, u, [key], reason='orphan')
    entered, resume = threading.Event(), threading.Event()
    original = cloud.r2.delete_objects
    def hold(**kw):
        entered.set()
        assert resume.wait(8)
        return original(**kw)
    monkeypatch.setattr(cloud.r2, 'delete_objects', hold)
    with ThreadPoolExecutor(1) as pool:
        first = pool.submit(lifecycle.tick, cloud.sb, apply=True, only_user_id=u)
        assert entered.wait(8)
        try:
            second = lifecycle.tick(PgSupabase(cloud.sb.uri), apply=True, only_user_id=u)
            assert second['failed'] == 0 and second['deleted'] == 0
        finally:
            resume.set()
        assert first.result(timeout=10)['failed'] == 0
    assert cloud.r2.data(key) is None


def test_lifespan_runs_explicitly_enabled_cleanup(cloud, monkeypatch):
    from app import deps
    from app.main import app
    from app.settings import get_settings
    from fastapi.testclient import TestClient
    ran = threading.Event()
    monkeypatch.setenv('CLOUD_CLEANUP_ENABLED', 'true')
    get_settings.cache_clear()
    monkeypatch.setattr(deps, 'require_supabase', lambda: cloud.sb)
    def run(*args, **kw):
        assert kw['apply'] is True
        ran.set()
        return {'errors': 0}
    monkeypatch.setattr(lifecycle, 'tick', run)
    try:
        with TestClient(app):
            assert ran.wait(5)
    finally:
        get_settings.cache_clear()
