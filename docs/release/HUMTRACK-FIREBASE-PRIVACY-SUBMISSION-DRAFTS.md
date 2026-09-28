# HumTrack Firebase privacy and store submission drafts

**Status:** Draft for the next release. Do not submit these answers and do not enable production Firebase Analytics until every item in the release gate is complete.

**Privacy policy URL:** `https://hum-track.com/privacy`

This draft covers the whole app, including Supabase, Sentry, Microsoft Clarity, in-app purchases, and the proposed Firebase Analytics activation. Store wording and categories must be rechecked against the exact binary immediately before submission.

## App Store Privacy draft

Use these answers in App Store Connect after the 1.4 privacy policy is effective.

| Apple category | Collected | Linked to user | Purpose | Notes |
|---|---:|---:|---|---|
| Contact Info → Email Address | Yes | Yes | App Functionality / Account Management | Supabase authentication, including Apple relay email where used. |
| Identifiers → User ID | Yes | Yes | App Functionality; Analytics | OAuth/Supabase ID; Firebase and Sentry receive only the opaque Supabase UUID for signed-in users. |
| Identifiers → Device ID | Yes | Yes (conservative answer) | Analytics | Firebase app-instance identifier. Android advertising ID and iOS IDFA are disabled. |
| Purchases → Purchase History | Yes | Yes | App Functionality | Product, status, expiry, transaction/receipt identifiers for entitlement and restoration. |
| Usage Data → Product Interaction | Yes | Yes for signed-in users | Analytics | Clarity interactions and allowlisted Firebase funnel events. Firebase can be disabled in Settings. |
| Diagnostics → Crash Data | Yes | Yes for signed-in users | Analytics / App Functionality | Sentry crash reporting with default PII collection disabled. |
| Diagnostics → Performance Data | Yes | Yes for signed-in users | Analytics / App Functionality | Sentry's sampled traces. |
| Diagnostics → Other Diagnostic Data | Yes | Yes for signed-in users | Analytics / App Functionality | Device/OS/app context around errors. |

Answer **No** to tracking. The app does not use collected data for third-party advertising, developer advertising, marketing, or cross-app tracking. It does not request ATT and does not collect IDFA/AAID.

Audio sent to HumTrack for analysis or processing is handled in server memory and immediately discarded. Under Apple's definition, data used only to service a request in real time and not retained longer is not declared as collected. Reclassify Audio Data as collected before submission if logging, caching, storage, training, or delayed processing changes that behavior.

Do not declare location, contacts, photos, health, sensitive information, song titles, lyrics, free text, raw audio, recording paths, or note/MIDI content for analytics. The binary and backend must continue to enforce those boundaries.

## Google Play Data safety draft

Use these answers for the production artifact and all active versions represented by the Play form.

- Does the app collect or share required user data types? **Collects: Yes. Shares: No**, provided each named processor continues to act only as a service provider under contract. Recheck vendor terms before submission.
- Is all collected data encrypted in transit? **Yes.**
- Can users request deletion? **Yes**, through Settings → Delete Account or `heobusy@gmail.com`.
- Is collection optional? Email/account and purchase records are required for those features. Firebase App interactions and Device or other IDs are optional because users can disable Anonymous usage analytics.
- Is data sold or used for advertising/personalization? **No.**

| Play category | Collected | Shared | Required/optional | Purpose |
|---|---:|---:|---|---|
| Personal info → Email address | Yes | No | Required for account features | Account management / App functionality |
| App activity → App interactions | Yes | No | Optional for Firebase; Clarity behavior must be assessed against the shipped consent/settings behavior | Analytics |
| Device or other IDs | Yes | No | Optional for Firebase | Analytics; app-instance ID and opaque account ID, no advertising ID |
| App info and performance → Crash logs | Yes | No | Required while Sentry is enabled | Analytics / App functionality |
| App info and performance → Diagnostics | Yes | No | Required while Sentry is enabled | Analytics / App functionality |
| Financial info → Purchase history | Yes | No | Required for paid entitlement | App functionality / Account management |

Do not declare the real-time audio request as collected while it remains ephemeral and is discarded immediately. Revisit the answer before release if server behavior changes. Play's Data safety form applies globally across the app's distributed versions, so check every active production/testing track and every embedded SDK.

## Physical-device DebugView validation

Run on one Android device and one iPhone before production activation. Save the tester, device/OS, app version/build, commit, Firebase project, time window, screenshots/export, and pass/fail result in the release record. Use staging only.

### Prerequisites

- Use official platform config files and a staging build with `APP_ENVIRONMENT=staging`, `FIREBASE_ANALYTICS_ENABLED=true`, and all required Firebase `--dart-define` values.
- Confirm the build shows the Anonymous usage analytics setting and starts with the intended current preference.
- Confirm Firebase console data retention is **2 months**, Google Signals/ad personalization are off, and no ad-network linking is enabled.
- Use a dedicated test account. Do not perform a paid production purchase. Use StoreKit/sandbox/Play test products for purchase events.

### Enable and disable DebugView

Android:

```text
adb shell setprop debug.firebase.analytics.app com.humtrack.app
adb shell setprop debug.firebase.analytics.app .none
```

iOS: launch the staging scheme once with `-FIRDebugEnabled`; after validation launch with `-FIRDebugDisabled` and remove the debug argument from the scheme.

### Checks

1. Turn Anonymous usage analytics off before a cold start. Confirm no HumTrack product events or app-set user ID appear.
2. Turn it on, cold start, and confirm `app_started` appears once with only allowlisted app/environment context.
3. Exercise the beginner flow and confirm the applicable events: `guided_started`, `recording_started`, `analyze_completed` or `analyze_failed`, `guided_backing_previewed`, `guided_backing_applied`, `guided_song_saved` or `guided_song_failed`.
4. Open the paywall and use sandbox/test purchase flows only. Confirm applicable `paywall_viewed`, `purchase_started`, `purchase_failed`, `purchase_restored`, and sandbox `purchase_completed` events.
5. Exercise permitted exports and confirm the applicable `export_midi`, `export_wav`, and `export_stems` events.
6. Inspect every event and parameter. Fail the release if any email, name, song title, lyrics, audio, recording/file path, note/MIDI content, voice trait, free text, token, receipt, or raw error message appears.
7. Confirm signed-out events have no app-set user ID. Sign in and confirm only the opaque Supabase UUID is used.
8. Turn analytics off again. After the SDK dispatch/buffer interval, repeat actions and confirm no new HumTrack product events arrive and the app-set user ID has been cleared.
9. Disable DebugView on both devices and attach evidence to the release record.

## Production release gate and dart-defines

The release helper rejects an invalid analytics flag, incomplete Firebase values, or a production analytics build without the non-Dart environment gate `HUMTRACK_FIREBASE_DISCLOSURES_READY=true`. The gate is deliberately outside the compiled defines so it cannot accidentally become application configuration.

Required defines when Firebase Analytics is enabled:

```text
APP_ENVIRONMENT
FIREBASE_ANALYTICS_ENABLED=true
FIREBASE_PROJECT_ID
FIREBASE_MESSAGING_SENDER_ID
FIREBASE_ANDROID_APP_ID
FIREBASE_ANDROID_API_KEY
FIREBASE_IOS_APP_ID
FIREBASE_IOS_API_KEY
```

`FIREBASE_MEASUREMENT_ID` remains optional. Do not paste actual keys into logs or release records.

Before setting the production readiness gate, verify all of the following:

- [ ] The 1.4 policy was published at `https://hum-track.com/privacy` and in the app, with in-app and member-email notice at least 30 days before its effective date.
- [ ] The policy is effective; if either notice went out after 2026-10-02, the effective date was moved to at least 30 days after both notices.
- [ ] App Store Privacy and Play Data safety forms were reviewed against the final binary and submitted.
- [ ] Android and iOS physical-device DebugView checks passed with evidence.
- [ ] Firebase user/event data retention is 2 months and advertising/Google Signals/linking settings were reviewed.
- [ ] Android manifest and iOS plist default collection, advertising identifier, and personalization settings remain disabled; iOS uses Firebase Analytics without ad-ID support.
- [ ] Static analysis, related tests, and release build verification passed from the exact release commit.

Only after every box is complete may the release environment set `HUMTRACK_FIREBASE_DISCLOSURES_READY=true` and build production with analytics enabled. This repository change does not set that environment variable, submit either store form, publish the policy, or enable production collection.

## Official references

- [Apple: App privacy details on the App Store](https://developer.apple.com/app-store/app-privacy-details/)
- [Apple: App Review Guidelines — Privacy](https://developer.apple.com/app-store/review/guidelines/#privacy)
- [Google Play: Provide information for the Data safety section](https://support.google.com/googleplay/android-developer/answer/10787469)
- [Firebase: Configure Analytics data collection and usage on Android](https://firebase.google.com/docs/analytics/configure-data-collection?platform=android)
- [Firebase: Configure Analytics data collection and usage on Apple platforms](https://firebase.google.com/docs/analytics/configure-data-collection?platform=ios)
- [Google Analytics: Data retention](https://support.google.com/analytics/answer/7667196)
