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
`docs/release/STAGING-VERIFICATION-2026-11-01.md`.

| File | Feature | Staging | Production |
|---|---|---|---|
| `001_initial_schema.sql` | base schema | earlier — not re-verified here | earlier — not re-verified here |
| `002_iap_transaction_binding.sql` | IAP transaction binding | earlier — not re-verified here | earlier — not re-verified here |
| `003_lock_down_iap_and_cloud_tables.sql` | IAP / cloud table lock-down | earlier — not re-verified here | earlier — not re-verified here |
| `004_cloud_backup_commit.sql` | cloud backup commit | earlier — not re-verified here | earlier — not re-verified here |
| `005_app_announcements.sql` | announcements table, read RLS, revision | applied | applied 2026-11-02 |
| `006_announcements_admin.sql` | announcement admins + admin write policy | not applied (isolated local check only) | applied 2026-11-02 |
| `006_cloud_lifecycle.sql` | cloud account exit, delayed delete, worker | applied + verified | **not applied** |
| `007_lock_legacy_cloud_rpcs.sql` | revoke client execute on legacy RPCs | applied + verified | applied 2026-11-01 |
| `008_cloud_cleanup_observability.sql` | admin heartbeat, cleanup backlog view | applied + scheduled run verified | **not applied** |

`006_announcements_admin.sql` being applied in production does **not** mean
`006_cloud_lifecycle.sql` is. Before any production apply, compare this table
with the read-only report `backend/sql/2026-10-31_release_preflight_readonly.sql`.
