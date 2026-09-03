// iOS-only live synth backend — MeltySynth (dart_melty_soundfont) + real-time
// PCM output via flutter_pcm_sound.
//
// WHY: on iOS, flutter_midi_pro routes notes through AVAudioUnitSampler, which
// could not reliably SELECT instruments from our soundfonts — every channel
// fell back to the default program 0 (piano), so bass/drums/non-piano melody
// played as the wrong instrument. MeltySynth is the SAME pure-Dart engine the
// WAV export already uses, so it renders these soundfonts correctly and selects
// instruments via standard MIDI program/bank changes. Android is unaffected and
// stays on flutter_midi_pro/FluidSynth (see SynthEngine).
//
// HOW: each soundfont (main GM, 808, hip-hop, downloaded catalog slots) is its
// own Synthesizer. Notes/programs are routed to the right Synthesizer per
// channel; a single render loop sums every loaded synth's audio block and
// streams it to the speaker. Drum channels set bank 128 (MeltySynth resolves
// bank-128 presets on ANY channel, falling back to the Standard kit).
//
// Mirrors the public surface SynthEngine forwards to it: ensureLoaded, noteOn,
// noteOff, playNote (auto note-off after release), ensureDrumKitOn, playClick,
// stopAll.
//
// KNOWN LIMITATIONS / TODO:
//  - Latency: Dart render + buffered PCM feed adds ~40-90ms vs native. Fine for
//    loop playback; live pad taps feel slightly late. Tune _frames if needed.
//  - The flutter_pcm_sound calls are isolated in _startOutput/_onFeed — if the
//    installed package version's API differs, only those need adjusting.
import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;

// Float32List/Int16List/ByteData/Uint8List come via dart_melty_soundfont's
// re-export of dart:typed_data.
import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

// resetToPlaybackSession (full session reset after recording) +
// setAudioInterruptionListener (native AVAudioSession interruption events).
import 'headset.dart';
import '../looptap/music/soundfont_catalog.dart'; // isDynamicSlot, SoundfontCatalog

// WidgetsBindingObserver: the PCM feed loop must stop while the app is not in
// the foreground and the output unit must be re-primed / rebuilt on return
// (see _onFeed / didChangeAppLifecycleState).
class MeltyEngine with WidgetsBindingObserver {
  MeltyEngine._();
  static final MeltyEngine _instance = MeltyEngine._();
  factory MeltyEngine() => _instance;

  // SAME soundfont as Android (SynthEngine._sfAsset) so iOS and Android sound
  // the same — MeltySynth renders GeneralUser-GS correctly (AVAudioUnitSampler
  // could not, which is why we left flutter_midi_pro). Note: it's 31MB, so the
  // one-time parse on first load is heavier; pre-warm ensureLoaded behind a
  // loading state if first-play jank shows up.
  static const String _sfAsset = 'assets/sounds/GeneralUser-GS.sf2';
  static const String _sf808Asset = 'assets/sounds/808.sf2';
  static const String _sfHipHopAsset = 'assets/sounds/hiphop_kit.sf2';

  // Sentinels mirror SynthEngine (kept in sync intentionally).
  static const int program808 = 128; // 808 sub-bass → 808.sf2
  static const int kitHipHop = 200; // hip-hop kit → hiphop_kit.sf2
  static const int drumChannel = 9;
  static const int clickChannel = 15;

  static const int _sampleRate = 44100;
  // PCM render block. ~23ms @44.1k. Render granularity + pad-tap latency floor.
  static const int _frames = 1024;

  // How deep to keep flutter_pcm_sound's native ring buffer, in frames.
  //
  // The native output pulls on the REAL-TIME audio thread but is refilled via a
  // MAIN-THREAD method-channel round-trip (RenderCallback → OnFeedSamples →
  // _onFeed → feed). If the main thread stalls longer than the buffer holds, it
  // underruns and emits silence mid-waveform = the crackle. At idle this is
  // inaudible (the buffer holds silence anyway), which is why pre-recording
  // sounds clean; while RECORDING the refill slips (the session flips to
  // .playAndRecord → smaller hardware IO buffer pulled more often, plus extra
  // platform-thread traffic from the capture pipeline) so a thin buffer starves
  // → audible crackle. A deep cushion absorbs the slip whatever its exact cause.
  //
  // Idle/normal: shallow, so live pad taps stay responsive.
  // Recording window: deep cushion — no live taps happen, so the latency the
  // depth adds is irrelevant, and it survives multi-block main-thread stalls.
  static const int _idleThreshold = 1024;
  static const int _idleTarget = 2048; // ~46ms
  static const int _recThreshold = 4096; // signal refill with ~93ms still buffered
  static const int _recTarget = 8192; // ~186ms cushion against main-thread stalls
  int _targetFrames = _idleTarget;

  // Master makeup gain applied before the soft limiter. MeltySynth renders well
  // below full scale (a single track peaks ~0.2-0.3), so the raw mono mix was
  // noticeably quiet on iOS. ~1.5× (+3.5dB) lifts the body; the tanh limiter
  // below keeps peaks from clipping when several tracks/synths sum past 1.0.
  static const double _masterGain = 1.5;

  // ── lifecycle / interruption state (audit A1/A2) ──────────────────────
  // Category the output unit was last built under — recovery rebuilds under
  // the same one so a rebuild mid-recording keeps capture alive.
  bool _forRecording = false;
  // App not in the foreground: _onFeed is a no-op. Without this the native
  // side answers every feed with OnFeedSamples(0) while inactive (it drops the
  // buffer), and _onFeed → feed → OnFeedSamples(0) → _onFeed spins the main
  // thread (Control Center pull-down, lock screen, app switcher).
  bool _feedPaused = false;
  // Output unit must be recreated before feeding again (real background,
  // AVAudioSession interruption began, feed error). Gates _onFeed too.
  bool _needsRebuild = false;
  bool _recovering = false;
  int _recoverFailures = 0;
  static const int _maxRecoverFailures = 3;
  DateTime _lastRecoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _recoverBackoff = Duration(seconds: 1);
  Timer? _recoverRetry;

  Synthesizer? _main;
  Synthesizer? _s808;
  Synthesizer? _hiphop;
  final Map<int, Synthesizer> _slots = <int, Synthesizer>{}; // catalog slot → synth

  Future<void>? _loading;
  final Map<int, Future<Synthesizer>?> _loadingSlot = <int, Future<Synthesizer>?>{};
  bool _outputStarted = false;

  // channel → synth it's currently bound to (so noteOff/notes go to the right
  // instance) and a cache of the last program selected on that channel.
  final Map<int, Synthesizer> _channelSynth = <int, Synthesizer>{};
  final Map<int, int> _channelProgram = <int, int>{};

  // Channels the app has designated as drums via ensureDrumKitOn (plus the base
  // drum channel 9). noteOn must NEVER re-bind these as melodic: kit and GM
  // program numbers overlap (kit 0 == GM piano 0), so the channel — not the
  // program value — is the only reliable disambiguator.
  final Set<int> _drumChannels = <int>{drumChannel};

  // (channel, pitch) → scheduled release timer (for playNote auto note-off).
  final Map<int, Map<int, Timer>> _activeReleases = <int, Map<int, Timer>>{};

  // Reusable render scratch (avoid per-callback allocation).
  final Float32List _bl = Float32List(_frames);
  final Float32List _br = Float32List(_frames);
  final Float32List _acc = Float32List(_frames);
  final Int16List _out = Int16List(_frames);

  bool get isLoaded => _main != null;

  // ── loading ──────────────────────────────────────────────────────────
  Future<void> ensureLoaded() => _loading ??= _init();

  Future<void> _init() async {
    try {
      _main = await _loadSynth(_sfAsset);
      await _startOutput();
    } catch (e) {
      _loading = null; // allow retry
      debugPrint('[melty] init failed: $e');
      rethrow;
    }
  }

  Future<Synthesizer> _loadSynth(String asset) async {
    final bd = await rootBundle.load(asset);
    final bytes = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    return Synthesizer.loadByteData(
      ByteData.sublistView(bytes),
      SynthesizerSettings(sampleRate: _sampleRate, enableReverbAndChorus: true),
    );
  }

  Future<Synthesizer> _ensure808() async =>
      _s808 ??= await _loadSynth(_sf808Asset);

  Future<Synthesizer> _ensureHipHop() async =>
      _hiphop ??= await _loadSynth(_sfHipHopAsset);

  /// A downloaded catalog soundfont (slot >= 1000), or null when its file isn't
  /// present yet / fails to load.
  Future<Synthesizer?> _ensureSlot(int slot) async {
    if (_slots.containsKey(slot)) return _slots[slot];
    final path = SoundfontCatalog.instance.localPath(slot);
    if (path == null) return null;
    try {
      final s = await (_loadingSlot[slot] ??= () async {
        final bytes = await File(path).readAsBytes();
        return Synthesizer.loadByteData(
          ByteData.sublistView(bytes),
          SynthesizerSettings(sampleRate: _sampleRate, enableReverbAndChorus: true),
        );
      }());
      _slots[slot] = s;
      return s;
    } catch (e) {
      _loadingSlot[slot] = null;
      debugPrint('[melty] slot $slot load failed: $e');
      return null;
    }
  }

  // ── real-time output (flutter_pcm_sound) ──────────────────────────────
  // All package-specific calls live here; adjust only this block if the
  // installed flutter_pcm_sound version exposes a different API.
  Future<void> _startOutput() async {
    if (_outputStarted) return;
    _outputStarted = true;
    await FlutterPcmSound.setLogLevel(LogLevel.none); // silence per-feed [PCM] spam
    await FlutterPcmSound.setup(sampleRate: _sampleRate, channelCount: 1);
    _targetFrames = _idleTarget;
    _forRecording = false;
    FlutterPcmSound.setFeedThreshold(_idleThreshold);
    FlutterPcmSound.setFeedCallback(_onFeed);
    // Lifecycle gate + native interruption events (iOS). Registered once.
    WidgetsBinding.instance.addObserver(this);
    final st = WidgetsBinding.instance.lifecycleState;
    _feedPaused = st != null && st != AppLifecycleState.resumed;
    setAudioInterruptionListener(_onAudioInterruption);
    FlutterPcmSound.start(); // returns bool (not a Future) in this version
  }

  // ── lifecycle / interruption recovery ─────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _feedPaused = false;
      if (_needsRebuild) {
        _scheduleRecover('resumed');
      } else {
        // Native dropped its ring buffer while inactive and the feed loop is
        // idle (no OnFeedSamples will come) — kick it once. Harmless if the
        // loop is still running: it just tops the buffer up.
        _onFeed(0);
      }
      return;
    }
    _feedPaused = true;
    if (state != AppLifecycleState.inactive) {
      // paused / hidden / detached: the RemoteIO unit gets stopped underneath
      // us and the session may be interrupted — recreate it on return.
      _needsRebuild = true;
    }
  }

  // AppDelegate.swift forwards AVAudioSession.interruptionNotification. On
  // `began` the system has stopped our audio unit; on `ended` with
  // shouldResume the native side re-activated the session and we rebuild +
  // re-prime right away. Ended WITHOUT shouldResume (another app kept the
  // audio): stay silent until the next user-driven note (see _touchOutput) so
  // we don't barge in over the other app.
  void _onAudioInterruption(AudioInterruptionEvent ev) {
    if (ev.began) {
      _needsRebuild = true;
      return;
    }
    if (ev.shouldResume) {
      _scheduleRecover('interruption ended');
    } else {
      _needsRebuild = true;
    }
  }

  // User-driven sound request while the output is flagged dead → recover now.
  void _touchOutput() {
    if (_needsRebuild && !_feedPaused) _scheduleRecover('note');
  }

  /// Rebuild the output unit (release → setup under the current category →
  /// prime) at most once per [_recoverBackoff]; a request inside the window
  /// is retried once the window closes, and repeated failures give up until
  /// the next external trigger (resume / interruption end / note).
  void _scheduleRecover(String reason) {
    _needsRebuild = true;
    if (!_outputStarted || _feedPaused || _recovering) return;
    if (_recoverFailures >= _maxRecoverFailures) return;
    final wait = _recoverBackoff - DateTime.now().difference(_lastRecoverAt);
    if (wait > Duration.zero) {
      _recoverRetry ??= Timer(wait, () {
        _recoverRetry = null;
        if (_needsRebuild) _scheduleRecover('$reason/backoff');
      });
      return;
    }
    _lastRecoverAt = DateTime.now();
    _recovering = true;
    _recover(reason).whenComplete(() => _recovering = false);
  }

  Future<void> _recover(String reason) async {
    debugPrint('[melty] recover output ($reason) forRecording=$_forRecording');
    try {
      await FlutterPcmSound.release();
      await FlutterPcmSound.setup(
        sampleRate: _sampleRate,
        channelCount: 1,
        iosAudioCategory: _forRecording
            ? IosAudioCategory.playAndRecord
            : IosAudioCategory.playback,
      );
      _targetFrames = _forRecording ? _recTarget : _idleTarget;
      FlutterPcmSound.setFeedThreshold(_forRecording ? _recThreshold : _idleThreshold);
      FlutterPcmSound.setFeedCallback(_onFeed);
      _needsRebuild = false;
      _recoverFailures = 0;
      _onFeed(0); // prime — restarts the native feed loop
    } catch (e) {
      _recoverFailures += 1;
      debugPrint('[melty] recover failed ($_recoverFailures): $e');
      if (_recoverFailures < _maxRecoverFailures) _scheduleRecover('retry');
    }
  }

  /// Rebuild the PCM output unit under the CURRENT shared audio session.
  ///
  /// WHY: starting/stopping recording flips the process-wide AVAudioSession
  /// (.playback ↔ .playAndRecord), which renegotiates the hardware IO underneath
  /// our already-running RemoteIO unit and corrupts it (crackle during AND after
  /// recording). flutter_pcm_sound has no route-change observer to re-sync, so we
  /// tear the unit down and recreate it against the new session at the record
  /// lifecycle boundaries (driven from hum_modal). The synths themselves are
  /// untouched — only the output pipe is rebuilt.
  ///
  /// [forRecording] picks the category the new unit is born under:
  ///   true  → .playAndRecord — rebuild WHILE recording (keeps capture alive)
  ///   false → .playback      — rebuild AFTER recording (restores normal output)
  ///
  /// We deliberately do NOT call FlutterPcmSound.start() to resume: its second
  /// call is a no-op because of a stale internal _needsStart flag (this is why
  /// earlier restart attempts went silent). Instead we prime the loop directly
  /// with one render block — that feed kicks AudioOutputUnitStart inside the
  /// native feed handler, which is what start() was supposed to do.
  Future<void> rebuildOutput({required bool forRecording}) async {
    if (!_outputStarted) {
      debugPrint('[rebuild] SKIP — output not started');
      return; // output never started — nothing to rebuild
    }
    debugPrint('[rebuild] start forRecording=$forRecording '
        'hwRate(before)=${await outputSampleRate()}');
    await FlutterPcmSound.release();
    if (!forRecording) {
      // Output unit is released; now force a clean session reset. Flipping the
      // category alone leaves recording's duplex hardware IO in place (output
      // keeps crackling after); a full deactivate→.playback→reactivate
      // renegotiates the IO from scratch. (.playAndRecord case skips this — it
      // must stay active to keep recording alive.)
      await resetToPlaybackSession();
      debugPrint('[rebuild] after session reset hwRate=${await outputSampleRate()}');
    }
    await FlutterPcmSound.setup(
      sampleRate: _sampleRate,
      channelCount: 1,
      iosAudioCategory: forRecording
          ? IosAudioCategory.playAndRecord
          : IosAudioCategory.playback,
    );
    // Deep buffer while recording (survives main-thread stalls = no crackle),
    // shallow again after (responsive pad taps).
    _targetFrames = forRecording ? _recTarget : _idleTarget;
    _forRecording = forRecording;
    FlutterPcmSound.setFeedThreshold(forRecording ? _recThreshold : _idleThreshold);
    FlutterPcmSound.setFeedCallback(_onFeed);
    // A fresh unit supersedes any pending recovery.
    _recoverRetry?.cancel();
    _recoverRetry = null;
    _needsRebuild = false;
    _recoverFailures = 0;
    _onFeed(0); // manual prime — bypasses the _needsStart no-op in start()
    debugPrint('[rebuild] done forRecording=$forRecording '
        'hwRate(after)=${await outputSampleRate()}');
  }

  // Called by flutter_pcm_sound whenever its buffer drops below the threshold.
  // Top the native ring buffer back up to _targetFrames — feeding SEVERAL blocks
  // per callback when deep — so a main-thread stall between refills can't drain
  // it to silence (that underrun is the crackle). At idle this feeds one block.
  //
  // No-op while the app is not in the foreground or the unit is flagged for
  // rebuild — otherwise the native inactive-path (OnFeedSamples(0) for every
  // feed) turns this into a main-thread render storm (audit A2).
  void _onFeed(int remainingFrames) {
    if (_main == null || _feedPaused || _needsRebuild) return;
    var depth = remainingFrames;
    do {
      _renderBlock();
      _feed(PcmArrayInt16.fromList(_out)); // fromList copies _out
      depth += _frames;
    } while (depth < _targetFrames);
  }

  // feed() is fire-and-forget on the hot path; a failure (AudioOutputUnitStart
  // after an interruption, "must call setup first" after a stale release)
  // means the unit is dead → recover once (backoff-limited) instead of
  // surfacing an unhandled async error on every block.
  void _feed(PcmArrayInt16 buf) {
    FlutterPcmSound.feed(buf).catchError((Object e) {
      debugPrint('[melty] feed failed: $e');
      _scheduleRecover('feed error');
    });
  }

  // Render one _frames block: sum every loaded synth to mono Int16 in _out.
  void _renderBlock() {
    final main = _main!;
    for (var i = 0; i < _frames; i++) {
      _acc[i] = 0.0;
    }
    _mixSynth(main);
    if (_s808 != null) _mixSynth(_s808!);
    if (_hiphop != null) _mixSynth(_hiphop!);
    for (final s in _slots.values) {
      _mixSynth(s);
    }
    for (var i = 0; i < _frames; i++) {
      // Boost, then soft-limit with tanh: small signals stay ~linear (×gain, so
      // louder), peaks saturate smoothly toward ±1 instead of clipping hard.
      // This also makes overall loudness more consistent — loud passes are gently
      // compressed rather than jumping in level. Output can never exceed ±1.
      final v = _tanh(_acc[i] * _masterGain);
      _out[i] = (v < 0 ? v * 32768 : v * 32767).round();
    }
  }

  // tanh soft clipper. dart:math has no tanh, so compute it from exp; clamp the
  // argument to avoid exp overflow (tanh(±4) ≈ ±0.9993, already at the rail).
  static double _tanh(double x) {
    if (x > 4.0) return 1.0;
    if (x < -4.0) return -1.0;
    final e = math.exp(2.0 * x);
    return (e - 1.0) / (e + 1.0);
  }

  void _mixSynth(Synthesizer s) {
    s.render(_bl, _br);
    for (var i = 0; i < _frames; i++) {
      _acc[i] += (_bl[i] + _br[i]) * 0.5; // stereo → mono
    }
  }

  // ── instrument routing ────────────────────────────────────────────────
  // Point [channel] at synth [s]. When the channel moves to a DIFFERENT synth
  // (808 ↔ GM, catalog slot ↔ GM, kit swaps), release every note still
  // sounding on the previous synth's channel first — noteOff would otherwise
  // go to the new synth and the old voices would ring forever (audit A9).
  void _bindSynth(int channel, Synthesizer s) {
    final prev = _channelSynth[channel];
    if (prev != null && !identical(prev, s)) {
      prev.noteOffAll(channel: channel); // natural release, not a hard cut
    }
    _channelSynth[channel] = s;
  }

  // Bind a melodic channel to the synth/preset for [program] and return it.
  // program == null keeps the existing binding (per-note sequencer calls).
  Future<Synthesizer> _bindMelodic(int channel, int? program) async {
    final main = _main!;
    if (program == null) return _channelSynth[channel] ?? main;
    if (program == program808) {
      final s = await _ensure808();
      if (_channelProgram[channel] != program808) {
        _programChange(s, channel, 0); // 808's single preset (default bank 0)
        _channelProgram[channel] = program808;
      }
      _bindSynth(channel, s);
      return s;
    }
    if (isDynamicSlot(program)) {
      final s = await _ensureSlot(program);
      if (s != null) {
        final entry = SoundfontCatalog.instance.bySlot(program);
        final marker = 100000 + program;
        if (_channelProgram[channel] != marker) {
          _selectWithBank(s, channel,
              bank: entry?.sfBank ?? 0, program: entry?.sfProgram ?? 0);
          _channelProgram[channel] = marker;
        }
        _bindSynth(channel, s);
        return s;
      }
      // not downloaded / failed → fall back to grand piano so it still sounds.
      _selectGm(main, channel, 0);
      _bindSynth(channel, main);
      return main;
    }
    _selectGm(main, channel, program);
    _bindSynth(channel, main);
    return main;
  }

  void _selectGm(Synthesizer s, int channel, int program) {
    if (_channelSynth[channel] == s && _channelProgram[channel] == program) return;
    _programChange(s, channel, program); // melodic: default bank 0 (matches buildMidi)
    _channelProgram[channel] = program;
  }

  // The WAV export (buildMidi) drives MeltySynth with program changes ONLY and
  // relies on each channel's default bank (0 melodic / 128 on percussion ch9) —
  // and it renders correctly. Mirror that: _programChange for the default-bank
  // cases, _selectWithBank only where the bank truly differs (catalog
  // soundfonts, or forcing 128 on a NON-percussion drum channel).
  void _programChange(Synthesizer s, int channel, int program) {
    s.processMidiMessage(channel: channel, command: 0xC0, data1: program & 0x7f, data2: 0);
  }

  void _selectWithBank(Synthesizer s, int channel, {required int bank, required int program}) {
    s.processMidiMessage(channel: channel, command: 0xB0, data1: 0x00, data2: bank);
    s.processMidiMessage(channel: channel, command: 0xC0, data1: program & 0x7f, data2: 0);
  }

  /// Bind a (drum) channel to a kit. GM kits live in bank 128 of the main SF2;
  /// the hip-hop / catalog kits are their own soundfonts. Mirrors
  /// SynthEngine.ensureDrumKitOn.
  Future<void> ensureDrumKitOn(int channel, int program) async {
    await ensureLoaded();
    _drumChannels.add(channel); // remember: this channel plays drums, not melody
    final marker = 1000 + program;
    if (_channelProgram[channel] == marker) return;
    Synthesizer s;
    int prog;
    if (program == kitHipHop) {
      s = await _ensureHipHop();
      prog = 0;
    } else if (isDynamicSlot(program)) {
      final d = await _ensureSlot(program);
      if (d != null) {
        s = d;
        prog = 0;
      } else {
        s = _main!;
        prog = 0; // catalog kit not downloaded → GM Standard kit
      }
    } else {
      s = _main!;
      prog = program; // GM kit number
    }
    // ch9 is already percussion (default bank 128) — just send the kit program,
    // exactly like buildMidi (the working export path). A NON-percussion drum
    // channel (beat-fill / added drum track) needs bank 128 forced so MeltySynth
    // resolves a percussion preset there (falls back to Standard kit 128:0).
    if (channel == drumChannel) {
      _programChange(s, channel, prog);
    } else {
      _selectWithBank(s, channel, bank: 128, program: prog);
    }
    _channelProgram[channel] = marker;
    _bindSynth(channel, s);
  }

  Future<void> ensureDrumKit(int program) => ensureDrumKitOn(drumChannel, program);

  // ── playback ────────────────────────────────────────────────────────
  Future<void> noteOn({
    required int channel,
    required int pitch,
    int velocity = 100,
    int? program,
  }) async {
    await ensureLoaded();
    _touchOutput();
    final Synthesizer s;
    if (_drumChannels.contains(channel)) {
      // A drum channel: any non-null program is a KIT, not a GM melodic program.
      if (program != null) await ensureDrumKitOn(channel, program);
      s = _channelSynth[channel] ?? _main!;
    } else {
      s = await _bindMelodic(channel, program);
    }
    s.noteOn(channel: channel, key: pitch.clamp(0, 127), velocity: velocity.clamp(1, 127));
  }

  Future<void> noteOff({required int channel, required int pitch}) async {
    final s = _channelSynth[channel] ?? _main;
    s?.noteOff(channel: channel, key: pitch.clamp(0, 127));
  }

  /// Play a note that auto-stops after [release] (single-tap preview / grid).
  Future<void> playNote({
    int channel = 0,
    required int pitch,
    int velocity = 100,
    int program = 0,
    Duration release = const Duration(milliseconds: 600),
  }) async {
    final p = pitch.clamp(0, 127);
    _cancelRelease(channel, p);
    await noteOn(channel: channel, pitch: p, velocity: velocity, program: program);
    final timer = Timer(release, () {
      noteOff(channel: channel, pitch: p);
      _activeReleases[channel]?.remove(p);
    });
    (_activeReleases[channel] ??= <int, Timer>{})[p] = timer;
  }

  void _cancelRelease(int channel, int pitch) {
    _activeReleases[channel]?.remove(pitch)?.cancel();
  }

  /// Metronome wood-block on a dedicated channel (GM program 115), kept off the
  /// drum channel so it never disturbs the selected kit.
  Future<void> playClick(bool accent) async {
    try {
      await ensureLoaded();
      _touchOutput();
      final s = _main!;
      _selectGm(s, clickChannel, 115); // GM Wood Block
      final pitch = accent ? 84 : 79;
      s.noteOn(channel: clickChannel, key: pitch, velocity: accent ? 100 : 66);
      Timer(const Duration(milliseconds: 110), () {
        s.noteOff(channel: clickChannel, key: pitch);
      });
    } catch (_) {/* not loaded yet — fire-and-forget */}
  }

  /// Cancel all release timers and silence every channel on every synth.
  Future<void> stopAll() async {
    for (final m in _activeReleases.values) {
      for (final t in m.values) {
        t.cancel();
      }
      m.clear();
    }
    for (final s in [
      if (_main != null) _main!,
      if (_s808 != null) _s808!,
      if (_hiphop != null) _hiphop!,
      ..._slots.values,
    ]) {
      s.noteOffAll(immediate: true);
    }
  }
}
