# Cloud cleanup operational check — prepared, not enabled

The operator CLI is `python -m app.cloud_monitor` inside the backend container.
It reads migration008's aggregate health RPC. It never scans/deletes bucket objects,
retries Auth deletion, starts a worker, changes a feature flag, or publishes anything.
Exit0 means healthy; exit1 means missing/stale worker, failed pass, overdue work or
an unavailable/missing schema. A queue with zero rows alone cannot pass health.

## Signals and initial thresholds

| Signal | Alert |
|---|---|
| No scheduled worker recorded | `scheduled_worker_missing` |
| Last successful pass >5min, or current pass running >2min | `scheduled_worker_stale` |
| Last pass has provider/Auth/persistence errors | `worker_pass_failed` |
| Delete job exists for >1h | `delete_queue_old` |
| Account scan overdue >10min | `account_scans_overdue` |
| Auth deletion requested >15min and still unconfirmed | `auth_deletion_overdue` |
| Primary file purge >15min past URL/grace boundary | `primary_purge_overdue` |

These are operational alert thresholds, not a customer deletion-time promise.
Completed tombstones keep daily late-upload scans. The health table contains only
random process UUIDs, timestamps, states and allowlisted numeric counters. Old
process rows expire after7days; customer deletion tombstones do not share that rule.
Manual CLI passes do not certify that the scheduled service is alive.

## Enable only after approved rollout

1. Apply003/004/005/006/007/008 in the reviewed order (007 production tightening is
   already done). Check24 schema/ACL rows and actual public-key rejections.
2. Deploy the verified backend candidate with cleanup enabled; retain cloud writes
   OFF initially. Verify a real scheduled pass and operator health0 twice.
3. Connect an appropriately scoped Fly monitoring credential as GitHub
   `FLY_API_TOKEN`. Do not paste it into a workflow/source/log/chat. Existing repo
   secret-name inspection on11/02 found no such repository secret. It was not created
   or registered in this work. Its scope and secure registration remain a separate step.
4. Only then set repository variable `HUMTRACK_CLOUD_MONITOR_ENABLED=true`, run
   `Cloud cleanup watch` manually, and verify the responsible owner's failure
   notification settings. That variable was not set and the workflow was not run/pushed.

The prepared job runs every15minutes and executes only the read-only SSH command.
CI stdout includes health and known alert codes only, never the full SSH output,
provider errors, counters, account identifiers or filenames. Before pushing, confirm
the rollout/credential readiness and owner notification destination. The CLI can be
used locally with `infra/scripts/check_cloud_cleanup.py --flyctl <existing flyctl>`.
It deliberately fails rather than claiming health when the deployed image lacks008.

## Response

On worker/queue failure, inspect private aggregate health and Sentry error groups
`cloud cleanup pass incomplete; durable work retained` or
`cloud cleanup pass failed; durable jobs will retry`. No customer key/title is logged.
Keep the durable queue/tombstones/leases. Do not prune the bucket or remove migration006.
Use `CLOUD_BACKUP_WRITES_ENABLED=false` to stop new writes while retaining existing
list/restore/delete access and the cleanup worker. Check provider availability,
permissions, claims and the next pass before declaring recovery.

Sentry alert routing, the GitHub notification recipient and sustained production
execution are still unverified. No email/message was sent and no live alert rule was changed.
