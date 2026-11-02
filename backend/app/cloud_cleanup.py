"""Operator-only bounded worker: python -m app.cloud_cleanup (dry-run).

--apply performs one pass, --user UUID restricts both scans and retry jobs.
No public cleanup endpoint; normal scheduling is the app lifespan loop behind
CLOUD_CLEANUP_ENABLED after migration 006 has been verified in staging.
"""
import argparse
import json
import uuid

from .cloud_lifecycle import tick
from .deps import require_supabase


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--apply', action='store_true')
    p.add_argument('--user')
    p.add_argument('--accounts', type=int, default=10)
    p.add_argument('--objects', type=int, default=200)
    p.add_argument('--jobs', type=int, default=200)
    args = p.parse_args()
    limits = dict(only_user_id=args.user, max_accounts=args.accounts, max_objects=args.objects, max_jobs=args.jobs)
    if args.apply:
        from .cloud_monitor import run_pass
        result = run_pass(require_supabase(), worker_id=str(uuid.uuid4()), **limits)
    else:
        result = tick(require_supabase(), apply=False, **limits)
    print(json.dumps(result, sort_keys=True))
    if result['errors'] or result['failed'] or result['auth_failed']:
        raise SystemExit(1)


if __name__ == '__main__': main()
