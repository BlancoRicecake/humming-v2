"""Real-PG health/ACL/failure evidence; no provider credentials or customer data."""
import json
import uuid

import pytest

from app import cloud_monitor, cloud_lifecycle
from tests.cloud_fixtures import PG_URI, PgSupabase, create_database

pytestmark = pytest.mark.skipif(not PG_URI, reason='CLOUD_TEST_PG_URI not set')


@pytest.fixture
def sb():
    return PgSupabase(create_database())


def completed(sb, *, scheduled=True, counts=None):
    worker = str(uuid.uuid4())
    cloud_monitor.record(sb, worker, 'running', scheduled=scheduled)
    cloud_monitor.record(sb, worker, 'ok', counts, scheduled=scheduled)
    return worker


def test_empty_queue_and_manual_run_do_not_certify_scheduler(sb):
    assert cloud_monitor.health(sb)['alerts'] == ['scheduled_worker_missing']
    completed(sb, scheduled=False)
    assert cloud_monitor.health(sb)['healthy'] is False
    assert cloud_monitor.health(sb)['alerts'] == ['scheduled_worker_missing']


def test_actual_empty_pass_records_healthy_scheduled_worker(sb):
    result = cloud_monitor.run_pass(sb, worker_id=str(uuid.uuid4()), scheduled=True)
    assert result['errors'] == 0
    report = cloud_monitor.health(sb)
    assert report['healthy'] is True and report['last_counts']['accounts'] == 0
    assert report['worker_state'] == 'ok' and report['last_ok_at']


def test_stalled_worker_is_not_healthy(sb):
    worker = completed(sb)
    with sb.connect() as c:
        c.execute("update cloud_cleanup_workers set started_at=now()-interval '10 minutes',last_ok_at=now()-interval '10 minutes' where worker_id=%s", [worker])
    assert cloud_monitor.health(sb)['alerts'] == ['scheduled_worker_stale']


def test_exception_records_failure_without_exception_text(sb, monkeypatch):
    def broken(*args, **kwargs):
        raise RuntimeError('signed-url-and-token-must-not-be-stored')
    monkeypatch.setattr(cloud_lifecycle, 'tick', broken)
    with pytest.raises(RuntimeError):
        cloud_monitor.run_pass(sb, worker_id=str(uuid.uuid4()), scheduled=True)
    report = cloud_monitor.health(sb)
    assert report['alerts'] == ['worker_pass_failed']
    assert report['last_counts'] == {'errors': 1}
    assert 'signed-url' not in json.dumps(report)


def test_partial_failure_and_only_allowlisted_counts_persist(sb, monkeypatch, caplog):
    monkeypatch.setattr(cloud_lifecycle, 'tick', lambda *a, **kw: {'failed': 1, 'accounts': 2, 'title': 'private-title'})
    cloud_monitor.run_pass(sb, worker_id=str(uuid.uuid4()), scheduled=True)
    report = cloud_monitor.health(sb)
    assert report['alerts'] == ['worker_pass_failed']
    assert report['last_counts'] == {'failed': 1, 'accounts': 2}
    assert 'private-title' not in json.dumps(report) + caplog.text


def test_api_roles_cannot_access_private_worker_table_or_rpc(sb):
    import psycopg
    with sb.connect() as c:
        for role in ('anon', 'authenticated'):
            for query in ("select * from public.cloud_cleanup_workers", "select public.cloud_cleanup_health()",
                          "select public.record_cloud_cleanup_pass(gen_random_uuid(),'running','{}','scheduled')"):
                with pytest.raises(psycopg.errors.InsufficientPrivilege):
                    with c.transaction():
                        c.execute('set local role '+role)
                        c.execute(query)
        with c.transaction():
            c.execute('set local role service_role')
            c.execute("select public.record_cloud_cleanup_pass(gen_random_uuid(),'running','{}','manual')")
            assert c.execute('select public.cloud_cleanup_health()').fetchone()[0]['healthy'] is False


def test_queue_and_deletion_overdue_report_contains_no_customer_identifiers(sb):
    completed(sb)
    a,b=uuid.uuid4(),uuid.uuid4()
    with sb.connect() as c:
        c.execute("insert into cloud_accounts(user_id,delete_requested_at,next_sweep_at) values(%s,now()-interval '2 hours',now()-interval '1 hour')", [a])
        c.execute("insert into cloud_accounts(user_id,delete_requested_at,auth_deleted_at,purge_after) values(%s,now()-interval '2 hours',now()-interval '2 hours',now()-interval '1 hour')", [b])
        c.execute("insert into cloud_delete_jobs(object_key,user_id,project_id,reason,created_at) values('private-object-key',%s,'private-project','account_delete',now()-interval '2 hours')",[a])
    report=cloud_monitor.health(sb)
    assert set(report['alerts']) == {'delete_queue_old','account_scans_overdue','auth_deletion_overdue','primary_purge_overdue'}
    assert report['old_delete_jobs']==1 and report['overdue_auth_deletions']==1 and report['overdue_primary_purges']==1
    assert all(value not in json.dumps(report) for value in [str(a),str(b),'private-object-key','private-project'])


def test_sql_redaction_and_worker_retention_preserve_customer_tombstones(sb):
    worker=completed(sb);u=uuid.uuid4()
    with sb.connect() as c:
        c.execute("update cloud_cleanup_workers set started_at=now()-interval '8 days' where worker_id=%s",[worker])
        c.execute("insert into cloud_accounts(user_id,delete_requested_at) values(%s,now()-interval '8 days')",[u])
        fresh=uuid.uuid4()
        c.execute("select record_cloud_cleanup_pass(%s,'running','{}','scheduled')",[fresh])
        c.execute("select record_cloud_cleanup_pass(%s,'ok',%s::jsonb,'scheduled')",[fresh,json.dumps({'title':'private','objects':4,'errors':'private'})])
        assert c.execute('select counts from cloud_cleanup_workers where worker_id=%s',[fresh]).fetchone()[0]=={'objects':4}
        assert c.execute('select count(*) from cloud_cleanup_workers where worker_id=%s',[worker]).fetchone()[0]==0
        assert c.execute('select count(*) from cloud_accounts where user_id=%s',[u]).fetchone()[0]==1


def test_monitor_cli_failure_prints_sanitized_json(monkeypatch,capsys):
    from app import deps
    def unavailable():raise RuntimeError('private service credential')
    monkeypatch.setattr(deps,'require_supabase',unavailable)
    with pytest.raises(SystemExit) as error:cloud_monitor.main()
    assert error.value.code==1
    output=capsys.readouterr().out
    assert json.loads(output)=={'healthy':False,'alerts':['cloud_cleanup_health_unavailable']}
    assert 'credential' not in output
