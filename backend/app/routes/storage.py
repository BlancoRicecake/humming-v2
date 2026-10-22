"""/storage — Cloud Sync (2026-06-04).

R2 presigned PUT URL 발급 + 사용량 조회 endpoints.

Key prefix 강제: `vocals/{user_id}/{project_id}/{file_name}` — user_id 는
JWT 의 sub 에서 가져오므로 client 가 위조 불가.

Pro gating (B7): 업로드 URL 발급·용량 확인·업로드 완료는 서버가 Pro 를 확인한다
(``cloud_quota.require_cloud_pro``, /iap/status 와 같은 기준). 다운로드 URL·사용량
조회는 구독이 끝난 사용자도 자기 데이터를 받을 수 있게 열어 둔다.

용량은 앱이 보낸 값이 아니라 R2 에 실제로 있는 바이트로 잰다. 앱은 PUT 이 끝나면
POST /storage/complete 를 불러야 하고, 한도를 넘긴 객체는 거기서 지워진다.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from ..auth import extract_user_id
from ..cloud_quota import (
    measure_bytes,
    quota_bytes,
    quota_exceeded,
    record_used_bytes,
    require_cloud_pro,
    user_prefix,
)
from ..deps import require_supabase
from ..settings import get_settings
from ..storage_r2 import delete_objects, object_size, presign_get, presign_put, sanitise_key_part

logger = logging.getLogger("humming.storage")
router = APIRouter(prefix="/storage", tags=["storage"])

# Key-segment normaliser lives in storage_r2 so DELETE /projects uses the
# identical rule when computing the R2 prefix to clean up (B22).
_sanitise = sanitise_key_part


def _recorded_used_bytes(user_id: str) -> int:
    """Last measured total stored in cloud_quota (cheap read for /usage)."""
    sb = require_supabase()
    try:
        res = (
            sb.table("cloud_quota")
            .select("used_bytes")
            .eq("user_id", user_id)
            .maybe_single()
            .execute()
        )
    except Exception:
        logger.exception("quota lookup failed")
        raise HTTPException(500, "quota lookup failed")
    row = getattr(res, "data", None) or {}
    return int(row.get("used_bytes") or 0)


# ── Models ──────────────────────────────────────────────────────────────────
class PresignIn(BaseModel):
    project_id: str = Field(..., min_length=1, max_length=128)
    file_name: str = Field(..., min_length=1, max_length=200)
    content_type: str = "audio/wav"


class PresignOut(BaseModel):
    url: str
    headers: dict
    key: str
    public_url: Optional[str] = None
    expires_at: datetime


class PresignGetIn(BaseModel):
    key: str = Field(..., min_length=1, max_length=512)


class PresignGetOut(BaseModel):
    url: str
    expires_at: datetime


class UsageOut(BaseModel):
    used_bytes: int
    quota_bytes: int


class QuotaCheckIn(BaseModel):
    size: int = Field(..., ge=0)


class QuotaCheckOut(BaseModel):
    allowed: bool
    used: int
    quota: int
    deficit: int


class CompleteIn(BaseModel):
    key: str = Field(..., min_length=1, max_length=512)


class CompleteOut(BaseModel):
    key: str
    size_bytes: int
    used_bytes: int
    quota_bytes: int


def _measured_used_bytes(user_id: str) -> int:
    used = measure_bytes(user_prefix(user_id))
    if used is None:
        raise HTTPException(503, "R2 not configured")
    return used


# ── POST /storage/presign ───────────────────────────────────────────────────
@router.post("/presign", response_model=PresignOut)
def presign(
    payload: PresignIn,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/storage/presign")
    require_cloud_pro(user_id, tag="/storage/presign")
    s = get_settings()

    quota = quota_bytes()
    used = _measured_used_bytes(user_id)
    if used >= quota:
        raise quota_exceeded(used, quota)

    # 경로 위조 방지: user_id 는 JWT 에서, project_id/file_name 은 sanitize.
    safe_project = _sanitise(payload.project_id)
    safe_file = _sanitise(payload.file_name)
    key = f"vocals/{user_id}/{safe_project}/{safe_file}"

    url = presign_put(key, content_type=payload.content_type, expires_in=s.presign_ttl_sec)
    if url is None:
        raise HTTPException(503, "R2 not configured")

    public_base = (s.r2_public_base_url or "").rstrip("/")
    public_url = f"{public_base}/{key}" if public_base else None
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=s.presign_ttl_sec)

    return PresignOut(
        url=url,
        headers={"Content-Type": payload.content_type},
        key=key,
        public_url=public_url,
        expires_at=expires_at,
    )


# ── POST /storage/presign_get ───────────────────────────────────────────────
@router.post("/presign_get", response_model=PresignGetOut)
def presign_download(
    payload: PresignGetIn,
    authorization: Optional[str] = Header(default=None),
):
    """Issue a short-lived presigned GET URL for downloading a vocal chunk.

    Key must start with ``vocals/{user_id}/`` matching the JWT sub claim —
    prevents one user from downloading another user's audio (R2 itself has
    no per-user ACL, so this check is the only enforcement).
    """
    user_id = extract_user_id(authorization, tag="/storage/presign_get")
    s = get_settings()

    expected_prefix = f"vocals/{user_id}/"
    if not payload.key.startswith(expected_prefix):
        logger.warning(
            "/storage/presign_get: prefix mismatch user_id=%s key=%s",
            user_id,
            payload.key,
        )
        raise HTTPException(403, "key does not belong to caller")

    try:
        url = presign_get(payload.key, expires_in=s.presign_ttl_sec)
    except Exception:
        logger.exception("/storage/presign_get: R2 client error")
        raise HTTPException(500, "presign failed")

    if url is None:
        raise HTTPException(503, "R2 not configured")

    expires_at = datetime.now(timezone.utc) + timedelta(seconds=s.presign_ttl_sec)
    return PresignGetOut(url=url, expires_at=expires_at)


# ── GET /storage/usage ──────────────────────────────────────────────────────
@router.get("/usage", response_model=UsageOut)
def usage(authorization: Optional[str] = Header(default=None)):
    user_id = extract_user_id(authorization, tag="/storage/usage")
    return UsageOut(used_bytes=_recorded_used_bytes(user_id), quota_bytes=quota_bytes())


# ── POST /storage/quota_check ───────────────────────────────────────────────
@router.post("/quota_check", response_model=QuotaCheckOut)
def quota_check(
    payload: QuotaCheckIn,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/storage/quota_check")
    require_cloud_pro(user_id, tag="/storage/quota_check")
    used = _measured_used_bytes(user_id)
    quota = quota_bytes()
    needed = used + payload.size
    deficit = max(0, needed - quota)
    return QuotaCheckOut(
        allowed=(deficit == 0),
        used=used,
        quota=quota,
        deficit=deficit,
    )


# ── POST /storage/complete ──────────────────────────────────────────────────
@router.post("/complete", response_model=CompleteOut)
def complete_upload(
    payload: CompleteIn,
    authorization: Optional[str] = Header(default=None),
):
    """Call after a presigned PUT finishes. The server HEADs the object,
    re-measures the caller's R2 total and stores it in cloud_quota. An upload
    that pushes the total over the quota is deleted and rejected with 412."""
    user_id = extract_user_id(authorization, tag="/storage/complete")
    require_cloud_pro(user_id, tag="/storage/complete")

    if not payload.key.startswith(user_prefix(user_id)):
        raise HTTPException(403, "key does not belong to caller")

    try:
        size = object_size(payload.key)
    except FileNotFoundError:
        raise HTTPException(404, "object not found")
    except Exception:
        logger.exception("/storage/complete: HEAD failed key=%s", payload.key)
        raise HTTPException(500, "object lookup failed")
    if size is None:
        raise HTTPException(503, "R2 not configured")

    sb = require_supabase()
    quota = quota_bytes()
    used = _measured_used_bytes(user_id)
    if used > quota:
        delete_objects([payload.key])
        record_used_bytes(sb, user_id, used - size)
        logger.info("/storage/complete: over quota, removed key=%s user_id=%s", payload.key, user_id)
        raise quota_exceeded(used, quota)

    record_used_bytes(sb, user_id, used)
    return CompleteOut(key=payload.key, size_bytes=size, used_bytes=used, quota_bytes=quota)
