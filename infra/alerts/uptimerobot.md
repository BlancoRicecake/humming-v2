# UptimeRobot — uptime monitors

Free plan: 50 monitors, 5min interval. We use 2.

## Monitors

| Monitor name | Type | URL | Interval | Keyword check | Down trigger |
|--------------|------|-----|----------|---------------|--------------|
| `humming-api-health` | HTTP(s) | `https://api.hum-track.com/health` | 5 min | response contains `"ok"` | 2 consecutive failures (~10 min) |
| `humming-landing` | HTTP(s) | `https://hum-track.com` | 5 min | response status 200 | 2 consecutive failures |

## Alert contacts

1. **Email** → `heobusy@gmail.com` (immediate)
2. **iOS push** via UptimeRobot mobile app (immediate)
3. **SMS** — skip at MVP (paid)

## Escalation

| Severity | Trigger | Action |
|----------|---------|--------|
| P1 | API down > 3 min | Email + push. Open `flyctl logs` and Sentry within 5 min. |
| P2 | Landing down > 5 min | Email only. Investigate within 30 min (Vercel status page first). |
| P3 | SSL cert expiring < 14 days | UptimeRobot built-in alert. Fly & Vercel auto-renew, so this is informational. |

## Status page (optional, free)

UptimeRobot offers a public status page at `https://stats.uptimerobot.com/<id>`.
Enable after launch; link from landing footer.

## Maintenance windows

For planned deploys >1 min downtime, create a *Maintenance window* in
UptimeRobot to suppress false alerts. Fly rolling deploys at MVP cause
~5–10 s blip — within 1 missed check, won't trigger 2-failure threshold.
