"""Operator-only aggregate check: python -m app.cloud_monitor. Never performs cleanup."""
from __future__ import annotations

import json
import logging
import uuid
import asyncio

import anyio

log = logging.getLogger('humming.cloud_monitor')
COUNTERS = frozenset({'accounts', 'objects', 'eligible', 'queued', 'deleted', 'failed', 'busy', 'auth_failed', 'errors'})


def record(sb, worker_id, state, counts=None, *, scheduled=False):
    # Caller/exception strings and object/account identifiers have no representable fields.
    safe = {k: max(0, min(2147483647, v)) for k, v in (counts or {}).items()
            if k in COUNTERS and isinstance(v, int) and not isinstance(v, bool)}
    result = sb.rpc('record_cloud_cleanup_pass', {
        'p_worker_id': str(uuid.UUID(str(worker_id))), 'p_state': state,
        'p_counts': safe, 'p_kind': 'scheduled' if scheduled else 'manual',
    }).execute().data
    if not isinstance(result, dict) or result.get('status') != 'ok':
        raise RuntimeError('cloud cleanup heartbeat unavailable')


def run_pass(sb, *, worker_id, scheduled=False, **limits):
    from .cloud_lifecycle import tick
    record(sb, worker_id, 'running', scheduled=scheduled)
    try:
        stats = tick(sb, apply=True, **limits)
    except Exception:
        record(sb, worker_id, 'error', {'errors': 1}, scheduled=scheduled)
        raise
    failed = any(stats.get(k, 0) for k in ('failed', 'auth_failed', 'errors'))
    record(sb, worker_id, 'error' if failed else 'ok', stats, scheduled=scheduled)
    if failed:
        log.error('cloud cleanup pass incomplete; durable work retained')
    return stats


def health(sb):
    result = sb.rpc('cloud_cleanup_health', {}).execute().data
    if not isinstance(result, dict) or not isinstance(result.get('healthy'), bool):
        raise RuntimeError('cloud cleanup health unavailable')
    return result


async def scheduled_loop():
    """Shared by the API lifespan; no DSP imports or public maintenance endpoint."""
    from .deps import require_supabase
    worker_id = str(uuid.uuid4())
    while True:
        try:
            def run():
                return run_pass(require_supabase(), worker_id=worker_id, scheduled=True)
            stats = await anyio.to_thread.run_sync(run)
            log.info('cloud cleanup counts=%s', stats)
        except Exception:
            log.error('cloud cleanup pass failed; durable jobs will retry')
        await asyncio.sleep(60)


def main():
    from .deps import require_supabase
    try:
        report = health(require_supabase())
    except Exception:
        report = {'healthy': False, 'alerts': ['cloud_cleanup_health_unavailable']}
    print(json.dumps(report, sort_keys=True))
    raise SystemExit(0 if report['healthy'] else 1)


if __name__ == '__main__':
    main()
