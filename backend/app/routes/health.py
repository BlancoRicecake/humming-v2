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
async def health() -> dict:
    # MUST stay `async def`. Sentry's FastApiIntegration re-wraps the handler of
    # *sync* endpoints (`dependant.call`) on every get_request_handler call with
    # no idempotency guard (sentry-sdk 2.61.1, integrations/fastapi.py). /health
    # is hit every few seconds by Fly's health checker, so a sync handler
    # accumulates hundreds of nested wrappers until a request RecursionErrors.
    # `async def` is skipped by that wrapper (iscoroutinefunction guard) → safe.
    # Body is trivial/non-blocking, so async costs nothing.
    return {
        "ok": True,
        "uptime_sec": round(time.time() - _BOOT_TS, 1),
        "env": _resolve_env(),
        "version": _resolve_version(),
    }


# ── GET /health/cloud — is cloud backup really ready? (2026-11-04) ─────────
# Public and token-free so the app's release gate (mobile/tool/
# release_support.rb) can refuse a cloud-ON build against a server that only
# looks open. Reports switches and readiness only: no counts, ids, keys or
# URLs. The DB check runs at most every 30 s (cached) and never writes.
_CLOUD_TTL = 30.0
_cloud_cache: tuple[float, dict] | None = None
# the codes migration 008's cloud_cleanup_health() can report
_ALERT_CODES = frozenset({
    "scheduled_worker_missing", "worker_pass_failed", "scheduled_worker_stale",
    "delete_queue_old", "account_scans_overdue", "auth_deletion_overdue",
    "primary_purge_overdue",
})


def _cloud_readiness() -> dict:
    from ..cloud_quota import BACKUP_CONTRACT
    from ..settings import get_settings

    s = get_settings()
    storage = all([s.r2_access_key_id, s.r2_secret_access_key, s.r2_endpoint, s.r2_bucket])
    out = {
        "contract": BACKUP_CONTRACT,
        "version": _resolve_version(),
        "sync_enabled": bool(s.cloud_sync_enabled),
        "writes_enabled": bool(s.cloud_backup_writes_enabled),
        "cleanup_enabled": bool(s.cloud_cleanup_enabled),
        "storage_configured": bool(storage),
        # migration 006 (lifecycle) + 008 (cleanup health) answer
        "lifecycle_db": False,
        "cleanup_healthy": False,
        "alerts": [],
    }
    if out["sync_enabled"]:
        try:
            from ..cloud_monitor import health as cleanup_health
            from ..deps import require_supabase

            report = cleanup_health(require_supabase())
            out["lifecycle_db"] = True
            out["cleanup_healthy"] = bool(report.get("healthy"))
            out["alerts"] = sorted(
                a for a in report.get("alerts", []) if isinstance(a, str) and a in _ALERT_CODES
            )
        except Exception:
            out["alerts"] = ["cloud_health_unavailable"]
    out["ready"] = all(
        out[k] for k in ("sync_enabled", "writes_enabled", "cleanup_enabled",
                         "storage_configured", "lifecycle_db", "cleanup_healthy")
    )
    return out


@router.get("/health/cloud")
async def cloud_health() -> dict:
    # async for the same Sentry reason as /health; the DB call runs in a thread
    global _cloud_cache
    now = time.monotonic()
    if _cloud_cache is None or now - _cloud_cache[0] > _CLOUD_TTL:
        import anyio

        _cloud_cache = (now, await anyio.to_thread.run_sync(_cloud_readiness))
    return dict(_cloud_cache[1])
