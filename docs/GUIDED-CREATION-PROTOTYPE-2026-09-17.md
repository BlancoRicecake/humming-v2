# HumTrack guided creation prototype — 2026-09-17

Branch: `codex/humtrack-guided-creation`. Based on Android internal 1.0.7 (35). This prototype has not been uploaded to Play or App Store.

## Implemented
- Guided creation reuses the existing hum-to-MIDI server and recording UI. No replacement recognition engine or second song format.
- Existing songs can enter guided mode from the sparkle button; detailed editor remains available.
- Calm / Bounce / Drive generate in-key bass and drum patterns for the current section. Selecting auditions the result, preserving melody, recorded audio, other sections and undo history.
- Samples: record with existing recorder, import PCM16 WAV (8–96 kHz, max 60 s / 24 MiB), select a range, preview/loop, keep trimmed copies, and add to the song audio lane.
- Samples are copied to independent durable library storage. Song insertion makes its own durable copy; deleting a song does not erase the sample library.
- Trims leave the source intact and add 5 ms edge fades. Insertion records the actual grid length. Selections longer than the current section cannot be inserted; the UI explains the limit. A full lane follows the existing overlap warning.
- Responsive two-column guided layout with fixed playback/save controls, Korean and English strings.

## Verification
- 154 Flutter tests passed, including immutable backing generation, musical bounds, serialization, sample persistence and format/size rejection, and both languages' landscape controls.
- Android debug build passed using JDK 17 and Gradle 8.14.3.
- Headless Pixel emulator: open existing converted melody; apply and save backing; import synthetic 2 s WAV through Android Documents UI; trim to about 1.51 s; keep as a separate sample; add to song; change backing; undo; save; force-stop and reopen.
- Saved JSON comparison confirmed Undo restored the whole section, including melody, bass, drums and sample. Inserted WAV persisted (48,352 bytes). Both library entries survived restart.
- Direct sample recording was attempted; emulator input was too quiet and the existing silence message appeared. Real microphone quality/latency and human listening evaluation remain device checks.
- Found and fixed during QA: missing Android plugin registration following Windows symlink failure; layout requiring unnecessary scrolling; Windows file-path separator mismatch; missing sample grid duration.
- Final build reuse check: the 1.51 s sample was inserted again and saved with `durSteps: 10` at 92 BPM. Recent logcat contained no fatal, unhandled or RenderFlex overflow errors. The headless emulator was stopped after verification.
- Latest changed-file Dart analysis and build results are recorded under `C:/dev/Handy_code/reports/humtrack-qa-20260916`.

## Scope and remaining product work
This is a usable first-song/sampling prototype, not a complete desktop DAW. Backings are deterministic templates, not generative accompaniment. Samples are arranged as audio clips, not yet playable chromatic instruments. The library is local; no cloud synchronization, rename/delete management or arbitrary compressed-audio import was added. Export remains in the existing detailed editor and follows the existing Pro rules.

## Desktop implementation sequence
1. Audio capability boundary: retain song/MIDI/WAV model and converter API, isolate synth, PCM output, recording, routing and export behind platform capabilities. Verify actual sound before exposing a desktop platform as supported.
2. macOS spike on a Mac: native build/signing, microphone usage description and sandbox microphone/network/file-selection entitlements, SoundFont/PCM output, record/playback/export, and account flows. Current entitlements lack these required capabilities; do not advertise Mac support yet.
3. Windows audio spike: select and validate a Windows synth/PCM backend. Current MIDI/PCM plugins do not provide the required Windows playback backend. Test latency, device changes, simultaneous recording and rendering. Visual Studio Desktop development with C++ is absent on this machine, so Windows compilation is currently blocked.
4. Desktop interaction: resizable window, mouse/keyboard shortcuts, drag/drop samples, timeline zoom and project portability. Reuse guided flow and sample storage semantics.
5. Real-device release gate: iPhone and Android recording quality, Bluetooth routing, conversion failure/retry, export listening checks and signed distribution. Build macOS on a Mac and Windows after its toolchain/audio backend are available.

No production credentials or account entitlements were changed for this prototype.
