"""Cloud-sync gate shared by /projects and /storage (B7).

- Writes require Pro, using the same verdict as GET /iap/status.
- Usage is what R2 actually holds under ``vocals/{user_id}/`` — never the size
  the app reports. After each write the measured total is stored in
  ``cloud_quota.used_bytes`` so GET /storage/usage shows it.
"""
from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import Optional

from fastapi import HTTPException

from .deps import user_is_pro
from .storage_r2 import prefix_bytes, sanitise_key_part

logger = logging.getLogger("humming.cloud_quota")


def require_cloud_pro(user_id: str, *, tag: str) -> None:
    """403 unless the caller is Pro. Read endpoints skip this so a lapsed
    subscriber can still download their own data."""
    if not user_is_pro(user_id):
        logger.info("%s: Pro required user_id=%s", tag, user_id)
        raise HTTPException(403, "Pro subscription required")


def quota_bytes() -> int:
    raw = os.environ.get("CLOUD_QUOTA_PRO_BYTES")
    if raw:
        try:
            return int(raw)
        except ValueError:
            logger.warning("CLOUD_QUOTA_PRO_BYTES invalid: %r", raw)
    return 5 * 1024 * 1024 * 1024  # 5 GB default (Pro)


def user_prefix(user_id: str) -> str:
    return f"vocals/{user_id}/"


def project_prefix(user_id: str, project_id: str) -> str:
    # Same normalisation as /storage/presign so the prefix matches uploads (B22).
    return f"vocals/{user_id}/{sanitise_key_part(project_id)}/"


def measure_bytes(prefix: str) -> Optional[int]:
    """R2 bytes under `prefix`; None if R2 is not configured; 500 on R2 error."""
    try:
        return prefix_bytes(prefix)
    except Exception:
        logger.exception("R2 usage measurement failed (prefix=%s)", prefix)
        raise HTTPException(500, "usage measurement failed")


def record_used_bytes(sb, user_id: str, used: int) -> None:
    """Store the measured total. Best-effort: enforcement re-measures R2."""
    try:
        sb.table("cloud_quota").upsert(
            {
                "user_id": user_id,
                "used_bytes": used,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
            on_conflict="user_id",
        ).execute()
    except Exception:
        logger.exception("cloud_quota update failed user_id=%s", user_id)


def quota_exceeded(used: int, quota: int) -> HTTPException:
    return HTTPException(
        status_code=412,
        detail={
            "error": "quota_exceeded",
            "used": used,
            "quota": quota,
            "deficit": max(0, used - quota),
        },
    )
