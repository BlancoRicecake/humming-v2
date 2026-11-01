"""Server-side Pro gate + measured quota for /projects and /storage (B7).

Runs without Supabase/R2 credentials: both are replaced by in-memory fakes.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app import deps, storage_r2
from app.routes import projects as projects_mod
from app.routes import storage as storage_mod
from app.settings import get_settings
from tests.iap_fixtures import FakeSupabase, _Query, _Res, hs256_token

SECRET = "test-jwt-secret-please-ignore"
QUOTA = 1000


# --- fakes --------------------------------------------------------------------
class _CloudQuery(_Query):
    """`maybe_single()` returns one row (or None), like supabase-py."""

    _single = False

    def maybe_single(self):
        self._single = True
        return super().maybe_single()

    def execute(self):
        res = super().execute()
        if self._single:
            return _Res(res.data[0] if res.data else None)
        return res


class _Rpc:
    def __init__(self, fn):
        self._fn = fn

    def execute(self):
        return _Res(self._fn())


class FakeCloudDB(FakeSupabase):
    """Adds cloud_projects / cloud_quota and the two RPCs from the 06-04 schema."""

    def __init__(self):
        super().__init__()
        self.tables.update({"cloud_projects": [], "cloud_quota": []})

    def table(self, name):
        return _CloudQuery(self, name)

    def _quota_row(self, user_id):
        rows = self.tables["cloud_quota"]
        row = next((r for r in rows if r["user_id"] == user_id), None)
        if row is None:
            row = {"user_id": user_id, "used_bytes": 0}
            rows.append(row)
        return row

    def rpc(self, name, p):
        projects = self.tables["cloud_projects"]

        def find():
            return next((r for r in projects if r["user_id"] == p["p_user_id"]
                         and r["project_id"] == p["p_project_id"]), None)

        def upsert():
            row = find()
            old = row["size_bytes"] if row else 0
            now = datetime.now(timezone.utc).isoformat()
            if row is None:
                row = {"user_id": p["p_user_id"], "project_id": p["p_project_id"], "uploaded_at": now}
                projects.append(row)
            row.update(title=p["p_title"], meta=p["p_meta"], size_bytes=p["p_size_bytes"], updated_at=now)
            q = self._quota_row(p["p_user_id"])
            q["used_bytes"] = max(0, q["used_bytes"] + p["p_size_bytes"] - old)
            return q["used_bytes"]

        def delete():
            row = find()
            if row is None:
                return None
            projects.remove(row)
            q = self._quota_row(p["p_user_id"])
            q["used_bytes"] = max(0, q["used_bytes"] - row["size_bytes"])
            return q["used_bytes"]

        return _Rpc({"upsert_cloud_project": upsert, "delete_cloud_project": delete}[name])

    # convenience
    def used(self, user_id):
        return self._quota_row(user_id)["used_bytes"]

    def project(self, user_id, project_id):
        return next((r for r in self.tables["cloud_projects"]
                     if r["user_id"] == user_id and r["project_id"] == project_id), None)


class _NotFound(Exception):
    response = {"Error": {"Code": "404"}}


class FakeR2:
    """Just enough of a boto3 S3 client for storage_r2."""

    def __init__(self):
        self.objects = {}

    def put(self, key, size):
        """What the app's presigned PUT would leave in the bucket."""
        self.objects[key] = size

    def generate_presigned_url(self, ClientMethod, Params, ExpiresIn, HttpMethod):
        return f"https://r2.test/{Params['Key']}?method={HttpMethod}"

    def head_object(self, Bucket, Key):
        if Key not in self.objects:
            raise _NotFound()
        return {"ContentLength": self.objects[Key]}

    def get_paginator(self, name):
        assert name == "list_objects_v2"
        r2 = self

        class _Pager:
            def paginate(self, Bucket, Prefix):
                yield {"Contents": [{"Key": k, "Size": v} for k, v in r2.objects.items()
                                    if k.startswith(Prefix)]}

        return _Pager()

    def delete_objects(self, Bucket, Delete):
        gone = [o for o in Delete["Objects"] if self.objects.pop(o["Key"], None) is not None]
        return {"Deleted": gone}


# --- fixtures -----------------------------------------------------------------
@pytest.fixture
def db(monkeypatch):
    monkeypatch.setenv("SUPABASE_JWT_SECRET", SECRET)
    monkeypatch.setenv("CLOUD_QUOTA_PRO_BYTES", str(QUOTA))
    get_settings.cache_clear()
    fake = FakeCloudDB()
    for mod in (deps, projects_mod, storage_mod):
        monkeypatch.setattr(mod, "require_supabase", lambda: fake)
    yield fake
    get_settings.cache_clear()


@pytest.fixture
def r2(monkeypatch):
    fake = FakeR2()
    monkeypatch.setattr(storage_r2, "get_r2_client", lambda: fake)
    return fake


@pytest.fixture
def client():
    from app.main import app
    with TestClient(app) as c:
        yield c


def _user(db, status=None, expires_in_days=30):
    uid = str(uuid.uuid4())
    if status:
        expires = datetime.now(timezone.utc) + timedelta(days=expires_in_days)
        db.tables["subscriptions"].append(
            {"user_id": uid, "status": status, "expires_at": expires.isoformat()})
    return uid


def _auth(uid):
    return {"Authorization": f"Bearer {hs256_token(SECRET, uid)}"}


def _project_body(pid, size_bytes=0):
    return {"project_id": pid, "title": "Song", "meta": {"bpm": 90}, "size_bytes": size_bytes}


def _upload(client, r2, uid, pid, file_name, size):
    """presign → PUT (simulated) → complete, as the app will do it."""
    r = client.post("/storage/presign", headers=_auth(uid),
                    json={"project_id": pid, "file_name": file_name})
    assert r.status_code == 200, r.text
    key = r.json()["key"]
    r2.put(key, size)
    return key, client.post("/storage/complete", headers=_auth(uid), json={"key": key})


# --- tests --------------------------------------------------------------------
def test_free_user_gets_403_on_every_cloud_write(client, db, r2):
    uid = _user(db)  # no subscription row
    key = f"vocals/{uid}/p1/a.wav"
    r2.put(key, 10)
    calls = [
        ("post", "/projects", _project_body("p1")),
        ("delete", "/projects/p1", None),
        ("post", "/storage/presign", {"project_id": "p1", "file_name": "a.wav"}),
        ("post", "/storage/quota_check", {"size": 1}),
        ("post", "/storage/complete", {"key": key}),
    ]
    for method, path, body in calls:
        r = client.request(method.upper(), path, headers=_auth(uid), json=body)
        assert r.status_code == 403, (path, r.status_code, r.text)
    assert db.tables["cloud_projects"] == []


def test_pro_user_uploads_and_saves(client, db, r2):
    uid = _user(db, "active")
    key, r = _upload(client, r2, uid, "p1", "vocal.wav", 300)
    assert r.status_code == 200, r.text
    assert r.json() == {"key": key, "size_bytes": 300, "used_bytes": 300, "quota_bytes": QUOTA}
    assert db.used(uid) == 300

    r = client.post("/projects", headers=_auth(uid), json=_project_body("p1"))
    assert r.status_code == 200, r.text
    assert r.json()["used_bytes"] == 300
    assert db.project(uid, "p1")["size_bytes"] == 300


def test_trial_counts_as_pro(client, db, r2):
    uid = _user(db, "trial")
    r = client.post("/storage/quota_check", headers=_auth(uid), json={"size": 10})
    assert r.status_code == 200, r.text
    assert r.json()["allowed"] is True


def test_lapsed_subscriber_can_read_but_not_write(client, db, r2):
    uid = _user(db, "active")
    key, r = _upload(client, r2, uid, "p1", "vocal.wav", 120)
    assert r.status_code == 200, r.text
    assert client.post("/projects", headers=_auth(uid), json=_project_body("p1")).status_code == 200

    # Subscription ends: same status string, expiry in the past.
    db.tables["subscriptions"][0]["expires_at"] = (
        datetime.now(timezone.utc) - timedelta(days=1)).isoformat()

    assert client.get("/projects", headers=_auth(uid)).json()[0]["project_id"] == "p1"
    assert client.get("/projects/p1", headers=_auth(uid)).status_code == 200
    assert client.post("/storage/presign_get", headers=_auth(uid), json={"key": key}).status_code == 200
    assert client.get("/storage/usage", headers=_auth(uid)).json()["used_bytes"] == 120

    assert client.post("/projects", headers=_auth(uid), json=_project_body("p1")).status_code == 403
    assert client.post("/storage/presign", headers=_auth(uid),
                       json={"project_id": "p1", "file_name": "b.wav"}).status_code == 403
    assert client.delete("/projects/p1", headers=_auth(uid)).status_code == 403
    assert key in r2.objects


def test_upload_over_quota_is_removed_and_rejected(client, db, r2):
    uid = _user(db, "active")
    _, r = _upload(client, r2, uid, "p1", "a.wav", 900)
    assert r.status_code == 200, r.text

    key, r = _upload(client, r2, uid, "p1", "b.wav", 200)
    assert r.status_code == 412, r.text
    assert r.json()["detail"]["error"] == "quota_exceeded"
    assert key not in r2.objects
    assert db.used(uid) == 900

    r = client.post("/storage/quota_check", headers=_auth(uid), json={"size": 200})
    assert r.json() == {"allowed": False, "used": 900, "quota": QUOTA, "deficit": 100}


def test_presign_refused_once_quota_is_full(client, db, r2):
    uid = _user(db, "active")
    r2.put(f"vocals/{uid}/p1/a.wav", QUOTA)
    r = client.post("/storage/presign", headers=_auth(uid),
                    json={"project_id": "p1", "file_name": "b.wav"})
    assert r.status_code == 412, r.text


def test_project_size_is_measured_not_trusted(client, db, r2):
    uid = _user(db, "active")
    r2.put(f"vocals/{uid}/p1/a.wav", 250)
    r2.put(f"vocals/{uid}/p1/b.wav", 150)

    # Under-reporting does not shrink usage …
    r = client.post("/projects", headers=_auth(uid), json=_project_body("p1", size_bytes=0))
    assert r.status_code == 200, r.text
    assert db.project(uid, "p1")["size_bytes"] == 400
    assert r.json()["used_bytes"] == 400 == db.used(uid)

    # … and over-reporting does not trip the quota.
    r = client.post("/projects", headers=_auth(uid), json=_project_body("p1", size_bytes=10**12))
    assert r.status_code == 200, r.text
    assert db.project(uid, "p1")["size_bytes"] == 400


def test_complete_rejects_foreign_and_missing_keys(client, db, r2):
    uid = _user(db, "active")
    other = str(uuid.uuid4())
    r2.put(f"vocals/{other}/p1/a.wav", 10)
    r = client.post("/storage/complete", headers=_auth(uid), json={"key": f"vocals/{other}/p1/a.wav"})
    assert r.status_code == 403
    r = client.post("/storage/complete", headers=_auth(uid), json={"key": f"vocals/{uid}/p1/none.wav"})
    assert r.status_code == 404


def test_delete_frees_measured_usage(client, db, r2):
    uid = _user(db, "active")
    _upload(client, r2, uid, "p1", "a.wav", 300)
    client.post("/projects", headers=_auth(uid), json=_project_body("p1"))
    r = client.delete("/projects/p1", headers=_auth(uid))
    assert r.status_code == 204
    assert r2.objects == {}
    assert db.used(uid) == 0
