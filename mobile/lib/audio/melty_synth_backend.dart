// Shared iOS/macOS/Windows live synth — MeltySynth + real-time PCM output.
// PcmOutput preserves flutter_pcm_sound on Apple and uses WASAPI on Windows.
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
// streams it to the speaker as interleaved STEREO Int16 (mixer-001: track pan
// is CC10 on the channel, rendered by the synth itself). Drum channels set bank 128 (MeltySynth resolves
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
import 'dart:io' show File, Platform;
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
import 'pcm_output.dart';
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
  // Interleaved L/R output (mixer-001). Before pan existed the synth's stereo
  // was folded to mono; a centred voice has L == R, so it sounds the same.
  static const int _channels = 2;
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
  static const int _recThreshold =
      4096; // signal refill with ~93ms still buffered
  static const int _recTarget =
      8192; // ~186ms cushion against main-thread stalls
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
  // Output-unit release/setup sequences (rebuildOutput, _recover) must never
  // interleave: two overlapping rebuilds could leave the unit in the wrong
  // session category with _forRecording/_targetFrames out of step.
  Future<void> _outputOps = Future<void>.value();

  Future<void> _serialOutput(Future<void> Function() op) {
    final next = _outputOps.then((_) => op());
    _outputOps = next.catchError((Object _) {});
    return next;
  }
  int _recoverFailures = 0;
  static const int _maxRecoverFailures = 3;
  DateTime _lastRecoverAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _recoverBackoff = Duration(seconds: 1);
  Timer? _recoverRetry;

  Synthesizer? _main;
  Synthesizer? _s808;
  Synthesizer? _hiphop;
  final Map<int, Synthesizer> _slots =
      <int, Synthesizer>{}; // catalog slot → synth

  Future<void>? _loading;
  final Map<int, Future<Synthesizer>?> _loadingSlot =
      <int, Future<Synthesizer>?>{};
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
  final Map<int, int> _channelEpoch = {};
  final Map<int, int> _noteEpoch = {};
  final Map<int, Map<int, Timer>> _activeReleases = <int, Map<int, Timer>>{};

  // mixer-001: last CC10 value per channel. Re-sent whenever the channel is
  // bound to a different synth (instrument swap to 808 / catalog / kit font),
  // and to the main synth once it loads.
  final Map<int, int> _channelPan = <int, int>{};

  // Reusable render scratch (avoid per-callback allocation).
  final Float32List _bl = Float32List(_frames);
  final Float32List _br = Float32List(_frames);
  final Float32List _accL = Float32List(_frames);
  final Float32List _accR = Float32List(_frames);
  final Int16List _out = Int16List(_frames * _channels);

  bool get isLoaded => _main != null && _outputStarted;

  // ── loading ──────────────────────────────────────────────────────────
  Future<void> ensureLoaded() => _loading ??= _init();

  Future<void> _init() async {
    try {
      final main = _main = await _loadSynth(_sfAsset);
      for (final e in _channelPan.entries) {
        if (_channelSynth[e.key] == null) _sendPan(main, e.key, e.value);
      }
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
      final s =
          await (_loadingSlot[slot] ??= () async {
            final bytes = await File(path).readAsBytes();
            return Synthesizer.loadByteData(
              ByteData.sublistView(bytes),
              SynthesizerSettings(
                sampleRate: _sampleRate,
                enableReverbAndChorus: true,
              ),
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
    await PcmOutput.setLogLevel(LogLevel.none); // silence per-feed [PCM] spam
    await PcmOutput.setup(sampleRate: _sampleRate, channelCount: _channels);
    _outputStarted = true;
    _targetFrames = _idleTarget;
    _forRecording = false;
    PcmOutput.setFeedThreshold(_idleThreshold);
    PcmOutput.setFeedCallback(_onFeed);
    // Lifecycle gate + native interruption events (iOS). Registered once.
    WidgetsBinding.instance.addObserver(this);
    final st = WidgetsBinding.instance.lifecycleState;
    _feedPaused = st != null && st != AppLifecycleState.resumed;
    setAudioInterruptionListener(_onAudioInterruption);
    PcmOutput.start(); // returns bool (not a Future) in this version
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
    if ((Platform.isWindows || Platform.isMacOS) &&
        state == AppLifecycleState.inactive) {
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
    _serialOutput(() => _recover(reason)).whenComplete(() => _recovering = false);
  }

  Future<void> _recover(String reason) async {
    debugPrint('[melty] recover output ($reason) forRecording=$_forRecording');
    try {
      await PcmOutput.release();
      await PcmOutput.setup(
        sampleRate: _sampleRate,
        channelCount: _channels,
        iosAudioCategory:
            _forRecording
                ? IosAudioCategory.playAndRecord
                : IosAudioCategory.playback,
      );
      _targetFrames = _forRecording ? _recTarget : _idleTarget;
      PcmOutput.setFeedThreshold(
        _forRecording ? _recThreshold : _idleThreshold,
      );
      PcmOutput.setFeedCallback(_onFeed);
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
  /// We deliberately do NOT call PcmOutput.start() to resume: its second
  /// call is a no-op because of a stale internal _needsStart flag (this is why
  /// earlier restart attempts went silent). Instead we prime the loop directly
  /// with one render block — that feed kicks AudioOutputUnitStart inside the
  /// native feed handler, which is what start() was supposed to do.
  Future<void> rebuildOutput({required bool forRecording}) =>
      _serialOutput(() => _rebuildOutput(forRecording));

  Future<void> _rebuildOutput(bool forRecording) async {
    if (!_outputStarted) {
      debugPrint('[rebuild] SKIP — output not started');
      return; // output never started — nothing to rebuild
    }
    debugPrint(
      '[rebuild] start forRecording=$forRecording '
      'hwRate(before)=${await outputSampleRate()}',
    );
    await PcmOutput.release();
    if (!forRecording) {
      // Output unit is released; now force a clean session reset. Flipping the
      // category alone leaves recording's duplex hardware IO in place (output
      // keeps crackling after); a full deactivate→.playback→reactivate
      // renegotiates the IO from scratch. (.playAndRecord case skips this — it
      // must stay active to keep recording alive.)
      await resetToPlaybackSession();
      debugPrint(
        '[rebuild] after session reset hwRate=${await outputSampleRate()}',
      );
    }
    await PcmOutput.setup(
      sampleRate: _sampleRate,
      channelCount: _channels,
      iosAudioCategory:
          forRecording
              ? IosAudioCategory.playAndRecord
              : IosAudioCategory.playback,
    );
    // Deep buffer while recording (survives main-thread stalls = no crackle),
    // shallow again after (responsive pad taps).
    _targetFrames = forRecording ? _recTarget : _idleTarget;
    _forRecording = forRecording;
    PcmOutput.setFeedThreshold(forRecording ? _recThreshold : _idleThreshold);
    PcmOutput.setFeedCallback(_onFeed);
    // A fresh unit supersedes any pending recovery.
    _recoverRetry?.cancel();
    _recoverRetry = null;
    _needsRebuild = false;
    _recoverFailures = 0;
    _onFeed(0); // manual prime — bypasses the _needsStart no-op in start()
    debugPrint(
      '[rebuild] done forRecording=$forRecording '
      'hwRate(after)=${await outputSampleRate()}',
    );
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
    PcmOutput.feed(buf).catchError((Object e) {
      debugPrint('[melty] feed failed: $e');
      _scheduleRecover('feed error');
    });
  }

  // Render one _frames block: sum every loaded synth into interleaved stereo
  // Int16 in _out (L0 R0 L1 R1 ...).
  void _renderBlock() {
    final main = _main!;
    for (var i = 0; i < _frames; i++) {
      _accL[i] = 0.0;
      _accR[i] = 0.0;
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
      // Same gain + limiter on each channel, so a centred sound keeps its level.
      _out[2 * i] = pcm16(_accL[i] * _masterGain);
      _out[2 * i + 1] = pcm16(_accR[i] * _masterGain);
    }
  }

  /// Soft-limit one (pre-gain-applied) sample to Int16. Non-finite input
  /// (a NaN from a misbehaving voice) maps to silence: `NaN.round()` throws,
  /// and a throw inside the feed callback would silence output for good.
  @visibleForTesting
  static int pcm16(double x) {
    if (!x.isFinite) return 0;
    final v = _tanh(x);
    return (v < 0 ? v * 32768 : v * 32767).round();
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
      _accL[i] += _bl[i];
      _accR[i] += _br[i];
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
    if (!identical(prev, s)) {
      // mixer-001: the new synth has never heard this channel's pan.
      final pan = _channelPan[channel];
      if (pan != null) _sendPan(s, channel, pan);
    }
    _channelSynth[channel] = s;
  }

  void _sendPan(Synthesizer s, int channel, int value) {
    s.processMidiMessage(
      channel: channel,
      command: 0xB0,
      data1: 0x0A,
      data2: value & 0x7f,
    );
  }

  /// Send a MIDI control change to the synth [channel] is bound to (the main
  /// GM synth until it is bound elsewhere). CC10 (pan) is remembered and
  /// re-sent when the channel moves to another soundfont's synth.
  void controlChange(int channel, int controller, int value) {
    final v = value.clamp(0, 127);
    if (controller == 0x0A) _channelPan[channel] = v;
    final s = _channelSynth[channel] ?? _main;
    if (s == null) return; // not loaded yet — pan is re-sent on load / bind
    s.processMidiMessage(
      channel: channel,
      command: 0xB0,
      data1: controller & 0x7f,
      data2: v,
    );
  }

  /// Test hooks: install a (fake) main synth and bind a channel directly.
  @visibleForTesting
  void debugSetMain(Synthesizer? s) => _main = s;

  @visibleForTesting
  void debugBind(int channel, Synthesizer s) => _bindSynth(channel, s);

  @visibleForTesting
  void debugReset() {
    _main = null;
    _loading = null;
    _channelSynth.clear();
    _channelPan.clear();
    _channelProgram.clear();
    _drumChannels
      ..clear()
      ..add(drumChannel);
    _roleGen.clear();
  }

  /// Test hook: use [s] as the loaded GM synth (no asset load, no output),
  /// so noteOn/noteOff/ensureDrumKitOn run their real routing on it.
  @visibleForTesting
  void debugInstallMain(Synthesizer s, {Future<void>? loading}) {
    _main = s;
    _loading = loading ?? Future<void>.value();
  }

  // gt-003: role generation per channel, bumped only by releaseChannel (a
  // Stop must not cancel a kit/program set-up, a role switch must).
  final Map<int, int> _roleGen = <int, int>{};

  /// Test hook: whether [channel] is currently routed as a drum channel.
  @visibleForTesting
  bool debugIsDrumChannel(int channel) => _drumChannels.contains(channel);

  /// gt-003 channel-role switch: forget everything [channel] carried for its
  /// previous role (drum membership, kit/program cache, pan, synth binding)
  /// and reset it on every synth: voices cut, controllers reset, bank 0,
  /// program 0. The next noteOn/ensureDrumKitOn sets the new role up from
  /// scratch. The base drum channel (9) stays percussion.
  void releaseChannel(int channel) {
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    _roleGen[channel] = (_roleGen[channel] ?? 0) + 1;
    for (final timer in _activeReleases.remove(channel)?.values ?? <Timer>[]) {
      timer.cancel();
    }
    if (channel != drumChannel) _drumChannels.remove(channel);
    _channelProgram.remove(channel);
    _channelPan.remove(channel);
    _channelSynth.remove(channel);
    for (final s in {_main, _s808, _hiphop, ..._slots.values}) {
      if (s == null) continue;
      s.noteOffAll(channel: channel, immediate: true);
      s.processMidiMessage(
        channel: channel,
        command: 0xB0,
        data1: 0x79, // reset all controllers (volume 100, pan centre)
        data2: 0,
      );
      s.processMidiMessage(
        channel: channel,
        command: 0xB0,
        data1: 0x00, // bank 0
        data2: 0,
      );
      _programChange(s, channel, 0);
    }
  }

  /// Interleaved stereo render of one block with [main] as the GM synth (test
  /// hook: L/R kept apart, same gain + limiter per channel).
  @visibleForTesting
  Int16List debugRenderBlock(Synthesizer main) {
    final prev = _main;
    _main = main;
    try {
      _renderBlock();
      return Int16List.fromList(_out);
    } finally {
      _main = prev;
    }
  }

  // Bind a melodic channel to the synth/preset for [program] and return it.
  // program == null keeps the existing binding (per-note sequencer calls).
  // Returns null when the channel changed role (releaseChannel) while a
  // soundfont was loading: the late completion must not bind anything.
  Future<Synthesizer?> _bindMelodic(int channel, int? program) async {
    final main = _main!;
    if (program == null) return _channelSynth[channel] ?? main;
    final gen = _roleGen[channel] ?? 0;
    if (program == program808) {
      final s = await _ensure808();
      if ((_roleGen[channel] ?? 0) != gen) return null;
      if (_channelProgram[channel] != program808) {
        _programChange(s, channel, 0); // 808's single preset (default bank 0)
        _channelProgram[channel] = program808;
      }
      _bindSynth(channel, s);
      return s;
    }
    if (isDynamicSlot(program)) {
      final s = await _ensureSlot(program);
      if ((_roleGen[channel] ?? 0) != gen) return null;
      if (s != null) {
        final entry = SoundfontCatalog.instance.bySlot(program);
        final marker = 100000 + program;
        if (_channelProgram[channel] != marker) {
          _selectWithBank(
            s,
            channel,
            bank: entry?.sfBank ?? 0,
            program: entry?.sfProgram ?? 0,
          );
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
    if (_channelSynth[channel] == s && _channelProgram[channel] == program) {
      return;
    }
    _programChange(
      s,
      channel,
      program,
    ); // melodic: default bank 0 (matches buildMidi)
    _channelProgram[channel] = program;
  }

  // The WAV export (buildMidi) drives MeltySynth with program changes ONLY and
  // relies on each channel's default bank (0 melodic / 128 on percussion ch9) —
  // and it renders correctly. Mirror that: _programChange for the default-bank
  // cases, _selectWithBank only where the bank truly differs (catalog
  // soundfonts, or forcing 128 on a NON-percussion drum channel).
  void _programChange(Synthesizer s, int channel, int program) {
    s.processMidiMessage(
      channel: channel,
      command: 0xC0,
      data1: program & 0x7f,
      data2: 0,
    );
  }

  void _selectWithBank(
    Synthesizer s,
    int channel, {
    required int bank,
    required int program,
  }) {
    s.processMidiMessage(
      channel: channel,
      command: 0xB0,
      data1: 0x00,
      data2: bank,
    );
    s.processMidiMessage(
      channel: channel,
      command: 0xC0,
      data1: program & 0x7f,
      data2: 0,
    );
  }

  /// Bind a (drum) channel to a kit. GM kits live in bank 128 of the main SF2;
  /// the hip-hop / catalog kits are their own soundfonts. Mirrors
  /// SynthEngine.ensureDrumKitOn.
  Future<void> ensureDrumKitOn(int channel, int program) async {
    // gt-003: a role switch (releaseChannel) while this awaits drops the
    // late commit — the channel never becomes percussion again
    final gen = _roleGen[channel] ?? 0;
    bool stale() => (_roleGen[channel] ?? 0) != gen;
    await ensureLoaded();
    if (stale()) return;
    _drumChannels.add(
      channel,
    ); // remember: this channel plays drums, not melody
    final marker = 1000 + program;
    if (_channelProgram[channel] == marker) return;
    Synthesizer s;
    int prog;
    if (program == kitHipHop) {
      s = await _ensureHipHop();
      if (stale()) return;
      prog = 0;
    } else if (isDynamicSlot(program)) {
      final d = await _ensureSlot(program);
      if (stale()) return;
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

  Future<void> ensureDrumKit(int program) =>
      ensureDrumKitOn(drumChannel, program);

  // ── playback ────────────────────────────────────────────────────────
  Future<void> noteOn({
    required int channel,
    required int pitch,
    int velocity = 100,
    int? program,
  }) async {
    final p = pitch.clamp(0, 127), key = channel * 128 + pitch.clamp(0, 127);
    final generation = (_noteEpoch[key] ?? 0) + 1;
    _noteEpoch[key] = generation;
    _cancelRelease(channel, p);
    final epoch = _channelEpoch[channel] ?? 0;
    final gen = _roleGen[channel] ?? 0;
    await ensureLoaded();
    if ((_roleGen[channel] ?? 0) != gen) return; // channel changed role
    _touchOutput();
    final Synthesizer s;
    if (_drumChannels.contains(channel)) {
      if (program != null) await ensureDrumKitOn(channel, program);
      s = _channelSynth[channel] ?? _main!;
    } else {
      final bound = await _bindMelodic(channel, program);
      if (bound == null) return;
      s = bound;
    }
    if ((_channelEpoch[channel] ?? 0) != epoch ||
        _noteEpoch[key] != generation) {
      return;
    }
    s.noteOn(channel: channel, key: p, velocity: velocity.clamp(1, 127));
  }

  Future<void> noteOff({required int channel, required int pitch}) async {
    final p = pitch.clamp(0, 127), key = channel * 128 + pitch.clamp(0, 127);
    _noteEpoch[key] = (_noteEpoch[key] ?? 0) + 1;
    _cancelRelease(channel, p);
    final s = _channelSynth[channel] ?? _main;
    s?.noteOff(channel: channel, key: p);
  }

  /// Every attack owns its release. A previous preview cannot silence a newly
  /// held key, and an obsolete async load cannot restart a released key.
  Future<void> playNote({
    int channel = 0,
    required int pitch,
    int velocity = 100,
    int program = 0,
    Duration release = const Duration(milliseconds: 600),
  }) async {
    final epoch = _channelEpoch[channel] ?? 0;
    final p = pitch.clamp(0, 127), key = channel * 128 + pitch.clamp(0, 127);
    final started = noteOn(
      channel: channel,
      pitch: p,
      velocity: velocity,
      program: program,
    );
    final generation = _noteEpoch[key];
    await started;
    if ((_channelEpoch[channel] ?? 0) != epoch ||
        _noteEpoch[key] != generation) {
      return;
    }
    final timer = Timer(release, () {
      if (_noteEpoch[key] == generation) noteOff(channel: channel, pitch: p);
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
    } catch (_) {
      /* not loaded yet — fire-and-forget */
    }
  }

  /// Cancel all release timers and silence every channel on every synth.
  Future<void> stopChannel(int channel) async {
    _channelEpoch[channel] = (_channelEpoch[channel] ?? 0) + 1;
    for (final timer in _activeReleases.remove(channel)?.values ?? <Timer>[]) {
      timer.cancel();
    }
    for (final s in {_main, _s808, _hiphop, ..._slots.values}) {
      s?.noteOffAll(channel: channel, immediate: true);
    }
  }

  Future<void> stopAll() async {
    for (var ch = 0; ch < 16; ch++) {
      _channelEpoch[ch] = (_channelEpoch[ch] ?? 0) + 1;
    }
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
