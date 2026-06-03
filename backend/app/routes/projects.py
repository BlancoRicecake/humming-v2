"""/projects — Cloud Sync (2026-06-04).

HumTrack 모바일 클라이언트가 보컬 + 메타데이터를 클라우드에 백업/복원하는
경로. 보컬 오디오 파일 자체는 R2 에 직접 PUT (presigned URL 로) 하고,
프로젝트 트랙/청크/노트 트리는 본 엔드포인트에서 JSONB(meta) 로 통째 저장.

스키마: `backend/sql/2026-06-04_cloud_sync_schema.sql` 참고.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Dict, List, Optional

from fastapi import APIRouter, Header, HTTPException, Query, Response
from pydantic import BaseModel, Field

from ..auth import extract_user_id
from ..deps import require_supabase
from ..storage_r2 import delete_prefix

logger = logging.getLogger("humming.cloud_projects")
router = APIRouter(prefix="/projects", tags=["cloud-projects"])


# ── Models ──────────────────────────────────────────────────────────────────
class CloudProjectSummary(BaseModel):
    project_id: str
    title: str
    size_bytes: int
    uploaded_at: datetime
    updated_at: datetime


class CloudProjectDetail(CloudProjectSummary):
    meta: Dict[str, Any]


class CloudProjectUpsertIn(BaseModel):
    project_id: str = Field(..., min_length=1, max_length=128)
    title: str = Field(..., min_length=1, max_length=200)
    meta: Dict[str, Any]
    size_bytes: int = Field(..., ge=0)
    expected_updated_at: Optional[datetime] = None


class CloudProjectUpsertOut(BaseModel):
    project_id: str
    used_bytes: int
    quota_bytes: int


class ConflictOut(BaseModel):
    detail: str = "conflict"
    cloud_version: Dict[str, Any]


# ── Helpers ─────────────────────────────────────────────────────────────────
def _quota_bytes() -> int:
    import os

    raw = os.environ.get("CLOUD_QUOTA_PRO_BYTES")
    if raw:
        try:
            return int(raw)
        except ValueError:
            logger.warning("CLOUD_QUOTA_PRO_BYTES invalid: %r", raw)
    return 5 * 1024 * 1024 * 1024  # 5 GB default (Pro)


def _used_bytes(sb, user_id: str) -> int:
    try:
        res = (
            sb.table("cloud_quota")
            .select("used_bytes")
            .eq("user_id", user_id)
            .maybe_single()
            .execute()
        )
    except Exception as e:
        logger.exception("quota lookup failed")
        raise HTTPException(500, f"quota lookup failed: {e}")
    row = getattr(res, "data", None) or {}
    return int(row.get("used_bytes") or 0)


def _to_dt(v: Any) -> Optional[datetime]:
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception:
        return None


# ── GET /projects ───────────────────────────────────────────────────────────
@router.get("", response_model=List[CloudProjectSummary])
def list_cloud_projects(
    include: Optional[str] = Query(default=None, description="`meta` 포함 여부"),
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/projects")
    sb = require_supabase()
    cols = "project_id,title,size_bytes,uploaded_at,updated_at"
    if include == "meta":
        cols += ",meta"
    try:
        rows = (
            sb.table("cloud_projects")
            .select(cols)
            .eq("user_id", user_id)
            .order("updated_at", desc=True)
            .execute()
            .data
            or []
        )
    except Exception as e:
        logger.exception("list failed")
        raise HTTPException(500, f"list failed: {e}")
    # When `meta` requested, callers expect richer payload — return Detail model shape via dict.
    return rows  # FastAPI will coerce; extra keys (meta) tolerated by Pydantic v2 if allowed.


# ── GET /projects/{project_id} ──────────────────────────────────────────────
@router.get("/{project_id}", response_model=CloudProjectDetail)
def get_cloud_project(
    project_id: str,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/projects")
    sb = require_supabase()
    try:
        res = (
            sb.table("cloud_projects")
            .select("project_id,title,size_bytes,uploaded_at,updated_at,meta")
            .eq("user_id", user_id)
            .eq("project_id", project_id)
            .maybe_single()
            .execute()
        )
    except Exception as e:
        logger.exception("get failed")
        raise HTTPException(500, f"get failed: {e}")
    row = getattr(res, "data", None)
    if not row:
        raise HTTPException(404, "project not found")
    return row


# ── POST /projects (upsert) ─────────────────────────────────────────────────
@router.post("", response_model=CloudProjectUpsertOut)
def upsert_cloud_project(
    payload: CloudProjectUpsertIn,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/projects")
    sb = require_supabase()
    quota = _quota_bytes()

    # 충돌 감지: expected_updated_at 이 주어졌고 DB row 의 updated_at 과 다르면 409.
    try:
        existing_res = (
            sb.table("cloud_projects")
            .select("title,size_bytes,updated_at")
            .eq("user_id", user_id)
            .eq("project_id", payload.project_id)
            .maybe_single()
            .execute()
        )
    except Exception as e:
        logger.exception("conflict pre-read failed")
        raise HTTPException(500, f"conflict pre-read failed: {e}")
    existing = getattr(existing_res, "data", None)

    if (
        existing
        and payload.expected_updated_at is not None
        and _to_dt(existing.get("updated_at"))
        and _to_dt(existing["updated_at"]) != payload.expected_updated_at
    ):
        raise HTTPException(
            status_code=409,
            detail={
                "error": "conflict",
                "project_id": payload.project_id,
                "cloud_version": {
                    "title": existing.get("title"),
                    "size_bytes": existing.get("size_bytes"),
                    "updated_at": (
                        existing["updated_at"].isoformat()
                        if isinstance(existing.get("updated_at"), datetime)
                        else existing.get("updated_at")
                    ),
                },
            },
        )

    # Quota 사전 검증 (delta 가 양수일 때만 의미 있음 — 음수면 항상 통과).
    old_size = int((existing or {}).get("size_bytes") or 0)
    delta = payload.size_bytes - old_size
    if delta > 0:
        current_used = _used_bytes(sb, user_id)
        if current_used + delta > quota:
            raise HTTPException(
                status_code=412,
                detail={
                    "error": "quota_exceeded",
                    "used": current_used,
                    "quota": quota,
                    "deficit": (current_used + delta) - quota,
                },
            )

    # RPC 원자 호출 — upsert + quota 갱신을 한 트랜잭션으로.
    try:
        rpc_res = sb.rpc(
            "upsert_cloud_project",
            {
                "p_user_id": user_id,
                "p_project_id": payload.project_id,
                "p_title": payload.title,
                "p_meta": payload.meta,
                "p_size_bytes": payload.size_bytes,
            },
        ).execute()
    except Exception as e:
        logger.exception("upsert RPC failed")
        raise HTTPException(500, f"upsert failed: {e}")

    used = int(getattr(rpc_res, "data", 0) or 0)
    return CloudProjectUpsertOut(
        project_id=payload.project_id, used_bytes=used, quota_bytes=quota
    )


# ── DELETE /projects/{project_id} ───────────────────────────────────────────
@router.delete("/{project_id}", status_code=204)
def delete_cloud_project(
    project_id: str,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/projects")
    sb = require_supabase()

    try:
        rpc_res = sb.rpc(
            "delete_cloud_project",
            {"p_user_id": user_id, "p_project_id": project_id},
        ).execute()
    except Exception as e:
        logger.exception("delete RPC failed")
        raise HTTPException(500, f"delete failed: {e}")

    result = getattr(rpc_res, "data", None)
    if result is None:
        # 존재하지 않음 — idempotent: 그래도 204 로 응답.
        logger.info("delete: project not found user=%s pid=%s", user_id, project_id)

    # R2 객체 삭제 (best-effort)
    prefix = f"vocals/{user_id}/{project_id}/"
    try:
        deleted = delete_prefix(prefix)
        if deleted:
            logger.info("R2 cleaned: prefix=%s deleted=%d", prefix, deleted)
    except Exception:
        logger.exception("R2 prefix cleanup failed: %s", prefix)

    return Response(status_code=204)
