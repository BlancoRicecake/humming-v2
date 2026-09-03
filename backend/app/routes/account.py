"""계정 관리 — 회원 탈퇴.

DELETE /account
    - 헤더: Authorization: Bearer <user JWT>
    - JWT 의 sub(user_id) 를 추출 → (1) R2 의 `vocals/{user_id}/` 음성 파일 전부
      삭제 → (2) Supabase admin API 로 auth user 삭제 (FK cascade 로
      cloud_projects / cloud_quota / subscriptions 행도 함께 삭제됨)
    - 성공: 204 No Content
    - 실패: 401 (인증 실패) / 502 (Supabase 호출 실패) / 500 (기타)

R2 삭제는 best-effort 다 — R2 가 미설정이거나 실패해도 계정 삭제는 진행하고
경고를 남긴다 (사용자 요청은 "계정 삭제"이며, 음성 파일은 uid 로 나중에 정리
가능). 단 auth user 삭제 *전에* 시도해야 uid 를 알 수 있다.

스토어 구독은 서버가 해지할 수 없다 — 클라이언트가 탈퇴 전에 App Store /
Play 구독 관리에서 직접 해지하라고 안내한다.
"""
from __future__ import annotations

import logging
from typing import Optional

import anyio
import httpx
from fastapi import APIRouter, Header, HTTPException, status
from fastapi.responses import Response

from ..auth import extract_user_id as _shared_extract_user_id
from ..settings import get_settings
from ..storage_r2 import delete_prefix

log = logging.getLogger("soundlab")

router = APIRouter()


def _extract_user_id(auth_header: Optional[str]) -> str:
    """Thin wrapper around shared JWT verifier (kept for backwards compat
    with any module that might import this symbol)."""
    return _shared_extract_user_id(auth_header, tag="/account")


@router.delete("/account", status_code=204)
async def delete_account(authorization: Optional[str] = Header(default=None)):
    """현재 사용자의 Supabase 계정 삭제 (자기 자신만 가능)."""
    user_id = _extract_user_id(authorization)

    s = get_settings()
    supabase_url = (s.supabase_url or "").rstrip("/")
    service_role = s.supabase_service_role_key or ""
    if not supabase_url or not service_role:
        log.error("SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY missing")
        raise HTTPException(status_code=500, detail="server misconfigured")

    # 1) Purge the user's voice recordings from R2 (best-effort, blocking
    #    boto3 calls → thread).
    try:
        deleted = await anyio.to_thread.run_sync(delete_prefix, f"vocals/{user_id}/")
        log.info("account delete: removed %d R2 objects for user_id=%s", deleted, user_id)
    except Exception:
        log.exception("account delete: R2 purge failed for user_id=%s (continuing)", user_id)

    # 2) Delete the auth user (cascades to our tables).
    url = f"{supabase_url}/auth/v1/admin/users/{user_id}"
    headers = {
        "Authorization": f"Bearer {service_role}",
        "apikey": service_role,
    }
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            res = await client.delete(url, headers=headers)
    except httpx.HTTPError:
        log.exception("supabase delete failed")
        raise HTTPException(status_code=502, detail="account service unavailable")

    if res.status_code not in (200, 204):
        log.warning(
            "supabase delete returned %s body=%s", res.status_code, res.text[:200]
        )
        raise HTTPException(status_code=502, detail="account delete failed")

    log.info("account deleted user_id=%s", user_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
