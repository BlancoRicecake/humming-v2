# iOS 1.0.9 launch crash hotfix — 2026-10-04

## Summary

iOS/iPadOS 1.0.9 (build 38, released 2026-10-02 16:48 KST) aborts on every
launch. 1.0.10 (build 39) fixes it and was submitted to App Store review on
2026-10-04 23:24 KST with automatic release. The fix was verified on a physical
iPad (iPad14,4, iPadOS 26.5) with both a development build and the TestFlight
build 39: no crash, no new crash report. 1.0.9 crashed on the same device on
every launch.

Android is not affected by this crash. The Android login hotfix (1.0.10 build 39,
`docs/LOGIN-HOTFIX-2026-09-29.md`) was Android-only by design.

## Root cause

- 1.0.9 is the first release that links `firebase_core` / `firebase_analytics`
  (product analytics, `docs/HUMTRACK-PRODUCT-ANALYTICS.md`).
- `FLTFirebaseCorePlugin` calls `FirebaseApp.configure()` during plugin
  registration whenever `ios/Runner/GoogleService-Info.plist` exists. This is
  independent of the analytics consent/production gate.
- The iOS build machine (Mac) still had the old **Google Sign-In-only** plist
  (`BUNDLE_ID`, `CLIENT_ID`, `PLIST_VERSION`, `REVERSED_CLIENT_ID`). Without
  `GOOGLE_APP_ID` / `API_KEY`, `+[FIRApp addAppToAppDictionary:]` raises an
  `NSException` → `SIGABRT` before Dart `main()` runs.
- Symbolicated stack (1.0.9 archive dSYM, UUID `300E6510-…` matches the crash):
  `AppDelegate.didInitializeImplicitFlutterEngine` →
  `GeneratedPluginRegistrant.registerWithRegistry` →
  `FLTFirebaseCorePlugin.register(with:)` → `FirebaseApp.configure()` → abort.
- The old release guard only checked that the plist contained `CLIENT_ID`, so the
  build passed.

Why monitoring was blind:

- Sentry starts in Dart `main()`, after plugin registration, so it can never see a
  crash at this stage. Only Apple crash logs (Xcode Organizer / device
  `.ips`) show it.
- Separately, `SENTRY_DSN_MOBILE` pointed to a key that belongs to neither
  `humtrack-mobile` nor `humtrack-server`. The mobile Sentry project received
  **zero** events for at least 30 days on both platforms.
- Clarity iOS sessions dropped to zero after 2026-10-03 ~20:17 KST as users
  auto-updated to 1.0.9. Android sessions continued normally.

## Changes (branch `fix/ios-firebase-plist`, based on `codex/humtrack-login-hotfix`)

- `mobile/tool/release_support.rb`: `require_google_plist!` now requires
  `GOOGLE_APP_ID`, `API_KEY`, `GCM_SENDER_ID`, `PROJECT_ID`, `BUNDLE_ID`,
  `CLIENT_ID`, `REVERSED_CLIENT_ID`, an iOS-format `GOOGLE_APP_ID`
  (`1:<num>:ios:<hex>`) and `BUNDLE_ID == com.humtrack.app`. A Sign-In-only or
  Firebase-only plist is rejected. 4 new tests; 19/19 pass on Ruby 3.
- `mobile/ios/Flutter/AppFrameworkInfo.plist`: Flutter 3.47 migration
  (`MinimumOSVersion` removed), same as the 1.0.9 build.
- iOS release notes: crash-fix line added to `en-US` and `ko`.
- Local, not in git: merged `mobile/ios/Runner/GoogleService-Info.plist` =
  official Firebase iOS plist (`humtrack-hq`, app `com.humtrack.app`) + the
  existing Sign-In `CLIENT_ID` / `REVERSED_CLIENT_ID`. Native collection stays
  off (`FIREBASE_ANALYTICS_COLLECTION_ENABLED=false` in `Info.plist`).
- Local, not in git: `backend/.env.secrets` `SENTRY_DSN_MOBILE` now uses the
  `humtrack-mobile` client key (project `4511601866833920`). A test event was
  accepted (HTTP 200).

## Handoff for other build machines (Windows / CI)

1. **GoogleService-Info.plist**: copy the merged file to
   `mobile/ios/Runner/GoogleService-Info.plist` on every machine that builds iOS.
   Never ship a Sign-In-only plist while `firebase_core` is a dependency. The
   release guard now blocks it.
2. **SENTRY_DSN_MOBILE**: replace the value in the local `backend/.env.secrets`
   **and** in the GitHub secret `HUMTRACK_DART_DEFINES_JSON`. Take the DSN from
   Sentry → `humtrack-mobile` → Client Keys. Android 1.0.10 (39) shipped with the
   old value, so Android errors are still not reported until the next Android
   build.
3. **ENGINE_URL**: required by the release guard; production value
   `https://api.hum-track.com`. It was missing from the Mac `.env.secrets` and was
   supplied through the environment for the 1.0.10 build.
4. **Toolchain** used for iOS 1.0.9/1.0.10: Flutter 3.47.1 (fvm), fastlane via
   Ruby 3.4.1 (rbenv; the vendored gems do not load under Homebrew Ruby).
5. **Versions**: iOS 1.0.10 (39) in review; Android 1.0.10 (39) submitted to
   production on 2026-09-29. Next builds must use build number 40+ and a
   marketing version above 1.0.10. An App Store Connect version entry created as
   1.1.0 was renamed to 1.0.10 by `deliver` at submission.
6. **Branches**: 1.0.9/1.0.10 code lives on `codex/humtrack-product-analytics` →
   `codex/humtrack-login-hotfix` → `fix/ios-firebase-plist`. None of it is merged
   into `main` yet.

## Open issues found during the investigation (not fixed)

- App Store Server Notifications are not arriving: `iap_notifications` has 0
  rows and many `subscriptions` rows keep `active` / `trial` after `expires_at`.
- Firebase Analytics production gate is still pending (policy notice, store
  privacy forms, DebugView). Collection remains disabled.
- After 1.0.10 is live, confirm iOS sessions reappear in Clarity and the first
  mobile events arrive in Sentry `humtrack-mobile`.
