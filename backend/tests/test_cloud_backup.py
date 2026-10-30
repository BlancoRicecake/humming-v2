"""Cloud backup contract 1 (2026-10-30) against a REAL PostgreSQL with the
production schema files (sql/2026-06-04 + migrations 003/004) and an
in-memory R2 that enforces the signed PUT rules (see cloud_fixtures).

What is proven here vs. not:
- Atomic pointer switch and RLS: real Postgres, real concurrent connections.
- R2 behaviour (signed Content-Length, If-None-Match create-only, CopyObject)
  is the FakeR2 stand-in — NOT verified against the real bucket.

Needs CLOUD_TEST_PG_URI (see artifacts/cloud-backup-2026-10-30/README.md).
"""
from __future__ import annotations

import hashlib
import logging
import threading
import uuid
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient

from app import cloud_quota, storage_r2
from app.routes import projects as projects_mod
from app.routes import storage as storage_mod
from app.settings import get_settings

from tests.cloud_fixtures import PG_URI, FakeR2, PgSupabase, create_database
from tests.iap_fixtures import hs256_token

pytestmark = pytest.mark.skipif(not PG_URI, reason="CLOUD_TEST_PG_URI not set")

SECRET = "test-jwt-secret-please-ignore"


@pytest.fixture(scope="module")
def db_uri():
    return create_database()


@pytest.fixture
def env(monkeypatch, db_uri):
    monkeypatch.setenv("SUPABASE_JWT_SECRET", SECRET)
    monkeypatch.setenv("CLOUD_SYNC_ENABLED", "1")
    monkeypatch.setenv("CLOUD_QUOTA_PRO_BYTES", str(10_000))
    get_settings.cache_clear()
    sb = PgSupabase(db_uri)
    r2 = FakeR2()
    pro: set = set()
    monkeypatch.setattr(projects_mod, "require_supabase", lambda: sb)
    monkeypatch.setattr(storage_mod, "require_supabase", lambda: sb)
    monkeypatch.setattr(cloud_quota, "user_is_pro", lambda uid: uid in pro)
    monkeypatch.setattr(storage_r2, "get_r2_client", lambda: r2)
    yield sb, r2, pro
    get_settings.cache_clear()


@pytest.fixture
def client():
    from app.main import app

    with TestClient(app) as c:
        yield c


class Cloud:
    def __init__(self, client, sb, r2, pro):
        self.c, self.sb, self.r2, self.pro = client, sb, r2, pro

    def user(self, *, pro=True) -> str:
        uid = str(uuid.uuid4())
        self.sb.add_user(uid)
        if pro:
            self.pro.add(uid)
        return uid

    @staticmethod
    def h(uid):
        return {"Authorization": f"Bearer {hs256_token(SECRET, uid)}"}

    def presign(self, uid, pid, size, **extra):
        return self.c.post(
            "/storage/presign",
            json={"project_id": pid, "size_bytes": size, **extra},
            headers=self.h(uid),
        )

    def upload(self, uid, pid, data: bytes):
        r = self.presign(uid, pid, len(data))
        assert r.status_code == 200, r.text
        body = r.json()
        assert self.r2.client_put(body["url"], data, body["headers"]) == 200
        return body

    @staticmethod
    def meta(key, data, *, audio=True):
        return {
            "format": "humtrack",
            "formatVersion": 1,
            "key": key,
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "audioIncluded": audio,
            "takes": 1 if audio else 0,
            "missingTakes": 0,
            "songSchema": 3,
        }

    def commit(self, uid, pid, key, data, *, expected=None, absent=False, title="Song", meta=None):
        body = {"project_id": pid, "title": title, "meta": meta or self.meta(key, data)}
        if expected is not None:
            body["expected_updated_at"] = expected
        if absent:
            body["expect_absent"] = True
        return self.c.post("/projects", json=body, headers=self.h(uid))

    def backup(self, uid, pid, data, **kw):
        up = self.upload(uid, pid, data)
        r = self.commit(uid, pid, up["key"], data, **kw)
        return up, r

    def current(self, uid, pid):
        r = self.c.get(f"/projects/{pid}", headers=self.h(uid))
        return r.json() if r.status_code == 200 else None


@pytest.fixture
def cloud(client, env):
    sb, r2, pro = env
    return Cloud(client, sb, r2, pro)


# ── flag, contract, gate ────────────────────────────────────────────────────
def test_flag_off_hides_everything(client, env, monkeypatch, cloud):
    monkeypatch.setenv("CLOUD_SYNC_ENABLED", "0")
    get_settings.cache_clear()
    u = cloud.user()
    for r in [
        client.get("/projects", headers=cloud.h(u)),
        client.get("/storage/usage", headers=cloud.h(u)),
        cloud.presign(u, "lt1", 10),
    ]:
        assert r.status_code == 404


def test_usage_reports_contract_and_measured_bytes(cloud):
    u = cloud.user()
    cloud.backup(u, "lt1", b"x" * 300, absent=True)
    r = cloud.c.get("/storage/usage", headers=cloud.h(u)).json()
    assert r["contract"] == 1
    assert r["used_bytes"] == 300  # what R2 holds, not what the app said
    assert r["quota_bytes"] == 10_000


def test_free_user_cannot_upload_but_lapsed_can_read_and_delete(cloud):
    u = cloud.user()
    data = b"a" * 100
    up, r = cloud.backup(u, "lt1", data, absent=True)
    assert r.status_code == 200
    cloud.pro.discard(u)  # subscription ended
    assert cloud.presign(u, "lt2", 10).status_code == 403
    assert cloud.commit(u, "lt1", up["key"], data, expected=r.json()["updated_at"]).status_code == 403
    assert cloud.c.get("/projects?include=meta", headers=cloud.h(u)).status_code == 200
    key = cloud.current(u, "lt1")["meta"]["key"]
    assert cloud.c.post("/storage/presign_get", json={"key": key}, headers=cloud.h(u)).status_code == 200
    assert cloud.c.delete("/projects/lt1", headers=cloud.h(u)).status_code == 204
    assert cloud.current(u, "lt1") is None
    assert not [k for k in cloud.r2.objects if k.startswith(f"vocals/{u}/")]


# ── account isolation ───────────────────────────────────────────────────────
def test_accounts_are_isolated(cloud):
    a, b = cloud.user(), cloud.user()
    data = b"A" * 120
    _, r = cloud.backup(a, "lt1", data, absent=True)
    assert r.status_code == 200
    a_key = cloud.current(a, "lt1")["meta"]["key"]
    # B can't see, download, commit into or delete A's copy
    assert cloud.c.get("/projects", headers=cloud.h(b)).json() == []
    assert cloud.current(b, "lt1") is None
    assert cloud.c.post("/storage/presign_get", json={"key": a_key}, headers=cloud.h(b)).status_code == 403
    b_up = cloud.upload(b, "lt1", b"B" * 50)
    forged = a_key.replace("bk-", "up-")
    assert cloud.commit(b, "lt1", forged, b"B" * 50, absent=True).status_code == 403
    a_up = f"vocals/{a}/lt1/up-{'c' * 32}.humtrack"
    cloud.r2.put(a_up, b"C" * 50)
    assert cloud.commit(b, "lt1", a_up, b"C" * 50, absent=True).status_code == 403
    assert cloud.c.delete("/projects/lt1", headers=cloud.h(b)).status_code == 204  # B's own (absent)
    assert cloud.r2.data(a_key) == data
    assert cloud.current(a, "lt1")["meta"]["key"] == a_key
    assert b_up["key"].startswith(f"vocals/{b}/")


def test_rls_blocks_direct_client_writes(db_uri):
    """Through PostgREST a user acts as `authenticated` with RLS: they may
    read their own rows and nothing else, and can't write or call the RPCs."""
    import psycopg

    sb = PgSupabase(db_uri)
    a, b = str(uuid.uuid4()), str(uuid.uuid4())
    sb.add_user(a)
    sb.add_user(b)
    with sb.connect() as c:
        c.execute(
            "select public.commit_cloud_project(%s::uuid, 'lt1', 't', '{}'::jsonb, 1, null, true)",
            [a],
        )
    with sb.connect() as c:
        c.execute("set role authenticated")
        c.execute("select set_config('request.jwt.claim.sub', %s, false)", [a])
        assert c.execute("select count(*) from public.cloud_projects").fetchone()[0] == 1
        c.execute("select set_config('request.jwt.claim.sub', %s, false)", [b])
        assert c.execute("select count(*) from public.cloud_projects").fetchone()[0] == 0
        for sql in [
            "insert into public.cloud_projects (user_id, project_id, title, meta) values (auth.uid(), 'x', 't', '{}')",
            "update public.cloud_quota set used_bytes = 0",
        ]:
            try:
                changed = c.execute(sql).rowcount
            except psycopg.Error:
                changed = 0  # refused by the policy / grants
            assert changed == 0
        with pytest.raises(psycopg.Error):
            c.execute(
                "select public.commit_cloud_project(auth.uid(), 'y', 't', '{}'::jsonb, 1, null, true)"
            )


# ── the previous good copy survives every failure ───────────────────────────
def test_replace_keeps_old_until_switch_then_removes_it(cloud):
    u = cloud.user()
    v1 = b"1" * 200
    _, r1 = cloud.backup(u, "lt1", v1, absent=True)
    k1 = cloud.current(u, "lt1")["meta"]["key"]
    v2 = b"2" * 220
    up2 = cloud.upload(u, "lt1", v2)
    # uploaded but not committed (app closed / cancelled): v1 untouched
    assert cloud.current(u, "lt1")["meta"]["key"] == k1
    assert cloud.r2.data(k1) == v1
    r2_ = cloud.commit(u, "lt1", up2["key"], v2, expected=r1.json()["updated_at"])
    assert r2_.status_code == 200, r2_.text
    k2 = cloud.current(u, "lt1")["meta"]["key"]
    assert k2 != k1 and cloud.r2.data(k2) == v2
    assert cloud.r2.data(k1) is None, "replaced copy removed after the switch"
    assert cloud.r2.data(up2["key"]) is None, "upload object removed after copy"


def test_stale_device_gets_409_and_changes_nothing(cloud):
    u = cloud.user()
    _, r1 = cloud.backup(u, "lt1", b"1" * 100, absent=True)
    t1 = r1.json()["updated_at"]
    _, r2_ = cloud.backup(u, "lt1", b"2" * 100, expected=t1)  # other device
    k2 = cloud.current(u, "lt1")["meta"]["key"]
    up3 = cloud.upload(u, "lt1", b"3" * 100)
    r3 = cloud.commit(u, "lt1", up3["key"], b"3" * 100, expected=t1)  # stale
    assert r3.status_code == 409
    assert r3.json()["detail"]["cloud_version"]["meta"]["key"] == k2
    assert cloud.r2.data(k2) == b"2" * 100
    # "keep this device's": retry the same upload against the version shown
    r4 = cloud.commit(u, "lt1", up3["key"], b"3" * 100, expected=r3.json()["detail"]["cloud_version"]["updated_at"])
    assert r4.status_code == 200
    assert cloud.r2.data(cloud.current(u, "lt1")["meta"]["key"]) == b"3" * 100
    # a first-upload claim against an existing copy is a conflict too
    up5 = cloud.upload(u, "lt1", b"5" * 10)
    assert cloud.commit(u, "lt1", up5["key"], b"5" * 10, absent=True).status_code == 409


def test_over_quota_upload_is_removed_and_old_copy_kept(cloud):
    u = cloud.user()
    _, r1 = cloud.backup(u, "lt1", b"1" * 6000, absent=True)
    k1 = cloud.current(u, "lt1")["meta"]["key"]
    # presign refuses a size that can't fit
    assert cloud.presign(u, "lt1", 5000).status_code == 412
    # an object that got there anyway (raced past presign) is refused at commit
    sneaky = f"vocals/{u}/lt1/up-{'0' * 32}.humtrack"
    cloud.r2.put(sneaky, b"9" * 5000)
    r = cloud.commit(u, "lt1", sneaky, b"9" * 5000, expected=r1.json()["updated_at"])
    assert r.status_code == 412
    assert cloud.r2.data(sneaky) is None
    assert cloud.current(u, "lt1")["meta"]["key"] == k1 and cloud.r2.data(k1) == b"1" * 6000


def test_commit_checks_object_and_descriptor(cloud):
    u = cloud.user()
    up = cloud.upload(u, "lt1", b"x" * 64)
    # wrong declared size / missing object / not a descriptor / no version claim
    assert cloud.commit(u, "lt1", up["key"], b"y" * 65).status_code == 422
    missing = f"vocals/{u}/lt1/up-{'1' * 32}.humtrack"
    assert cloud.commit(u, "lt1", missing, b"x" * 64, absent=True).status_code == 404
    assert cloud.commit(u, "lt1", up["key"], b"x", absent=True, meta={"tracks": []}).status_code == 422
    assert cloud.c.post(
        "/projects",
        json={"project_id": "lt1", "title": "t", "meta": cloud.meta(up["key"], b"x" * 64)},
        headers=cloud.h(u),
    ).status_code == 422
    assert cloud.current(u, "lt1") is None


# ── Codex review 2026-10-30: the PUT path can't touch a committed copy ──────
def test_upload_keys_are_server_made_and_never_a_committed_key(cloud):
    u = cloud.user()
    _, r1 = cloud.backup(u, "lt1", b"good" * 25, absent=True)
    k1 = cloud.current(u, "lt1")["meta"]["key"]
    # asking for the committed name (or any name) gets a fresh upload key
    r = cloud.presign(u, "lt1", 10, file_name=k1.rsplit("/", 1)[1])
    assert r.status_code == 200
    assert r.json()["key"] != k1 and "/up-" in r.json()["key"]
    # and that key can't be committed under another name family
    assert cloud.commit(u, "lt1", k1, b"good" * 25, expected=r1.json()["updated_at"]).status_code == 403
    assert cloud.r2.data(k1) == b"good" * 25


def test_reusing_an_upload_url_after_commit_never_changes_the_backup(cloud):
    u = cloud.user()
    good = b"good" * 25
    up, r = cloud.backup(u, "lt1", good, absent=True)
    k1 = cloud.current(u, "lt1")["meta"]["key"]
    # the same URL again: the bytes land on the (deleted) upload name at most
    status = cloud.r2.client_put(up["url"], b"evil" * 25, up["headers"])
    assert status in (200, 412)
    assert cloud.r2.data(k1) == good
    assert cloud.current(u, "lt1")["meta"]["key"] == k1
    # while the upload object still exists (before commit), create-only holds
    up2 = cloud.upload(u, "lt1", b"next" * 25)
    assert cloud.r2.client_put(up2["url"], b"evil" * 25, up2["headers"]) == 412
    assert cloud.r2.data(up2["key"]) == b"next" * 25


def test_size_is_required_and_signed(cloud):
    u = cloud.user()
    r = cloud.c.post("/storage/presign", json={"project_id": "lt1", "file_name": "a.humtrack"}, headers=cloud.h(u))
    assert r.status_code == 422
    body = cloud.presign(u, "lt1", 100).json()
    assert body["headers"]["Content-Length"] == "100"
    assert body["headers"]["If-None-Match"] == "*"
    assert cloud.r2.client_put(body["url"], b"z" * 5000, {**body["headers"], "Content-Length": "5000"}) == 403
    assert cloud.r2.client_put(body["url"], b"z" * 100, {"Content-Type": "application/octet-stream", "Content-Length": "100"}) == 403


@pytest.mark.parametrize("pid", ["a/b", "a b", "a.b", "../x", "x" * 101, "가나"])
def test_project_ids_that_would_share_a_prefix_are_refused(cloud, pid):
    u = cloud.user()
    assert cloud.presign(u, pid, 10).status_code == 422
    assert cloud.c.delete(f"/projects/{pid}", headers=cloud.h(u)).status_code in (404, 405, 422)


def test_deleting_one_song_never_touches_a_similar_one(cloud):
    u = cloud.user()
    cloud.backup(u, "a_b", b"1" * 10, absent=True)
    cloud.backup(u, "a_b2", b"2" * 10, absent=True)
    keep = cloud.current(u, "a_b2")["meta"]["key"]
    assert cloud.c.delete("/projects/a_b", headers=cloud.h(u)).status_code == 204
    assert cloud.r2.data(keep) == b"2" * 10


def test_orphans_only_old_ones_are_swept(cloud):
    u = cloud.user()
    _, r1 = cloud.backup(u, "lt1", b"1" * 10, absent=True)
    old = f"vocals/{u}/lt1/up-{'a' * 32}.humtrack"
    young = f"vocals/{u}/lt1/up-{'b' * 32}.humtrack"
    cloud.r2.put(old, b"o" * 10, age=timedelta(hours=30))
    cloud.r2.put(young, b"y" * 10, age=timedelta(minutes=5))  # another device mid-upload
    cloud.backup(u, "lt1", b"2" * 10, expected=r1.json()["updated_at"])
    assert cloud.r2.data(old) is None
    assert cloud.r2.data(young) == b"y" * 10


# ── concurrency (real Postgres, concurrent requests) ────────────────────────
def _race(n, fn):
    out = [None] * n
    gate = threading.Barrier(n)

    def run(i):
        gate.wait()
        out[i] = fn(i)

    ts = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    return out


def test_concurrent_replacements_exactly_one_wins(cloud):
    u = cloud.user()
    _, r1 = cloud.backup(u, "lt1", b"0" * 10, absent=True)
    t1 = r1.json()["updated_at"]
    datas = [bytes([65 + i]) * 30 for i in range(6)]
    ups = [cloud.upload(u, "lt1", d) for d in datas]
    res = _race(6, lambda i: cloud.commit(u, "lt1", ups[i]["key"], datas[i], expected=t1).status_code)
    assert sorted(res) == [200] + [409] * 5
    winner = res.index(200)
    cur = cloud.current(u, "lt1")["meta"]["key"]
    assert cloud.r2.data(cur) == datas[winner]
    # no committed copy left behind for the losers
    bks = [k for k in cloud.r2.objects if k.startswith(f"vocals/{u}/lt1/bk-")]
    assert bks == [cur]


def test_concurrent_first_uploads_exactly_one_wins(cloud):
    u = cloud.user()
    datas = [bytes([97 + i]) * 20 for i in range(5)]
    ups = [cloud.upload(u, "lt9", d) for d in datas]
    res = _race(5, lambda i: cloud.commit(u, "lt9", ups[i]["key"], datas[i], absent=True).status_code)
    assert sorted(res) == [200] + [409] * 4
    assert cloud.r2.data(cloud.current(u, "lt9")["meta"]["key"]) == datas[res.index(200)]


def test_rpc_serialises_on_the_row_lock(db_uri):
    """Directly at the SQL level: N connections commit with the same
    expected version at once; exactly one succeeds."""
    sb = PgSupabase(db_uri)
    u = str(uuid.uuid4())
    sb.add_user(u)
    first = sb.rpc("commit_cloud_project", {
        "p_user_id": u, "p_project_id": "p", "p_title": "t", "p_meta": {"key": "k0"},
        "p_size_bytes": 1, "p_expected_updated_at": None, "p_expect_absent": True,
    }).execute().data
    res = _race(8, lambda i: sb.rpc("commit_cloud_project", {
        "p_user_id": u, "p_project_id": "p", "p_title": "t", "p_meta": {"key": f"k{i + 1}"},
        "p_size_bytes": 1, "p_expected_updated_at": first["updated_at"], "p_expect_absent": False,
    }).execute().data["status"])
    assert sorted(res) == ["conflict"] * 7 + ["ok"]


# ── logs ────────────────────────────────────────────────────────────────────
def test_no_signed_url_or_token_in_logs(cloud, caplog):
    caplog.set_level(logging.DEBUG)
    u = cloud.user()
    token = hs256_token(SECRET, u)
    up, r = cloud.backup(u, "lt1", b"s" * 10, absent=True)
    cloud.c.post("/storage/presign_get", json={"key": cloud.current(u, "lt1")["meta"]["key"]}, headers=cloud.h(u))
    cloud.c.post("/storage/presign_get", json={"key": f"vocals/{uuid.uuid4()}/x"}, headers=cloud.h(u))
    text = caplog.text
    assert "SECRET-SIGNATURE" not in text and token not in text


# ── Codex independent review 2 (2026-10-30): C1–C3 ──────────────────────────
# Moved from artifacts/cloud-backup-2026-10-30/codex/test_server_safety.py
# (initial failures in codex/server-initial.log); the events are the same,
# the DELETE pause sits at the new cleanup boundary (objects first, row last).
def test_committed_backup_survives_rpc_response_loss(cloud, monkeypatch):
    """C1: the DB commits, then the RPC answer is lost. The new copy must not
    be deleted on that guess; the server confirms the commit from the row."""
    u, pid = cloud.user(), "rpc_response_lost"
    _, first = cloud.backup(u, pid, b"previous good bytes", absent=True)
    upload = cloud.upload(u, pid, b"new durable bytes")
    original = cloud.sb.rpc

    class LostResponse:
        def __init__(self, query):
            self.query = query

        def execute(self):
            self.query.execute()  # the DB really commits
            raise TimeoutError("simulated loss AFTER database commit")

    def rpc(name, params):
        q = original(name, params)
        return LostResponse(q) if name == "commit_cloud_project" else q

    monkeypatch.setattr(cloud.sb, "rpc", rpc)
    r = cloud.commit(u, pid, upload["key"], b"new durable bytes", expected=first.json()["updated_at"])
    assert r.status_code == 200, r.text  # confirmed from the row
    current = cloud.current(u, pid)
    assert cloud.r2.data(current["meta"]["key"]) == b"new durable bytes"


def test_rpc_failure_before_commit_keeps_both_copies_and_reports_unknown(cloud, monkeypatch):
    """C1, the other side: the RPC fails without committing. 503 'unknown',
    the previous copy stays current, and nothing the RPC might still commit
    is deleted (the unreferenced copy is swept only after ORPHAN_AGE)."""
    u, pid = cloud.user(), "rpc_lost_before"
    _, first = cloud.backup(u, pid, b"old", absent=True)
    k1 = cloud.current(u, pid)["meta"]["key"]
    upload = cloud.upload(u, pid, b"new")
    original = cloud.sb.rpc

    class Down:
        def execute(self):
            raise TimeoutError("no answer, nothing committed")

    monkeypatch.setattr(cloud.sb, "rpc", lambda n, p: Down() if n == "commit_cloud_project" else original(n, p))
    r = cloud.commit(u, pid, upload["key"], b"new", expected=first.json()["updated_at"])
    assert r.status_code == 503 and r.json()["detail"]["error"] == "commit_unknown"
    assert cloud.current(u, pid)["meta"]["key"] == k1 and cloud.r2.data(k1) == b"old"
    bks = [k for k in cloud.r2.objects if f"/{pid}/bk-" in k]
    assert len(bks) == 2, "the uncertain copy is kept, not deleted"
    assert cloud.r2.data(upload["key"]) == b"new", "upload kept for a retry"


def _pause_first_delete(monkeypatch):
    reached, resume = threading.Event(), threading.Event()
    original = projects_mod._delete_keys
    state = {"first": True}

    def paused(keys):
        if state["first"]:
            state["first"] = False
            reached.set()
            assert resume.wait(10)
        return original(keys)

    monkeypatch.setattr(projects_mod, "_delete_keys", paused)
    return reached, resume


def test_delete_cleanup_cannot_remove_a_newly_committed_backup(cloud, monkeypatch):
    """C2: DELETE has fixed what to remove; meanwhile another device commits a
    new copy; DELETE resumes. The new copy and its row must survive (409)."""
    from concurrent.futures import ThreadPoolExecutor

    u, pid = cloud.user(), "delete_race"
    _, first = cloud.backup(u, pid, b"old", absent=True)
    reached, resume = _pause_first_delete(monkeypatch)
    with ThreadPoolExecutor(max_workers=1) as pool:
        deleting = pool.submit(cloud.c.delete, f"/projects/{pid}", headers=cloud.h(u))
        try:
            assert reached.wait(10)
            _, replacement = cloud.backup(u, pid, b"NEW from the other device", expected=first.json()["updated_at"])
            assert replacement.status_code == 200, replacement.text
        finally:
            resume.set()
        assert deleting.result(10).status_code == 409
    current = cloud.current(u, pid)
    assert current is not None
    assert cloud.r2.data(current["meta"]["key"]) == b"NEW from the other device"


def test_late_delete_after_a_new_first_upload_leaves_it(cloud, monkeypatch):
    """C2, Codex's original order: the copy is deleted; a retried DELETE has
    already listed what to remove; another device makes a NEW first upload;
    the late DELETE resumes and must not touch it."""
    from concurrent.futures import ThreadPoolExecutor

    u, pid = cloud.user(), "delete_late"
    cloud.backup(u, pid, b"old", absent=True)
    assert cloud.c.delete(f"/projects/{pid}", headers=cloud.h(u)).status_code == 204
    assert cloud.current(u, pid) is None
    reached, resume = _pause_first_delete(monkeypatch)
    with ThreadPoolExecutor(max_workers=1) as pool:
        late = pool.submit(cloud.c.delete, f"/projects/{pid}", headers=cloud.h(u))
        try:
            assert reached.wait(10)
            _, replacement = cloud.backup(u, pid, b"NEW after deletion", absent=True)
            assert replacement.status_code == 200, replacement.text
        finally:
            resume.set()
        assert late.result(10).status_code == 204
    current = cloud.current(u, pid)
    assert current is not None
    assert cloud.r2.data(current["meta"]["key"]) == b"NEW after deletion"


def test_delete_partial_r2_failure_does_not_claim_everything_removed(cloud, monkeypatch):
    """C3: the bucket refuses the delete. Not 204; the copy stays listed so
    the user can retry; once the bucket works, the retry removes it all."""
    u, pid = cloud.user(), "delete_failure"
    cloud.backup(u, pid, b"private vocal", absent=True)
    key = cloud.current(u, pid)["meta"]["key"]
    real = cloud.r2.delete_objects

    def failed_delete(**kw):
        return {"Errors": [{"Key": x["Key"], "Code": "AccessDenied"} for x in kw["Delete"]["Objects"]]}

    monkeypatch.setattr(cloud.r2, "delete_objects", failed_delete)
    r = cloud.c.delete(f"/projects/{pid}", headers=cloud.h(u))
    assert r.status_code == 503 and r.json()["detail"]["error"] == "storage_delete_failed"
    assert cloud.r2.data(key) == b"private vocal"
    listed = cloud.c.get("/projects", headers=cloud.h(u)).json()
    assert [p["project_id"] for p in listed] == [pid], "still listed: retry possible"
    # the bucket works again: the retry removes the recording and the row
    monkeypatch.setattr(cloud.r2, "delete_objects", real)
    assert cloud.c.delete(f"/projects/{pid}", headers=cloud.h(u)).status_code == 204
    assert cloud.r2.data(key) is None
    assert cloud.current(u, pid) is None
    assert not [k for k in cloud.r2.objects if f"/{pid}/" in k]


def test_delete_removes_leftover_uploads_but_not_a_commit_in_progress(cloud):
    """Deleting a song removes its abandoned uploads too (privacy), but a
    young committed-name copy (another device mid-commit) is left alone."""
    u, pid = cloud.user(), "delete_leftovers"
    cloud.backup(u, pid, b"v", absent=True)
    stale_up = f"vocals/{u}/{pid}/up-{'d' * 32}.humtrack"
    young_bk = f"vocals/{u}/{pid}/bk-{'e' * 32}.humtrack"
    old_bk = f"vocals/{u}/{pid}/bk-{'f' * 32}.humtrack"
    cloud.r2.put(stale_up, b"u")
    cloud.r2.put(young_bk, b"y", age=timedelta(minutes=1))
    cloud.r2.put(old_bk, b"o", age=timedelta(hours=2))
    assert cloud.c.delete(f"/projects/{pid}", headers=cloud.h(u)).status_code == 204
    assert cloud.r2.data(stale_up) is None and cloud.r2.data(old_bk) is None
    assert cloud.r2.data(young_bk) == b"y"


def test_expected_user_guard_refuses_a_token_of_another_account(cloud):
    """C5: the app names the account (X-Expected-User); a token of another
    account (switch while the token was fetched) is refused before anything
    happens — here a DELETE that would hit B's song of the same id."""
    a, b = cloud.user(), cloud.user()
    cloud.backup(b, "lt1", b"B's song", absent=True)
    b_key = cloud.current(b, "lt1")["meta"]["key"]
    r = cloud.c.delete("/projects/lt1", headers={**cloud.h(b), "X-Expected-User": a})
    assert r.status_code == 409 and r.json()["detail"]["error"] == "account_mismatch"
    assert cloud.r2.data(b_key) == b"B's song"
    assert cloud.current(b, "lt1") is not None
    for call in [
        lambda h: cloud.c.get("/projects", headers=h),
        lambda h: cloud.c.post("/storage/presign", json={"project_id": "lt1", "size_bytes": 5}, headers=h),
    ]:
        assert call({**cloud.h(b), "X-Expected-User": a}).status_code == 409
        assert call({**cloud.h(b), "X-Expected-User": b}).status_code == 200
