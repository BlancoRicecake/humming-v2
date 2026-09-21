# HumTrack product analytics rollout

Status: code complete; Firebase collection remains disabled until the console,
release secrets, privacy notice, and store disclosures below are complete.

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

1. Create or select a dedicated HumTrack Firebase project and enable Google Analytics.
2. Register Android and iOS apps with bundle/application ID `com.humtrack.app`.
3. Verify events in Android and iOS DebugView with a non-production build.
4. Add these optional fields to `HUMTRACK_DART_DEFINES_JSON` for each release environment:
   - `FIREBASE_ANALYTICS_ENABLED=true`
   - `FIREBASE_PROJECT_ID`
   - `FIREBASE_MESSAGING_SENDER_ID`
   - `FIREBASE_MEASUREMENT_ID` when supplied
   - `FIREBASE_ANDROID_APP_ID`, `FIREBASE_ANDROID_API_KEY`
   - `FIREBASE_IOS_APP_ID`, `FIREBASE_IOS_API_KEY`
   - `APP_ENVIRONMENT=production` (or `staging` for internal validation)
5. Do not enable `FIREBASE_ANALYTICS_ENABLED` until the privacy and store items below are published.

Existing production release validation still requires non-empty
`CLARITY_PROJECT_ID` and `SENTRY_DSN_MOBILE`; secret values must remain outside Git.

## Required disclosure work before enabling Firebase

- Amend the Korean and English privacy policy to name Google/Firebase Analytics,
  describe product interaction data, the opaque user ID, retention, purpose, and
  international processing, and describe the in-app opt-out.
- Complete the policy's existing advance-notice process before the effective date.
- Update App Store Privacy answers for product interaction/analytics data.
- Update Google Play Data safety for app interactions/analytics data and the opt-out.
- Confirm DebugView contains none of the prohibited content listed above.

No App Store review submission, production rollout, or TestFlight upload is part
of this implementation change.
