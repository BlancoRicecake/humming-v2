# Raw research — open-source & licensable building blocks (collected 2026-10-12)

# HumTrack: open-source and licensable building blocks (research as of 2026-10-12)

**Scope note:** The shared web-search budget ran out partway through. Items marked **[unverified]** come from general knowledge and were not confirmed against a source in this session. These are: GridSound, Wavacity, Tenacity, Audiotool licensing, the Ardour and PortAudio license text, ACRCloud price figures, Dart bindings for Yjs (y-crdt), and the librosa license. Everything else has a source URL. None of this is legal advice.

---

## 1. Audio engines (cross-platform and mobile)

| Item | License / cost | Status | Fit |
|---|---|---|---|
| **JUCE 8** | AGPLv3 or commercial ([GitHub](https://github.com/juce-framework/JUCE)). Starter is free up to $20k/yr revenue with no splash screen. Indie is $40/mo or $800 perpetual, up to $300k. Pro is $175/mo or $3,500, no cap ([JUCE forum EULA post](https://forum.juce.com/t/amendments-to-the-juce-end-user-licence-agreement-for-juce-8/61265)) | Mature | **Evaluate** only if the engine moves to C++. It is heavy to bridge from Flutter. AGPL is not usable for a closed paid app, so it would mean a paid tier once revenue passes $20k |
| **Tracktion Engine** | GPL or commercial. Shipping it requires **both** a JUCE license and a Tracktion license. C++20. Supports iOS and Android ([GitHub](https://github.com/Tracktion/tracktion_engine/)) | Active (v3) | **Evaluate later**. It is a full DAW model (edits, clips, automation), but it means two commercial licenses |
| **miniaudio** | Public domain or MIT-0. Backends: WASAPI, CoreAudio, AAudio, OpenSL\|ES. Includes a node graph and a resource manager ([GitHub](https://github.com/mackron/miniaudio)) | Very active | **Adopt** as the native audio I/O layer through FFI. Could replace the custom WASAPI code |
| **flutter_soloud 5.2.0** | Dart plugin is MIT, the SoLoud engine is zlib/libpng, and the codecs are BSD-style ([license doc](https://docs.page/alnitak/flutter_soloud_docs/get_started/license)). Built on SoLoud and miniaudio. Runs on Android, iOS, macOS, Windows, Linux and Web. Offers push/pull buffer streams, waveform synthesis, effects, buses, and capture of the master output to Opus/FLAC/WAV ([pub.dev](https://pub.dev/packages/flutter_soloud)) | Released about 2 days ago | **Evaluate (high priority)**. It is the only maintained Flutter plugin with Windows support and a permissive license. It could unify the three platform audio paths |
| **flutter_pcm_sound 3.3.3** | Unlicense. Android, iOS and macOS only. Uses a feed-callback model with a threshold, and recommends feeding from an Isolate. Gives no iOS underrun guidance ([pub.dev](https://pub.dev/packages/flutter_pcm_sound)) | Last published Oct 2025 | **Current stack, likely the cause of iOS underruns.** Dart-side feeding is subject to isolate scheduling and GC. Raising the feed threshold trades latency for stability |
| **Oboe** | Apache-2.0. Latest is 1.11.0, released 15 Sep (year not shown) ([releases](https://github.com/google/oboe/releases)) | Active | **Adopt only if** you write native Android audio. miniaudio already covers AAudio |
| **AudioKit** | MIT. Apple platforms only (iOS, macOS, tvOS) ([GitHub](https://github.com/AudioKit/AudioKit)) | Active | Avoid, because it is Apple-only |
| **Superpowered** | **Being retired.** No new licenses are issued (renewals only), and operations end on **31 Jul 2027**. The announcement was dated 9 Sep 2026 ([farewell page](https://superpowered.com/superpowered-farewell)) | Ending | **Avoid** |
| **libpd** | BSD-style ([LICENSE](https://github.com/libpd/libpd/blob/master/LICENSE.txt)). iOS and Android through companion repos ([GitHub](https://github.com/libpd/libpd)) | Maintained | Evaluate for patch-based instruments. Niche |
| **Faust** | Compiler is LGPL-2.1+ (v2.87.11) ([COPYING](https://github.com/grame-cncm/faust/blob/master-dev/COPYING.txt)). The repo summary mentions an exception for generated code, but I did not read its text **[verify the exception wording]** | Active | Evaluate as a DSP-authoring tool. Generated C++ or Rust is normally shipped without the compiler |
| **Csound** | LGPL-2.1. Version 7.0 is in beta and 6.x is end-of-life ([GitHub](https://github.com/csound/csound)) | Active | Avoid on iOS because of the LGPL problem below |
| **RtAudio / PortAudio** | RtAudio license is "similar to MIT" and desktop-only ([GitHub](https://github.com/thestk/rtaudio)). PortAudio is desktop-only, and its license (MIT-style) was not confirmed **[unverified]** ([GitHub](https://github.com/PortAudio/portaudio)) | Mature | Avoid, because there is no mobile support. miniaudio covers the same ground |
| **Rust: cpal / fundsp** | cpal is Apache-2.0, with WASAPI/ASIO, CoreAudio (iOS too) and AAudio backends ([GitHub](https://github.com/RustAudio/cpal)). fundsp 0.23 is MIT or Apache, with graph-based DSP and synthesis ([GitHub](https://github.com/SamiPerttu/fundsp)) | Active | **Evaluate** if you would go the flutter_rust_bridge route. This is a permissive, all-platform alternative to C++ |

---

## 2. Synthesis, sampling and sound content

| Item | License | Notes | Fit |
|---|---|---|---|
| **dart_melty_soundfont 2.0.0** (current, iOS) | MIT. A port of MeltySynth. Allocates no memory during rendering ([pub.dev](https://pub.dev/packages/dart_melty_soundfont)) | Pure Dart, last published Aug 2025 | Keep as the fallback. Running the synth in Dart and pushing PCM through a platform channel is the structural risk behind the underruns |
| **flutter_midi_pro 4.0.4** (current, Android) | MIT wrapper, but it is **"powered by FluidSynth on Android and AVFoundation on iOS/macOS."** Polyphony defaults to 64 and is configurable on Android only. No Windows support ([pub.dev](https://pub.dev/packages/flutter_midi_pro)) | n/a | The FluidSynth binary inside it is **LGPL-2.1** (see the next row) |
| **FluidSynth** | LGPL-2.1 ([GitHub](https://github.com/FluidSynth/fluidsynth)). The project's FAQ calls it "questionable whether iOS and the App Store can fulfil the requirements of the LGPL." It recommends shipping FluidSynth as a separate, replaceable library, and otherwise releasing app object files so users can relink ([Licensing FAQ](https://www.fluidsynth.org/wiki/LicensingFAQ/)) | n/a | Android `.so`: fine if you keep a dynamic library, attribution, and a source offer. **iOS: avoid.** Server use: no issue, because nothing is distributed |
| **TinySoundFont** | MIT, a single header (`tsf.h`) ([GitHub](https://github.com/schellingb/TinySoundFont)) | Moderate activity. Has a no-LLM-contributions policy | **Adopt candidate.** Calling it from C inside a miniaudio callback through FFI gives one permissive SF2 synth on all four platforms. That removes the Android polyphony cap and the iOS Dart feeding path |
| **sfizz** (SFZ) | BSD-2 | **Archived 21 Jun 2026** ([GitHub](https://github.com/sfztools/sfizz)) | Avoid for new work. Fork only if you need SFZ |
| **Surge XT** | GPL-3.0 ([GitHub](https://github.com/surge-synthesizer/surge)) | Active | Avoid shipping it. Fine to study |
| **Vital** | GPLv3. The README itself says you can't ship it on the iOS App Store without buying an exception (licensing@vital.audio). The free presets are not redistributable. The "Vital" name is trademarked ([GitHub](https://github.com/mtytel/vital)) | Low activity | Avoid. Ask about a commercial license only if you truly need a wavetable synth |
| **Dexed** | GPL-3.0, **but its msfa FM engine is Apache-2.0** ([GitHub](https://github.com/asb2m10/dexed)) | Maintained | **Evaluate msfa** as a permissive DX7-style FM engine. Avoid the Dexed code itself |

**Sound content (SF2/SFZ)**

| Library | License | Fit |
|---|---|---|
| GeneralUser GS 2.0 | Permissive. "Use it in your software projects," including commercial work. The author notes he cannot be certain of every sample's origin ([scancode](https://scancode-licensedb.aboutcode.org/generaluser-gs-2.0.html)) | **Adopt** as the default GM bank |
| MuseScore General / FluidR3 GM / FluidR3 Mono | MIT, with some CC0 or public-domain parts ([Debian copyright](https://people.debian.org/~tg/sf/MuseScore_General_Full.copyright)) | **Adopt** |
| VSCO 2 CE and VCSL | CC0. VSCO 2 CE comes as SFZ or WAV only, no SF2 ([Versilian](https://versilian-studios.com/vsco-community/), [VCSL](https://github.com/sgossner/VCSL)) | **Adopt** for orchestral sounds and percussion. You'll have to convert them to SF2 yourself |
| Sonatina Symphonic Orchestra | CC Sampling Plus 1.0. Some source authors are unknown ([readme](https://os.zynthian.org/factory_sfz/Other/sonatina/Sonatina%20Symphonic%20Orchestra/Readme.html)) | Avoid. The license is retired and ambiguous for redistribution in an app |
| Spitfire LABS | Royalty-free in your own music, but "not permitted to use the sounds to create another sample library" ([Spitfire support](https://support.spitfireaudio.com/en/articles/11815239-are-spitfire-audio-sample-libraries-royalty-free-and-can-i-use-them-on-commercial-recordings)) | **Avoid** bundling it |

---

## 3. Open-source DAWs and editors to learn from (study, don't ship)

| Project | License | Notes |
|---|---|---|
| Helio Workstation | GPL-3. JUCE-based. Runs on desktop, Android and iPad, and is listed on the App Store ([GitHub](https://github.com/helio-fm/helio-sequencer)) | **The best reference** for a beginner-friendly mobile sequencer UX |
| openDAW | **AGPLv3 or commercial** (andre.michelle@opendaw.org). TypeScript with a Rust/WASM engine. Has instruments including a SoundFont player, and recording with takes. Roadmap: 1.0 launch targeted for Q3 2026 ([GitHub](https://github.com/andremichelle/openDAW)) | Strong reference. A commercial license is possible if you ever want web components |
| Audacity 4.0 | Released 3 Sep 2026 with a Qt6 UI, a new clip model and the `.aup4` format ([Phoronix](https://phoronix.com/news/Audacity-4.0-Released)). GPL **[license unverified in this session]** | Reference for clip-editing UX |
| Zrythm 2 alpha | Copyleft. Moved to C++23 and Qt6/QML. Alpha released Aug 2026, unstable ([BPB](https://bedroomproducersblog.com/2026/08/06/zrythm-2-alpha/)) | Reference only |
| LMMS | GPL-2.0 ([GitHub](https://github.com/LMMS/lmms)) | Reference for pattern and piano-roll UX |
| MuseScore Studio | GPL-3.0 ([GitHub](https://github.com/musescore/MuseScore)) | Reference for notation and MusicXML |
| BespokeSynth | GPL-3.0 ([GitHub](https://github.com/BespokeSynth/BespokeSynth)) | Reference for modular design |
| Ardour | GPL **[unverified; COPYING not read]** ([GitHub](https://github.com/Ardour/ardour)) | Reference for the engine |
| Audiotool | Proprietary. Its Nexus SDK (v0.0.x) syncs project documents in real time with OAuth scopes ([docs](https://developer.audiotool.com/js-package-documentation/documents/Getting_Started.html)) | Reference for a collaboration data model |
| GridSound, Wavacity, Tenacity | **[unverified]** | Not researched |

---

## 4. On-device pitch detection and ML (the main server-cost lever)

| Item | License | Size / speed | Fit |
|---|---|---|---|
| **SwiftF0** | MIT. 14,386 parameters. "180× real time on a single laptop CPU core." Covers 46.9–2093.75 Hz. Streaming lookahead is 176 ms. Runs on ONNX Runtime. Version 0.3.0 released 25 Sep 2026 ([PyPI](https://pypi.org/project/swift-f0/), [paper](https://arxiv.org/abs/2508.18440v1)) | Tiny | **Adopt candidate.** A monophonic hum/voice pitch tracker small enough to run on-device on every platform |
| **Basic Pitch** (Spotify) | Apache-2.0. Polyphonic, note events plus pitch bends. Ships TF, CoreML, TFLite and ONNX versions ([GitHub](https://github.com/spotify/basic-pitch)). A LiteRT port is 0.84 MB, about 4.4 ms per 2 s window on a Pixel 8a GPU ([HF](https://huggingface.co/litert-community/Basic-Pitch-LiteRT)). A CoreML fp16 version can run on the Neural Engine, about 17k params ([HF](https://huggingface.co/schism-audio/basic-pitch-coreml)) | Small | **Adopt candidate** for hum-to-MIDI with note segmentation |
| CREPE (full, LiteRT) | MIT. 44.5 MB fp16. About 75 ms per frame on a Pixel 8a GPU, and the CPU path declined the graph ([HF](https://huggingface.co/litert-community/CREPE-pitch-LiteRT)) | Heavy | Avoid on mobile. The tiny variant was not evaluated |
| PESTO | **LGPL-3.0**. About 0.7 ms per ONNX call ([GitHub](https://github.com/SonyCSLParis/pesto)) | Tiny | Evaluate only after checking whether the LGPL covers the shipped weights. Prefer SwiftF0 |
| **flutter_onnxruntime 1.9.0** | MIT. Runs on Android, iOS, macOS, Windows, Linux and Web. Bundles ORT 1.28. Published 6 Oct 2026 ([pub.dev](https://pub.dev/packages/flutter_onnxruntime)) | n/a | **Adopt** as the runtime for SwiftF0 and Basic Pitch |
| LiteRT (formerly TFLite) | Renamed by Google ([blog](https://developers.googleblog.com/en/tensorflow-lite-is-now-litert/)) | n/a | Use if you need the Android GPU/NPU path |
| Demucs (HTDemucs) on device | MIT. CoreML fp16 version runs on the Neural Engine. You must implement the STFT front end yourself. Segments are 7.8 s ([HF](https://huggingface.co/schism-audio/htdemucs-coreml)) | Large | Evaluate later, iOS only. A stem-separation feature is not needed now |
| Essentia | **AGPLv3** for non-commercial use. A commercial license comes from MTG/UPF. **Models are CC BY-NC-ND 4.0** ([licensing](https://essentia.upf.edu/licensing_information.html)) | n/a | **Avoid** |
| aubio | **GPL-3.0+** ([GitHub](https://github.com/aubio/aubio)) | n/a | **Avoid** |
| pitch_detector_dart 0.0.7 | BSD-3. YIN algorithm, a port of TarsosDSP. Last published Apr 2024 ([pub.dev](https://pub.dev/packages/pitch_detector_dart)) | Pure Dart | Good for a real-time tuner preview. Too stale and too basic to replace pYIN |

---

## 5. Music theory and MIDI libraries

| Item | License | Status | Fit |
|---|---|---|---|
| mido | MIT, v1.3 ([GitHub](https://github.com/mido/mido)) | Stable | Keep (server) |
| music21 | BSD-3, v10 era ([GitHub](https://github.com/cuthbertLab/music21)) | Active | **Adopt** on the server for MusicXML export and key/chord analysis |
| tonal.js | MIT ([GitHub](https://github.com/tonaljs/tonal)) | Active | Reference for porting its logic to Dart |
| Magenta note-seq | Apache-2.0, **archived 6 May 2026** ([GitHub](https://github.com/magenta/note-seq)) | Archived | Avoid as a dependency |
| dart_midi_pro 1.0.4+2 | MIT. Reads and writes MIDI files. Last published Nov 2024 ([pub.dev](https://pub.dev/packages/dart_midi_pro)) | Stale but simple | **Adopt** for on-device `.mid` export |
| music_xml 2.10.0 | BSD-3. Parses and writes `.xml` and `.mxl`. Published Aug 2026 ([pub.dev](https://pub.dev/packages/music_xml)) | Active | **Adopt** for on-device MusicXML |
| flutter_midi_command 1.4.0 | BSD-3. USB MIDI on all 6 platforms. BLE MIDI via an add-on package (not on Linux or Web). Published 9 Oct 2026 ([pub.dev](https://pub.dev/packages/flutter_midi_command)) | Active | Evaluate for MIDI keyboard input |

---

## 6. Collaboration infrastructure

| Item | License / cost | Fit |
|---|---|---|
| Yjs | MIT. Ports exist for Rust (y-crdt/y-octo), C#, and Go, but **none for Dart** ([GitHub](https://github.com/yjs/yjs)) | Evaluate. A Dart binding would go through y-crdt plus flutter_rust_bridge **[Dart binding availability unverified]** |
| Automerge 3 | MIT. About 10× less memory than v2. Bindings for JS (WASM), Rust and C ([GitHub](https://github.com/automerge/automerge)), plus Swift, Python and Java ([site](https://automerge.org/)) | Evaluate. Would be reached through the Rust or C core via FFI |
| Cloudflare R2 | $0.015/GB-month standard or $0.01 infrequent access. Class A operations $4.50 per million, Class B $0.36 per million. **Free egress.** Free tier: 10 GB plus 1M A and 10M B operations per month ([pricing](https://developers.cloudflare.com/r2/pricing/)) | **Adopt** for Opus stems and renders |
| FFmpeg | LGPL-2.1+ unless built with `--enable-gpl` or `--enable-nonfree`. LGPL compliance means dynamic linking, a matching source tarball, and attribution ([legal](https://www.ffmpeg.org/legal.html)). **FFmpegKit was retired and archived on 2 Jul 2026.** Its successor, FFmpegKitNext, ships as source only ([GitHub](https://github.com/arthenica/ffmpeg-kit)) | Use on the server only, as an LGPL build. Avoid on the client. The `record` package's Opus output already covers capture |
| Chromaprint / AcoustID | Chromaprint is MIT, but "as a whole… LGPL 2.1" because of the FFmpeg code it includes. Building with FFTW makes it GPL, so use KissFFT or vDSP ([LICENSE](https://github.com/acoustid/chromaprint/blob/master/LICENSE.md), [README](https://github.com/acoustid/chromaprint)). The AcoustID service is free only for non-commercial use. Commercial use goes through AcoustID OÜ, with no public price ([acoustid.org](https://acoustid.org/)) | Evaluate for duplicate and re-upload detection on the server |
| ACRCloud | Usage-based (per 1k requests, per scanned hour). It has a free trial and copyright-compliance products ([acrcloud.com](https://www.acrcloud.com/pricing/)). **Price figures not published on the page [unverified]** | Evaluate if public sharing launches. Ask for a quote |
| Audible Magic | The only public small-site tier found is CopySense Basic: free, 300 transactions per day, one domain. That announcement is from **2008** and is likely outdated ([audiblemagic.com](https://www.audiblemagic.com/?p=1605)) | Enterprise sales. Not for now |

---

## Top 5 findings that affect decisions

1. **There's a license gap on Android right now.** flutter_midi_pro bundles **FluidSynth (LGPL-2.1)** on Android ([pub.dev](https://pub.dev/packages/flutter_midi_pro)). You need an LGPL notice, a FluidSynth source offer, and a replaceable `.so`. Check that it isn't statically merged into the app binary. On iOS, avoid FluidSynth: its own FAQ says App Store distribution "might be incompatible with the LGPL" ([FAQ](https://www.fluidsynth.org/wiki/LicensingFAQ/)). Your current iOS path (dart_melty_soundfont, MIT, plus flutter_pcm_sound, Unlicense) is clean. Also confirm the SoundFont you bundle is GeneralUser GS, MuseScore General or FluidR3 (MIT), and drop any Sonatina or Spitfire content.

2. **The best way to cut server cost is on-device pitch detection.** SwiftF0 (MIT, 14k params, 180× real time on one CPU core) and Basic Pitch (Apache-2.0, 0.84 MB LiteRT, with CoreML and ONNX versions) can run through **flutter_onnxruntime** (MIT, all 6 platforms, updated 6 Oct 2026). Together they could replace server-side pYIN for most analyses. Keep the server as a fallback or for heavy processing. Avoid Essentia (AGPL, NC-ND models), aubio (GPL), and PESTO (LGPL-3).

3. **One permissive native audio engine could fix three platform problems at once.** Use miniaudio (public domain/MIT-0) or flutter_soloud 5.2.0 (MIT/zlib, includes Windows) for output, and run **TinySoundFont (MIT, C)** inside the native callback through FFI. That removes the Dart-side PCM feeding (the likely iOS underrun cause), the 64-voice FluidSynth cap on Android, and the custom WASAPI code on Windows. It also removes FluidSynth from the client entirely. A Rust route (cpal plus fundsp, both permissive) is the alternative.

4. **Several dependencies have recently been archived or are being retired.** Avoid them as new dependencies:
   - Superpowered (no new licenses, shuts down 31 Jul 2027)
   - FFmpegKit (archived 2 Jul 2026)
   - sfizz (archived 21 Jun 2026)
   - Magenta note-seq (archived 6 May 2026)

5. **Reuse code only from permissive sources. GPL and AGPL projects are UX references, not code donors.**
   - **JUCE** is AGPL or commercial. Starter is free up to $20k revenue, Indie is $40/mo up to $300k. Tracktion Engine needs a second license on top.
   - **Vital** says outright that GPLv3 blocks the iOS App Store without a paid exception.
   - **openDAW** (AGPL or commercial) and **Helio** (GPL-3, already on iOS and Android) are the best UX references for a beginner DAW.
   - Permissive pieces you can actually ship: Dexed's msfa FM engine (Apache-2.0), music_xml and dart_midi_pro for on-device export, R2 for storage with free egress, and Automerge 3 or Yjs (both MIT) when collaboration arrives.

**Worth saving to memory:** HumTrack's Android path bundles FluidSynth (LGPL) through flutter_midi_pro, and Superpowered, FFmpegKit, sfizz and note-seq are all archived or being retired as of 2026.
