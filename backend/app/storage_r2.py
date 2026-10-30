"""R2 (S3-compatible) helpers for cloud-sync.

`deps.get_r2_client()` 가 boto3 S3 client 를 lazy 로 만들어 준다. 본 모듈은
그 위에 cloud-sync 가 필요로 하는 작은 유틸 (presigned PUT, prefix 삭제) 만
제공한다.
"""
from __future__ import annotations

import logging
import re
from datetime import datetime
from typing import Iterable, List, Optional, Tuple

from .deps import get_r2_client
from .settings import get_settings

logger = logging.getLogger("humming.r2")

_SAFE_KEY_PART = re.compile(r"[^A-Za-z0-9._-]+")


def sanitise_key_part(name: str) -> str:
    """Normalise one path segment of an R2 object key (project_id / file_name).

    Shared by ``/storage/presign`` (key issuance) and ``DELETE /projects``
    (prefix cleanup) so both derive the *same* ``vocals/{uid}/{project}/``
    prefix for a given project_id — otherwise deletes would miss objects
    whose project_id contained characters the presign path rewrote.
    """
    base = _SAFE_KEY_PART.sub("_", name).strip("._") or "file"
    return base[:120]


def presign_put(
    key: str,
    *,
    content_type: str = "application/octet-stream",
    expires_in: int = 300,
    content_length: Optional[int] = None,
    if_none_match: bool = False,
) -> Optional[str]:
    """Return a presigned PUT URL for `key`, or None if R2 not configured.

    With ``content_length`` the length is part of the signature, so the
    upload must be exactly that many bytes (the size the quota check
    approved).
    """
    r2 = get_r2_client()
    if r2 is None:
        return None
    s = get_settings()
    params = {
        "Bucket": s.r2_bucket,
        "Key": key,
        "ContentType": content_type,
    }
    if content_length is not None:
        params["ContentLength"] = int(content_length)
    if if_none_match:
        # Signed `If-None-Match: *`: the URL can only CREATE the key, never
        # replace an existing object (S3 conditional write; R2 support is
        # documented but not verified against the real bucket here).
        params["IfNoneMatch"] = "*"
    return r2.generate_presigned_url(
        ClientMethod="put_object",
        Params=params,
        ExpiresIn=expires_in,
        HttpMethod="PUT",
    )


def presign_get(key: str, *, expires_in: int = 300) -> Optional[str]:
    """Return a presigned GET URL for `key`, or None if R2 not configured.

    Used by mobile client to download vocal chunks from cloud sync. Caller is
    responsible for any authorisation checks (e.g. user_id prefix match) —
    R2 itself has no per-user ACL.
    """
    r2 = get_r2_client()
    if r2 is None:
        return None
    s = get_settings()
    return r2.generate_presigned_url(
        ClientMethod="get_object",
        Params={
            "Bucket": s.r2_bucket,
            "Key": key,
        },
        ExpiresIn=expires_in,
        HttpMethod="GET",
    )


def object_size(key: str) -> Optional[int]:
    """Byte size of `key` from a HEAD request, or None if R2 not configured.

    Raises FileNotFoundError when the object does not exist (never uploaded,
    or the presigned PUT has not finished). (From e328408.)
    """
    r2 = get_r2_client()
    if r2 is None:
        return None
    s = get_settings()
    try:
        res = r2.head_object(Bucket=s.r2_bucket, Key=key)
    except Exception as e:
        code = str(getattr(e, "response", {}).get("Error", {}).get("Code", ""))
        if code in ("404", "NoSuchKey", "NotFound"):
            raise FileNotFoundError(key) from e
        raise
    return int(res.get("ContentLength") or 0)


def copy_object(src: str, dst: str) -> bool:
    """Server-side copy inside the bucket. False if R2 not configured."""
    r2 = get_r2_client()
    if r2 is None:
        return False
    s = get_settings()
    r2.copy_object(
        Bucket=s.r2_bucket,
        Key=dst,
        CopySource={"Bucket": s.r2_bucket, "Key": src},
    )
    return True


def list_objects(prefix: str) -> Optional[List[Tuple[str, int, Optional[datetime]]]]:
    """(key, size, last_modified) beneath `prefix`, or None if R2 is not
    configured. Listing errors propagate: an under-count would let quota
    checks pass."""
    r2 = get_r2_client()
    if r2 is None:
        return None
    s = get_settings()
    out: List[Tuple[str, int, Optional[datetime]]] = []
    paginator = r2.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=s.r2_bucket, Prefix=prefix):
        for obj in page.get("Contents", []) or []:
            k = obj.get("Key")
            if k:
                out.append((k, int(obj.get("Size") or 0), obj.get("LastModified")))
    return out


def prefix_bytes(prefix: str) -> Optional[int]:
    """Total bytes stored beneath `prefix`, or None if R2 not configured.
    (From e328408.)"""
    objs = list_objects(prefix)
    if objs is None:
        return None
    return sum(size for _, size, _ in objs)


def delete_objects(keys: Iterable[str]) -> int:
    """Delete listed object keys. Returns count of deleted keys (best-effort)."""
    keys = list(keys)
    if not keys:
        return 0
    r2 = get_r2_client()
    if r2 is None:
        return 0
    s = get_settings()
    total = 0
    # S3 DeleteObjects 는 1000개 batch 한계.
    for i in range(0, len(keys), 1000):
        batch = keys[i : i + 1000]
        try:
            res = r2.delete_objects(
                Bucket=s.r2_bucket,
                Delete={"Objects": [{"Key": k} for k in batch]},
            )
            total += len(res.get("Deleted", []) or [])
        except Exception:
            logger.exception("delete_objects batch failed (start=%d)", i)
    return total


def delete_objects_strict(keys: Iterable[str]) -> List[str]:
    """Delete `keys`; return the keys that were NOT confirmed deleted (a
    per-key ``Errors`` entry, or a failed batch). Deleting a key that does
    not exist counts as deleted (S3 semantics)."""
    keys = list(dict.fromkeys(keys))
    if not keys:
        return []
    r2 = get_r2_client()
    if r2 is None:
        return keys
    s = get_settings()
    failed: List[str] = []
    for i in range(0, len(keys), 1000):
        batch = keys[i : i + 1000]
        try:
            res = r2.delete_objects(
                Bucket=s.r2_bucket,
                Delete={"Objects": [{"Key": k} for k in batch]},
            )
        except Exception:
            logger.exception("delete_objects batch failed (start=%d)", i)
            failed.extend(batch)
            continue
        errors = {e.get("Key") for e in (res.get("Errors") or [])}
        failed.extend(k for k in batch if k in errors)
    if failed:
        logger.warning("delete_objects: %d key(s) not deleted", len(failed))
    return failed


def delete_prefix(prefix: str) -> int:
    """List + delete all objects beneath `prefix`. Returns total deleted."""
    r2 = get_r2_client()
    if r2 is None:
        return 0
    s = get_settings()
    keys: List[str] = []
    paginator = r2.get_paginator("list_objects_v2")
    try:
        for page in paginator.paginate(Bucket=s.r2_bucket, Prefix=prefix):
            for obj in page.get("Contents", []) or []:
                k = obj.get("Key")
                if k:
                    keys.append(k)
    except Exception:
        logger.exception("list_objects_v2 failed (prefix=%s)", prefix)
        return 0
    return delete_objects(keys)
