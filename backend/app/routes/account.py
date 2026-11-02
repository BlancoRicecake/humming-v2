"""Durable account deletion (migration 006).

202 is accepted/pending, not a claim that every object is already gone.
The request and retry jobs survive Auth cascade, block new cloud activity,
and audit late PUTs. Store subscriptions are managed separately by the user.
"""
from __future__ import annotations

from typing import Optional

import anyio
from fastapi import APIRouter, Header, HTTPException
from fastapi.responses import JSONResponse, Response

from ..auth import extract_user_id as _shared_extract_user_id
from ..deps import require_supabase
from .. import cloud_lifecycle as lifecycle

router = APIRouter()


def _extract_user_id(auth_header: Optional[str]) -> str:
    """Thin wrapper around shared JWT verifier (kept for backwards compat
    with any module that might import this symbol)."""
    return _shared_extract_user_id(auth_header, tag="/account")


@router.delete("/account", status_code=202)
async def delete_account(authorization: Optional[str] = Header(default=None),
                         x_account_deletion_receipt: Optional[str] = Header(default=None)):
    """현재 사용자의 Supabase 계정 삭제 (자기 자신만 가능)."""
    # JWKS fetch / JWT verify is blocking — keep it off the event loop.
    user_id = await anyio.to_thread.run_sync(_extract_user_id, authorization)

    sb = await anyio.to_thread.run_sync(require_supabase)
    await anyio.to_thread.run_sync(lifecycle.request_account_deletion, sb, user_id)
    if x_account_deletion_receipt != 'pending-v1':
        # Released clients accept only 200/204. Confirm the Auth account is
        # actually gone before using their legacy "account deleted" response;
        # the durable storage purge remains scheduled in either case.
        def auth_is_gone():
            state = sb.table('cloud_accounts').select('auth_deleted_at').eq('user_id', user_id).maybe_single().execute().data or {}
            return state.get('auth_deleted_at') is not None
        if await anyio.to_thread.run_sync(auth_is_gone):
            return Response(status_code=204)
        raise HTTPException(503, detail={'error': 'deletion_pending'})
    return JSONResponse(status_code=202, content={'status': 'deletion_pending'})
