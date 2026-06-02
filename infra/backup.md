# Backup & Recovery — Tier 0

## Scope

| Asset | Backup strategy at MVP | Rationale |
|-------|------------------------|-----------|
| **Supabase Postgres** | Manual weekly `pg_dump` → R2 (cold) | Free tier offers no PITR; Pro tier (Tier 1) adds it |
| **R2 vocals/songs** | Rely on R2 11-nines durability | R2 SLA = 99.999999999% durability; cross-region redundant by default |
| **Backend code** | Git (GitHub) | Standard |
| **Fly machine config** | `fly.toml` in git | Re-createable in minutes |
| **Cloudflare DNS** | Documented in `infra/cloudflare/dns.md` | Re-createable manually in <15 min |
| **Secrets** | 1Password vault + `flyctl secrets list` cross-check | DO NOT commit |

## Weekly Postgres backup script

Run every **Sunday 03:00 KST**. Manual at MVP; cron via GitHub Actions
once landing repo exists.

```bash
#!/usr/bin/env bash
# infra/scripts/backup-supabase.sh
# Requires: pg_dump, aws CLI configured for R2 (S3-compatible)

set -euo pipefail

STAMP=$(date -u +%Y%m%d-%H%M%S)
OUT="/tmp/humming-db-${STAMP}.sql.gz"

pg_dump "${SUPABASE_DB_URL:?}" \
  --no-owner --no-privileges --clean --if-exists \
  | gzip -9 > "$OUT"

aws s3 cp "$OUT" "s3://humming-backups/postgres/${STAMP}.sql.gz" \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Retain last 12 weekly snapshots (~3 months). Lifecycle on humming-backups
# bucket handles the expiry (separate from humming-vocals bucket).
```

### Notes
- Use a **separate R2 bucket** `humming-backups` so the no-delete policy
  on `humming-vocals` doesn't conflict. On `humming-backups` set
  *Object expiration* = 90 days.
- `SUPABASE_DB_URL` lives in 1Password — never in Fly env (only the API
  uses anon/service-role keys, not direct DB URL).
- Test restore quarterly: `gunzip -c <file>.sql.gz | psql <staging-db>`.

## RTO / RPO (Tier 0)

| Failure | RTO | RPO | Mitigation |
|---------|-----|-----|------------|
| Fly machine crash | < 2 min | 0 (stateless API) | `auto_start_machines = true` + `min_machines_running = 1` |
| Supabase region outage | hours (wait for Supabase) | up to 1 week (last weekly dump) | Acceptable at MVP; upgrade to Pro PITR at Tier 1 |
| R2 region outage | hours | 0 (multi-region durable) | Acceptable; no DR replica at MVP |
| Domain hijack | 1–2 days | 0 | Cloudflare Registrar + 2FA + registrar lock enabled |
| Cloudflare account compromise | 1 day | 0 (DNS rebuild from `dns.md`) | 2FA + hardware key |

## Upgrade triggers for stronger backup

At **Tier 1** (~1,500 MAU, Supabase Pro):
- Enable Supabase PITR (7-day rolling, included with Pro).
- Drop manual `pg_dump` to monthly (audit-archive only).
- Add cross-region R2 replication via Cloudflare Workers (when GA).
