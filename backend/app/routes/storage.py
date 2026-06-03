"""/storage — Cloud Sync (2026-06-04).

R2 presigned PUT URL 발급 + 사용량 조회 endpoints.

Key prefix 강제: `vocals/{user_id}/{project_id}/{file_name}` — user_id 는
JWT 의 sub 에서 가져오므로 client 가 위조 불가.

Pro gating: presigned URL 발급은 단순히 인증된 사용자면 통과 (모바일 측
free/pro 분기는 UI 가 처리). quota 한도가 plan 별 가드 역할.
"""
from __future__ import annotations

import logging
import os
import re
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from ..auth import extract_user_id
from ..deps import require_supabase
from ..settings import get_settings
from ..storage_r2 import presign_put

logger = logging.getLogger("humming.storage")
router = APIRouter(prefix="/storage", tags=["storage"])

_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def _sanitise(name: str) -> str:
    base = _SAFE_NAME.sub("_", name).strip("._") or "file"
    return base[:120]


def _quota_bytes() -> int:
    raw = os.environ.get("CLOUD_QUOTA_PRO_BYTES")
    if raw:
        try:
            return int(raw)
        except ValueError:
            logger.warning("CLOUD_QUOTA_PRO_BYTES invalid: %r", raw)
    return 5 * 1024 * 1024 * 1024


def _used_bytes(user_id: str) -> int:
    sb = require_supabase()
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


# ── POST /storage/presign ───────────────────────────────────────────────────
@router.post("/presign", response_model=PresignOut)
def presign(
    payload: PresignIn,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/storage/presign")
    s = get_settings()

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


# ── GET /storage/usage ──────────────────────────────────────────────────────
@router.get("/usage", response_model=UsageOut)
def usage(authorization: Optional[str] = Header(default=None)):
    user_id = extract_user_id(authorization, tag="/storage/usage")
    return UsageOut(used_bytes=_used_bytes(user_id), quota_bytes=_quota_bytes())


# ── POST /storage/quota_check ───────────────────────────────────────────────
@router.post("/quota_check", response_model=QuotaCheckOut)
def quota_check(
    payload: QuotaCheckIn,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/storage/quota_check")
    used = _used_bytes(user_id)
    quota = _quota_bytes()
    needed = used + payload.size
    deficit = max(0, needed - quota)
    return QuotaCheckOut(
        allowed=(deficit == 0),
        used=used,
        quota=quota,
        deficit=deficit,
    )
