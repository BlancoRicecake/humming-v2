# Android internal-test build 40 — 2026-10-02

Status: **signed release files verified and ready for a later authorized upload**.
This work prepared files, release notes, release name and an installation-email
draft. No Play upload, production release, purchase, email delivery or new
infrastructure was performed. The branch was not pushed.

## Version and source

- Play Console read-only verification: highest uploaded versionCode **39** in
  All App Bundles (18 total bundles, newest first). Production **1.0.10 (39)** is
  available on Google Play at 100% rollout. Internal testers also have build 39.
  There are no unpublished changes. The chosen build 40 is unused at this check.
- New version: **1.0.11 (40)**, package `com.humtrack.app`, minSdk 24, targetSdk 36.
- Branch: `codex/humtrack-first-song-funnel`.
- Feature commit: `11f1419cb5a86ac1a61fbd683526a47d497a548e`.
- Release binary source/version commit: `4c03a78108c95bce1c3c767c025fbbcd840fbc13`.
  Later documentation/changelog commits do not alter the binary source.
- Entrypoint: **lib/main.dart**. No QA dart-defines; isolated QA entrypoint is
  absent from the release. Original commits/worktrees remain intact.

## Verified files

Ready folder: `C:/src/humming-v2/mobile/build/internal-test-1.0.11-40/`.

| File | Bytes | SHA-256 |
|---|---:|---|
| `HumTrack-1.0.11-40.aab` | 127866289 | `be992a5df6a61ba7c5e9bb031453ac28f3bec952c56f3a8e00788fed32d14b88` |
| `HumTrack-1.0.11-40.apk` | 134378600 | `c6d608060eae605bfe41c9dfa7178262ce860ca95288522986ff634cb8e959f4` |

The AAB is the store upload file. The universal APK was generated **from this
same AAB** using Google's bundletool 1.18.1 and signed with the existing upload
key, then installed on the dedicated emulator. It is a local QA file; it does
not carry Google's Play app-signing certificate. Use the Play opt-in link for
existing user installations rather than uninstalling an existing Play app to
install this APK. Songs can be stored locally.

Both certificates match the verified, successfully uploaded build 39:
`15:01:22:4A:30:01:EE:87:2F:86:A1:A9:A6:3F:A7:A8:9C:A0:71:C1:8A:F8:B5:F2:56:6C:50:D3:3D:D8:36:94` (SHA-256).

## Release configuration and validation

- Reused the complete production settings from the existing local transfer
  material. Required auth, engine, Clarity and Sentry fields were nonblank.
  No credential values were printed or committed.
- All three compiled architectures contain the matching production Supabase
  hostname/anon JWT, Google web client, engine URL, Clarity project and Sentry
  DSN. The JWT belongs to the expected production project and anon role.
- Firebase project/app/API values match the existing official Android native
  configuration (`humtrack-hq`, `com.humtrack.app`). APP_ENVIRONMENT is production;
  FIREBASE_ANALYTICS_ENABLED is false. Native collection, advertising-ID
  collection and ad-personalization defaults remain false; AD_ID permission is
  absent. Existing disclosure/release gates were not enabled or bypassed.
- Production engine health: HTTP 200, env production, version 01fc868, ok true.
  Supabase public JWKS: HTTP 200, one key. This is endpoint health, not a claim
  of completed user sign-in or humming conversion.
- **10 real Gradle authentication guard tests passed**. The actual release
  compilation also executed the existing guard. Missing/invalid authentication
  inputs were never bypassed.
- Release appbundle build passed. Google bundletool validation, JAR signature
  verification, APK apksigner verification and package/version checks passed.
- All **54 64-bit native libraries** have ELF LOAD alignment of at least 16KB.
  APK zipalign 16KB check passed.
- Dedicated Android 35 AVD `humtrack_release40_20261002`, serial emulator-5560:
  installed version 1.0.11 (40), MainActivity resumed, first-song card → guidance
  directly without sign-in/mode chooser → back to library. No fatal Flutter,
  AndroidRuntime or missing-plugin/channel errors were found for that process.
  Other projects' emulator processes/data were not manipulated.
- The 197 passing app tests and prior analyzer/guest save-reload/backing/restore
  UI checks at feature commit 11f1419 are retained evidence. This task changed
  only version/release metadata, so that full suite was not rerun. It is not
  represented as a new 197-test execution against this release binary.
- Temporary private defines/password files and the worktree signing-property
  copy were removed after packaging. Existing source credentials/keystore were
  preserved. The ready folder contains no build credentials.

## Upload and tester handoff prepared

- Release name: `1.0.11 (40) — First-song creation and restore`.
- Korean/English changelog files are committed under
  `mobile/android/fastlane/metadata/android/{ko-KR,en-US}/changelogs/40.txt`.
- `play-release-notes.txt` has the Play Console locale-tag format for pasting.
- `release-name.txt`, `SHA256SUMS.txt`, `verification.json` and
  `installation-email-draft.txt` are in the ready folder.
- Existing opt-in link:
  https://play.google.com/apps/internaltest/4701278899500552203
  It currently provides build 39, not the new build 40. Send the prepared email
  only after Play confirms build 40 is available to internal testers.
- For the later authorized upload, use the verified AAB above, internal track,
  prepared release name/notes, and recheck the highest code if intervening work
  has uploaded another HumTrack build. No production rollout is part of this
  preparation.

## Evidence and remaining device checks

`verification.json` contains per-architecture config checks, library alignment,
version/signature/hash receipts and runtime flags. Logs in the build worktree's
`mobile/build/internal40/`: `auth-guard.log`, `aab-build.log`,
`package-verification.log`, `service-check.json`, `signer-check.json`.
The ready folder's `evidence/` contains Play highest-code screenshot,
`release-first-song.png`, `release-guided-entry.png`,
`release-returned-home.png` and installed-version text.

Real-device microphone/humming quality, actual Google sign-in/session retention,
and real Play Billing restore still require device testing. No real purchase was
made. The emulator has Google APIs but no Play Store. iOS was not built in this
Android-only task. Prior mocked restore tests do not replace store testing.

Flutter reports existing future Gradle/AGP/Kotlin minimum-version warnings; no
toolchain upgrade was included. Full release files nevertheless compiled and
passed the checks above.
