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

### ios screenshots_only

```sh
[bundle exec] fastlane ios screenshots_only
```

Upload iPhone 6.9-inch screenshots only (ko, en-US)

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
