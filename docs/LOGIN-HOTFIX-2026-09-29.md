# Android login hotfix — 2026-09-29

## Incident and evidence

The user reports that the new Android version shows “이 빌드에는 로그인이 설정되어 있지 않아요.” and that login works in the previous version. The user rolled production back and authorized a corrected internal test release, with an installation email to jlionk200@gmail.com. Production release requires their later approval.

The affected local `1.0.9 (38)` release AAB at `C:/dev/Handy_code/humtrack-songplan/mobile/build/app/outputs/bundle/release/app-release.aab` contains neither the known production Supabase host nor the Google web OAuth client ID in any of its three libapp.so architectures. The local internal Firebase defines JSON contains only analytics fields. The existing Fastlane build lane already rejects missing authentication defines; a direct Flutter build previously did not. These findings support a configuration-omitted build bypassing the official release guard. Exact upload provenance still requires a checksum comparison with the uploaded artifact.

The UI message is caused by disabled AuthService (missing build configuration or initialization failure), not by a Google sign-in response. Therefore SHA registration is not the first failure in this incident. No Supabase security checks were relaxed.

Read-only checks: production API health HTTP 200 (`production`, `01fc868`); Supabase public JWKS HTTP 200 with one ES256 key. Google OAuth project `humtrack` has Android Play Signing, Android, iOS and Supabase web clients, and its audience is external/production. The separate analytics project `humtrack-hq` is not the OAuth project. No provider, certificate or backend settings were changed.

## Changes

- Version `1.0.10+39`, branch `codex/humtrack-login-hotfix`, base `8364ef8`.
- Android Gradle compilation requires nonblank `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `GOOGLE_WEB_CLIENT_ID` on every release, including direct Flutter, APK/AAB and flavored builds. Validate HTTPS origin and OAuth client format. Errors print field names only. Debug builds remain usable without production settings.
- Internal upload lane always rebuilds through the existing validated Fastlane lane, preventing accidental upload of an old manually generated AAB. Existing full release configuration and signing checks remain intact.
- CI and official Android release workflow execute ten offline Gradle regression cases before app build/upload.
- No app login behavior, iOS code, backend code or production configuration changes. The separately investigated iOS configuration hardening was removed from this hotfix.

## Validation

- Real Gradle guard execution with JDK 17 / Gradle 8.14.3: 10 tests passed. Covers missing/all-blank values, Firebase-only input, malformed encoding, invalid URL/client ID, valid configuration, flavored release, debug and repeated execution after a successful build.
- Workflow actionlint: passed. `git diff --check`: passed.
- Existing backend JWT tests: 11 passed; existing mobile auth refresh tests: 8 passed. Auth code is unchanged by this hotfix.
- Full build, app tests, Ruby helper tests and Fastlane syntax run in the official Android workflow before upload. Windows has no local Ruby runtime; no local release AAB was represented as validated.
- Local AVD has no Play Store. Actual Play installation and successful account sign-in must be verified using the internal testing link on the user's device.

## Release procedure

Use the complete existing GitHub `HUMTRACK_DART_DEFINES_JSON` and Android upload secrets. Firebase-only JSON is an additive analytics configuration, never a complete release configuration. Do not replace the full JSON with it. No secret values should be logged or committed.

After the user authorized internal testing, the intended command is:

```sh
gh workflow run release-mobile.yml --repo BlancoRicecake/humming-v2 --ref codex/humtrack-login-hotfix -f platform=android -f destination=internal -f build_number=39
```

For build-only validation use `destination=build`. Do not use `destination=production` or platform `both` for this hotfix. Use Linux Android runners; no macOS Actions are needed.

Existing Play internal testers/groups should be reused. Send the verified opt-in/install link to the requested address after build 39 is available. Ask the tester to confirm version 1.0.10 (39), Google login, logout/login again and reopening the app. Avoid uninstalling or clearing storage because songs may be local. Production stays on the user's chosen rollback release until explicit approval.

No server scaling, service plan changes or paid APIs are required. GitHub Actions consumes the account's runner allowance; do not claim its cost is always zero.

## Completed internal release

- GitHub Actions run [36445483549](https://github.com/BlancoRicecake/humming-v2/actions/runs/36445483549) completed successfully from `e8ac3da` on `codex/humtrack-login-hotfix`. Android only, `destination=internal`, build number 39. Ruby helper/syntax checks, Gradle guard tests, analyzer, Flutter tests, signed release build and internal upload passed.
- Play Console shows `1.0.10`, bundle `39 (1.0.10)`, **available to internal testers**. Existing tester group already includes the requested recipient; no membership changes were needed.
- The workflow AAB artifact SHA-256 is `aa9af0a609aa3852f031b4ab61fe5b16d3e74a5fb9c1f5c7c85bea234b906c1e`. All three compiled architectures contain the expected Supabase hostname, Google web client ID and an anon JWT matching the production project. Verification output contains booleans only, no credential values.
- Installation link: https://play.google.com/apps/internaltest/4701278899500552203
- The requested installation/checklist email was sent to `jlionk200@gmail.com`; Gmail returned the `SENT` label (message ID `1a0e8bbaeadc40b0`).
- Actual device login confirmation remains with the user. Production was not deployed; later explicit user approval is required.
