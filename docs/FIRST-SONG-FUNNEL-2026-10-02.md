# First-song creation and restore funnel — 2026-10-02

## Scope and evidence

Branch: `codex/humtrack-first-song-funnel`, based on `f6deaee` (Android login
hotfix complete). Local changes only: no push, store submission, production
release, pricing changes, new paid service, or analytics collection enablement.
Version remains 1.0.10+39 for local QA; this is not a new distributable release.

The portfolio supplied Play installed-user count 557, 28-day device acquisitions
554, first opens 323, and monthly active devices 568; Apple September first
downloads 688, proceeds US$30 and 4 opt-in crash reports. These were not
independently re-fetched for this change. Acquisition and first-open totals are
not a common cohort and cannot establish a conversion rate or cause of churn.

Code inspection found guest song creation and saving already supported. The
first action was visually mixed with demos and required a mode choice. Restore
was below the long plan list. Guided-save events excluded autosave/back saves;
explicit guided exits, paywall closure and restore attempt outcomes were absent.
Existing purchase benefits and price/trial disclosures were retained.

## Changes and expected behavior

| Area | Before | After |
|---|---|---|
| First creation | Find New song after demos, choose guided/direct mode | First card precedes demos and opens guidance directly, without sign-in |
| Returning creator | Guided/direct chooser | Same chooser after at least one user song exists |
| Guidance | Manual-save completion event only | First successful content save per guided visit, including autosave/back; explicit exit stage |
| Restore | Bottom of long paywall | Accessible text button above plans, duplicate-tap guard covers sign-in, errors recover |
| Measurement | No restore/close result events | Allowlisted attempt, outcome and close events; consent unchanged |

Seed demos do not count as the user's first song. Deleting all user songs shows
first-song guidance again. Detailed editing remains available from guidance.
First-card impression is a widget impression, not a unique-user count. See
`HUMTRACK-PRODUCT-ANALYTICS.md` for event semantics and measurement limits.

## Changed files

- `mobile/lib/looptap/screens/songs_screen.dart` and
  `widgets/first_song_card.dart`: first-song routing/card and small-width layout.
- `mobile/lib/looptap/screens/edit_screen.dart`: save and explicit exit events.
- `mobile/lib/looptap/widgets/sheets/paywall_sheet.dart`: restore placement,
  safe busy-state recovery, restore/close instrumentation.
- `mobile/lib/services/product_analytics.dart`: events and fixed-value allowlist.
- English/Korean ARBs and three generated localization files.
- `mobile/test/looptap/{first_song_flow_test,paywall_funnel_test}.dart`,
  `mobile/test/services/product_analytics_test.dart`, offline font test support.
- `mobile/test/first_song_smoke_app.dart`: explicit debug-only local QA entrypoint,
  separate song/preferences/entitlement storage and privacy-filtered local logs.

## Validation

- `flutter analyze --no-pub`: no issues. Added smoke entrypoint separately
  analyzed with no issues after placement under `test/`.
- `flutter test --no-pub --reporter expanded`: **197 passed**, including 13 new
  widget scenarios. Covers EN/KO guest entry, returning chooser, empty exit,
  real disk save/reload, 640x360 at 1.15 text scale, autosave deduplication,
  all four restore service outcomes, exception recovery and sign-in cancellation.
- Standard `flutter build apk --debug --no-pub`: passed after Android plugin
  generation was repaired. Separate QA-entrypoint APK also built successfully. The final standard APK
  was installed over the emulator build and booted with its original library;
  no missing-plugin/channel errors were present for that app process.
- Android 35 pixel emulator: first card → guided mode without sign-in/chooser;
  switch to detailed editor → enter note → guidance → apply calm backing;
  back/save → cold restart → own song remains and first card disappears;
  reopen song → export paywall → restore visible above plans → close → notes
  and backing remain. No purchase or real login was attempted.
- Local event evidence: `first_song_prompt_viewed`, `guided_started` with
  `first_song`, explicit `guided_exited` with `empty/editor` and `saved/back`,
  one `guided_song_saved` autosave event per tested visit, backing application,
  paywall view and `paywall_closed` with `export/dismissed`.
- `git diff --check`: passed.

Evidence remains local under
`C:/src/humming-v2/mobile/build/first-song-evidence/`:
`01-first-song.png`, `02-saved-after-restart.png`, `03-restore-visible.png`,
`events.log`. Build/test logs are under this worktree's `mobile/build/`.

### Reproducing local Android QA on this Windows host

The first `pub get --offline` stopped at Windows desktop symlink setup and did
not generate Android's `GeneratedPluginRegistrant.java`; `--no-pub` can still
compile that state but native plugins fail at runtime. Resolved without changing
OS settings or global Flutter settings: in the command process set
`FLUTTER_WINDOWS=false` and `FLUTTER_LINUX=false`, then run `flutter pub get
--offline` successfully before building. No dependency versions were changed.
Do not treat APK compilation alone as startup validation.

To use isolated QA storage, build with
`flutter build apk --debug --no-pub -t test/first_song_smoke_app.dart
--dart-define=HUMTRACK_FIRST_SONG_QA=true` (one command). It calls the real app
main, uses `files/first_song_qa_20261002` for test data, and overrides Korean only
in memory. Use no service/auth/analytics defines for this local guest QA.
The entrypoint refuses non-debug or non-explicit QA execution. Never upload it.

## Remaining limits and release decision

- No measured conversion improvement claim: this is a code-supported hypothesis.
  After an approved release, compare version/platform cohorts for first-song
  impression → guided start → successful content save, and restore outcomes.
- Real microphone/humming conversion, physical-device login/session persistence,
  Play Billing/App Store restore and iOS build were not validated here. Restore
  result behavior is verified with service doubles; the emulator has no Play
  Store and its restore button is unavailable as expected.
- Firebase production collection remains disabled behind the existing disclosure
  and release gate. No new SDK, identifier or consent default was introduced.
  Song titles, audio, musical notes, email and raw errors are not event fields.
- Explicit exit events do not cover process death or crashes. A `saved` stage
  means a successful content save occurred, not that every later edit was saved.
- Current Flutter toolchain warns about future minimum Gradle/AGP/Kotlin
  versions. No toolchain upgrade was included.
- A later internal-test/store release needs its own reviewed version/build and
  release authorization. This branch was neither uploaded nor deployed.
