"""/storage — Cloud backup (2026-06-04, gate + contract 2026-10-30).

R2 presigned URL 발급 + 사용량 조회 endpoints.

Key prefix 강제: `vocals/{user_id}/{project_id}/{file_name}` — user_id 는
JWT 의 sub 에서 가져오므로 client 가 위조 불가.

Pro gating (B7, e328408 통합): 업로드 URL 발급·용량 확인은 서버가 Pro 를
확인한다 (``cloud_quota.require_cloud_pro``, /iap/status 와 같은 기준). 다운로드
URL·사용량 조회는 구독이 끝난 사용자도 자기 데이터를 받을 수 있게 열어 둔다.

용량은 앱이 보낸 값이 아니라 R2 에 실제로 있는 바이트로 잰다. 업로드 URL 은
요청한 크기를 서명에 넣어(Content-Length) 그 크기만 올릴 수 있다. 업로드한
객체는 POST /projects 커밋에서 다시 재고, 넘치면 지운다.

로그에 서명 URL·토큰·곡 내용은 남기지 않는다.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field

from ..auth import extract_user_id
from ..cloud_quota import (
    expected_user_guard,
    BACKUP_CONTRACT,
    MAX_BACKUP_BYTES,
    check_project_id,
    measure_bytes,
    new_upload_key,
    quota_bytes,
    quota_exceeded,
    require_cloud_pro,
    user_prefix,
)
from ..deps import require_supabase
from ..settings import get_settings
from ..storage_r2 import presign_get, presign_put, sanitise_key_part

logger = logging.getLogger("humming.storage")
router = APIRouter(prefix="/storage", tags=["storage"], dependencies=[Depends(expected_user_guard)])

# Key-segment normaliser lives in storage_r2 so DELETE /projects uses the
# identical rule when computing the R2 prefix to clean up (B22). Upload keys
# are server-made now; kept for the prefix rule and its tests.
_sanitise = sanitise_key_part

def _recorded_used_bytes(user_id: str) -> int:
    """Last measured total stored in cloud_quota (when R2 can't be listed)."""
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


def _measured_used_bytes(user_id: str) -> int:
    used = measure_bytes(user_prefix(user_id))
    if used is None:
        raise HTTPException(503, "R2 not configured")
    return used


# ── Models ──────────────────────────────────────────────────────────────────
class PresignIn(BaseModel):
    project_id: str = Field(..., min_length=1, max_length=128)
    # Ignored (contract 1): the server names every upload itself, so a client
    # can never ask for the key of an existing backup.
    file_name: Optional[str] = Field(default=None, max_length=200)
    content_type: str = "application/octet-stream"
    # The exact upload size: required, checked against the measured quota and
    # signed into the URL (no size, no URL).
    size_bytes: int = Field(..., ge=1, le=MAX_BACKUP_BYTES)


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
    # Backup contract the server speaks (the app refuses to upload to a
    # server without it — an older deployment).
    contract: int = BACKUP_CONTRACT


class QuotaCheckIn(BaseModel):
    size: int = Field(..., ge=0)


class QuotaCheckOut(BaseModel):
    allowed: bool
    used: int
    quota: int
    deficit: int


# ── POST /storage/presign ───────────────────────────────────────────────────
@router.post("/presign", response_model=PresignOut)
def presign(
    payload: PresignIn,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/storage/presign")
    require_cloud_pro(user_id, tag="/storage/presign")
    check_project_id(payload.project_id)
    s = get_settings()

    quota = quota_bytes()
    used = _measured_used_bytes(user_id)
    needed = used + payload.size_bytes
    if needed > quota:
        raise quota_exceeded(needed, quota)

    # A fresh server-made key per request (user_id from the JWT): never the
    # key of an existing object, and create-only (If-None-Match) besides.
    key = new_upload_key(user_id, payload.project_id)
    content_type = "application/octet-stream"

    url = presign_put(
        key,
        content_type=content_type,
        expires_in=s.presign_ttl_sec,
        content_length=payload.size_bytes,
        if_none_match=True,
    )
    if url is None:
        raise HTTPException(503, "R2 not configured")

    public_base = (s.r2_public_base_url or "").rstrip("/")
    public_url = f"{public_base}/{key}" if public_base else None
    expires_at = datetime.now(timezone.utc) + timedelta(seconds=s.presign_ttl_sec)

    # every signed header the PUT must carry
    headers = {
        "Content-Type": content_type,
        "Content-Length": str(payload.size_bytes),
        "If-None-Match": "*",
    }
    return PresignOut(
        url=url,
        headers=headers,
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
    """Issue a short-lived presigned GET URL for one of the caller's objects.

    Key must start with ``vocals/{user_id}/`` matching the JWT sub claim —
    prevents one user from downloading another user's audio (R2 itself has
    no per-user ACL, so this check is the only enforcement). Open to lapsed
    subscribers.
    """
    user_id = extract_user_id(authorization, tag="/storage/presign_get")
    s = get_settings()

    expected_prefix = f"vocals/{user_id}/"
    if not payload.key.startswith(expected_prefix):
        logger.warning("/storage/presign_get: key outside the caller's prefix")
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
    """What R2 holds for the caller now (falls back to the last recorded
    total when R2 is not configured)."""
    user_id = extract_user_id(authorization, tag="/storage/usage")
    used = measure_bytes(user_prefix(user_id))
    if used is None:
        used = _recorded_used_bytes(user_id)
    return UsageOut(used_bytes=used, quota_bytes=quota_bytes())


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
