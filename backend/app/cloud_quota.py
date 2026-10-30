"""Cloud backup gate shared by /projects and /storage.

Integrated from e328408 (feat/cloud-server-gate, B7) on 2026-10-30:

- Writes require Pro, using the same verdict as GET /iap/status. Reads (list,
  download URL, usage) and deleting one's own copy stay open to a lapsed
  subscriber, so their data is never held hostage.
- Usage is what R2 actually holds under ``vocals/{user_id}/`` — never the size
  the app reports. The measured total is stored in ``cloud_quota.used_bytes``.

Backup contract 1 (2026-10-30): one cloud copy of a song is one ``.humtrack``
object (the app's validated project backup) under the project prefix; the
``cloud_projects`` row points at it (``meta.key``) and is switched only by
the ``commit_cloud_project`` RPC (migration 004), so a failed, cancelled or
over-quota upload never replaces or deletes the previous good copy. The app
uploads to a server-made ``up-<uuid>`` key (signed size, create-only); the
commit copies it to a new server-made ``bk-<uuid>`` key that no upload URL
is ever issued for, so a reused upload URL cannot change a committed copy.
"""
from __future__ import annotations

import logging
import os
import re
import uuid
from datetime import datetime, timezone
from typing import Optional

from fastapi import Header, HTTPException

from .deps import user_is_pro
from .storage_r2 import prefix_bytes, sanitise_key_part

logger = logging.getLogger("humming.cloud_quota")

# What the app checks before uploading (GET /storage/usage ``contract``).
BACKUP_CONTRACT = 1

# Same limit as the app's importer (kBackupMaxBytes).
MAX_BACKUP_BYTES = 1024 * 1024 * 1024

# Uploads get a fresh server-made name; a committed copy gets ANOTHER fresh
# server-made name that no PUT URL was ever issued for (Codex review
# 2026-10-30: a reused or re-issued upload URL can then never change a
# committed backup's bytes).
_UPLOAD_NAME = re.compile(r"^up-[0-9a-f]{32}\.humtrack$")
_BACKUP_NAME = re.compile(r"^bk-[0-9a-f]{32}\.humtrack$")

# project_id is used verbatim as one key segment: only names the key
# normaliser leaves unchanged, so two songs can never share a prefix.
_PROJECT_ID = re.compile(r"^[A-Za-z0-9_-]{1,100}$")


def require_cloud_pro(user_id: str, *, tag: str) -> None:
    """403 unless the caller is Pro."""
    if not user_is_pro(user_id):
        logger.info("%s: Pro required", tag)
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


def check_project_id(project_id: str) -> str:
    """422 unless `project_id` is a plain id (letters, digits, `_`, `-`)."""
    if not _PROJECT_ID.match(project_id) or sanitise_key_part(project_id) != project_id:
        raise HTTPException(422, "invalid project_id")
    return project_id


def project_prefix(user_id: str, project_id: str) -> str:
    # Same normalisation as /storage/presign so the prefix matches uploads (B22).
    return f"vocals/{user_id}/{sanitise_key_part(project_id)}/"


def new_upload_key(user_id: str, project_id: str) -> str:
    return f"{project_prefix(user_id, project_id)}up-{uuid.uuid4().hex}.humtrack"


def new_backup_key(user_id: str, project_id: str) -> str:
    return f"{project_prefix(user_id, project_id)}bk-{uuid.uuid4().hex}.humtrack"


def _in_project(key: str, user_id: str, project_id: str, pattern) -> bool:
    prefix = project_prefix(user_id, project_id)
    return key.startswith(prefix) and bool(pattern.match(key[len(prefix):]))


def is_upload_key(key: str, user_id: str, project_id: str) -> bool:
    """An upload of THIS user's THIS project (server-made ``up-`` name)."""
    return _in_project(key, user_id, project_id, _UPLOAD_NAME)


def is_backup_key(key: str, user_id: str, project_id: str) -> bool:
    """A committed copy of THIS user's THIS project (``bk-`` name)."""
    return _in_project(key, user_id, project_id, _BACKUP_NAME)


def measure_bytes(prefix: str) -> Optional[int]:
    """R2 bytes under `prefix`; None if R2 is not configured; 500 on R2 error."""
    try:
        return prefix_bytes(prefix)
    except Exception:
        logger.exception("R2 usage measurement failed")
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
        logger.exception("cloud_quota update failed")


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


def expected_user_guard(
    authorization: Optional[str] = Header(default=None),
    x_expected_user: Optional[str] = Header(default=None),
) -> None:
    """The app names the account a cloud action is for (``X-Expected-User``).
    If the bearer token belongs to someone else — the account changed while
    the request was being prepared — refuse before doing anything
    (409 ``account_mismatch``). Requests without the header are unaffected.
    """
    if x_expected_user is None:
        return
    from .auth import extract_user_id

    if extract_user_id(authorization, tag="cloud") != x_expected_user:
        raise HTTPException(409, detail={"error": "account_mismatch"})
