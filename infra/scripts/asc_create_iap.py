#!/usr/bin/env python3
"""
Create HumTrack Pro auto-renewable subscriptions on App Store Connect
via the ASC API.

Steps:
  1. Mint an ES256 JWT for the ASC API.
  2. Look up the app by bundle ID.
  3. Create (or reuse) the `HumTrack Pro` subscription group.
  4. Create monthly + yearly subscription products.
  5. Add ko + en-US localizations to each product.
  6. Attach an introductory offer (7-day free trial) to each product.
  7. Set base territory price (USD 4.99 / 29.99 — Apple auto-converts to KRW).

Apple endpoints used (current as of ASC API v3):
  - GET    /v1/apps?filter[bundleId]=...
  - GET    /v1/apps/{id}/subscriptionGroups
  - POST   /v1/subscriptionGroups
  - POST   /v1/subscriptionGroupLocalizations
  - POST   /v1/subscriptions
  - POST   /v1/subscriptionLocalizations
  - POST   /v1/subscriptionIntroductoryOffers
  - POST   /v1/subscriptionPrices  (requires a price point ID)
  - GET    /v1/subscriptions/{id}/pricePoints

Many of these endpoints reject `POST` until the app has at least one
submitted build in App Store Connect, or until the app's "Paid Apps
Agreement" is signed. The script logs each step so the caller can see
exactly where it stops.

Env vars (loaded from mobile/ios/fastlane/.env.default if present):
  ASC_KEY_ID
  ASC_ISSUER_ID
  ASC_KEY_FILEPATH   (relative to repo root or absolute)
  BUNDLE_ID
  SUBSCRIPTION_GROUP_REF
  SUBSCRIPTION_GROUP_NAME
"""
from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import jwt  # PyJWT
import requests


REPO_ROOT = Path(__file__).resolve().parents[2]
ENV_FILE = REPO_ROOT / "mobile" / "ios" / "fastlane" / ".env.default"

API_BASE = "https://api.appstoreconnect.apple.com"


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


def make_jwt() -> str:
    key_id = must_env("ASC_KEY_ID")
    issuer = must_env("ASC_ISSUER_ID")
    key_path_raw = must_env("ASC_KEY_FILEPATH")
    key_path = Path(key_path_raw)
    if not key_path.is_absolute():
        # Try relative to repo root, then relative to mobile/ios/
        candidates = [
            REPO_ROOT / key_path_raw,
            REPO_ROOT / "mobile" / "ios" / key_path_raw,
        ]
        for c in candidates:
            if c.exists():
                key_path = c
                break
    if not key_path.exists():
        sys.exit(f"[fatal] ASC key not found at {key_path_raw}")
    private_key = key_path.read_text()
    now = int(time.time())
    payload = {
        "iss": issuer,
        "iat": now,
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    token = jwt.encode(
        payload,
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )
    return token if isinstance(token, str) else token.decode()


class ASC:
    def __init__(self, token: str) -> None:
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
        r = self.s.get(API_BASE + path, params=params)
        self._log("GET", path, r)
        return r

    def post(self, path: str, payload: dict) -> requests.Response:
        r = self.s.post(API_BASE + path, data=json.dumps(payload))
        self._log("POST", path, r)
        return r


def find_app(asc: ASC, bundle_id: str) -> str | None:
    r = asc.get("/v1/apps", **{"filter[bundleId]": bundle_id})
    if r.status_code != 200:
        return None
    data = r.json().get("data", [])
    if not data:
        return None
    return data[0]["id"]


def find_group(asc: ASC, app_id: str, ref: str, *aliases: str) -> str | None:
    r = asc.get(f"/v1/apps/{app_id}/subscriptionGroups", limit=200)
    if r.status_code != 200:
        return None
    accepted = {ref, *aliases}
    for grp in r.json().get("data", []):
        if grp["attributes"].get("referenceName") in accepted:
            return grp["id"]
    return None


def create_group(asc: ASC, app_id: str, ref: str) -> str | None:
    payload = {
        "data": {
            "type": "subscriptionGroups",
            "attributes": {"referenceName": ref},
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}}
            },
        }
    }
    r = asc.post("/v1/subscriptionGroups", payload)
    if r.status_code in (200, 201):
        return r.json()["data"]["id"]
    return None


def add_group_localization(asc: ASC, group_id: str, locale: str, name: str) -> None:
    payload = {
        "data": {
            "type": "subscriptionGroupLocalizations",
            "attributes": {"locale": locale, "name": name, "customAppName": None},
            "relationships": {
                "subscriptionGroup": {
                    "data": {"type": "subscriptionGroups", "id": group_id}
                }
            },
        }
    }
    asc.post("/v1/subscriptionGroupLocalizations", payload)


def find_subscription(asc: ASC, group_id: str, product_id: str) -> str | None:
    r = asc.get(
        f"/v1/subscriptionGroups/{group_id}/subscriptions",
        limit=200,
    )
    if r.status_code != 200:
        return None
    for sub in r.json().get("data", []):
        if sub["attributes"].get("productId") == product_id:
            return sub["id"]
    return None


def find_subscription_anywhere(asc: ASC, app_id: str, product_id: str) -> str | None:
    """Look across every subscription group on the app."""
    r = asc.get(f"/v1/apps/{app_id}/subscriptionGroups", limit=200)
    if r.status_code != 200:
        return None
    for grp in r.json().get("data", []):
        found = find_subscription(asc, grp["id"], product_id)
        if found:
            return found
    return None


def create_subscription(
    asc: ASC,
    group_id: str,
    product_id: str,
    name: str,
    duration: str,
    family_sharable: bool = False,
) -> str | None:
    payload = {
        "data": {
            "type": "subscriptions",
            "attributes": {
                "name": name,
                "productId": product_id,
                "familySharable": family_sharable,
                "subscriptionPeriod": duration,
                "reviewNote": "HumTrack Pro auto-renewable subscription.",
            },
            "relationships": {
                "group": {
                    "data": {"type": "subscriptionGroups", "id": group_id}
                }
            },
        }
    }
    r = asc.post("/v1/subscriptions", payload)
    if r.status_code in (200, 201):
        return r.json()["data"]["id"]
    return None


def add_subscription_localization(
    asc: ASC, sub_id: str, locale: str, name: str, description: str
) -> None:
    payload = {
        "data": {
            "type": "subscriptionLocalizations",
            "attributes": {
                "locale": locale,
                "name": name,
                "description": description,
            },
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}}
            },
        }
    }
    asc.post("/v1/subscriptionLocalizations", payload)


def pick_price_point(asc: ASC, sub_id: str, target_usd: float) -> str | None:
    """Find a USA price point closest to target USD (USA territory id = 'USA').

    Paginates through every price point — there are ~800 per territory.
    """
    url = f"/v1/subscriptions/{sub_id}/pricePoints"
    params: dict[str, Any] = {"filter[territory]": "USA", "limit": 200}
    best_id: str | None = None
    best_diff = 1e9
    while True:
        r = asc.s.get(API_BASE + url, params=params)
        if r.status_code != 200:
            return None
        j = r.json()
        for pp in j.get("data", []):
            try:
                cust = float(pp["attributes"].get("customerPrice", "0"))
            except (TypeError, ValueError):
                continue
            diff = abs(cust - target_usd)
            if diff < best_diff:
                best_diff = diff
                best_id = pp["id"]
        nxt = j.get("links", {}).get("next")
        if not nxt:
            break
        url = nxt.replace(API_BASE, "")
        params = {}
    return best_id


def add_intro_offer(asc: ASC, sub_id: str, territory: str = "USA") -> None:
    # Apple's enum for 7-day trial is "ONE_WEEK".
    # `territory` is a required *relationship*. The offer is per-territory,
    # so callers may want to iterate over multiple territories.
    payload = {
        "data": {
            "type": "subscriptionIntroductoryOffers",
            "attributes": {
                "duration": "ONE_WEEK",
                "offerMode": "FREE_TRIAL",
                "numberOfPeriods": 1,
            },
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}},
                "territory": {"data": {"type": "territories", "id": territory}},
            },
        }
    }
    asc.post("/v1/subscriptionIntroductoryOffers", payload)


def set_base_price(asc: ASC, sub_id: str, price_point_id: str) -> None:
    payload = {
        "data": {
            "type": "subscriptionPrices",
            "attributes": {"startDate": None, "preserveCurrentPrice": False},
            "relationships": {
                "subscription": {
                    "data": {"type": "subscriptions", "id": sub_id}
                },
                "subscriptionPricePoint": {
                    "data": {
                        "type": "subscriptionPricePoints",
                        "id": price_point_id,
                    }
                },
            },
        }
    }
    asc.post("/v1/subscriptionPrices", payload)


PRODUCTS = [
    {
        "product_id": "humtrack_pro_monthly",
        "name": "HumTrack Pro Monthly",
        "duration": "ONE_MONTH",
        "usd": 4.99,
        "loc": {
            "ko": ("HumTrack Pro 월간", "HumTrack의 모든 Pro 기능을 매달 이용하세요."),
            "en-US": (
                "HumTrack Pro Monthly",
                "Unlock every HumTrack Pro feature, billed monthly.",
            ),
        },
    },
    {
        "product_id": "humtrack_pro_yearly",
        "name": "HumTrack Pro Yearly",
        "duration": "ONE_YEAR",
        "usd": 29.99,
        "loc": {
            "ko": ("HumTrack Pro 연간", "HumTrack의 모든 Pro 기능을 1년간 이용하세요."),
            "en-US": (
                "HumTrack Pro Yearly",
                "Unlock every HumTrack Pro feature, billed yearly.",
            ),
        },
    },
]


def main() -> int:
    load_env()
    bundle_id = os.environ.get("BUNDLE_ID", "com.humtrack.app")
    group_ref = os.environ.get("SUBSCRIPTION_GROUP_REF", "humtrack_pro_group")
    group_name = os.environ.get("SUBSCRIPTION_GROUP_NAME", "HumTrack Pro")

    print(f"[1/7] Mint JWT for issuer {os.environ.get('ASC_ISSUER_ID')}")
    token = make_jwt()
    asc = ASC(token)

    print(f"[2/7] Look up app for bundle id {bundle_id}")
    app_id = find_app(asc, bundle_id)
    if not app_id:
        print(
            "  -> App record not found in App Store Connect. Create the app "
            "in ASC GUI first (My Apps > +), then re-run this script."
        )
        return 1
    print(f"  app_id={app_id}")

    print(f"[3/7] Ensure subscription group '{group_ref}' exists")
    group_id = find_group(asc, app_id, group_ref, group_name)
    if not group_id:
        group_id = create_group(asc, app_id, group_ref)
    if not group_id:
        print("  -> Could not create or find subscription group.")
        return 1
    print(f"  group_id={group_id}")
    add_group_localization(asc, group_id, "ko", group_name)
    add_group_localization(asc, group_id, "en-US", group_name)

    for idx, p in enumerate(PRODUCTS, start=1):
        print(f"[4/7.{idx}] Subscription product {p['product_id']}")
        sub_id = find_subscription_anywhere(asc, app_id, p["product_id"])
        if not sub_id:
            sub_id = create_subscription(
                asc,
                group_id,
                p["product_id"],
                p["name"],
                p["duration"],
            )
        if not sub_id:
            print("  -> Could not create subscription, skipping.")
            continue
        print(f"  subscription_id={sub_id}")

        print(f"[5/7.{idx}] Localizations")
        for locale, (name, desc) in p["loc"].items():
            add_subscription_localization(asc, sub_id, locale, name, desc)

        print(f"[6/7.{idx}] Base price (~USD {p['usd']:.2f})")
        pp_id = pick_price_point(asc, sub_id, p["usd"])
        if pp_id:
            print(f"  resolved USA price point: {pp_id}")
            set_base_price(asc, sub_id, pp_id)
            # Initial price + availability cannot be set via ASC API today —
            # see https://developer.apple.com/forums/thread/720698. Apple
            # returns ENTITY_ERROR.RELATIONSHIP.INVALID until the first
            # price is set in the ASC GUI ("Subscription Pricing" tab).
        else:
            print("  -> Could not resolve price point; set manually in ASC GUI.")

        print(f"[7/7.{idx}] 7-day free trial intro offer (USA)")
        # Intro offer requires `availabilities` (base price) to exist first.
        # Will return STATE_ERROR until pricing is bootstrapped via GUI.
        add_intro_offer(asc, sub_id, territory="USA")

    print("Done. Review subscription state in App Store Connect.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
