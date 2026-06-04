fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Android

### android play_internal

```sh
[bundle exec] fastlane android play_internal
```

Upload AAB + metadata + screenshots to Play Internal Testing

### android play_metadata_only

```sh
[bundle exec] fastlane android play_metadata_only
```

Upload only metadata/screenshots (no AAB)

### android play_promote_to_production

```sh
[bundle exec] fastlane android play_promote_to_production
```

Promote existing Internal build to Production (draft)

### android play_production

```sh
[bundle exec] fastlane android play_production
```

Upload AAB + metadata + screenshots to Play Production (draft)

### android build_and_play_internal

```sh
[bundle exec] fastlane android build_and_play_internal
```

Flutter build AAB + Play Internal upload

----


## iOS

### ios assets_upload

```sh
[bundle exec] fastlane ios assets_upload
```

Upload iPhone 6.9-inch screenshots + metadata (ko, en-US)

### ios screenshots_only

```sh
[bundle exec] fastlane ios screenshots_only
```



### ios beta

```sh
[bundle exec] fastlane ios beta
```

Upload an already-built Flutter IPA to TestFlight

### ios build_and_beta

```sh
[bundle exec] fastlane ios build_and_beta
```

Build IPA via Flutter and upload to TestFlight

### ios release

```sh
[bundle exec] fastlane ios release
```

Upload to TestFlight plus push current metadata/screenshots (no auto submit)

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
