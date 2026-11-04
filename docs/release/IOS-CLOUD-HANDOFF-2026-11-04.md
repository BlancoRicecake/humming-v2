# iOS cloud backup: Mac handoff (2026-11-04)

For the person building iOS on the Mac. Android is built from this PC and Codex's CI. iOS builds, signing and TestFlight happen only on the Mac.

## What changed for every release build

`HUMTRACK_CLOUD_BACKUP` is now **required** by `mobile/tool/release_support.rb`. Leaving it unset (or empty) stops the build with:

> Set HUMTRACK_CLOUD_BACKUP=true (verified cloud server) or false: a release decides cloud backup explicitly

The Mac can no longer ship cloud OFF without meaning to. `fastlane ios …` (and `fastlane mac build`) print `Cloud backup: ON (verified server)` or `Cloud backup: OFF` before building. Check that line.

## Cloud ON build: the same gate as Android

`HUMTRACK_CLOUD_BACKUP=true` builds only when all three checks agree at build time:

1. `HUMTRACK_CLOUD_SERVICE_VERIFIED` equals the host of `ENGINE_URL` (production: the `humming-api` host). It is the operator's statement that the live customer checks passed for that server.
2. `HUMTRACK_CLOUD_PROVIDER_RECEIPT` is the path to the receipt JSON written by `python -m app.cloud_provider_check --apply`. The receipt must:
   - have `kind: humtrack-cloud-provider-receipt`, `passed: true` and `cleanup_confirmed: true`;
   - name the same `api_host`;
   - have a `checked_at` at most **14 days** old;
   - have a non-empty `server_version`.
3. `GET {ENGINE_URL}/health/cloud` (it needs network) answers `ready: true` and `contract: 1`, with `version` equal to the receipt's `server_version`. After any backend redeploy, the receipt has to be redone for the new version.

The receipt and the attestation steer the gate only; neither is compiled into the app. Keep the receipt file outside Git and delete it after the build.

Example (Mac shell, values from Codex, never committed):

```sh
export HUMTRACK_CLOUD_BACKUP=true
export HUMTRACK_CLOUD_SERVICE_VERIFIED=<api host>
export HUMTRACK_CLOUD_PROVIDER_RECEIPT="$HOME/humtrack-private/cloud-provider-receipt.json"
cd mobile/ios && bundle exec fastlane <lane>
```

Instead of the local Mac build, the `release-mobile.yml` workflow can be used with the `cloud_backup` input. It reads `vars.HUMTRACK_CLOUD_SERVICE_VERIFIED` and `secrets.HUMTRACK_CLOUD_PROVIDER_RECEIPT_JSON`, and Codex replaces both after each verified server version.

## Before an iOS cloud-ON build goes to testers

- **Same commit** as the Android cloud-ON build. Use the develop SHA Codex records after the push.
- **App Store Connect privacy label:** cloud backup stores the songs a user chooses to back up in their account (song data, and recordings only when ticked). Update "User Content" (audio data / other user content, linked to the user, not used for tracking) before the cloud-ON build is submitted. This is an owner decision on wording; the facts are in `artifacts/cloud-service-2026-11-04/OPS-REQUIREMENTS.md`.
- **Release notes:** describe it as **manual** cloud backup / restore / management, never "automatic sync". The Android 47 notes (`mobile/android/fastlane/metadata/android/*/changelogs/47.txt`) can be adapted.
- **Real purchase check:** the live service probe used QA accounts with a synthetic Pro entitlement. A real StoreKit purchase followed by a backup on a device is still a user check on the Mac/iPhone.
- **Cloud OFF iOS build:** set `HUMTRACK_CLOUD_BACKUP=false` explicitly. Nothing else is needed and nothing contacts the server.
