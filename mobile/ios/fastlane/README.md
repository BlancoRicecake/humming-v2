# HumTrack iOS fastlane

## Setup

```bash
cd mobile/ios
bundle install
```

Secrets are loaded from `fastlane/.env.default` (committed, ASC API key path) and
optionally `fastlane/.env.secrets` (gitignored) for overrides.

## Lanes

- `bundle exec fastlane ios hello` — sanity check
- `bundle exec fastlane ios beta` — build + TestFlight upload (needs signing)
- `bundle exec fastlane ios release` — build + submit for App Store review
- `bundle exec fastlane ios sync_metadata` — push metadata only
- `bundle exec fastlane ios sync_iap` — run ASC API IAP sync script

## ASC API key

- Issuer: `e40f6783-ba51-4b34-8f5a-f620821fbd15`
- Key ID: `TF99MYSPK2`
- .p8: `backend/secrets/AuthKey_TF99MYSPK2.p8` (do NOT commit)
