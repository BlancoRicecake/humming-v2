"""/projects — Cloud backup (2026-06-04; contract 1 + gate 2026-10-30).

One cloud copy per song (``project_id``): the app uploads its validated
``.humtrack`` project backup to R2 with a presigned PUT (/storage/presign),
then commits it here. The ``cloud_projects`` row's ``meta`` is a small
descriptor of that object (``key``, ``size``, ``sha256``, whether recordings
are included…), not the song itself.

Commit rules (failure keeps the previous good copy):
- Pro only (B7, same verdict as /iap/status; integrated from e328408).
- The object must be this user's, under this project's prefix, exist in R2
  and have the declared size; the server measures usage from R2 and refuses
  (and removes the new object) when over quota.
- The row is switched by the ``commit_cloud_project`` RPC (migration 004):
  row lock + compare ``expected_updated_at`` (or ``expect_absent`` for a first
  upload) + update in ONE transaction. A stale client gets 409 with the cloud
  version and nothing changes.
- Only after the switch is the replaced object deleted; abandoned uploads are
  removed once they are older than ``ORPHAN_AGE`` (never a young one, which
  may be another device's upload in progress).

Reads and deleting one's own copy stay open after a subscription ends.
Schema: ``backend/sql/2026-06-04_cloud_sync_schema.sql`` + migrations 003/004.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Literal, Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Response
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from ..auth import extract_user_id
from ..cloud_quota import (
    expected_user_guard,
    MAX_BACKUP_BYTES,
    check_project_id,
    is_backup_key,
    is_upload_key,
    measure_bytes,
    new_backup_key,
    project_prefix,
    quota_bytes,
    quota_exceeded,
    record_used_bytes,
    require_cloud_pro,
    user_prefix,
)
from ..deps import require_supabase
from ..storage_r2 import (
    copy_object,
    delete_objects,
    delete_objects_strict,
    list_objects,
    object_size,
)

logger = logging.getLogger("humming.cloud_projects")
router = APIRouter(prefix="/projects", tags=["cloud-projects"], dependencies=[Depends(expected_user_guard)])

# An upload nobody committed is removed after this long.
ORPHAN_AGE = timedelta(hours=24)

# A committed-name (bk-) object younger than this may belong to a commit that
# is still running (copy done, RPC not yet): deletion sweeps leave it.
COMMIT_WINDOW = timedelta(minutes=10)

# Strict delete used by every cleanup (a seam for failure tests).
_delete_keys = delete_objects_strict


# ── Models ──────────────────────────────────────────────────────────────────
class CloudProjectSummary(BaseModel):
    project_id: str
    title: str
    size_bytes: int
    uploaded_at: datetime
    updated_at: datetime


class CloudProjectDetail(CloudProjectSummary):
    meta: Dict[str, Any]


class CloudProjectListItem(CloudProjectSummary):
    """List row. ``meta`` is populated only for ``?include=meta`` and omitted
    from the JSON otherwise (``response_model_exclude_none``)."""
    meta: Optional[Dict[str, Any]] = None


class HumtrackMeta(BaseModel):
    """The descriptor stored as ``meta`` (backup contract 1)."""

    model_config = ConfigDict(extra="forbid")

    format: Literal["humtrack"]
    formatVersion: int = Field(..., ge=1, le=1)
    key: str = Field(..., min_length=1, max_length=512)
    size: int = Field(..., ge=1, le=MAX_BACKUP_BYTES)
    sha256: str = Field(..., pattern=r"^[0-9a-f]{64}$")
    audioIncluded: bool
    takes: int = Field(..., ge=0, le=100000)
    missingTakes: int = Field(..., ge=0, le=100000)
    songSchema: int = Field(..., ge=1, le=1000)


class CloudProjectUpsertIn(BaseModel):
    project_id: str = Field(..., min_length=1, max_length=128)
    title: str = Field(..., min_length=1, max_length=200)
    meta: Dict[str, Any]
    # Ignored: the server measures the object (B7). Accepted for old clients.
    size_bytes: Optional[int] = Field(default=None, ge=0)
    # Exactly one of these: the cloud version this device last saw, or
    # "there is no cloud copy yet" for a first upload.
    expected_updated_at: Optional[datetime] = None
    expect_absent: bool = False


class CloudProjectUpsertOut(BaseModel):
    project_id: str
    updated_at: datetime
    used_bytes: int
    quota_bytes: int


# ── Helpers ─────────────────────────────────────────────────────────────────
def _to_dt(v: Any) -> Optional[datetime]:
    if v is None:
        return None
    if isinstance(v, datetime):
        return v
    try:
        return datetime.fromisoformat(str(v).replace("Z", "+00:00"))
    except Exception:
        return None


def _current_row(sb, user_id: str, project_id: str) -> Optional[dict]:
    """The project's row now (title, size, updated_at, meta) or None."""
    res = (
        sb.table("cloud_projects")
        .select("title,size_bytes,updated_at,meta")
        .eq("user_id", user_id)
        .eq("project_id", project_id)
        .maybe_single()
        .execute()
    )
    return getattr(res, "data", None) or None


def _row_key(row: Optional[dict]) -> Optional[str]:
    return ((row or {}).get("meta") or {}).get("key")


def _stale_objects(
    sb, user_id: str, project_id: str, *, up_age: timedelta, bk_age: timedelta
) -> List[str]:
    """This project's objects old enough to remove, listed FIRST and then
    checked against the row read AFTER the listing: the current copy is never
    included, and neither is anything created after the listing (a new
    device's upload/commit) — the set is fixed before anything is deleted."""
    objs = list_objects(project_prefix(user_id, project_id)) or []
    current = _row_key(_current_row(sb, user_id, project_id))
    now = datetime.now(timezone.utc)
    out = []
    for key, _, modified in objs:
        if key == current:
            continue
        age = now - modified if modified is not None else timedelta(0)
        limit = bk_age if is_backup_key(key, user_id, project_id) else up_age
        if age >= limit:
            out.append(key)
    return out


def _cleanup_after_commit(
    sb,
    user_id: str,
    project_id: str,
    keep_key: str,
    upload_key: str,
    previous_key: Optional[str],
) -> None:
    """Remove the committed upload, the replaced copy and old abandoned
    objects of this project (best effort). Never the current copy, never a
    young upload (another device may be mid-upload)."""
    doomed: List[str] = [upload_key]
    if previous_key and previous_key != keep_key and is_backup_key(previous_key, user_id, project_id):
        doomed.append(previous_key)
    try:
        doomed += [
            k
            for k in _stale_objects(sb, user_id, project_id, up_age=ORPHAN_AGE, bk_age=ORPHAN_AGE)
            if k != keep_key
        ]
    except Exception:
        logger.exception("orphan listing failed")
    if _delete_keys(doomed):
        logger.warning("post-commit cleanup left objects (retried by later sweeps)")


# ── GET /projects ───────────────────────────────────────────────────────────
@router.get("", response_model=List[CloudProjectListItem], response_model_exclude_none=True)
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
    except Exception:
        logger.exception("list failed")
        raise HTTPException(500, "list failed")
    return rows


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
    except Exception:
        logger.exception("get failed")
        raise HTTPException(500, "get failed")
    row = getattr(res, "data", None)
    if not row:
        raise HTTPException(404, "project not found")
    return row


# ── POST /projects (commit an uploaded backup) ──────────────────────────────
@router.post("", response_model=CloudProjectUpsertOut)
def commit_cloud_project(
    payload: CloudProjectUpsertIn,
    authorization: Optional[str] = Header(default=None),
):
    user_id = extract_user_id(authorization, tag="/projects")
    require_cloud_pro(user_id, tag="POST /projects")
    check_project_id(payload.project_id)
    if (payload.expected_updated_at is None) == (not payload.expect_absent):
        raise HTTPException(422, "send exactly one of expected_updated_at / expect_absent")
    try:
        meta = HumtrackMeta.model_validate(payload.meta)
    except ValidationError:
        raise HTTPException(422, "meta is not a backup descriptor (contract 1)")
    # Only an upload this server issued for this user's song can be committed.
    if not is_upload_key(meta.key, user_id, payload.project_id):
        raise HTTPException(403, "key is not an upload of this project")
    upload_key = meta.key

    try:
        size = object_size(meta.key)
    except FileNotFoundError:
        raise HTTPException(404, "backup object not found")
    except Exception:
        logger.exception("HEAD failed")
        raise HTTPException(500, "object lookup failed")
    if size is None:
        raise HTTPException(503, "R2 not configured")
    if size != meta.size:
        raise HTTPException(422, "uploaded size does not match")

    sb = require_supabase()
    quota = quota_bytes()
    used = measure_bytes(user_prefix(user_id)) or 0
    if used > quota:
        # the new object can't stay; the previous copy is untouched
        delete_objects([upload_key])
        record_used_bytes(sb, user_id, used - size)
        raise quota_exceeded(used, quota)

    # The committed copy lives under a NEW server-made name that no upload URL
    # was issued for: re-using this upload's URL later can't touch it.
    final_key = new_backup_key(user_id, payload.project_id)
    try:
        copy_object(upload_key, final_key)
        if object_size(final_key) != size:
            raise RuntimeError("copy size mismatch")
    except Exception:
        logger.exception("copy to the committed name failed")
        delete_objects([final_key])
        raise HTTPException(500, "commit copy failed")
    meta = meta.model_copy(update={"key": final_key})

    try:
        res = sb.rpc(
            "commit_cloud_project",
            {
                "p_user_id": user_id,
                "p_project_id": payload.project_id,
                "p_title": payload.title,
                "p_meta": meta.model_dump(),
                "p_size_bytes": size,
                "p_expected_updated_at": (
                    payload.expected_updated_at.isoformat()
                    if payload.expected_updated_at
                    else None
                ),
                "p_expect_absent": payload.expect_absent,
            },
        ).execute()
        result = getattr(res, "data", None) or {}
    except Exception:
        # The outcome is UNKNOWN: the transaction may have committed and only
        # the answer was lost (Codex C1). Never delete the new copy on that
        # guess — read the row: if it points at our copy, the commit happened.
        logger.exception("commit RPC failed; checking the row")
        try:
            row = _current_row(sb, user_id, payload.project_id)
        except Exception:
            row = None
            logger.exception("row re-read failed")
        if _row_key(row) != final_key:
            # Not visibly committed (or the RPC is still running): keep both
            # objects; an unreferenced copy is swept after ORPHAN_AGE.
            raise HTTPException(
                status_code=503,
                detail={"error": "commit_unknown", "project_id": payload.project_id},
            )
        result = {"status": "ok", "updated_at": row.get("updated_at"), "previous_meta": None}
    if result.get("status") != "ok":
        current = result.get("current") or None
        # Not committed: drop the copy. The upload stays for a retry ("keep
        # this device's") and is swept after ORPHAN_AGE if nobody commits it.
        delete_objects([final_key])
        raise HTTPException(
            status_code=409,
            detail={
                "error": "conflict",
                "project_id": payload.project_id,
                "cloud_version": current,
            },
        )

    previous = (result.get("previous_meta") or {}).get("key")
    _cleanup_after_commit(sb, user_id, payload.project_id, final_key, upload_key, previous)
    try:
        used = measure_bytes(user_prefix(user_id)) or used
    except HTTPException:
        pass  # logged; the commit itself succeeded
    record_used_bytes(sb, user_id, used)
    updated = _to_dt(result.get("updated_at")) or datetime.now(timezone.utc)
    return CloudProjectUpsertOut(
        project_id=payload.project_id,
        updated_at=updated,
        used_bytes=used,
        quota_bytes=quota,
    )


# ── DELETE /projects/{project_id} ───────────────────────────────────────────
@router.delete("/{project_id}", status_code=204)
def delete_cloud_project(
    project_id: str,
    authorization: Optional[str] = Header(default=None),
):
    """Delete this cloud copy. Open after a subscription ends — removing
    one's own data never needs Pro.

    Objects first, row last (Codex C2/C3):
    1. The set to delete is fixed up front: the copy the row points at plus
       this song's leftover uploads/copies (never a young ``bk-`` that may be
       another device's commit in progress, never anything created later).
    2. Every one must be confirmed deleted; otherwise 503 and the row stays,
       so the copy is still listed and the delete can be retried.
    3. The row is removed only if it still points at the copy from step 1;
       if another device committed a new copy meanwhile, 409 and the new copy
       stays.
    """
    user_id = extract_user_id(authorization, tag="/projects")
    check_project_id(project_id)  # never a prefix shared with another song
    sb = require_supabase()

    try:
        row = _current_row(sb, user_id, project_id)
        doomed = _stale_objects(sb, user_id, project_id, up_age=timedelta(0), bk_age=COMMIT_WINDOW)
    except Exception:
        logger.exception("delete: listing failed")
        raise HTTPException(503, detail={"error": "storage_unavailable"})
    key = _row_key(row)
    if key and key not in doomed:
        doomed.insert(0, key)

    failed = _delete_keys(doomed)
    if failed:
        raise HTTPException(
            status_code=503,
            detail={"error": "storage_delete_failed", "remaining": len(failed)},
        )

    if row is not None:
        try:
            res = sb.rpc(
                "delete_cloud_backup",
                {"p_user_id": user_id, "p_project_id": project_id, "p_expected_key": key},
            ).execute()
            status = getattr(res, "data", None)
        except Exception:
            logger.exception("delete RPC failed")
            # objects are gone; the row (if still there) points at nothing
            # and a retry removes it
            raise HTTPException(503, detail={"error": "delete_unknown"})
        if status == "changed":
            raise HTTPException(409, detail={"error": "changed", "project_id": project_id})

    try:
        used = measure_bytes(user_prefix(user_id))
    except HTTPException:
        used = None  # already logged; the project itself is deleted
    if used is not None:
        record_used_bytes(sb, user_id, used)

    return Response(status_code=204)
