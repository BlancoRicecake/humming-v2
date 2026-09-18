# HumTrack desktop prototype — 2026-09-18

Branch: `codex/humtrack-desktop`, based on guided-creation commit `80b831c`.

## Implementation
- Windows uses the same MeltySynth / SoundFont instruments as iOS and the export renderer. Only PCM output is new: shared-mode WASAPI, 44.1 kHz mono PCM16, bounded hardware queue and device-error propagation into the existing recovery logic.
- A small platform adapter preserves the existing flutter_pcm_sound path on iOS and macOS. Android continues to use its existing native MIDI backend.
- Output opens lazily, supports explicit release/recreation, and ignores replies from previously released Windows output generations. Losing desktop keyboard focus does not stop playback.
- Desktop startup does not invoke mobile immersive/orientation APIs. Mobile store purchase initialization and Clarity are disabled on unconfigured desktop platforms; server account entitlements are not granted or bypassed.
- Windows app branding uses HumTrack and the existing icon. Minimum window size is 960 × 600 logical pixels.
- macOS microphone description, sandbox recording, outbound networking and user-selected file permissions are added. macOS routes through the shared synth/PCM implementation; no Mac build or execution has been verified here.

## Verification and artifacts
Report directory: `C:/dev/Handy_code/reports/humtrack-desktop-20260918`.
- Initial Windows debug native build passed with zero compiler warnings/errors.
- Android regression `assembleDebug` passed after the shared audio/startup changes (546 tasks).
- 156 Flutter tests passed, including stale-device callback and PCM encoding/release tests.
- Initial hidden native smoke passed: real WASAPI stream started, 67,584 PCM frames submitted, nonzero signal peak 1,111 / 32,768; MIDI and WAV created, exported WAV peak 0.94.
- Optimized release smoke also passed, including guided-editor backing playback and saving: SoundFont load 93 ms, final RSS 211,120,128 bytes (~201 MiB), peak RSS 299,864,064 bytes (~286 MiB). Native peak was 1,251 / 32,768, exported WAV peak 0.94. Host: Core Ultra 5 225F, ~16 GB RAM. Short functional run only; no long-session latency/CPU claim.
- Debug process peak RSS was 577,044,480 bytes (~550 MiB), measured on this PC. This is not a minimum hardware specification or a sustained multi-track benchmark.
- The dedicated `test/desktop_smoke_app.dart` entry point runs the real app with isolated song storage and validates native output, generated accompaniment, export, editor transport and save. `--humtrack-smoke` keeps its native window hidden; this entry point is never used for the distributed preview.

## Preview package
- `C:/dev/Handy_code/reports/humtrack-desktop-20260918/HumTrack-Windows-Preview-20260918.zip` (79,836,317 bytes).
- Built with the regular `lib/main.dart` entry point in release mode, without QA Pro or smoke defines. Contains the whole runtime/data directory and the MSVC app-local CRT DLLs.
- Starting the copied preview executable with its window hidden stayed alive through a five-second startup check; RSS was 136,597,504 bytes (~130 MiB). The verification process was then stopped.
- Extract the complete archive and run `HumTrack.exe`; do not copy the executable alone. This is an unsigned local preview, not a store release.

## Build locally
1. Install Flutter and Visual Studio Build Tools with C++ desktop tooling and Windows SDK. This machine now has Build Tools 2022 17.14 installed; no reboot was performed.
2. In `mobile`, run `flutter pub get`, then `flutter build windows --release --target lib/main.dart`.
3. Ship the complete `build/windows/x64/runner/Release` directory: the executable depends on sibling DLLs and `data`.
4. To run the native check: build with target `test/desktop_smoke_app.dart` and `--dart-define=DESKTOP_SMOKE_OUTPUT=<absolute report directory>`, then run `HumTrack.exe --humtrack-smoke`.
5. This machine lacks symlink privileges. Existing local plugin directories under `windows/flutter/ephemeral/.plugin_symlinks` and `linux/flutter/ephemeral/.plugin_symlinks` were connected with directory junctions to the resolved Pub cache, then normal `flutter pub get` generated registrants. No Windows Developer Mode or system security setting was changed.

## Remaining release gates
- Supabase public client configuration and desktop browser OAuth callback registration; desktop subscription purchase channel/entitlement UX. Local preview does not contain production auth configuration or unlock Pro.
- Real microphone recording quality/monitoring latency, sustained polyphony, Bluetooth/output device switching, sleep/resume and audio interruption testing.
- Full keyboard/drag-and-drop editing workflow and smaller-window UX beyond the initial minimum size.
- Windows signing/installer and clean-machine distribution testing.
- macOS build/signing/notarization and actual Mac microphone, audio and export tests.

## Sources for native implementation
- https://learn.microsoft.com/en-us/windows/win32/coreaudio/rendering-a-stream
- https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nf-audioclient-iaudioclient-initialize
