"""Announcements feed (migration 005) on a REAL PostgreSQL (2026-10-30).

The apps read as PostgREST does: `anon` / `authenticated` roles with RLS.
Checked: only published + active rows are visible (drafts, scheduled and
ended ones are not), clients can't write, the revision trigger, and the
constraints that refuse bad rows. Fixture rows only; nothing is published
anywhere. Needs CLOUD_TEST_PG_URI (see artifacts/announcements-2026-10-30).
"""
from __future__ import annotations

import uuid
from pathlib import Path

import pytest

from tests.cloud_fixtures import PG_URI, _BOOTSTRAP

pytestmark = pytest.mark.skipif(not PG_URI, reason="CLOUD_TEST_PG_URI not set")

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module")
def db():
    import psycopg

    name = f"anntest_{uuid.uuid4().hex[:10]}"
    with psycopg.connect(PG_URI, autocommit=True) as c:
        c.execute(f'create database "{name}"')
    uri = PG_URI.rsplit("/", 1)[0] + "/" + name
    with psycopg.connect(uri, autocommit=True) as c:
        c.execute(_BOOTSTRAP)
        c.execute((ROOT / "migrations" / "005_app_announcements.sql").read_text(encoding="utf-8"))
        # applied twice: the migration is re-runnable
        c.execute((ROOT / "migrations" / "005_app_announcements.sql").read_text(encoding="utf-8"))
    return uri


def owner(db):
    import psycopg

    return psycopg.connect(db, autocommit=True)


def row(id_, **kw):
    base = {
        "id": id_,
        "kind": "info",
        "title_ko": "제목",
        "title_en": "Title",
        "body_ko": "본문",
        "body_en": "Body",
        "published": True,
        "starts_at": "now() - interval '1 hour'",
        "ends_at": "null",
    }
    base.update(kw)
    return base


def insert(c, r):
    cols, vals, params = [], [], []
    for k, v in r.items():
        cols.append(k)
        if isinstance(v, str) and (v.startswith("now()") or v == "null"):
            vals.append(v)
        else:
            vals.append("%s")
            params.append(v)
    c.execute(f"insert into public.app_announcements ({', '.join(cols)}) values ({', '.join(vals)})", params)


def visible(db, role="anon"):
    with owner(db) as c:
        c.execute(f"set role {role}")
        return {r[0] for r in c.execute("select id from public.app_announcements").fetchall()}


def test_only_published_and_active_rows_are_visible(db):
    with owner(db) as c:
        c.execute("delete from public.app_announcements")
        insert(c, row("live"))
        insert(c, row("draft", published=False))
        insert(c, row("scheduled", starts_at="now() + interval '1 day'"))
        insert(c, row("ended", starts_at="now() - interval '2 day'", ends_at="now() - interval '1 day'"))
        insert(c, row("until-tomorrow", ends_at="now() + interval '1 day'"))
    for role in ("anon", "authenticated"):
        assert visible(db, role) == {"live", "until-tomorrow"}
    # filters in the query can't reveal drafts either
    with owner(db) as c:
        c.execute("set role anon")
        assert c.execute("select count(*) from public.app_announcements where published = false").fetchone()[0] == 0


def test_clients_cannot_write_or_unpublish(db):
    import psycopg

    with owner(db) as c:
        c.execute("delete from public.app_announcements")
        insert(c, row("live"))
    for role in ("anon", "authenticated"):
        for sql in [
            "insert into public.app_announcements (id, kind, title_ko, title_en, body_ko, body_en, published) values ('x', 'critical', 't', 't', 'b', 'b', true)",
            "update public.app_announcements set title_en = 'hacked'",
            "delete from public.app_announcements",
        ]:
            with owner(db) as c:
                c.execute(f"set role {role}")
                with pytest.raises(psycopg.Error):
                    c.execute(sql)
    with owner(db) as c:
        assert c.execute("select title_en from public.app_announcements where id = 'live'").fetchone()[0] == "Title"
    with owner(db) as c:
        c.execute("set role anon")
        with pytest.raises(psycopg.Error):
            c.execute("select public.app_announcements_revision()")


def test_revision_rises_with_content_only_and_never_falls(db):
    import psycopg

    with owner(db) as c:
        c.execute("delete from public.app_announcements")
        insert(c, row("r", published=False))
        rev = lambda: c.execute("select revision from public.app_announcements where id = 'r'").fetchone()[0]
        assert rev() == 1
        c.execute("update public.app_announcements set published = true, ends_at = now() + interval '3 day', platforms = array['windows'] where id = 'r'")
        assert rev() == 1, "publishing / scheduling / targeting keeps the revision"
        c.execute("update public.app_announcements set body_ko = '고친 본문' where id = 'r'")
        assert rev() == 2, "a content edit is a new revision even if the editor forgot"
        c.execute("update public.app_announcements set revision = 5, title_en = 'New' where id = 'r'")
        assert rev() == 5, "an explicit raise is kept (not raised twice)"
        with pytest.raises(psycopg.Error):
            c.execute("update public.app_announcements set revision = 3 where id = 'r'")
        assert rev() == 5


@pytest.mark.parametrize(
    "bad",
    [
        {"kind": "urgent"},
        {"id": "Bad ID!"},
        {"title_en": ""},
        {"body_ko": "x" * 4001},
        {"starts_at": "now()", "ends_at": "now() - interval '1 hour'"},
        {"platforms": ["windows", "linux"]},
        {"platforms": []},
        {"min_build": 50, "max_build": 40},
        {"action_url": "http://hum-track.com/x", "action_label_ko": "열기", "action_label_en": "Open"},
        {"action_url": "https://evil.example/hum-track.com", "action_label_ko": "열기", "action_label_en": "Open"},
        {"action_url": "file:///C:/Windows", "action_label_ko": "열기", "action_label_en": "Open"},
        {"action_url": "https://hum-track.com/a"},  # labels missing
    ],
)
def test_bad_rows_are_refused(db, bad):
    import psycopg

    with owner(db) as c:
        with pytest.raises(psycopg.Error):
            insert(c, row(f"bad-{uuid.uuid4().hex[:6]}", **bad) if "id" not in bad else row(bad["id"], **{k: v for k, v in bad.items() if k != "id"}))


def test_good_actions_and_targets_are_accepted(db):
    with owner(db) as c:
        c.execute("delete from public.app_announcements")
        for i, url in enumerate([
            "https://hum-track.com/status",
            "https://www.hum-track.com/news/1",
            "https://apps.apple.com/app/id1",
            "mailto:humtrack@gmail.com",
        ]):
            insert(c, row(f"ok{i}", action_url=url, action_label_ko="열기", action_label_en="Open",
                          platforms=["windows", "macos"], min_build=40, max_build=60))
    assert visible(db) == {"ok0", "ok1", "ok2", "ok3"}
