# HumTrack product analytics rollout

Status: code, Firebase project/app registration, privacy wording, store-form
drafts, native collection defaults, and release validation are complete.
Production collection remains disabled until the remaining manual release gate
below is complete.

## Architecture

Feature code calls `ProductAnalytics` only. The service validates event names and
an allowlist of enum-like properties before dispatching to:

- Microsoft Clarity for session replay, heatmaps, and the same named product events.
- Firebase Analytics for quantitative mobile funnels when explicitly configured.
- A no-op path on Windows, macOS, unconfigured mobile builds, and CI.

The Settings switch **Anonymous usage analytics** controls both Clarity and
Firebase. Turning it off pauses/removes Clarity collection, disables Firebase
collection, and clears the analytics user ID. Sentry remains enabled as the
separate crash/error diagnostic service described in the privacy policy.

## Funnel events

| Funnel step | Event | Safe parameters |
|---|---|---|
| App bootstrap completed | `app_started` | common context only |
| Guided editor opened | `guided_started` | `feature`, `entry_source` |
| Hum capture opened | `recording_started` | `feature` |
| Analysis succeeded/failed | `analyze_completed`, `analyze_failed` | `feature`, `role`, fixed `error_code` |
| Backing compared/applied | `guided_backing_previewed`, `guided_backing_applied` | `backing_style`, candidate number |
| Guided song saved/failed | `guided_song_saved`, `guided_song_failed` | `feature`, fixed `error_code` |
| Export completed | `export_midi`, `export_wav`, `export_stems` | `export_type`, `scope` |
| Export failed | `export_failed` | `export_type`, fixed `error_code` |
| Paywall and purchase | `paywall_viewed`, `purchase_started`, `purchase_completed`, `purchase_failed`, `purchase_restored` | `entry_source`, `store`, fixed `error_code` |

Common context is `app_id`, platform, app version/build, environment, locale,
and plan. Firebase already collects app/platform/version/locale dimensions, so
the Firebase adapter omits those duplicate event parameters and keeps only
environment, plan, and event-specific fields.

## Data boundary

The adapter has no fields for email, name, song title, lyrics, free text, paths,
audio, recordings, note content, MIDI content, or voice characteristics. Unknown
events and unknown properties are dropped. The only user identifier accepted is
an opaque Supabase ID; values containing an email marker or spaces are rejected.

## Firebase console and release steps

Completed:

- Created the dedicated Spark-plan project `humtrack-hq` and enabled Google
  Analytics property `p555155566`.
- Registered Android and iOS apps with bundle/application ID
  `com.humtrack.app`, plus a Web app for future browser integration.
- Stored the official files at `mobile/android/app/google-services.json` and
  `mobile/ios/Runner/GoogleService-Info.plist`. Both paths are ignored by Git.
- Rebuilt the Android debug APK with the official config and verified that the
  generated `google_app_id` matches the registered Android app.
- Added Korean/English Firebase disclosures to the canonical, in-app, and web
  privacy-policy drafts (`1.4-draft`, proposed effective date 2026-11-01).
- Drafted the full-app App Store Privacy and Play Data safety answers plus the
  Android/iOS physical-device DebugView procedure in
  `docs/release/HUMTRACK-FIREBASE-PRIVACY-SUBMISSION-DRAFTS.md`.
- Disabled Firebase collection, advertising-ID collection, and advertising
  personalization by default in native Android/iOS configuration. iOS uses the
  Firebase Analytics no-ad-ID pod variant.
- Made the release helper reject invalid flags, incomplete Firebase defines, and
  production analytics builds without `HUMTRACK_FIREBASE_DISCLOSURES_READY=true`.

Remaining:

1. Publish the 1.4 policy and send both required notices at least 30 days before
   its effective date. If either notice misses 2026-10-02, move the effective date.
2. Submit the reviewed App Store Privacy and Play Data safety forms for the exact
   release binary.
3. Set Firebase user/event retention to 2 months and verify Google Signals,
   advertising personalization, and ad-network links are off.
4. Verify the allowlisted events on physical Android and iOS devices in DebugView
   using a staging build and save the evidence.
5. Supply these fields in `HUMTRACK_DART_DEFINES_JSON` for the release environment:
   - `FIREBASE_ANALYTICS_ENABLED=true`
   - `FIREBASE_PROJECT_ID`
   - `FIREBASE_MESSAGING_SENDER_ID`
   - `FIREBASE_MEASUREMENT_ID` when supplied
   - `FIREBASE_ANDROID_APP_ID`, `FIREBASE_ANDROID_API_KEY`
   - `FIREBASE_IOS_APP_ID`, `FIREBASE_IOS_API_KEY`
   - `APP_ENVIRONMENT=production` (or `staging` for internal validation)
6. Only after steps 1–5 pass, set the release-process environment variable
   `HUMTRACK_FIREBASE_DISCLOSURES_READY=true` and enable Firebase Analytics in the
   production define JSON.

Existing production release validation still requires non-empty
`CLARITY_PROJECT_ID` and `SENTRY_DSN_MOBILE`; secret values must remain outside Git.

## Production activation gate

The reviewable drafts and exact checklist are in
`docs/release/HUMTRACK-FIREBASE-PRIVACY-SUBMISSION-DRAFTS.md`. The environment
gate does not replace those checks; it records that the human release owner has
completed them. It is intentionally not a Dart define and is never compiled into
the app.

No App Store review submission, production rollout, or TestFlight upload is part
of this implementation change.
