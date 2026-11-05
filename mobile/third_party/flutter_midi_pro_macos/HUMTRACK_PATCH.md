# HumTrack patch of flutter_midi_pro (macOS pod only)

`mobile/pubspec.yaml` pins the fork `hjm181227/flutter_midi_pro@1d8fc682` (iOS
drum-kit fix). Its `macos/Classes/FlutterMidiProPlugin.swift` uses
`AVAudioSession`, which is iOS-only, so `flutter build macos` fails with
`'AVAudioSession' is unavailable in macOS`. Upstream commits dfd9727/a218fa9
added the interruption handling and 0c7b5ec removed its `#if os(iOS)` guard;
3.1.6 on pub.dev does not have it.

This folder is a copy of that fork commit's `macos/` folder (plus `LICENSE`,
MIT). `mobile/macos/Podfile` builds the `flutter_midi_pro` pod from here instead
of the pub cache. Dart, iOS and Android still come from the pinned fork.
Only these changes:

- `Classes/FlutterMidiProPlugin.swift`: removed `init()`/`deinit`,
  `setupAudioSessionNotifications`, `handleAudioSessionInterruption` and
  `restartAudioEngines` (the AVAudioSession interruption block). macOS has no
  audio session interruptions; the rest of the file is unchanged apart from
  stripped trailing whitespace.
- `flutter_midi_pro.podspec`: license path `../LICENSE` -> `LICENSE`.

HumTrack plays notes on macOS through MeltySynth (`lib/audio/synth.dart`), so
this pod only needs to compile and register. If the fork's pin changes, re-copy
its `macos/` folder and re-apply the above. Drop this copy (and the Podfile
override) once the fork's macOS code builds.
