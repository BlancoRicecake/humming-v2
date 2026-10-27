// LoopTap song helpers — flatten sections, build grid thumbnails, and the
// "hum to MIDI" content generators. Ported from prototype/export.jsx + screens.jsx.
import 'dart:io';
import 'dart:math' as math;

import '../../audio/backup_exclusion.dart';
import '../models/loop_models.dart';
import '../state/loop_storage.dart';
import 'groove.dart';
import 'note_random.dart';
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
    this.selfTimed = const {},
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

  /// groove-001: lanes whose timing is already final (a groove — and Swing
  /// in their groove-less sections — is baked into the notes), so exporters
  /// must not add Swing again.
  final Set<String> selfTimed;
}

/// Lay [sections] out in order × repeats. Muted notes and drum hits are
/// always dropped.
/// With a [variationSeed] each note's chance / velocity variation is rolled
/// per section repeat (pass = repeat index) and the surviving notes are baked
/// in (fixed velocity, chance 1) — exports and Play Song then all use this
/// one variation. Null keeps every non-muted note as written (analysis and
/// previews).
///
/// With a [groove] context, every lane that has a groove in at least one
/// section is "self-timed": grooves are applied to its notes here (start and
/// velocity; chance/variation then use the grooved velocity) and Swing is
/// baked into its groove-less sections; its id goes into
/// [FlatSong.selfTimed]. Lanes without any groove are untouched, so a song
/// without grooves flattens exactly as before.
FlatSong flattenSong(
  List<Section> sections, {
  int? variationSeed,
  GrooveContext? groove,
}) {
  final selfTimed = <String>{};
  if (groove != null) {
    for (final sec in sections) {
      for (final id in [
        'melody',
        'melodyDec',
        'bass',
        'drums',
        'beatDec',
        for (final ref in sec.extras) ref.id,
      ]) {
        if (groove.resolve(sec, id) != null) selfTimed.add(id);
      }
    }
  }
  var current = sections.isEmpty ? null : sections.first;
  // Groove / baked Swing for one note of a self-timed lane: new start
  // (section steps) and velocity. Null for lanes the clock swings.
  ({double start, int? velocity})? timed(
    String trackId,
    double start,
    int step,
    int? velocity,
  ) {
    if (!selfTimed.contains(trackId)) return null;
    final g = groove!.resolve(current!, trackId);
    if (g == null) {
      return (start: start + swingOffset(step, groove.swing), velocity: velocity);
    }
    return applyGroove(
      start,
      velocity,
      g.template,
      g.assign,
      amount: groove.amount,
    );
  }

  var off = 0;
  var secSteps = 0; // steps of the section being flattened
  var secId = '', pass = 0;
  final m = <PitchNote>[], md = <PitchNote>[], b = <PitchNote>[];
  final d = <DrumNote>[], bd = <DrumNote>[];
  // Notes outside the section's current length (left behind when bars were
  // shrunk) are dropped, and a note running past the end is clamped — else
  // they'd leak into the NEXT section instance on the flat timeline (C7).
  void pitched(TrackData? t, String trackId, List<PitchNote> out) {
    if (t == null) return;
    for (final src in t.pitchNotes) {
      // deactivated notes never reach playback, exports or previews
      if (src.muted) continue;
      if (src.step < 0 || src.step >= secSteps) continue;
      // gt-001: a stroke string whose offset falls past the section end is
      // not scheduled (only offsets ≥ 1 step can get here; imports stay < 1).
      if (src.startSteps >= secSteps) continue;
      final dur = math.min(src.dur, secSteps - src.step);
      if (dur <= 0) continue;
      final gr = timed(trackId, src.startSteps, src.step, src.velocity);
      if (gr != null && src.stroke != null && gr.start >= secSteps) continue;
      final base =
          gr == null || gr.velocity == src.velocity
              ? src
              : src.copyWith(velocity: gr.velocity);
      final n =
          variationSeed == null
              ? base
              : realizePitchNote(
                base,
                seed: variationSeed,
                sectionId: secId,
                trackId: trackId,
                pass: pass,
              );
      if (n == null) continue;
      if (gr != null) {
        final step = gr.start.floor();
        final length = math.max(
          1 / 16,
          math.min(n.soundingSteps, secSteps - gr.start),
        );
        out.add(
          n.copyWith(
            chance: variationSeed == null ? null : 1.0,
            velocityDeviation: variationSeed == null ? null : 0,
            step: step + off,
            offsetSteps: gr.start - step,
            dur: math.max(1, length.ceil()),
            durationSteps: length,
          ),
        );
        continue;
      }
      out.add(
        n.copyWith(
          chance: variationSeed == null ? null : 1.0,
          velocityDeviation: variationSeed == null ? null : 0,
          step: n.step + off,
          dur: dur,
          durationSteps:
              n.durationSteps == null
                  ? null
                  : math.min(
                    n.soundingSteps,
                    secSteps - n.step - n.offsetSteps,
                  ),
        ),
      );
    }
  }

  void perc(TrackData? t, String trackId, List<DrumNote> out) {
    if (t == null) return;
    for (final src in t.drumNotes) {
      if (src.muted) continue;
      if (src.step < 0 || src.step >= secSteps) continue;
      final gr = timed(trackId, src.startSteps, src.step, src.velocity);
      final base =
          gr == null || gr.velocity == src.velocity
              ? src
              : src.copyWith(velocity: gr.velocity);
      final n =
          variationSeed == null
              ? base
              : realizeDrumNote(
                base,
                seed: variationSeed,
                sectionId: secId,
                trackId: trackId,
                pass: pass,
              );
      if (n == null) continue;
      final step = gr == null ? n.step : gr.start.floor();
      out.add(
        n.copyWith(
          chance: variationSeed == null ? null : 1.0,
          velocityDeviation: variationSeed == null ? null : 0,
          step: step + off,
          offsetSteps: gr == null ? null : gr.start - step,
        ),
      );
    }
  }

  final exP = <String, List<PitchNote>>{};
  final exD = <String, List<DrumNote>>{};
  for (final sec in sections) {
    final reps = sec.repeats;
    final st = stepsForBars(sec.bars);
    secSteps = st;
    secId = sec.id;
    current = sec;
    for (var r = 0; r < reps; r++) {
      pass = r;
      pitched(sec.tracks['melody'], 'melody', m);
      pitched(sec.tracks['melodyDec'], 'melodyDec', md);
      pitched(sec.tracks['bass'], 'bass', b);
      perc(sec.tracks['drums'], 'drums', d);
      perc(sec.tracks['beatDec'], 'beatDec', bd);
      // added instances: route by their base type's kind.
      for (final ref in sec.extras) {
        final drum = trackById(ref.type).kind == TrackKind.drums;
        if (drum) {
          perc(sec.tracks[ref.id], ref.id, exD[ref.id] ??= []);
        } else {
          pitched(sec.tracks[ref.id], ref.id, exP[ref.id] ??= []);
        }
      }
      off += st;
    }
  }
  return FlatSong(
    m,
    b,
    d,
    math.max(16, off),
    melodyDec: md,
    beatDec: bd,
    extraPitched: exP,
    extraDrums: exD,
    selfTimed: selfTimed,
  );
}

/// 30-bar waveform thumbnail (screens.jsx buildWave) from a flattened song.
List<double> buildWave(FlatSong flat) {
  final steps = flat.steps;
  final e = List<double>.filled(steps, 0.12);
  void bump(int s, double amt) {
    if (s >= 0 && s < steps) e[s] = math.min(1, e[s] + amt);
  }

  for (final n in flat.drums) {
    bump(
      n.step,
      n.kind == 'kick'
          ? 0.55
          : n.kind == 'snare'
          ? 0.42
          : 0.18,
    );
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
      out.add(
        PitchNote(midi: n.midi, freq: n.freq, step: bar * 16 + o, dur: 4),
      );
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

/// `<Documents>/looptap/exports`, created if missing — the single home for
/// every rendered .wav / .mid / stem (wav_export.dart, midi_export.dart).
///
/// Excluded from iCloud/iTunes backup (C18): an export is regenerable from the
/// song, so it must not eat the user's iCloud quota. The exclusion is best
/// effort and never throws — an export must never fail because of it.
Future<Directory> exportsFolder() async {
  final dir = await LoopStorage.documentsDirectory();
  final folder = Directory('${dir.path}/looptap/exports');
  if (!await folder.exists()) await folder.create(recursive: true);
  await excludeFromBackup(folder.path);
  return folder;
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
