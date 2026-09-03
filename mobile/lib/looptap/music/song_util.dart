// LoopTap song helpers — flatten sections, build grid thumbnails, and the
// "hum to MIDI" content generators. Ported from prototype/export.jsx + screens.jsx.
import 'dart:io';
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'theory.dart';

/// A whole song flattened to one timeline (sections in order × repeats).
/// melody/bass/drums are the main tracks; melodyDec/beatDec are the decoration
/// ("꾸밈") layers (melody-fill pitched voice + beat-fill percussion).
class FlatSong {
  FlatSong(
    this.melody,
    this.bass,
    this.drums,
    this.steps, {
    this.melodyDec = const [],
    this.beatDec = const [],
    this.extraPitched = const {},
    this.extraDrums = const {},
  });
  final List<PitchNote> melody;
  final List<PitchNote> bass;
  final List<DrumNote> drums;
  final int steps;
  final List<PitchNote> melodyDec;
  final List<DrumNote> beatDec;
  // Added track instances, flattened across sections, keyed by ref id.
  final Map<String, List<PitchNote>> extraPitched;
  final Map<String, List<DrumNote>> extraDrums;
}

FlatSong flattenSong(List<Section> sections) {
  var off = 0;
  var secSteps = 0; // steps of the section being flattened
  final m = <PitchNote>[], md = <PitchNote>[], b = <PitchNote>[];
  final d = <DrumNote>[], bd = <DrumNote>[];
  // Notes outside the section's current length (left behind when bars were
  // shrunk) are dropped, and a note running past the end is clamped — else
  // they'd leak into the NEXT section instance on the flat timeline (C7).
  void pitched(TrackData? t, List<PitchNote> out) {
    if (t == null) return;
    for (final n in t.pitchNotes) {
      if (n.step < 0 || n.step >= secSteps) continue;
      final dur = math.min(n.dur, secSteps - n.step);
      if (dur <= 0) continue;
      out.add(PitchNote(midi: n.midi, freq: n.freq, step: n.step + off, dur: dur));
    }
  }

  void perc(TrackData? t, List<DrumNote> out) {
    if (t == null) return;
    for (final n in t.drumNotes) {
      if (n.step < 0 || n.step >= secSteps) continue;
      out.add(DrumNote(kind: n.kind, step: n.step + off));
    }
  }

  final exP = <String, List<PitchNote>>{};
  final exD = <String, List<DrumNote>>{};
  for (final sec in sections) {
    final reps = sec.repeats;
    final st = stepsForBars(sec.bars);
    secSteps = st;
    for (var r = 0; r < reps; r++) {
      pitched(sec.tracks['melody'], m);
      pitched(sec.tracks['melodyDec'], md);
      pitched(sec.tracks['bass'], b);
      perc(sec.tracks['drums'], d);
      perc(sec.tracks['beatDec'], bd);
      // added instances: route by their base type's kind.
      for (final ref in sec.extras) {
        final drum = trackById(ref.type).kind == TrackKind.drums;
        if (drum) {
          perc(sec.tracks[ref.id], exD[ref.id] ??= []);
        } else {
          pitched(sec.tracks[ref.id], exP[ref.id] ??= []);
        }
      }
      off += st;
    }
  }
  return FlatSong(m, b, d, math.max(16, off),
      melodyDec: md, beatDec: bd, extraPitched: exP, extraDrums: exD);
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
  for (final n in flat.beatDec) {
    bump(n.step, 0.14);
  }
  for (final n in [...flat.melody, ...flat.melodyDec]) {
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

// ── export file naming (C11 / A20) ──────────────────────────────────
// One sanitiser for .wav / .mid / stems: strip only what a filesystem can't
// take (Korean and other non-ASCII titles survive intact), trim, and fall
// back to [fallback] (the song id) when nothing is left.
final RegExp _kIllegalFileChars = RegExp(r'[\\/:*?"<>|\x00-\x1F\x7F]');

String exportFileName(String title, {String fallback = 'loop'}) {
  var s = title.replaceAll(_kIllegalFileChars, '').trim();
  // Windows also rejects trailing dots/spaces in a name.
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.isEmpty) {
    s = fallback.replaceAll(_kIllegalFileChars, '').trim();
  }
  return s.isEmpty ? 'loop' : s;
}

/// `<folder>/<base>.<ext>`, or `<base> (2).<ext>`, `(3)`… when the name is
/// taken — an export never silently overwrites an earlier one.
Future<File> uniqueExportFile(Directory folder, String base, String ext) async {
  var f = File('${folder.path}/$base.$ext');
  var n = 2;
  while (await f.exists()) {
    f = File('${folder.path}/$base ($n).$ext');
    n++;
  }
  return f;
}
