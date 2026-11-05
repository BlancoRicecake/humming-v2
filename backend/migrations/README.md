# Migrations — full names and where they are applied

Two files share the number **006**. They are different features. A migration
is always named by its **full file name**; the number alone never picks a
file. Every tool lists the files it applies by full name
(`infra/scripts/prepare_cloud_staging_sql.py`, `backend/tests/cloud_fixtures.py`),
and `backend/tests/test_migration_names.py` fails if a reference does not
match an existing file name exactly or this table misses a file.

Do not rename an applied file, and do not re-run one: the table below is
the record. Source: `docs/release/DEVELOP-INTEGRATION-HANDOFF-2026-11-03.md`
(2026-11-03), `docs/release/ANNOUNCEMENTS-PRODUCTION-2026-11-02.md`,
`docs/release/STAGING-VERIFICATION-2026-11-01.md`, and the 2026-11-04
production cloud upgrade (below).

| File | Feature | Staging | Production |
|---|---|---|---|
| `001_initial_schema.sql` | base schema | earlier — not re-verified here | earlier — not re-verified here |
| `002_iap_transaction_binding.sql` | IAP transaction binding | earlier — not re-verified here | earlier — not re-verified here |
| `003_lock_down_iap_and_cloud_tables.sql` | IAP / cloud table lock-down | earlier — not re-verified here | **partial** — only the private receipt-table section, 2026-11-04 (see below) |
| `004_cloud_backup_commit.sql` | cloud backup commit | earlier — not re-verified here | applied 2026-11-04 |
| `005_app_announcements.sql` | announcements table, read RLS, revision | applied | applied 2026-11-02 |
| `006_announcements_admin.sql` | announcement admins + admin write policy | not applied (isolated local check only) | applied 2026-11-02 |
| `006_cloud_lifecycle.sql` | cloud account exit, delayed delete, worker | applied + verified | applied 2026-11-04 |
| `007_lock_legacy_cloud_rpcs.sql` | revoke client execute on legacy RPCs | applied + verified | applied 2026-11-01 |
| `008_cloud_cleanup_observability.sql` | admin heartbeat, cleanup backlog view | applied + scheduled run verified | applied 2026-11-04 |
| `009_announcement_images.sql` | optional announcement image + ko/en alt | not applied (local PostgreSQL rehearsal only) | **not applied** — public feed lacked the image columns (42703) on 2026-11-04; see `docs/release/ANNOUNCEMENT-PUBLISH-2026-11-04.md` |

`006_announcements_admin.sql` being applied in production does **not** mean
`006_cloud_lifecycle.sql` is. Before any production apply, compare this table
with the read-only report `backend/sql/2026-10-31_release_preflight_readonly.sql`.

## Production cloud upgrade — 2026-11-04 (Supabase `iznehtmmpnivtjdiohgg`)

Applied by Codex as **one atomic bundle** through the SQL Editor, after
rehearsals on an isolated PostgreSQL (004 absent and 004 present, both with
the existing `006_announcements_admin.sql`: 24/24 checks; an unsafe legacy
RPC grant rolled the whole transaction back).

- Catalog before: 004, `006_cloud_lifecycle.sql` and 008 absent; the
  existing `read_own_cloud_*` policies were SELECT-only with `auth.uid()`
  ownership; the IAP receipt table had RLS on and no policies, but anon /
  authenticated table grants were still present.
- Bundle: `004_cloud_backup_commit.sql` (it was absent),
  `006_cloud_lifecycle.sql`, `008_cloud_cleanup_observability.sql`, and only
  the **private receipt-table section of `003_lock_down_iap_and_cloud_tables.sql`**
  (revokes the client grants). The rest of 003 was not re-run: the existing
  cloud read policies and the announcement admin policy were kept as they
  were. `006_announcements_admin.sql` was not re-applied.
- Bundle SQL SHA-256 `b59355f13276364af64298e2841c3c1ab004c0b6a89fe4b2a6908fb1b8dccad4`.
- Read-back with `backend/sql/2026-10-31_release_preflight_readonly.sql`:
  24 checks, 0 failed. `cloud_projects` 0 rows, quota 0 rows, notices 0,
  admins 1, receipt client access false.
- Evidence (outside Git): `artifacts/cloud-service-2026-11-04/production-db-applied.json`,
  `production-db-24-pass.png`, `CODEX-OPS-STATUS.md`.

**Do not re-run this bundle or any of these files on production.** The
bundle refuses an already-applied lifecycle schema by design. The
fresh-staging bundle (`infra/scripts/prepare_cloud_staging_sql.py`) is for
new staging databases only.
