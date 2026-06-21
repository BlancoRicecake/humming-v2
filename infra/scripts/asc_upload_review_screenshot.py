#!/usr/bin/env python3
"""
Upload an App Review screenshot to each HumTrack Pro auto-renewable
subscription via the App Store Connect API.

Why: a subscription stays in "Missing Metadata" (and is therefore not
selectable on the app version's In-App Purchases section) until it has a
review screenshot. Apple's rejection (Guideline 2.1b) called this out.

Flow per subscription (ASC API):
  1. Resolve subscription id by productId.
  2. Delete any existing review screenshot (idempotent re-run / refresh).
  3. POST /v1/subscriptionAppStoreReviewScreenshots  (reserve, get upload ops)
  4. PUT the bytes to each uploadOperation URL (no auth header; pre-signed).
  5. PATCH .../{id}  uploaded=true + sourceFileChecksum (md5).
  6. Poll the asset state until it leaves UPLOAD_COMPLETE/AWAITING.

Reuses JWT auth + ASC helper from asc_create_iap.py.
"""
from __future__ import annotations

import hashlib
import sys
import tempfile
import time
from pathlib import Path

import requests
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc_create_iap import (  # noqa: E402
    ASC,
    API_BASE,
    find_app,
    find_subscription_anywhere,
    load_env,
    make_jwt,
)

# product_id -> source screenshot (the matching plan's paywall capture)
UPLOADS = {
    "humtrack_pro_monthly_v2": "/Users/heojeongmin/.claude/image-cache/de8d837f-c368-4434-b23e-30aa64a72c13/6.png",
    "humtrack_pro_yearly": "/Users/heojeongmin/.claude/image-cache/de8d837f-c368-4434-b23e-30aa64a72c13/5.png",
}
BUNDLE_ID = "com.humtrack.app"
SCREENSHOT_TYPE = "subscriptionAppStoreReviewScreenshots"


# Apple only accepts standard App Store screenshot dimensions for the IAP
# review screenshot. 2208x1242 = iPhone 5.5" landscape (an accepted size).
TARGET = (2208, 1242)
BG = (10, 10, 15)  # #0A0A0F — the paywall background


def flatten_to_rgb_png(src: str) -> tuple[bytes, str]:
    """Strip alpha, then fit (contain) the capture onto an accepted-size dark
    canvas so Apple's dimension check passes. Returns (bytes, filename)."""
    img = Image.open(src).convert("RGBA")
    bg = Image.new("RGBA", img.size, (*BG, 255))
    flat = Image.alpha_composite(bg, img).convert("RGB")
    scale = min(TARGET[0] / flat.width, TARGET[1] / flat.height)
    new_size = (round(flat.width * scale), round(flat.height * scale))
    resized = flat.resize(new_size, Image.LANCZOS)
    canvas = Image.new("RGB", TARGET, BG)
    offset = ((TARGET[0] - new_size[0]) // 2, (TARGET[1] - new_size[1]) // 2)
    canvas.paste(resized, offset)
    tmp = Path(tempfile.gettempdir()) / (Path(src).stem + "_review.png")
    canvas.save(tmp, format="PNG")
    return tmp.read_bytes(), tmp.name


def existing_screenshot_id(asc: ASC, sub_id: str) -> str | None:
    r = asc.s.get(f"{API_BASE}/v1/subscriptions/{sub_id}/appStoreReviewScreenshot")
    if r.status_code != 200:
        return None
    data = r.json().get("data")
    return data["id"] if data else None


def delete_screenshot(asc: ASC, shot_id: str) -> None:
    r = asc.s.delete(f"{API_BASE}/v1/{SCREENSHOT_TYPE}/{shot_id}")
    print(f"  [del] existing screenshot {shot_id} -> {r.status_code}")


def reserve(asc: ASC, sub_id: str, file_name: str, file_size: int) -> dict:
    payload = {
        "data": {
            "type": SCREENSHOT_TYPE,
            "attributes": {"fileName": file_name, "fileSize": file_size},
            "relationships": {
                "subscription": {"data": {"type": "subscriptions", "id": sub_id}}
            },
        }
    }
    r = asc.post(f"/v1/{SCREENSHOT_TYPE}", payload)
    if r.status_code not in (200, 201):
        raise SystemExit(f"  reserve failed: {r.status_code} {r.text[:400]}")
    return r.json()["data"]


def put_bytes(ops: list[dict], data: bytes) -> None:
    for op in ops:
        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
        chunk = data[op["offset"]: op["offset"] + op["length"]]
        r = requests.request(op["method"], op["url"], data=chunk, headers=headers)
        if r.status_code not in (200, 201, 204):
            raise SystemExit(f"  upload PUT failed: {r.status_code} {r.text[:300]}")
        print(f"  [put] {op['length']} bytes -> {r.status_code}")


def commit(asc: ASC, shot_id: str, md5_hex: str) -> requests.Response:
    payload = {
        "data": {
            "type": SCREENSHOT_TYPE,
            "id": shot_id,
            "attributes": {"uploaded": True, "sourceFileChecksum": md5_hex},
        }
    }
    r = asc.s.patch(
        f"{API_BASE}/v1/{SCREENSHOT_TYPE}/{shot_id}", data=__import__("json").dumps(payload)
    )
    print(f"  [commit] PATCH -> {r.status_code}")
    if r.status_code >= 300:
        print(f"        body: {r.text[:400]}")
    return r


def poll_state(asc: ASC, shot_id: str) -> None:
    for _ in range(10):
        r = asc.s.get(f"{API_BASE}/v1/{SCREENSHOT_TYPE}/{shot_id}")
        if r.status_code != 200:
            return
        attrs = r.json()["data"]["attributes"]
        state = (attrs.get("assetDeliveryState") or {}).get("state")
        print(f"  [state] {state}")
        if state in ("COMPLETE", "FAILED"):
            errs = (attrs.get("assetDeliveryState") or {}).get("errors")
            if errs:
                print(f"        errors: {errs}")
            return
        time.sleep(3)


def main() -> int:
    load_env()
    print(f"[1] Mint JWT + look up app {BUNDLE_ID}")
    asc = ASC(make_jwt())
    app_id = find_app(asc, BUNDLE_ID)
    if not app_id:
        sys.exit("  app not found")
    print(f"  app_id={app_id}")

    for product_id, src in UPLOADS.items():
        print(f"\n[ {product_id} ]  <- {Path(src).name}")
        sub_id = find_subscription_anywhere(asc, app_id, product_id)
        if not sub_id:
            print("  !! subscription not found, skipping")
            continue
        print(f"  subscription_id={sub_id}")

        old = existing_screenshot_id(asc, sub_id)
        if old:
            delete_screenshot(asc, old)

        data, fname = flatten_to_rgb_png(src)
        md5_hex = hashlib.md5(data).hexdigest()
        print(f"  flattened {fname}: {len(data)} bytes, md5={md5_hex[:12]}…")

        reserved = reserve(asc, sub_id, fname, len(data))
        put_bytes(reserved["attributes"]["uploadOperations"], data)
        commit(asc, reserved["id"], md5_hex)
        poll_state(asc, reserved["id"])

    print("\nDone. Check each subscription — status should leave 'Missing Metadata'.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
