"""Image contract, revision and RLS against isolated real PostgreSQL only."""
import uuid

import pytest

from tests.cloud_fixtures import PG_URI
from tests.test_announcements_sql import db, insert, owner, row  # noqa: F401 (pytest fixture)
from tests.test_announcements_sql import ROOT

pytestmark = pytest.mark.skipif(not PG_URI, reason="CLOUD_TEST_PG_URI not set")
IMAGE = {
    "image_url": "https://hum-track.com/assets/notices/feedback-v2.png",
    "image_alt_ko": "둥지의 새",
    "image_alt_en": "A bird in a nest",
}


@pytest.fixture(scope="module")
def image_db(db):
    with owner(db) as c:
        # Match the hosted JWT helper in this isolated fixture database.
        c.execute("""create or replace function auth.jwt() returns jsonb language sql stable as
            $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$""")
        c.execute((ROOT / "migrations/006_announcements_admin.sql").read_text(encoding="utf-8"))
        for _ in range(2):
            c.execute((ROOT / "migrations/009_announcement_images.sql").read_text(encoding="utf-8"))
    return db


def test_text_only_notice_and_first_party_image_both_work(image_db):
    with owner(image_db) as c:
        insert(c, row("legacy-text"))
        insert(c, row("with-image", **IMAGE))
        assert c.execute("select image_url from app_announcements where id='legacy-text'").fetchone() == (None,)
        c.execute("set role anon")
        assert c.execute("select image_url from app_announcements where id='with-image'").fetchone()[0] == IMAGE["image_url"]


@pytest.mark.parametrize("bad", [
    {"image_alt_ko": None}, {"image_alt_en": ""}, {"image_alt_en": "   "},
    {"image_alt_ko": "x" * 301}, {"image_url": None},
    {"image_url": "http://hum-track.com/assets/notices/a.png"},
    {"image_url": "https://evil.example/assets/notices/a.png"},
    {"image_url": "https://hum-track.com.evil.io/assets/notices/a.png"},
    {"image_url": "https://user@hum-track.com/assets/notices/a.png"},
    {"image_url": "https://hum-track.com:443/assets/notices/a.png"},
    {"image_url": "https://hum-track.com/assets/notices/a.svg"},
    {"image_url": "https://hum-track.com/assets/notices/a.png?tracking=user"},
    {"image_url": "https://hum-track.com/assets/notices/../a.png"},
    {"image_url": "https://hum-track.com/assets/notices/a.png\n"},
    {"image_url": "data:image/png;base64,x"},
])
def test_bad_media_is_rejected_by_database(image_db, bad):
    import psycopg
    with owner(image_db) as c:
        with pytest.raises(psycopg.errors.CheckViolation):
            insert(c, row("invalid-" + uuid.uuid4().hex[:8], **{**IMAGE, **bad}))


def test_media_edits_bump_revision_but_schedule_edits_do_not(image_db):
    with owner(image_db) as c:
        insert(c, row("image-revision", published=False))
        revision = lambda: c.execute("select revision from app_announcements where id='image-revision'").fetchone()[0]
        c.execute("update app_announcements set image_url=%s,image_alt_ko=%s,image_alt_en=%s where id='image-revision'", tuple(IMAGE.values()))
        assert revision() == 2
        c.execute("update app_announcements set image_alt_en='Updated description' where id='image-revision'")
        assert revision() == 3
        c.execute("update app_announcements set ends_at=now()+interval '2 day' where id='image-revision'")
        assert revision() == 3
        c.execute("update app_announcements set image_url=null,image_alt_ko=null,image_alt_en=null where id='image-revision'")
        assert revision() == 4
        c.execute("update app_announcements set revision=8, image_url=%s,image_alt_ko=%s,image_alt_en=%s where id='image-revision'", tuple(IMAGE.values()))
        assert revision() == 8


def test_drafts_stay_private_and_only_admins_can_write_images(image_db):
    import psycopg
    with owner(image_db) as c:
        c.execute("set role authenticated")
        c.execute("set request.jwt.claims = '{\"email\":\"humtrack@gmail.com\",\"user_metadata\":{\"email_verified\":true}}'")
        insert(c, row("admin-image-draft", published=False, **IMAGE))
    for role in ("anon", "authenticated"):
        with owner(image_db) as c:
            c.execute(f"set role {role}")
            assert c.execute("select id from app_announcements where id='admin-image-draft'").fetchall() == []
            with pytest.raises(psycopg.Error):
                insert(c, row("unauthorized-" + role, **IMAGE))
