"""Integration tests for /projects (cloud sync) + /storage.

실행:
  cd backend && source .venv/bin/activate
  pip install pytest httpx
  pytest -q tests/test_cloud_sync.py

전제: Supabase + R2 환경 변수가 .env (또는 shell) 에 로드되어 있고,
`backend/sql/2026-06-04_cloud_sync_schema.sql` 가 이미 적용되어 있어야 함.
`TEST_USER_JWT` 환경변수에 valid Supabase JWT (test user) 를 넣어야 함.
"""
from __future__ import annotations

import os
import uuid

import pytest
from fastapi.testclient import TestClient

from app.main import app

JWT = os.environ.get("TEST_USER_JWT")
JWT2 = os.environ.get("TEST_USER_JWT_OTHER")  # 두번째 user — RLS 테스트용

pytestmark = pytest.mark.skipif(
    not JWT, reason="TEST_USER_JWT not set — skipping cloud-sync integration tests"
)


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture
def auth():
    return {"Authorization": f"Bearer {JWT}"}


@pytest.fixture
def pid():
    return f"test_{uuid.uuid4().hex[:12]}"


def test_round_trip(client, auth, pid):
    """업로드 → 리스트에 등장 → 단건 조회 → 삭제 → 사라짐."""
    body = {
        "project_id": pid,
        "title": "Round Trip Test",
        "meta": {"tracks": [], "bpm": 90},
        "size_bytes": 12345,
    }
    r = client.post("/projects", json=body, headers=auth)
    assert r.status_code == 200, r.text
    assert r.json()["project_id"] == pid

    r = client.get("/projects", headers=auth)
    assert r.status_code == 200
    assert any(p["project_id"] == pid for p in r.json())

    r = client.get(f"/projects/{pid}", headers=auth)
    assert r.status_code == 200
    assert r.json()["meta"]["bpm"] == 90

    r = client.delete(f"/projects/{pid}", headers=auth)
    assert r.status_code == 204

    r = client.get(f"/projects/{pid}", headers=auth)
    assert r.status_code == 404


def test_quota_delta(client, auth, pid):
    """size 증가/감소 시 used_bytes 가 정확히 반영."""
    r = client.get("/storage/usage", headers=auth)
    base_used = r.json()["used_bytes"]

    body = {"project_id": pid, "title": "Q1", "meta": {}, "size_bytes": 1000}
    r = client.post("/projects", json=body, headers=auth)
    assert r.status_code == 200
    assert r.json()["used_bytes"] == base_used + 1000

    body["size_bytes"] = 2500
    r = client.post("/projects", json=body, headers=auth)
    assert r.json()["used_bytes"] == base_used + 2500

    r = client.delete(f"/projects/{pid}", headers=auth)
    assert r.status_code == 204

    r = client.get("/storage/usage", headers=auth)
    assert r.json()["used_bytes"] == base_used


def test_conflict_detection(client, auth, pid):
    body = {"project_id": pid, "title": "C1", "meta": {"v": 1}, "size_bytes": 100}
    client.post("/projects", json=body, headers=auth)
    detail = client.get(f"/projects/{pid}", headers=auth).json()

    # 잘못된 expected_updated_at — 다른 시각 보내면 409.
    bad = dict(body)
    bad["expected_updated_at"] = "2000-01-01T00:00:00+00:00"
    bad["meta"] = {"v": 2}
    r = client.post("/projects", json=bad, headers=auth)
    assert r.status_code == 409
    cloud = r.json()["detail"]["cloud_version"]
    assert cloud["title"] == "C1"

    # 정확한 expected_updated_at 으로 다시 보내면 성공.
    good = dict(body)
    good["expected_updated_at"] = detail["updated_at"]
    good["meta"] = {"v": 3}
    r = client.post("/projects", json=good, headers=auth)
    assert r.status_code == 200

    client.delete(f"/projects/{pid}", headers=auth)


def test_quota_exceed(client, auth, pid, monkeypatch):
    """CLOUD_QUOTA_PRO_BYTES 를 작게 잡고 한도 초과 시 412."""
    monkeypatch.setenv("CLOUD_QUOTA_PRO_BYTES", "1024")
    body = {"project_id": pid, "title": "QX", "meta": {}, "size_bytes": 2048}
    r = client.post("/projects", json=body, headers=auth)
    assert r.status_code == 412
    detail = r.json()["detail"]
    assert detail["error"] == "quota_exceeded"
    assert detail["deficit"] > 0


def test_quota_check_endpoint(client, auth):
    r = client.post("/storage/quota_check", json={"size": 0}, headers=auth)
    assert r.status_code == 200
    assert "allowed" in r.json()


def test_presign(client, auth, pid):
    body = {"project_id": pid, "file_name": "vocal.wav", "content_type": "audio/wav"}
    r = client.post("/storage/presign", json=body, headers=auth)
    if r.status_code == 503:
        pytest.skip("R2 not configured in this env")
    assert r.status_code == 200
    j = r.json()
    assert j["key"].startswith("vocals/")
    assert pid in j["key"]
    assert "url" in j


@pytest.mark.skipif(not JWT2, reason="TEST_USER_JWT_OTHER not set")
def test_rls_isolation(client, auth, pid):
    body = {"project_id": pid, "title": "RLS", "meta": {}, "size_bytes": 100}
    client.post("/projects", json=body, headers=auth)

    other = {"Authorization": f"Bearer {JWT2}"}
    r = client.get(f"/projects/{pid}", headers=other)
    assert r.status_code == 404  # 다른 user 는 조회 불가

    client.delete(f"/projects/{pid}", headers=auth)


def test_missing_token_401(client, pid):
    r = client.get("/projects")
    assert r.status_code == 401
