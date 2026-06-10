// LoopTap song helpers — flatten sections, build grid thumbnails, and the
// "hum to MIDI" content generators. Ported from prototype/export.jsx + screens.jsx.
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'theory.dart';

/// A whole song flattened to one timeline (sections in order × repeats).
class FlatSong {
  FlatSong(this.melody, this.bass, this.drums, this.steps);
  final List<PitchNote> melody;
  final List<PitchNote> bass;
  final List<DrumNote> drums;
  final int steps;
}

FlatSong flattenSong(List<Section> sections) {
  var off = 0;
  final m = <PitchNote>[], b = <PitchNote>[], d = <DrumNote>[];
  for (final sec in sections) {
    final reps = sec.repeats;
    final st = stepsForBars(sec.bars);
    for (var r = 0; r < reps; r++) {
      for (final n in sec.tracks['melody']!.pitchNotes) {
        m.add(PitchNote(midi: n.midi, freq: n.freq, step: n.step + off, dur: n.dur));
      }
      for (final n in sec.tracks['bass']!.pitchNotes) {
        b.add(PitchNote(midi: n.midi, freq: n.freq, step: n.step + off, dur: n.dur));
      }
      for (final n in sec.tracks['drums']!.drumNotes) {
        d.add(DrumNote(kind: n.kind, step: n.step + off));
      }
      off += st;
    }
  }
  return FlatSong(m, b, d, math.max(16, off));
}

/// 30-bar waveform thumbnail (screens.jsx buildWave) from a flattened song.
List<double> buildWave(FlatSong flat) {
  final steps = flat.steps;
  final e = List<double>.filled(steps, 0.12);
  void bump(int s, double amt) {
    if (s >= 0 && s < steps) e[s] = math.min(1, e[s] + amt);
  }

  for (final n in flat.drums) {
    bump(n.step, n.kind == 'kick' ? 0.55 : n.kind == 'snare' ? 0.42 : 0.18);
  }
  for (final n in flat.melody) {
    for (var s = n.step; s < n.step + n.dur && s < steps; s++) {
      bump(s, 0.3);
    }
  }
  for (final n in flat.bass) {
    for (var s = n.step; s < n.step + n.dur && s < steps; s++) {
      bump(s, 0.25);
    }
  }
  final out = <double>[];
  for (var i = 0; i < 30; i++) {
    out.add(e[(i / 30 * steps).floor().clamp(0, steps - 1)]);
  }
  return out;
}

// ── "Hum to MIDI" content generators (screens.jsx) ──────────────────
List<PitchNote> genMelody(List<Rung> ladder, int steps, math.Random rng) {
  final out = <PitchNote>[];
  var step = 0;
  while (step < steps) {
    if (rng.nextDouble() < 0.72) {
      final n = ladder[rng.nextInt(ladder.length)];
      out.add(PitchNote(midi: n.midi, freq: n.freq, step: step, dur: 2));
    }
    step += const [2, 2, 4][rng.nextInt(3)];
  }
  return out;
}

List<PitchNote> genBass(List<Rung> bassLadder, int bars) {
  final out = <PitchNote>[];
  for (var bar = 0; bar < bars; bar++) {
    final n = bassLadder[const [0, 0, 2, 3][bar % 4]];
    for (final o in const [0, 8]) {
      out.add(PitchNote(midi: n.midi, freq: n.freq, step: bar * 16 + o, dur: 4));
    }
  }
  return out;
}

List<DrumNote> genDrums(int steps) {
  final out = <DrumNote>[];
  for (var s = 0; s < steps; s++) {
    if (s % 8 == 0) out.add(DrumNote(kind: 'kick', step: s));
    if (s % 8 == 4) out.add(DrumNote(kind: 'snare', step: s));
    if (s % 2 == 0) out.add(DrumNote(kind: 'hihat', step: s));
  }
  return out;
}
