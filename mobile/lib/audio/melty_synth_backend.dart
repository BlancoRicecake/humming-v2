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

// Float32List/Int16List/ByteData/Uint8List come via dart_melty_soundfont's
// re-export of dart:typed_data.
import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

import '../looptap/music/soundfont_catalog.dart'; // isDynamicSlot, SoundfontCatalog

class MeltyEngine {
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
  // PCM block fed per callback. ~23ms @44.1k. Lower = less latency, more CPU.
  static const int _frames = 1024;

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
    await FlutterPcmSound.setup(sampleRate: _sampleRate, channelCount: 1);
    FlutterPcmSound.setFeedThreshold(_frames);
    FlutterPcmSound.setFeedCallback(_onFeed);
    FlutterPcmSound.start(); // returns bool (not a Future) in this version
  }

  // Called by flutter_pcm_sound whenever its buffer drops below the threshold.
  // Render one block from every loaded synth, sum to mono, feed as Int16.
  void _onFeed(int remainingFrames) {
    final main = _main;
    if (main == null) return;
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
      var v = _acc[i];
      if (v > 1.0) {
        v = 1.0;
      } else if (v < -1.0) {
        v = -1.0;
      }
      _out[i] = (v < 0 ? v * 32768 : v * 32767).round();
    }
    FlutterPcmSound.feed(PcmArrayInt16.fromList(_out));
  }

  void _mixSynth(Synthesizer s) {
    s.render(_bl, _br);
    for (var i = 0; i < _frames; i++) {
      _acc[i] += (_bl[i] + _br[i]) * 0.5; // stereo → mono
    }
  }

  // ── instrument routing ────────────────────────────────────────────────
  // Bind a melodic channel to the synth/preset for [program] and return it.
  // program == null keeps the existing binding (per-note sequencer calls).
  Future<Synthesizer> _bindMelodic(int channel, int? program) async {
    final main = _main!;
    if (program == null) return _channelSynth[channel] ?? main;
    if (program == program808) {
      final s = await _ensure808();
      if (_channelProgram[channel] != program808) {
        _selectProgram(s, channel, bank: 0, program: 0); // 808's single preset
        _channelProgram[channel] = program808;
      }
      _channelSynth[channel] = s;
      return s;
    }
    if (isDynamicSlot(program)) {
      final s = await _ensureSlot(program);
      if (s != null) {
        final entry = SoundfontCatalog.instance.bySlot(program);
        final marker = 100000 + program;
        if (_channelProgram[channel] != marker) {
          _selectProgram(s, channel,
              bank: entry?.sfBank ?? 0, program: entry?.sfProgram ?? 0);
          _channelProgram[channel] = marker;
        }
        _channelSynth[channel] = s;
        return s;
      }
      // not downloaded / failed → fall back to grand piano so it still sounds.
      _selectGm(main, channel, 0);
      _channelSynth[channel] = main;
      return main;
    }
    _selectGm(main, channel, program);
    _channelSynth[channel] = main;
    return main;
  }

  void _selectGm(Synthesizer s, int channel, int program) {
    if (_channelSynth[channel] == s && _channelProgram[channel] == program) return;
    _selectProgram(s, channel, bank: 0, program: program);
    _channelProgram[channel] = program;
  }

  // Bank select (CC0) then program change — standard MIDI, reliable in MeltySynth.
  void _selectProgram(Synthesizer s, int channel,
      {required int bank, required int program}) {
    s.processMidiMessage(channel: channel, command: 0xB0, data1: 0x00, data2: bank);
    s.processMidiMessage(channel: channel, command: 0xC0, data1: program, data2: 0);
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
    // Target an effective bankNumber of 128 (percussion). MeltySynth's setBank()
    // ADDS 128 on the percussion channel (9) — so send 0 there (→128) and an
    // explicit 128 on other drum channels (→128). bank 128 resolves a percussion
    // preset on ANY channel, falling back to the Standard kit (128:0).
    final bankSel = channel == drumChannel ? 0 : 128;
    _selectProgram(s, channel, bank: bankSel, program: prog);
    _channelProgram[channel] = marker;
    _channelSynth[channel] = s;
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
