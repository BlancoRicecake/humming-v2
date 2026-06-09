fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## iOS

### ios hello

```sh
[bundle exec] fastlane ios hello
```

Print available lanes (sanity)

### ios beta

```sh
[bundle exec] fastlane ios beta
```

Build and upload to TestFlight

### ios release

```sh
[bundle exec] fastlane ios release
```

Build and submit for App Store review

### ios sync_metadata

```sh
[bundle exec] fastlane ios sync_metadata
```

Sync App Store metadata (descriptions, keywords, etc) without binary

### ios sync_iap

```sh
[bundle exec] fastlane ios sync_iap
```

Sync IAP products via custom Python script (App Store Connect API)

### ios sync_play_iap

```sh
[bundle exec] fastlane ios sync_play_iap
```

Sync Play Console subscriptions via custom Python script (Android Publisher API)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
