"""Durable cleanup and deletion fences (migration 006).

No provider key, signed URL, title, or raw exception is logged here. RPCs
serialize decisions; R2 operations happen outside transactions, on keys that
can no longer become a published backup. Failures stay in the DB queue.
"""
from __future__ import annotations

import logging
import re
import time
import uuid
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from fastapi import HTTPException

from . import storage_r2

log = logging.getLogger('humming.cloud_lifecycle')
OBJECT_AGE = timedelta(hours=24)


def call(sb, action, user_id, **payload):
    try:
        result = sb.rpc('cloud_lifecycle', {'p_action': action, 'p_user_id': user_id, 'p_payload': payload}).execute().data
    except Exception:
        log.error('cloud lifecycle persistence unavailable action=%s', action)
        raise HTTPException(503, detail={'error': 'cloud_lifecycle_unavailable'}) from None
    if not isinstance(result, dict):
        raise HTTPException(503, detail={'error': 'cloud_lifecycle_unavailable'})
    return result


def require_ok(result):
    status = result.get('status')
    if status == 'ok':
        return result
    code = 410 if status in {'account_deleting', 'gone'} else 409
    raise HTTPException(code, detail={'error': status or 'cloud_lifecycle_unavailable'})


def ensure_account(sb, user_id):
    return require_ok(call(sb, 'ensure', user_id))


def register_upload(sb, user_id, project_id, key, ttl):
    return require_ok(call(sb, 'upload', user_id, project_id=project_id, key=key, ttl=ttl))


def begin_commit(sb, user_id, project_id, source, key):
    return require_ok(call(sb, 'begin_commit', user_id, project_id=project_id, source=source, key=key))


def enqueue(sb, user_id, keys, *, reason, project_id=None, expected_key=None, dry_run=False):
    keys = list(dict.fromkeys(keys))
    result = []
    for offset in range(0, len(keys), 500):
        r = call(sb, 'queue', user_id, keys=keys[offset:offset + 500], reason=reason,
                 project_id=project_id, expected_key=expected_key, dry_run=dry_run)
        if r.get('status') == 'changed':
            raise HTTPException(409, detail={'error': 'changed', 'project_id': project_id})
        result.extend(require_ok(r).get('keys', []))
    return result


def execute_deletes(sb, user_id, keys, *, delete=None, force_retry=False, deadline=None, outcome=None):
    """Only a claimed/fenced key can reach R2. Persist failures individually."""
    token = str(uuid.uuid4())
    keys = list(dict.fromkeys(keys))[:500]
    claimed = require_ok(call(sb, 'claim_deletes', user_id, keys=keys, token=token, force_retry=force_retry)).get('keys', [])
    try:
        failed = set((delete or storage_r2.delete_objects_strict)(claimed))
    except Exception:
        failed = set(claimed)
    for key in claimed:
        if deadline is not None and time.monotonic() >= deadline:
            failed.update(claimed[claimed.index(key):])
            break  # the uncompleted durable claims become retryable on expiry
        call(sb, 'finish_delete', user_id, key=key, token=token, ok=key not in failed)
    if outcome is not None:
        outcome.update(claimed=len(claimed), failed=len(failed), busy=len(set(keys) - set(claimed)))
    # A previously failed/claimed job is still pending even if this caller
    # didn't acquire it; never falsely report those files as removed.
    return list(failed | (set(keys) - set(claimed)))


def delete_auth_user(sb, user_id):
    try:
        sb.auth.admin.delete_user(user_id)
        return True
    except Exception as error:
        # Only the explicit Auth error code means a retry found it gone.
        # A generic 404 from a proxy or wrong URL is not proof of deletion.
        return getattr(error, 'code', None) == 'user_not_found'


def request_account_deletion(sb, user_id):
    result = call(sb, 'request_delete', user_id)
    if result.get('status') != 'deletion_pending':
        raise HTTPException(503, detail={'error': 'deletion_not_persisted'})
    token = str(uuid.uuid4())
    try:
        if call(sb, 'claim_account', user_id, token=token).get('status') == 'ok':
            ok = delete_auth_user(sb, user_id)
            call(sb, 'auth_result', user_id, token=token, ok=ok)
            call(sb, 'finish_scan', user_id, token=token, cursor=None, complete=False, delay=1)
    except Exception:
        log.error('account deletion accepted; immediate Auth attempt deferred')
    return result


def _dt(value):
    if isinstance(value, datetime):
        return value
    return datetime.fromisoformat(str(value).replace('Z', '+00:00')) if value else None


def tick(sb, *, apply=False, max_accounts=10, max_objects=200, max_jobs=200, max_seconds=45, only_user_id=None):
    """One bounded pass; dry-run by default. Tombstones keep auditing late PUTs.

    The provider can finish a request that started before URL expiry. Even
    after an initial empty purge, deleted accounts remain scheduled daily;
    their state survives Auth cascade and cannot issue or publish new writes.
    """
    max_accounts = max(1, min(50, max_accounts))
    max_objects = max(1, min(500, max_objects))
    max_jobs = max(1, min(500, max_jobs))
    now = datetime.now(timezone.utc)
    deadline = time.monotonic() + max(1, min(120, max_seconds))
    stats = dict(dry_run=not apply, accounts=0, objects=0, eligible=0, queued=0, deleted=0, failed=0, busy=0, auth_failed=0, errors=0)
    account_query = sb.table('cloud_accounts').select('*')
    if only_user_id:
        only_user_id = str(uuid.UUID(str(only_user_id)))
        account_query = account_query.eq('user_id', only_user_id)
    accounts = account_query.order('next_sweep_at').limit(max_accounts).execute().data or []
    for account in accounts:
        if time.monotonic() >= deadline:
            break
        if _dt(account['next_sweep_at']) > now:
            continue
        uid = account['user_id']
        token = str(uuid.uuid4())
        if apply and call(sb, 'claim_account', uid, token=token).get('status') != 'ok':
            continue
        stats['accounts'] += 1
        cursor = account.get('scan_cursor')
        deleting = account.get('delete_requested_at') is not None
        auth_deleted = account.get('auth_deleted_at') is not None
        try:
            if apply and deleting and not auth_deleted and _dt(account['auth_retry_at']) <= now:
                auth_deleted = delete_auth_user(sb, uid)
                call(sb, 'auth_result', uid, token=token, ok=auth_deleted)
                if not auth_deleted:
                    stats['auth_failed'] += 1
                    log.error('Auth deletion unconfirmed; durable retry scheduled')
            objects, following = storage_r2.list_objects_page(f'vocals/{uid}/', limit=max_objects, cursor=cursor)
            stats['objects'] += len(objects)
            keys = []
            for key, _, modified in objects:
                if not key.startswith(f'vocals/{uid}/'):
                    raise ValueError('provider returned an object outside requested prefix')
                known = re.fullmatch(r'vocals/' + re.escape(uid) + r'/[A-Za-z0-9_-]{1,100}/(?:up|bk)-[0-9a-f]{32}\.humtrack', key)
                if deleting or (known and modified is not None and now - modified >= OBJECT_AGE):
                    keys.append(key)
            accepted = enqueue(sb, uid, keys, reason='account_delete' if deleting else 'orphan', dry_run=not apply)
            stats['eligible'] += len(accepted)
            if apply:
                stats['queued'] += len(accepted)
                complete = deleting and not objects and not cursor and not following and auth_deleted
                # Empty after the expiry/grace boundary: primary purge complete.
                # Keep the account tombstone on a daily late-upload audit.
                past_grace = deleting and _dt(account.get('purge_after')) <= now
                delay = 1 if following else (86400 if complete and past_grace else 60 if deleting else 3600)
                call(sb, 'finish_scan', uid, token=token, cursor=following, complete=complete, delay=delay, has_objects=bool(objects))
        except Exception:
            stats['errors'] += 1
            log.error('cloud cleanup account pass failed (retained for retry)')
            if apply:
                try:
                    call(sb, 'finish_scan', uid, token=token, cursor=cursor, complete=False, delay=60)
                except Exception:
                    pass  # the claim lease expires; the durable task remains
    job_query = sb.table('cloud_delete_jobs').select('object_key,user_id,next_attempt_at,claim_until')
    if only_user_id:
        job_query = job_query.eq('user_id', only_user_id)
    jobs = job_query.order('next_attempt_at').limit(max_jobs).execute().data or []
    job_now = datetime.now(timezone.utc)  # includes jobs queued during this pass
    groups = defaultdict(list)
    for job in jobs:
        if _dt(job['next_attempt_at']) <= job_now and (not job.get('claim_until') or _dt(job['claim_until']) <= job_now):
            groups[job['user_id']].append(job['object_key'])
    if apply:
        for uid, keys in groups.items():
            if time.monotonic() >= deadline:
                break
            try:
                outcome = {}
                execute_deletes(sb, uid, keys, deadline=deadline, outcome=outcome)
                stats['deleted'] += outcome['claimed'] - outcome['failed']
                stats['failed'] += outcome['failed']
                stats['busy'] += outcome['busy']
                account = sb.table('cloud_accounts').select('delete_requested_at').eq('user_id', uid).maybe_single().execute().data or {}
                if not account.get('delete_requested_at'):
                    objects, following = storage_r2.list_objects_page(f'vocals/{uid}/', limit=500)
                    if following is None:
                        from .cloud_quota import record_used_bytes
                        record_used_bytes(sb, uid, sum(o[1] for o in objects))
            except Exception:
                stats['errors'] += 1
                log.error('cloud cleanup batch failed (durable task retained)')
    else:
        stats['jobs_due'] = sum(map(len, groups.values()))
    return stats
