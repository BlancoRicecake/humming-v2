"""Prepare a reviewable fresh-STAGING schema bundle; never connect or apply.

Only reads current repository migrations and writes workspace artifacts. Refuse
the production project ID. The SQL also refuses pre-existing accounts or app
tables, so it cannot be used as an in-place production migration/repair script.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
PRODUCTION = 'iznehtmmpnivtjdiohgg'
SOURCES = [
    'backend/migrations/001_initial_schema.sql',
    'backend/migrations/002_iap_transaction_binding.sql',
    'backend/sql/2026-06-04_cloud_sync_schema.sql',
    'backend/migrations/003_lock_down_iap_and_cloud_tables.sql',
    'backend/migrations/004_cloud_backup_commit.sql',
    'backend/migrations/005_app_announcements.sql',
    'backend/migrations/006_cloud_lifecycle.sql',
    'backend/migrations/007_lock_legacy_cloud_rpcs.sql',
    'backend/migrations/008_cloud_cleanup_observability.sql',
]


def prepare(project: str, output: Path):
    if not re.fullmatch('[a-z]{20}', project) or project == PRODUCTION:
        raise ValueError('Only an explicit, non-production staging project is allowed')
    output = output.resolve()
    if not output.is_relative_to(ROOT / 'artifacts'):
        raise ValueError('Generated SQL must remain in workspace artifacts')
    guard = """begin;
do $fresh_staging_only$ begin
  if exists(select 1 from auth.users)
     or to_regclass('public.subscriptions') is not null
     or to_regclass('public.cloud_projects') is not null then
    raise exception 'Fresh empty staging project required; refusing existing data/schema';
  end if;
end $fresh_staging_only$;
"""
    parts = [f'-- FRESH STAGING ONLY: {project}\n-- Verify this exact project in the dashboard URL before Run.\n', guard]
    hashes = {}
    for name in SOURCES:
        contents = (ROOT / name).read_text(encoding='utf-8')
        hashes[name] = hashlib.sha256(contents.encode()).hexdigest()
        parts.extend(['\n-- SOURCE: ' + name + '\n', contents, '\n'])
    # Explicit server grants also work when a new project's auto-grants are off.
    parts.append("""
grant usage on schema public to service_role;
grant select, insert, update, delete on public.projects,public.tracks,public.chunks,
  public.notes,public.subscriptions,public.iap_notifications,public.cloud_projects,
  public.cloud_quota to service_role;
commit;
notify pgrst, 'reload schema';
""")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(''.join(parts), encoding='utf-8')
    receipt = dict(project_ref=project, production_project=False, applied=False,
                   sources=hashes, sql_sha256=hashlib.sha256(output.read_bytes()).hexdigest())
    output.with_suffix('.receipt.json').write_text(json.dumps(receipt, indent=2), encoding='utf-8')
    return receipt


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-ref', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    receipt = prepare(args.project_ref, args.output)
    print(json.dumps({k: receipt[k] for k in ('project_ref','production_project','applied','sql_sha256')}))
