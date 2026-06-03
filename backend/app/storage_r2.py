"""R2 (S3-compatible) helpers for cloud-sync.

`deps.get_r2_client()` 가 boto3 S3 client 를 lazy 로 만들어 준다. 본 모듈은
그 위에 cloud-sync 가 필요로 하는 작은 유틸 (presigned PUT, prefix 삭제) 만
제공한다.
"""
from __future__ import annotations

import logging
from typing import Iterable, List, Optional

from .deps import get_r2_client
from .settings import get_settings

logger = logging.getLogger("humming.r2")


def presign_put(
    key: str,
    *,
    content_type: str = "application/octet-stream",
    expires_in: int = 300,
) -> Optional[str]:
    """Return a presigned PUT URL for `key`, or None if R2 not configured."""
    r2 = get_r2_client()
    if r2 is None:
        return None
    s = get_settings()
    return r2.generate_presigned_url(
        ClientMethod="put_object",
        Params={
            "Bucket": s.r2_bucket,
            "Key": key,
            "ContentType": content_type,
        },
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
