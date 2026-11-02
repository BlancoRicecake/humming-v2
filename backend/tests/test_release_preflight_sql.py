"""Validate the operator's read-only schema report on actual PostgreSQL."""
from pathlib import Path

import pytest

from tests.cloud_fixtures import PG_URI
from tests.test_cloud_backup import db_uri

pytestmark = pytest.mark.skipif(not PG_URI, reason='CLOUD_TEST_PG_URI not set')
ROOT = Path(__file__).resolve().parents[1]
REPORT = (ROOT / 'sql/2026-10-31_release_preflight_readonly.sql').read_text(encoding='utf-8')


def test_schema_report_is_readonly_and_detects_missing_migration_and_access(db_uri):
    import psycopg
    with psycopg.connect(db_uri) as connection:
        # Missing announcement migration must be reported, never silently passed.
        connection.execute('set transaction read only')
        checks = {name: passed for name, passed, _ in connection.execute(REPORT)}
        assert checks['table_rls:app_announcements'] is False
        assert checks['leased_commit_wrapper'] is True
        connection.rollback()
        connection.execute((ROOT / 'migrations/005_app_announcements.sql').read_text(encoding='utf-8'))
        connection.commit()
        connection.execute('set transaction read only')
        rows = list(connection.execute(REPORT))
        assert len(rows) == 24
        assert all(passed for _, passed, _ in rows), rows
        connection.rollback()
        # An accidental client grant on a private queue must fail the report.
        connection.execute('grant select on public.cloud_delete_jobs to anon')
        checks = {name: passed for name, passed, _ in connection.execute(REPORT)}
        assert checks['private_client_access:cloud_delete_jobs'] is False
        connection.rollback()


def test_legacy_rpc_repair_revokes_direct_api_role_grants(db_uri):
    import psycopg
    import uuid
    with psycopg.connect(db_uri) as connection:
        connection.execute('grant execute on function public.upsert_cloud_project(uuid,text,text,jsonb,bigint) to anon,authenticated')
        connection.execute('grant execute on function public.delete_cloud_project(uuid,text) to anon,authenticated')
        assert connection.execute("select has_function_privilege('anon','public.delete_cloud_project(uuid,text)','execute')").fetchone()[0]
        connection.execute((ROOT / 'migrations/007_lock_legacy_cloud_rpcs.sql').read_text(encoding='utf-8'))
        for role in ('anon','authenticated'):
            for signature,query,params in (
                ('public.delete_cloud_project(uuid,text)', 'select public.delete_cloud_project(%s,%s)',(uuid.uuid4(),'qa')),
                ('public.upsert_cloud_project(uuid,text,text,jsonb,bigint)', "select public.upsert_cloud_project(%s,%s,%s,'{}'::jsonb,0)",(uuid.uuid4(),'qa','QA')),
            ):
                assert connection.execute('select has_function_privilege(%s,%s,\'execute\')',(role,signature)).fetchone()[0] is False
                assert connection.execute("select has_function_privilege('service_role',%s,'execute')",(signature,)).fetchone()[0] is True
                with pytest.raises(psycopg.errors.InsufficientPrivilege):
                    with connection.transaction():
                        connection.execute('set local role '+role)
                        connection.execute(query,params)
        connection.rollback()
