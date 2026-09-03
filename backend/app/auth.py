"""Shared Supabase JWT verification — thin wrapper over ``app.deps``.

Historically this module carried its own verifier (used by /account,
/projects, /storage) that diverged from ``deps.get_current_user`` (used by
/iap/verify): different role checks, different algorithm lists, and both
decoded HS256 tokens *unverified* when ``SUPABASE_JWT_SECRET`` was unset.
There is now exactly one implementation — ``deps.decode_supabase_jwt`` — and
it fails closed.
"""
from __future__ import annotations

from typing import Optional

from .deps import _bearer_token, decode_supabase_jwt


def extract_user_id(auth_header: Optional[str], *, tag: str = "auth") -> str:
    """Validate a Supabase JWT bearer token and return its ``sub`` (user id).

    Raises HTTPException 401/403/503 — see ``deps.decode_supabase_jwt``.
    ``tag`` only labels log lines so callers can be told apart.
    """
    claims = decode_supabase_jwt(_bearer_token(auth_header), tag=tag)
    return str(claims["sub"])
