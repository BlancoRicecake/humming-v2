// LoopTap audio — thin layer over the existing SynthEngine (flutter_midi_pro + SF2).
// README says: swap the prototype's WebAudio for the platform stack but keep the
// data model + timing math. We map LoopTap voices onto GM instruments:
//   melody -> ch0 acoustic grand (prog 0)
//   bass   -> ch1 fingered bass  (prog 33)   (matches export.jsx MIDI ch1=33)
//   drums  -> ch9 GM kit; kick=36 snare=38 hihat=42 (matches export.jsx DRUM_NOTE)
//   click  -> ch9 wood block (accent=76 / normal=77)
import 'dart:async';

import 'package:audioplayers/audioplayers.dart';

import '../../audio/synth.dart';

/// GM drum note numbers per kind. Main kit (kick/snare/hihat) + the beat-fill
/// decoration kit (shaker/tambourine/clap) — both route to GM ch9.
const Map<String, int> kDrumNote = {
  'kick': 36,
  'snare': 38,
  'hihat': 42,
  'shaker': 82,
  'tambourine': 54,
  'clap': 39,
};

class LoopAudio {
  LoopAudio._();
  static final LoopAudio instance = LoopAudio._();

  final SynthEngine _engine = SynthEngine();
  bool _ready = false;

  // Current GM program per pitched channel — set per-song via [setPrograms].
  // ch0 melody, ch1 bass, ch2 melody-fill (see kTracks in theory.dart).
  final Map<int, int> _programs = {0: 0, 1: 33, 2: 48};

  /// Switch a channel's instrument (GM program). Pre-selects the new program
  /// with a silent note so the next audible note doesn't stall on the swap.
  Future<void> setProgram(int channel, int program) async {
    _programs[channel] = program;
    if (!_ready) return;
    try {
      await _engine.noteOn(channel: channel, pitch: 60, velocity: 1, program: program);
      await _engine.noteOff(channel: channel, pitch: 60);
    } catch (_) {/* graceful */}
  }

  /// Set several channels' programs at once (channel -> GM program).
  Future<void> setPrograms(Map<int, int> byChannel) async {
    for (final e in byChannel.entries) {
      await setProgram(e.key, e.value);
    }
  }

  /// Load the SoundFont once (lazy — safe to call on first user gesture).
  Future<void> ensure() async {
    if (_ready) return;
    try {
      await _engine.ensureLoaded();
      _ready = true;
    } catch (_) {/* graceful: stays silent if the SF2 can't load */}
  }

  /// Pre-load + pre-select instruments so the FIRST tap doesn't stall on
  /// soundfont load / program select. Call once when the editor opens.
  Future<void> prewarm() async {
    await ensure();
    if (!_ready) return;
    try {
      await _engine.ensureDrumKit(0);
      // pre-select every pitched channel's program (silent notes) so the first
      // live note on each voice is instant.
      for (final e in _programs.entries) {
        await _engine.noteOn(channel: e.key, pitch: 60, velocity: 1, program: e.value);
        await _engine.noteOff(channel: e.key, pitch: 60);
      }
    } catch (_) {/* graceful */}
  }

  int _vel(double vol) => (vol.clamp(0.0, 1.0) * 110 + 12).round().clamp(1, 127);

  // Held live notes — sound lasts exactly as long as the pad is pressed, so the
  // duration the user HEARS matches the note that gets recorded (item 3).
  final Map<int, Timer> _liveTimers = {};
  int _liveKey(int channel, int midi) => channel * 1000 + midi;

  /// Start a held note on pad press (paired with [noteOffLive] on release).
  void noteOnLive(int channel, int midi, {int? program, double vol = 0.85}) {
    final prog = program ?? _programs[channel] ?? 0;
    void fire() => _engine.noteOn(channel: channel, pitch: midi, velocity: _vel(vol), program: prog);
    if (!_ready) {
      ensure().then((_) {
        if (_ready) fire();
      });
    } else {
      fire();
    }
    // safety auto-off in case a release event is ever missed
    final key = _liveKey(channel, midi);
    _liveTimers[key]?.cancel();
    _liveTimers[key] = Timer(const Duration(seconds: 4), () => noteOffLive(channel, midi));
  }

  /// Stop a held note on pad release.
  void noteOffLive(int channel, int midi) {
    final key = _liveKey(channel, midi);
    _liveTimers.remove(key)?.cancel();
    _engine.noteOff(channel: channel, pitch: midi);
  }

  /// One-shot pitched voice (loop playback + grid preview). [durSec] sets release.
  /// Fire-and-forget on the hot path once warm.
  void playPitch(int channel, int midi, {int? program, double vol = 0.85, double durSec = 0.4}) {
    final prog = program ?? _programs[channel] ?? 0;
    final rel = Duration(milliseconds: (durSec * 1000).round().clamp(60, 4000));
    void fire() => _engine.playNote(channel: channel, pitch: midi, velocity: _vel(vol), program: prog, release: rel);
    if (!_ready) {
      ensure().then((_) {
        if (_ready) fire();
      });
      return;
    }
    fire();
  }

  /// Drum hit (tap feedback + loop playback). Fire-and-forget on the hot path:
  /// once warm, dispatch noteOn immediately without awaiting the continuation.
  void playDrum(String kind, {double vol = 1}) {
    final pitch = kDrumNote[kind];
    if (pitch == null) return;
    if (!_ready) {
      // cold path: warm up then hit (first tap only)
      prewarm().then((_) => _fireDrum(pitch, vol));
      return;
    }
    _fireDrum(pitch, vol);
  }

  void _fireDrum(int pitch, double vol) {
    _engine.noteOn(channel: SynthEngine.drumChannel, pitch: pitch, velocity: _vel(vol));
    // GM percussion samples are one-shot; schedule a tidy note-off.
    Timer(const Duration(milliseconds: 220), () {
      _engine.noteOff(channel: SynthEngine.drumChannel, pitch: pitch);
    });
  }

  /// Metronome click — accent on bar 1 (wood block 76), else 77.
  Future<void> click(bool accent) async {
    await ensure();
    final pitch = accent ? 76 : 77;
    await _engine.ensureDrumKit(0);
    await _engine.noteOn(channel: SynthEngine.drumChannel, pitch: pitch, velocity: accent ? 90 : 64);
    Timer(const Duration(milliseconds: 120), () {
      _engine.noteOff(channel: SynthEngine.drumChannel, pitch: pitch);
    });
  }

  // ── recorded vocal playback (audioplayers, plays alongside the SF2 synth) ──
  final AudioPlayer _vocalPlayer = AudioPlayer();
  bool _vocalConfigured = false;

  Future<void> _configVocal() async {
    if (_vocalConfigured) return;
    _vocalConfigured = true;
    // mix with the synth (don't take exclusive focus / don't stop on its own)
    await _vocalPlayer.setReleaseMode(ReleaseMode.stop);
    await _vocalPlayer.setAudioContext(AudioContext(
      android: const AudioContextAndroid(
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playback,
        options: const {AVAudioSessionOptions.mixWithOthers},
      ),
    ));
  }

  /// Start playing the recorded vocal file from its start.
  Future<void> playVocal(String path, {double vol = 0.85}) async {
    await _configVocal();
    try {
      await _vocalPlayer.setVolume(vol.clamp(0.0, 1.0));
      await _vocalPlayer.play(DeviceFileSource(path), volume: vol.clamp(0.0, 1.0));
    } catch (_) {/* file missing / unsupported — stay silent */}
  }

  /// Re-align the vocal to the loop start (called on loop wrap).
  Future<void> seekVocalToStart() async {
    try {
      await _vocalPlayer.seek(Duration.zero);
      if (_vocalPlayer.state != PlayerState.playing) await _vocalPlayer.resume();
    } catch (_) {}
  }

  Future<void> setVocalVolume(double vol) async {
    try {
      await _vocalPlayer.setVolume(vol.clamp(0.0, 1.0));
    } catch (_) {}
  }

  Future<void> stopVocal() async {
    try {
      await _vocalPlayer.stop();
    } catch (_) {}
  }

  /// Silence everything (stop / leaving the editor).
  Future<void> stopAll() {
    stopVocal();
    return _engine.stopAll();
  }
}
