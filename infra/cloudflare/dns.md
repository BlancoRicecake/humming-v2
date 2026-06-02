# Cloudflare DNS — `hum-track.com`

Add these records in *DNS → Records*. CNAME targets come from Vercel and
Fly.io after they're provisioned (SETUP.md steps 2 and 3). All TTLs *Auto*.

| Type  | Name | Target                           | Proxy        | Purpose |
|-------|------|----------------------------------|--------------|---------|
| A or CNAME | `@` (apex) | `cname.vercel-dns.com` (or A record Vercel provides) | DNS only (gray) | Landing page |
| CNAME | `www` | `hum-track.com`                   | Proxied (orange) | www redirect to apex |
| CNAME | `api` | `humming-api.fly.dev`            | Proxied (orange) | API server (Fly.io) |
| TXT   | `@`  | (Cloudflare-issued domain verification) | n/a | Registrar verification |
| MX    | `@`  | (skip — no email at MVP)         | n/a | — |

## Apex on Vercel

Vercel supports apex via either:
- **ANAME / ALIAS** (Cloudflare doesn't have this, use *CNAME flattening at apex* — Cloudflare's default behavior allows CNAME on apex).
- Or the **A record** set Vercel provides (76.76.21.21).

Use CNAME with Cloudflare's automatic flattening — simpler.

## Why proxy `api.` (orange cloud)?
- DDoS protection (free)
- Hide Fly machine IP
- Cloudflare Analytics on API traffic (free tier)

Caveat: only enable proxy **after** Fly issues the TLS cert
(`flyctl certs show api.hum-track.com` → *Issued*). Otherwise Fly cannot
complete ACME challenge.

## Why proxy `www` but not apex?
- apex CNAME flattening already routes via Cloudflare edge.
- `www` → orange ensures HTTPS upgrade + analytics, even if Vercel cert lags.

## SSL/TLS mode

*SSL/TLS → Overview* → **Full (strict)**. Both Fly and Vercel present valid
certs, so strict is safe and prevents downgrade attacks.
