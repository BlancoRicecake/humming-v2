"""Migrations are named by full file name — two different files share 006.

- every migration file is listed in migrations/README.md (its apply record);
- every reference in the tools / fixtures / tests is an exact existing name,
  and nothing refers to a migration by its number alone;
- on a real (throwaway) PostgreSQL both 006 features apply together and keep
  their own permissions: the cloud chain (006_cloud_lifecycle, 007, 008) and
  the announcements chain (005, 006_announcements_admin).
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

from tests.cloud_fixtures import PG_URI

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
MIGRATIONS = ROOT / 'migrations'
NAMES = sorted(p.name for p in MIGRATIONS.glob('*.sql'))

# files that name migrations (the apply tools, fixtures, tests)
REFERRERS = [
    REPO / 'infra/scripts/prepare_cloud_staging_sql.py',
    ROOT / 'tests/cloud_fixtures.py',
    *sorted((ROOT / 'tests').glob('test_*.py')),
]


def test_both_006_files_exist_and_are_distinct():
    six = [n for n in NAMES if n.startswith('006_')]
    assert six == ['006_announcements_admin.sql', '006_cloud_lifecycle.sql']


def test_every_migration_is_in_the_apply_record():
    record = (MIGRATIONS / 'README.md').read_text(encoding='utf-8')
    for name in NAMES:
        assert f'`{name}`' in record, f'{name} missing from migrations/README.md'


def test_references_use_exact_full_names():
    # a migration-like name ("006_cloud_lifecycle") must be an exact file name
    ref = re.compile(r'\b(\d{3}_[a-z][a-z0-9_]*)\.sql\b')
    # and no code picks migrations by number (glob / prefix / sort on digits)
    by_number = re.compile(r"(glob|startswith|rglob)\(\s*['\"]\d{3}")
    seen = set()
    for path in REFERRERS:
        if path.name == Path(__file__).name or not path.exists():
            continue
        text = path.read_text(encoding='utf-8')
        assert not by_number.search(text), f'{path.name} selects migrations by number'
        for m in ref.finditer(text):
            token = m.group(1) + '.sql'
            assert token in NAMES, (
                f'{path.name}: "{m.group(0)}" is not an exact migration file name'
            )
            seen.add(token)
    assert '006_cloud_lifecycle.sql' in seen  # the fixtures name it in full
    # the staging tool really names the cloud 006, never the number alone
    # (the repo checkout only; a backend-only test image has no infra/)
    tool = REPO / 'infra/scripts/prepare_cloud_staging_sql.py'
    if tool.exists():
        staging = tool.read_text(encoding='utf-8')
        assert 'backend/migrations/006_cloud_lifecycle.sql' in staging
        assert '006_announcements_admin' not in staging  # never applied to staging


_AUTH_JWT = """
create or replace function auth.jwt() returns jsonb language sql stable as
  $f$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $f$;
grant execute on function auth.jwt() to anon, authenticated, service_role;
"""


@pytest.mark.skipif(not PG_URI, reason='CLOUD_TEST_PG_URI not set')
def test_both_006_features_apply_together_with_their_own_permissions():
    import psycopg

    from tests.cloud_fixtures import create_database

    uri = create_database()  # cloud chain: ... 004, 006_cloud_lifecycle, 007, 008
    with psycopg.connect(uri, autocommit=True) as c:
        c.execute(_AUTH_JWT)
        for name in ['005_app_announcements.sql', '006_announcements_admin.sql']:
            c.execute((MIGRATIONS / name).read_text(encoding='utf-8'))

        def one(sql, *args):
            # no parameters: no placeholder parsing (LIKE 'cloud_%')
            cur = c.execute(sql, args) if args else c.execute(sql)
            return cur.fetchone()[0]

        # cloud 006 objects are there (from the cloud chain)
        assert one("select count(*) from pg_proc where proname like 'cloud_%'") > 0
        # announcements: read policy for everyone, write policy for admins
        policies = {r[0] for r in c.execute(
            "select policyname from pg_policies where tablename = 'app_announcements'")}
        assert policies == {'read_published_active', 'admin_all'}
        # the admin list: closed to the API roles, one seeded admin
        assert one("select count(*) from public.app_admins") == 1
        for role in ['anon', 'authenticated']:
            assert one("select has_table_privilege(%s, 'public.app_admins', 'select')", role) is False
        assert one("select has_function_privilege('anon', 'public.is_app_admin()', 'execute')") is False
        assert one("select has_function_privilege('authenticated', 'public.is_app_admin()', 'execute')") is True

        def as_user(email: str | None):
            c.execute('reset role')
            claims = '{}' if email is None else '{"email": "%s"}' % email
            c.execute("select set_config('request.jwt.claims', %s, false)", (claims,))
            c.execute('set role authenticated')

        row = ("insert into public.app_announcements (id, kind, title_ko, title_en, body_ko, body_en, published) "
               "values (%s, 'info', 't', 't', 'b', 'b', false)")
        # a non-admin cannot write, nor see drafts
        as_user('someone@example.com')
        with pytest.raises(psycopg.errors.InsufficientPrivilege):
            c.execute(row, ('not-admin',))
        # the admin can write a draft and read it back; others can't see it
        as_user('HumTrack@gmail.com')  # e-mail match ignores case
        c.execute(row, ('admin-draft',))
        assert one("select count(*) from public.app_announcements where id = 'admin-draft'") == 1
        as_user('someone@example.com')
        assert one("select count(*) from public.app_announcements where id = 'admin-draft'") == 0
        c.execute('reset role')
