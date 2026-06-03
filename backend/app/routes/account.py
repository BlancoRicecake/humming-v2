"""계정 관리 — 회원 탈퇴.

DELETE /account
    - 헤더: Authorization: Bearer <user JWT>
    - JWT 의 sub(user_id) 를 추출 → Supabase admin API 로 user 삭제
    - 성공: 204 No Content
    - 실패: 401 (인증 실패) / 502 (Supabase 호출 실패) / 500 (기타)

서비스 role key (SUPABASE_SERVICE_ROLE_KEY) 가 환경변수에 필요.
JWT 검증은 SUPABASE_JWT_SECRET 로 HS256 서명 확인.
"""
from __future__ import annotations

import os
import logging
from typing import Optional

import httpx
from fastapi import APIRouter, Header, HTTPException, status
from fastapi.responses import Response

from ..auth import extract_user_id as _shared_extract_user_id

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

    supabase_url = os.environ.get("SUPABASE_URL", "").rstrip("/")
    service_role = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not supabase_url or not service_role:
        log.error("SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY missing")
        raise HTTPException(status_code=500, detail="server misconfigured")

    url = f"{supabase_url}/auth/v1/admin/users/{user_id}"
    headers = {
        "Authorization": f"Bearer {service_role}",
        "apikey": service_role,
    }
    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            res = await client.delete(url, headers=headers)
    except httpx.HTTPError as e:
        log.exception("supabase delete failed")
        raise HTTPException(status_code=502, detail=f"supabase delete failed: {e}") from e

    if res.status_code not in (200, 204):
        log.warning(
            "supabase delete returned %s body=%s", res.status_code, res.text[:200]
        )
        raise HTTPException(
            status_code=502,
            detail=f"supabase delete returned {res.status_code}",
        )

    log.info("account deleted user_id=%s", user_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
