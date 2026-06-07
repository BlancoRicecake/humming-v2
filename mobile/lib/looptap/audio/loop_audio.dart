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

/// GM drum note numbers per kind (export.jsx DRUM_NOTE).
const Map<String, int> kDrumNote = {'kick': 36, 'snare': 38, 'hihat': 42};

const int _melodyCh = 0;
const int _bassCh = 1;
const int _melodyProg = 0; // acoustic grand
const int _bassProg = 33; // fingered bass

class LoopAudio {
  LoopAudio._();
  static final LoopAudio instance = LoopAudio._();

  final SynthEngine _engine = SynthEngine();
  bool _ready = false;

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
      // pre-select melodic programs (silent notes) so first live note is instant
      await _engine.noteOn(channel: _melodyCh, pitch: 60, velocity: 1, program: _melodyProg);
      await _engine.noteOff(channel: _melodyCh, pitch: 60);
      await _engine.noteOn(channel: _bassCh, pitch: 60, velocity: 1, program: _bassProg);
      await _engine.noteOff(channel: _bassCh, pitch: 60);
    } catch (_) {/* graceful */}
  }

  int _vel(double vol) => (vol.clamp(0.0, 1.0) * 110 + 12).round().clamp(1, 127);

  // Held live notes — sound lasts exactly as long as the pad is pressed, so the
  // duration the user HEARS matches the note that gets recorded (item 3).
  final Map<int, Timer> _liveTimers = {};
  int _liveKey(int midi, bool bass) => (bass ? 2000 : 1000) + midi;

  /// Start a held note on pad press (paired with [noteOffLive] on release).
  void noteOnLive(int midi, {required bool bass, double vol = 0.85}) {
    final ch = bass ? _bassCh : _melodyCh;
    final prog = bass ? _bassProg : _melodyProg;
    void fire() => _engine.noteOn(channel: ch, pitch: midi, velocity: _vel(vol), program: prog);
    if (!_ready) {
      ensure().then((_) {
        if (_ready) fire();
      });
    } else {
      fire();
    }
    // safety auto-off in case a release event is ever missed
    final key = _liveKey(midi, bass);
    _liveTimers[key]?.cancel();
    _liveTimers[key] = Timer(const Duration(seconds: 4), () => noteOffLive(midi, bass: bass));
  }

  /// Stop a held note on pad release.
  void noteOffLive(int midi, {required bool bass}) {
    final key = _liveKey(midi, bass);
    _liveTimers.remove(key)?.cancel();
    _engine.noteOff(channel: bass ? _bassCh : _melodyCh, pitch: midi);
  }

  /// One-shot pitched voice (loop playback + grid preview). [durSec] sets release.
  /// Fire-and-forget on the hot path once warm.
  void playPitch(int midi, {required bool bass, double vol = 0.85, double durSec = 0.4}) {
    final ch = bass ? _bassCh : _melodyCh;
    final prog = bass ? _bassProg : _melodyProg;
    final rel = Duration(milliseconds: (durSec * 1000).round().clamp(60, 4000));
    void fire() => _engine.playNote(channel: ch, pitch: midi, velocity: _vel(vol), program: prog, release: rel);
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
