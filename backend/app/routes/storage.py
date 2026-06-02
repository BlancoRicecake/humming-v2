"""POST /storage/presign — R2 presigned PUT URL for vocal chunk upload.

Pro-only. Keys are scoped to the calling user: ``users/{uid}/chunks/{filename}``.
TTL 5min, max 5MB. The mobile client uploads the WAV/Opus to the returned
URL using HTTP PUT, then stores ``public_url`` in ``chunks.audio_url``.
"""
from __future__ import annotations

import logging
import re
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException

from ..deps import CurrentUser, require_pro, require_r2
from ..models import PresignRequest, PresignResponse
from ..settings import get_settings

logger = logging.getLogger("humming.storage")
router = APIRouter(prefix="/storage", tags=["storage"])

_SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")


def _sanitise(name: str) -> str:
    base = _SAFE_NAME.sub("_", name).strip("._") or "file"
    return base[:80]


@router.post("/presign", response_model=PresignResponse)
def presign_upload(payload: PresignRequest, user: CurrentUser = Depends(require_pro)):
    s = get_settings()
    if payload.size_bytes > s.presign_max_bytes:
        raise HTTPException(413, f"file too large (>{s.presign_max_bytes} bytes)")
    r2 = require_r2()

    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S")
    key = f"users/{user.id}/chunks/{ts}_{uuid.uuid4().hex[:8]}_{_sanitise(payload.file_name)}"
    try:
        url = r2.generate_presigned_url(
            ClientMethod="put_object",
            Params={
                "Bucket": s.r2_bucket,
                "Key": key,
                "ContentType": payload.content_type,
                "ContentLength": payload.size_bytes,
            },
            ExpiresIn=s.presign_ttl_sec,
            HttpMethod="PUT",
        )
    except Exception as e:
        logger.exception("presign failed")
        raise HTTPException(500, f"presign failed: {e}")

    public_base = (s.r2_public_base_url or "").rstrip("/")
    public_url = f"{public_base}/{key}" if public_base else url.split("?", 1)[0]

    return PresignResponse(
        upload_url=url,
        headers={"Content-Type": payload.content_type},
        public_url=public_url,
        expires_in=s.presign_ttl_sec,
        key=key,
    )
