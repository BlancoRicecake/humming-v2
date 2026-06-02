"""GET /health — liveness probe for uptime monitors + Fly.io health checks.

Kept intentionally trivial. We do NOT touch Supabase / R2 here so a transient
upstream outage doesn't take the entire app offline (those routes already
return 503 on their own).
"""
from __future__ import annotations

import os
import time

from fastapi import APIRouter

router = APIRouter(tags=["health"])

_BOOT_TS = time.time()


def _resolve_env() -> str:
    # fly.toml [env] sets ENV=production. Fall back to ENVIRONMENT (Pydantic
    # Settings field) for backwards compat with local .env. Default to "dev".
    return (
        os.environ.get("ENV")
        or os.environ.get("ENVIRONMENT")
        or "dev"
    )


def _resolve_version() -> str:
    # Prefer build-time git SHA injected via Docker build arg.
    # Fly.io itself does not expose FLY_RELEASE_VERSION at runtime; FLY_MACHINE_VERSION
    # is per-machine, not per-release. GIT_SHA is the canonical source.
    return (
        os.environ.get("GIT_SHA")
        or os.environ.get("FLY_MACHINE_VERSION")
        or os.environ.get("FLY_IMAGE_REF", "").rsplit(":", 1)[-1]
        or "local"
    )


@router.get("/health")
def health() -> dict:
    return {
        "ok": True,
        "uptime_sec": round(time.time() - _BOOT_TS, 1),
        "env": _resolve_env(),
        "version": _resolve_version(),
    }
