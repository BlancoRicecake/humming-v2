# Cloudflare R2 — Storage alerts

R2 does not have native usage alerts on the free plan. We approximate with
a daily cron + manual dashboard check.

## Threshold

| Metric | Threshold | Action |
|--------|-----------|--------|
| Bucket size | **8 GB** (80% of 10 GB free) | Email + start Tier 1 prep |
| Class A operations (writes) | 800k/mo | Email (free limit 1M/mo) |
| Class B operations (reads) | 8M/mo | Email (free limit 10M/mo) |

## Daily cron (Tier 0 — runs on Fly machine itself)

`infra/cron/r2-usage-check.sh` (TODO once first deploy stable):

```bash
#!/usr/bin/env bash
# Run daily 09:00 KST via Fly machine cron or GitHub Actions schedule.
# Uses Cloudflare Graph API to fetch R2 usage; emails on threshold breach.

set -euo pipefail

ACCT="${R2_ACCOUNT_ID:?}"
TOKEN="${CF_ANALYTICS_TOKEN:?}"   # separate read-only token (Account Analytics:Read)
BUCKET="humming-vocals"
THRESHOLD_BYTES=$((8 * 1024 * 1024 * 1024))   # 8 GB

usage=$(curl -fsS \
  -H "Authorization: Bearer $TOKEN" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCT/r2/buckets/$BUCKET/usage" \
  | jq '.result.payloadSize')

if [ "$usage" -gt "$THRESHOLD_BYTES" ]; then
  # Pipe to mailgun / SES / Sentry capture-message. At MVP, capture-message.
  echo "{\"alert\":\"r2_storage_over_8gb\",\"bytes\":$usage}" \
    | curl -fsS -X POST "https://sentry.io/api/0/projects/humming/humming-server/events/" \
        -H "Authorization: Bearer $SENTRY_INGEST_TOKEN" \
        --data-binary @-
fi
```

(Script is documentation only at MVP. Manual weekly check in dashboard is
sufficient until storage approaches 5 GB.)

## Manual check (weekly)

1. R2 dashboard → `humming-vocals` → *Metrics*.
2. Note bucket size.
3. If > 5 GB, add a calendar reminder to re-check in 1 week. If > 8 GB,
   escalate to Tier 1 plan (see `docs/infra-mvp.html` §10 transitions).

## What triggers Tier 1 upgrade

Any one of:
- R2 storage > 8 GB
- Class A ops > 800k/mo
- Fly CPU sustained > 50% over a week
- Supabase DB > 400 MB

R2 paid tier: $0.015/GB-month + $4.50/M Class A + $0.36/M Class B. Egress
remains **free** (R2's flagship benefit). At 100 GB: $1.50/mo.
