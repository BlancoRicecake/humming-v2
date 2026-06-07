// LoopTap audio — thin layer over the existing SynthEngine (flutter_midi_pro + SF2).
// README says: swap the prototype's WebAudio for the platform stack but keep the
// data model + timing math. We map LoopTap voices onto GM instruments:
//   melody -> ch0 acoustic grand (prog 0)
//   bass   -> ch1 fingered bass  (prog 33)   (matches export.jsx MIDI ch1=33)
//   drums  -> ch9 GM kit; kick=36 snare=38 hihat=42 (matches export.jsx DRUM_NOTE)
//   click  -> ch9 wood block (accent=76 / normal=77)
import 'dart:async';

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

  int _vel(double vol) => (vol.clamp(0.0, 1.0) * 110 + 12).round().clamp(1, 127);

  /// Live pitched voice (tap feedback + loop playback). [durSec] sets release.
  Future<void> playPitch(int midi, {required bool bass, double vol = 0.85, double durSec = 0.4}) async {
    await ensure();
    await _engine.playNote(
      channel: bass ? _bassCh : _melodyCh,
      pitch: midi,
      velocity: _vel(vol),
      program: bass ? _bassProg : _melodyProg,
      release: Duration(milliseconds: (durSec * 1000).round().clamp(60, 4000)),
    );
  }

  /// Drum hit (tap feedback + loop playback).
  Future<void> playDrum(String kind, {double vol = 1}) async {
    await ensure();
    final pitch = kDrumNote[kind];
    if (pitch == null) return;
    await _engine.ensureDrumKit(0);
    await _engine.noteOn(channel: SynthEngine.drumChannel, pitch: pitch, velocity: _vel(vol));
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

  /// Silence everything (stop / leaving the editor).
  Future<void> stopAll() => _engine.stopAll();
}
