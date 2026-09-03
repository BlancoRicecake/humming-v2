"""Re-check subscription rows against the stores and repair drift.

Why this exists
---------------
`subscriptions` is normally kept current by two paths: the app calling
``/iap/verify``, and the store webhooks. Both can leave a row stale:

* a user on an **old app build** (one that never sent
  ``applicationUserName``) has no ``original_transaction_id`` /
  ``purchase_token`` binding yet, so Apple/Google notifications about them are
  recorded with ``error='no_user'`` and skipped;
* a webhook can be missed entirely (endpoint down past the store's retry
  window);
* a refund/chargeback that arrived while the row was unbound.

Left alone, those rows keep granting Pro after the subscription ended (or,
rarely, deny Pro to someone who renewed). This script asks the store what is
actually true for every row it *can* address, and writes the answer back
through the same code path the webhooks use.

It is deliberately conservative:

* a row is only changed when the store answered authoritatively;
* a row without a store binding is reported, never guessed at;
* ``--dry-run`` (the default) prints the diff and writes nothing.

Usage
-----
    cd backend
    # look first
    python tools/reconcile_subscriptions.py
    # then apply
    python tools/reconcile_subscriptions.py --apply

    # only rows that expire within 2 days (cheap daily pass)
    python tools/reconcile_subscriptions.py --apply --window-days 2

Environment: the same secrets the server runs with (SUPABASE_URL,
SUPABASE_SERVICE_ROLE_KEY, Apple StoreKit key vars, GOOGLE_* vars). Reads
``backend/.env`` like the app does.

Exit code is 0 unless a store call failed for every row it tried.
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.deps import require_supabase, subscription_is_pro  # noqa: E402
from app.routes import iap as iap_mod  # noqa: E402
from app.settings import get_settings  # noqa: E402

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
log = logging.getLogger("reconcile")

LIVE_STATUSES = ("trial", "active", "cancelled")


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _fetch_rows(sb, window_days: Optional[int]) -> List[dict]:
    """Rows that currently grant Pro (optionally only those expiring soon)."""
    q = sb.table("subscriptions").select("*").in_("status", list(LIVE_STATUSES))
    if window_days is not None:
        cutoff = (_now() + timedelta(days=window_days)).isoformat()
        q = q.lte("expires_at", cutoff)
    res = q.execute()
    return list(getattr(res, "data", None) or [])


async def _check_apple(row: dict) -> Tuple[Optional[str], Optional[datetime], Optional[dict]]:
    """Ask Apple for the current state of this subscription.

    Returns ``(status, expires_at, transaction)``; ``(None, None, None)`` when
    the row cannot be addressed (no transaction id on file).
    """
    tx_id = row.get("transaction_id") or row.get("original_transaction_id")
    if not tx_id:
        return None, None, None
    info = await iap_mod._apple_lookup_transaction(str(tx_id))
    signed = info.get("signedTransactionInfo")
    if not signed:
        raise RuntimeError("apple returned no signedTransactionInfo")
    tx = iap_mod._decode_apple_jws_verified(signed)
    status, expires_at = iap_mod._apple_status(tx)
    return status, expires_at, tx


async def _check_google(row: dict) -> Tuple[Optional[str], Optional[datetime], Optional[dict]]:
    token = row.get("purchase_token")
    product = row.get("product_id")
    if not (token and product):
        return None, None, None
    sub = await iap_mod._google_verify_subscription(str(product), str(token))
    status, expires_at = iap_mod._google_status(sub)
    return status, expires_at, sub


async def reconcile(*, apply: bool, window_days: Optional[int]) -> int:
    sb = require_supabase()
    rows = _fetch_rows(sb, window_days)
    log.info("%d subscription row(s) to check%s", len(rows),
             f" (expiring within {window_days}d)" if window_days else "")

    unaddressable: List[dict] = []
    failures: List[Tuple[dict, Exception]] = []
    changes: List[Tuple[dict, str, Optional[datetime]]] = []
    attempted = 0

    for row in rows:
        store = row.get("store")
        try:
            if store == "app_store":
                status, expires_at, payload = await _check_apple(row)
            elif store == "play_store":
                status, expires_at, payload = await _check_google(row)
            else:
                log.warning("user %s: unknown store %r — skipped", row.get("user_id"), store)
                continue
        except Exception as e:  # store outage, revoked key, deleted product …
            failures.append((row, e))
            log.warning("user %s (%s): store check failed: %s", row.get("user_id"), store, e)
            continue

        if status is None:
            unaddressable.append(row)
            continue
        attempted += 1

        was_pro = subscription_is_pro(row)
        now_pro = subscription_is_pro({"status": status, "expires_at": expires_at})
        old_exp = row.get("expires_at")
        if status == row.get("status") and str(old_exp or "") == str(
                expires_at.isoformat() if expires_at else ""):
            continue

        changes.append((row, status, expires_at))
        log.info("user %s (%s): %s → %s | expires %s → %s%s",
                 row.get("user_id"), store, row.get("status"), status,
                 old_exp, expires_at.isoformat() if expires_at else None,
                 "  [LOSES PRO]" if was_pro and not now_pro else
                 ("  [GAINS PRO]" if now_pro and not was_pro else ""))

        if not apply:
            continue

        kwargs: Dict[str, Any] = dict(
            user_id=row["user_id"], store=store,
            product_id=(payload or {}).get("productId") or row.get("product_id") or "",
            status=status, expires_at=expires_at,
            trial_ends_at=expires_at if status == "trial" else None,
            cancel_reason="reconcile" if status == "expired" else None,
            # keep the existing binding — never move a receipt between users here
            original_transaction_id=row.get("original_transaction_id"),
            purchase_token=row.get("purchase_token"),
            allow_transfer=False,
        )
        try:
            iap_mod._upsert_subscription(sb, **kwargs)
        except Exception as e:
            failures.append((row, e))
            log.error("user %s: write failed: %s", row.get("user_id"), e)

    log.info("---")
    log.info("checked %d, %s %d, unaddressable %d, failed %d",
             attempted, "updated" if apply else "would update", len(changes),
             len(unaddressable), len(failures))
    if unaddressable:
        log.info("unaddressable rows have no store binding yet — they get one the next "
                 "time that user's app calls /iap/verify (app builds from 2026-09 do "
                 "this on launch). Users: %s",
                 ", ".join(str(r.get("user_id")) for r in unaddressable[:20])
                 + (" …" if len(unaddressable) > 20 else ""))
    if not apply and changes:
        log.info("dry run — re-run with --apply to write these.")

    if attempted == 0 and failures:
        return 1
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="write the corrections (default: dry run)")
    ap.add_argument("--window-days", type=int, default=None,
                    help="only rows whose expires_at is within N days (cheap daily pass)")
    args = ap.parse_args()

    s = get_settings()
    if not (s.supabase_url and s.supabase_service_role_key):
        log.error("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY not configured")
        return 2
    return asyncio.run(reconcile(apply=args.apply, window_days=args.window_days))


if __name__ == "__main__":
    raise SystemExit(main())
