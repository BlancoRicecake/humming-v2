#!/usr/bin/env python3
"""
Create HumTrack Pro auto-renewing subscriptions on Google Play Console via
the Android Publisher API v3 (monetization.subscriptions).

Counterpart to ``asc_create_iap.py``. Idempotent — re-runs upsert each
resource by ID. The script will refuse to overwrite an already-active
base plan or offer (Play locks those immutable once active); deactivate
via Play Console first if you need to edit pricing.

Endpoints used (Android Publisher API v3 — 2022 monetization migration):
  - POST   /androidpublisher/v3/applications/{pkg}/subscriptions
  - PATCH  /androidpublisher/v3/applications/{pkg}/subscriptions/{productId}
  - POST   /androidpublisher/v3/applications/{pkg}/subscriptions/{productId}/basePlans
  - POST   /androidpublisher/v3/applications/{pkg}/subscriptions/{productId}/basePlans/{basePlanId}:activate
  - POST   /androidpublisher/v3/applications/{pkg}/subscriptions/{productId}/basePlans/{basePlanId}/offers
  - POST   /androidpublisher/v3/applications/{pkg}/subscriptions/{productId}/basePlans/{basePlanId}/offers/{offerId}:activate

Prereqs (one-time, GUI):
  1. App exists in Play Console with the target package name.
  2. App is uploaded to at least one track (Internal testing is enough) —
     until then Play won't expose the subscription to `queryProductDetails`.
  3. A service account with role "Service Account User" + Play Console
     access ("Manage orders and subscriptions" + "View financial data")
     has been linked under Play Console → Setup → API access.

Env vars (auto-loaded from infra/.env.play if present, else from process env):
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH  service-account JSON key (file)
    OR
  GOOGLE_PLAY_SERVICE_ACCOUNT_JSON       same JSON inlined as a string
  PLAY_PACKAGE_NAME                       defaults to com.humtrack.app
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, Optional

import requests
from google.auth.transport.requests import Request as GAuthRequest
from google.oauth2 import service_account


REPO_ROOT = Path(__file__).resolve().parents[2]
ENV_FILE = REPO_ROOT / "infra" / ".env.play"

API_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3"
SCOPE = "https://www.googleapis.com/auth/androidpublisher"

PACKAGE_NAME_DEFAULT = "com.humtrack.app"


def load_env() -> None:
    if not ENV_FILE.exists():
        return
    for raw in ENV_FILE.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip())


def must_env(name: str) -> str:
    v = os.environ.get(name)
    if not v:
        sys.exit(f"[fatal] env {name} is required")
    return v


def mint_token() -> str:
    json_path = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH")
    json_inline = os.environ.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON")
    if json_path:
        p = Path(json_path)
        if not p.is_absolute():
            p = REPO_ROOT / json_path
        if not p.exists():
            sys.exit(f"[fatal] service account JSON not found at {json_path}")
        info = json.loads(p.read_text())
    elif json_inline:
        info = json.loads(json_inline)
    else:
        sys.exit(
            "[fatal] set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON_PATH "
            "(file) or GOOGLE_PLAY_SERVICE_ACCOUNT_JSON (inline)"
        )
    creds = service_account.Credentials.from_service_account_info(info, scopes=[SCOPE])
    creds.refresh(GAuthRequest())
    return creds.token


class Play:
    def __init__(self, token: str, pkg: str) -> None:
        self.pkg = pkg
        self.s = requests.Session()
        self.s.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            }
        )

    def _log(self, method: str, path: str, resp: requests.Response) -> None:
        ok = resp.status_code < 300
        tag = "OK " if ok else "ERR"
        body = ""
        try:
            body = json.dumps(resp.json(), ensure_ascii=False)[:600]
        except Exception:
            body = resp.text[:600]
        print(f"  [{tag}] {method} {path} -> {resp.status_code}")
        if not ok:
            print(f"        body: {body}")

    def get(self, path: str, **params: Any) -> requests.Response:
        r = self.s.get(API_BASE + path, params=params or None)
        self._log("GET", path, r)
        return r

    def post(self, path: str, payload: Optional[dict] = None, **params: Any) -> requests.Response:
        r = self.s.post(API_BASE + path, params=params or None, data=json.dumps(payload or {}))
        self._log("POST", path, r)
        return r

    def patch(self, path: str, payload: dict, **params: Any) -> requests.Response:
        r = self.s.patch(API_BASE + path, params=params or None, data=json.dumps(payload))
        self._log("PATCH", path, r)
        return r


# ─── product spec ─────────────────────────────────────────────────────────
# Pricing mirrors mobile/lib/services/iap_pricing.dart. KRW + USD only —
# add regions in Play Console GUI after first run (or extend REGIONAL_CONFIGS).
REGIONAL_CONFIGS_MONTHLY = [
    {"regionCode": "KR", "newSubscriberAvailability": True,
     "price": {"currencyCode": "KRW", "units": "5500", "nanos": 0}},
    {"regionCode": "US", "newSubscriberAvailability": True,
     "price": {"currencyCode": "USD", "units": "3", "nanos": 490_000_000}},
]

REGIONAL_CONFIGS_YEARLY = [
    {"regionCode": "KR", "newSubscriberAvailability": True,
     "price": {"currencyCode": "KRW", "units": "55000", "nanos": 0}},
    {"regionCode": "US", "newSubscriberAvailability": True,
     "price": {"currencyCode": "USD", "units": "33", "nanos": 490_000_000}},
]

# Free-trial phase — present in all regions where the base plan has a price.
FREE_TRIAL_REGIONAL_CONFIGS = [
    {"regionCode": "KR", "free": {}},
    {"regionCode": "US", "free": {}},
]


PRODUCTS = [
    {
        "product_id": "humtrack_pro_monthly_v2",
        "base_plan_id": "monthly-auto",
        "billing_period": "P1M",
        "regional_configs": REGIONAL_CONFIGS_MONTHLY,
        "listings": [
            {
                "languageCode": "ko-KR",
                "title": "HumTrack Pro 월간",
                "benefits": ["무제한 내보내기", "5GB 클라우드 동기화", "보컬 영구 보관", "우선 분석 처리"],
                "description": (
                    "허밍을 코드·박자·악기 트랙으로 바꿔주는 HumTrack 의 모든 Pro 기능을 "
                    "매달 이용하세요. 7일 무료 체험 후 자동 결제됩니다."
                ),
            },
            {
                "languageCode": "en-US",
                "title": "HumTrack Pro Monthly",
                "benefits": ["Unlimited export", "5GB cloud sync", "Permanent vocal backup", "Priority analysis"],
                "description": (
                    "Unlock every HumTrack Pro feature monthly — chord/beat/instrument "
                    "tracks from your humming. 7-day free trial, then auto-renews."
                ),
            },
        ],
    },
    {
        "product_id": "humtrack_pro_yearly",
        "base_plan_id": "yearly-auto",
        "billing_period": "P1Y",
        "regional_configs": REGIONAL_CONFIGS_YEARLY,
        "listings": [
            {
                "languageCode": "ko-KR",
                "title": "HumTrack Pro 연간",
                "benefits": ["월 대비 약 20% 할인", "무제한 내보내기", "5GB 클라우드", "우선 분석"],
                "description": (
                    "HumTrack 의 모든 Pro 기능을 1년간 약 20% 할인된 가격으로. "
                    "7일 무료 체험 후 자동 결제됩니다."
                ),
            },
            {
                "languageCode": "en-US",
                "title": "HumTrack Pro Yearly",
                "benefits": ["~20% off monthly", "Unlimited export", "5GB cloud", "Priority analysis"],
                "description": (
                    "Unlock every HumTrack Pro feature for a year at ~20% off. "
                    "7-day free trial, then auto-renews."
                ),
            },
        ],
    },
]


def _base_plan_payload(p: dict) -> dict:
    return {
        "basePlanId": p["base_plan_id"],
        "state": "DRAFT",
        "autoRenewingBasePlanType": {
            "billingPeriodDuration": p["billing_period"],
            "resubscribeState": "RESUBSCRIBE_STATE_ACTIVE",
            "prorationMode": "SUBSCRIPTION_PRORATION_MODE_CHARGE_ON_NEXT_BILLING_DATE",
            "legacyCompatible": True,
        },
        "regionalConfigs": p["regional_configs"],
    }


def upsert_subscription(play: Play, p: dict, listings: list[dict]) -> bool:
    """Idempotent PATCH — creates on first call, overwrites listings on subsequent.

    `regionsVersion` is REQUIRED on the Subscription resource (added 2022/01 with
    the monetization API). It pins the set of regions Play recognizes when
    interpreting regionalConfigs. The constant "2022/01" is the only accepted
    value today.
    """
    product_id = p["product_id"]
    base = {
        "packageName": play.pkg,
        "productId": product_id,
        "listings": listings,
        # Required since 2024 for EEA — declares right-of-withdrawal terms.
        "taxAndComplianceSettings": {
            "eeaWithdrawalRightType": "WITHDRAWAL_RIGHT_DIGITAL_CONTENT",
            "isTokenizedDigitalAsset": False,
        },
    }
    # `regionsVersion.version` is REQUIRED as a *query* param on POST/PATCH —
    # not body — per https://developers.google.com/android-publisher/api-ref/rest/v3/monetization.subscriptions
    # On POST (create), `productId` is also a required query param.
    extra_patch = {"regionsVersion.version": "2022/01"}
    extra_post = {"regionsVersion.version": "2022/01", "productId": product_id}
    # Try PATCH first (upsert semantics — only listings + tax). Existing
    # subscriptions keep their base plans untouched.
    r = play.patch(
        f"/applications/{play.pkg}/subscriptions/{product_id}",
        base,
        updateMask="listings,taxAndComplianceSettings",
        **extra_patch,
    )
    if r.status_code == 200:
        return True
    if r.status_code == 404:
        # Create — Play requires at least one base plan inline on initial POST.
        create_body = dict(base)
        create_body["basePlans"] = [_base_plan_payload(p)]
        r = play.post(f"/applications/{play.pkg}/subscriptions", create_body, **extra_post)
        return r.status_code in (200, 201)
    return False


def get_base_plan(play: Play, product_id: str, base_plan_id: str) -> Optional[dict]:
    r = play.get(f"/applications/{play.pkg}/subscriptions/{product_id}")
    if r.status_code != 200:
        return None
    for bp in r.json().get("basePlans", []):
        if bp.get("basePlanId") == base_plan_id:
            return bp
    return None


def get_base_plan_state(play: Play, product_id: str, base_plan_id: str) -> Optional[str]:
    bp = get_base_plan(play, product_id, base_plan_id)
    return bp.get("state") if bp else None  # DRAFT / ACTIVE / INACTIVE


def base_plan_has_new_subscriber_avail(bp: dict) -> bool:
    for rc in bp.get("regionalConfigs", []):
        if rc.get("newSubscriberAvailability"):
            return True
    return False


def deactivate_base_plan(play: Play, product_id: str, base_plan_id: str) -> bool:
    r = play.post(
        f"/applications/{play.pkg}/subscriptions/{product_id}/basePlans/{base_plan_id}:deactivate",
        {},
    )
    return r.status_code in (200, 204)


def delete_base_plan(play: Play, product_id: str, base_plan_id: str) -> bool:
    r = play.s.delete(
        f"{API_BASE}/applications/{play.pkg}/subscriptions/{product_id}/basePlans/{base_plan_id}"
    )
    play._log("DELETE", f"/applications/{play.pkg}/subscriptions/{product_id}/basePlans/{base_plan_id}", r)
    return r.status_code in (200, 204)


def create_base_plan(play: Play, p: dict) -> bool:
    """Add a base plan to an existing subscription via subscription PATCH —
    Play has no standalone basePlans.create endpoint. We PATCH the parent
    subscription with `updateMask=basePlans` and the new basePlans list.
    """
    pid = p["product_id"]
    # Fetch current basePlans and append (or replace by id) the new one.
    cur = play.get(f"/applications/{play.pkg}/subscriptions/{pid}")
    plans = cur.json().get("basePlans", []) if cur.status_code == 200 else []
    plans = [bp for bp in plans if bp.get("basePlanId") != p["base_plan_id"]]
    plans.append(_base_plan_payload(p))
    body = {
        "packageName": play.pkg,
        "productId": pid,
        "basePlans": plans,
    }
    r = play.patch(
        f"/applications/{play.pkg}/subscriptions/{pid}",
        body,
        updateMask="basePlans",
        **{"regionsVersion.version": "2022/01"},
    )
    return r.status_code == 200


def replace_base_plan(play: Play, p: dict) -> bool:
    """Deactivate + delete + recreate via subscription PATCH. Use to update
    regional configs on an already-active base plan (Play locks pricing of
    active plans).
    """
    pid, bid = p["product_id"], p["base_plan_id"]
    deactivate_base_plan(play, pid, bid)
    delete_base_plan(play, pid, bid)
    if not create_base_plan(play, p):
        return False
    return activate_base_plan(play, pid, bid)


def activate_base_plan(play: Play, product_id: str, base_plan_id: str) -> bool:
    r = play.post(
        f"/applications/{play.pkg}/subscriptions/{product_id}/basePlans/{base_plan_id}:activate",
        {},
    )
    return r.status_code in (200, 204)


def create_free_trial_offer(play: Play, product_id: str, base_plan_id: str) -> bool:
    # offer-level regionalConfigs (availability) + phase-level (free/price).
    # Both must list the same regions, otherwise Play rejects with
    # "Subscription offers must target at least one country / region."
    offer_regional = [
        {"regionCode": "KR", "newSubscriberAvailability": True},
        {"regionCode": "US", "newSubscriberAvailability": True},
    ]
    body = {
        "packageName": play.pkg,
        "productId": product_id,
        "basePlanId": base_plan_id,
        "offerId": "freetrial",
        "state": "DRAFT",
        "regionalConfigs": offer_regional,
        "phases": [
            {
                "duration": "P7D",
                "recurrenceCount": 1,
                "regionalConfigs": FREE_TRIAL_REGIONAL_CONFIGS,
            }
        ],
        "offerTags": [{"tag": "freetrial7d"}],
        # 자격 기준 = "신규 고객 확보" — 이 앱의 어떤 구독도 한 번도 결제한 적 없는 사용자만 trial.
        # targeting 을 비우면 Play 가 "Developer determined" (앱 자체 검증) 으로 떨어뜨려
        # 같은 유저가 반복 redeem 가능해지므로 명시적으로 acquisitionRule 부여.
        "targeting": {
            "acquisitionRule": {
                "scope": {"anySubscriptionInApp": {}},
            },
        },
    }
    # offerId + regionsVersion.version required as query params on create.
    r = play.post(
        f"/applications/{play.pkg}/subscriptions/{product_id}/basePlans/{base_plan_id}/offers",
        body,
        **{"offerId": "freetrial", "regionsVersion.version": "2022/01"},
    )
    return r.status_code in (200, 201)


def activate_offer(play: Play, product_id: str, base_plan_id: str, offer_id: str) -> bool:
    r = play.post(
        f"/applications/{play.pkg}/subscriptions/{product_id}/basePlans/{base_plan_id}/offers/{offer_id}:activate",
        {},
    )
    return r.status_code in (200, 204)


def main() -> int:
    load_env()
    pkg = os.environ.get("PLAY_PACKAGE_NAME", PACKAGE_NAME_DEFAULT)
    print(f"[1/4] Mint OAuth2 token (scope=androidpublisher)")
    token = mint_token()
    play = Play(token, pkg)

    for idx, p in enumerate(PRODUCTS, start=1):
        print(f"\n[2/4.{idx}] Upsert subscription {p['product_id']}")
        if not upsert_subscription(play, p, p["listings"]):
            print("  -> Could not upsert subscription, skipping.")
            continue

        bp = get_base_plan(play, p["product_id"], p["base_plan_id"])
        state = bp.get("state") if bp else None
        print(f"[3/4.{idx}] Base plan {p['base_plan_id']} state={state or 'MISSING'}")
        if bp is None:
            if not create_base_plan(play, p):
                print("  -> Base plan create failed, skipping activate + offer.")
                continue
            activate_base_plan(play, p["product_id"], p["base_plan_id"])
        elif not base_plan_has_new_subscriber_avail(bp):
            # 모든 region 이 newSubscriberAvailability=false 면 신규 구매 불가
            # 상태이므로 재생성 — 가격 변경 없음.
            print("  -> Base plan has no new-subscriber availability; recreating.")
            if not replace_base_plan(play, p):
                print("  -> Replace failed, skipping offer.")
                continue
        elif state == "DRAFT":
            activate_base_plan(play, p["product_id"], p["base_plan_id"])
        else:
            print("  -> Base plan ACTIVE with new-subscriber availability; leaving as-is.")

        print(f"[4/4.{idx}] 7-day free trial offer")
        # Offer create returns ALREADY_EXISTS-ish error if 'freetrial' is there.
        # Activate is idempotent.
        create_free_trial_offer(play, p["product_id"], p["base_plan_id"])
        activate_offer(play, p["product_id"], p["base_plan_id"], "freetrial")

    print("\nDone. Confirm under Play Console → Monetize → Subscriptions.")
    print("Reminder: products are queryable only once the app is on Internal testing or higher.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
