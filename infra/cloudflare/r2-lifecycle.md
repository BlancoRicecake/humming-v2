# Cloudflare R2 — Lifecycle policy for `humming-vocals`

## Policy: NEVER auto-delete user content

User-generated vocals and rendered songs are **the product**. Auto-deleting
them would destroy trust. Deletion is user-initiated only.

This is a hard constraint from `docs/infra-mvp.html` §1 and the cost model
in `.claude/agents/infra-ops.md` — R2 storage is the cheapest line item
($0.015/GB after 10 GB free); even 100 GB of vocals costs ~$1.50/mo.

## What we DO clean up

Multipart uploads that never completed leak storage forever. Cloudflare's
default does not abort them. We add **one** rule:

| Rule name | Condition | Action |
|-----------|-----------|--------|
| `abort-incomplete-multipart-7d` | Multipart upload age > 7 days, status = incomplete | Abort upload, free reserved storage |

### How to add (dashboard)

1. R2 → bucket `humming-vocals` → *Settings* → *Object lifecycle rules* → *Add rule*.
2. Name: `abort-incomplete-multipart-7d`.
3. Apply to: *All objects* (prefix blank).
4. Action: **Abort multipart uploads** after **7 days**.
5. Save.

### How to add (wrangler, alternative)

```bash
wrangler r2 bucket lifecycle add humming-vocals \
  --id abort-incomplete-multipart-7d \
  --abort-multipart-upload-days 7
```

## What we do NOT add

- ❌ Object expiration / transition rules — user content is permanent.
- ❌ Storage class transitions — R2 is single-class.

## Storage growth model

| MAU | Avg vocals retained / user | Total storage | Monthly cost |
|-----|-----------------------------|---------------|--------------|
| 500   | ~20 MB (5 songs × 4 MB)   | ~10 GB    | $0 (free tier) |
| 1,500 | ~40 MB                    | ~60 GB    | ~$0.75 |
| 8,000 | ~60 MB                    | ~480 GB   | ~$7.05 |

Alert threshold for tier upgrade decision: **8 GB** (below 10 GB free
ceiling). See `infra/alerts/cloudflare-r2-alerts.md`.
