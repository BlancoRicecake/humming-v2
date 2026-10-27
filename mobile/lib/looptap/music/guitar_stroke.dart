// gt-001 guitar stroke conversion: rewrite selected chord hits into real
// note data (per-string start offset, velocity and length) so live playback,
// MIDI export and WAV render all read the same events. Opt-in only: nothing
// here runs unless the user applies a stroke, and untouched notes keep their
// identity (and so their legacy auto strum).
//
// Tempo note: offsets are stored in steps, so a later BPM change scales the
// spread with the tempo. The tag keeps `spreadMs`; re-applying recomputes
// the offsets at the new BPM.
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'audition.dart' show PlaybackRange;
import 'theory.dart' show kStepsPerBeat, strumPlan;

/// One stroke's parameters. [spreadMs] is the gap between successive
/// strings, [falloff] the fraction the last string is quieter than the
/// first, [accent] a velocity multiplier for the whole hit.
class StrokeSpec {
  const StrokeSpec({
    required this.dir,
    required this.spreadMs,
    this.falloff = .18,
    required this.accent,
  });

  /// Defaults: down 28 ms / 100 %, up 18 ms / 80 % (lighter and quicker),
  /// both with 18 % falloff.
  const StrokeSpec.down({this.spreadMs = 28, this.falloff = .18, this.accent = 1})
    : dir = StrokeDir.down;
  const StrokeSpec.up({this.spreadMs = 18, this.falloff = .18, this.accent = .8})
    : dir = StrokeDir.up;

  final StrokeDir dir;
  final double spreadMs, falloff, accent;

  /// The same stroke with every value inside the UI ranges (spread 5..60 ms,
  /// falloff 0..40 %, accent 50..130 %).
  StrokeSpec get clamped => StrokeSpec(
    dir: dir,
    spreadMs: spreadMs.clamp(5, 60).toDouble(),
    falloff: falloff.clamp(0, .4).toDouble(),
    accent: accent.clamp(.5, 1.3).toDouble(),
  );
}

/// A stroke pattern preset: directions assigned to successive chord hits
/// (time order), repeating. [label] is the chip text.
class StrokePattern {
  const StrokePattern(this.id, this.label, this.dirs);
  final String id, label;
  final List<StrokeDir> dirs;
}

const List<StrokePattern> kStrokePatterns = [
  StrokePattern('down', '↓', [StrokeDir.down]),
  StrokePattern('downUp', '↓↑', [StrokeDir.down, StrokeDir.up]),
  StrokePattern('folk', '↓ ↓↑ ↑↓↑', [
    StrokeDir.down,
    StrokeDir.down,
    StrokeDir.up,
    StrokeDir.up,
    StrokeDir.down,
    StrokeDir.up,
  ]),
];

StrokePattern strokePatternById(String id) =>
    kStrokePatterns.where((p) => p.id == id).firstOrNull ?? kStrokePatterns.first;

/// A stroke edit with the resulting selection (converted notes are new
/// objects, so identity-based selections must be remapped).
typedef GuitarStrokeEdit = ({List<PitchNote> notes, Set<PitchNote> selection});

/// [note] as it was before its stroke conversion (exact: velocity, offset,
/// dur and durationSteps including null-ness). Untagged notes are returned
/// as they are.
PitchNote strokeBase(PitchNote note) {
  final t = note.stroke;
  if (t == null) return note;
  return note.withTiming(
    dur: t.baseDur,
    offsetSteps: t.baseOffsetSteps,
    velocity: t.baseVelocity,
    durationSteps: t.baseDurationSteps,
    stroke: null,
  );
}

/// Notes whose actual starts lie within this many steps of a hit's earliest
/// note belong to that hit (|start - anchor| <= 0.05 step, about 6 ms at
/// 120 BPM). Chaining is anchored on the earliest note, never unbounded, so
/// a fast line (e.g. starts 0, .3, .6 inside one cell) stays separate hits.
/// The legacy auto strum keeps its own integer-`step` grouping.
const double kStrokeHitTolerance = 0.05;

/// The start a note is grouped by: its pre-conversion start for a converted
/// note (so re-apply/revert finds the original hit even though the strings
/// are staggered), else its actual start.
double strokeGroupStart(PitchNote n) {
  final t = n.stroke;
  return t == null ? n.startSteps : n.step + t.baseOffsetSteps;
}

/// Chord hits of [notes] in time order: indices of the non-muted notes in
/// [scope] grouped by [strokeGroupStart] within [kStrokeHitTolerance] of
/// the hit's earliest note. Within a hit, indices keep list order.
List<List<int>> strokeChordHits(List<PitchNote> notes, Set<PitchNote> scope) {
  final idx = [
    for (var i = 0; i < notes.length; i++)
      if (!notes[i].muted && scope.contains(notes[i])) i,
  ];
  final start = {for (final i in idx) i: strokeGroupStart(notes[i])};
  idx.sort((a, b) {
    final c = start[a]!.compareTo(start[b]!);
    return c != 0 ? c : a.compareTo(b);
  });
  final hits = <List<int>>[];
  double? anchor;
  for (final i in idx) {
    if (anchor == null || start[i]! - anchor > kStrokeHitTolerance + 1e-9) {
      hits.add(<int>[]);
      anchor = start[i];
    }
    hits.last.add(i);
  }
  return [for (final h in hits) h..sort()];
}

/// Indices of [hit] in string order for [dir]: by pitch (low → high for
/// down, high → low for up), equal pitches stably by list index.
List<int> strokeOrder(
  List<PitchNote> notes,
  List<int> hit,
  StrokeDir dir, {
  int Function(PitchNote n)? midiOf,
}) {
  int m(int i) => midiOf?.call(notes[i]) ?? notes[i].midi;
  return [...hit]..sort((a, b) {
    final c = dir == StrokeDir.down ? m(a).compareTo(m(b)) : m(b).compareTo(m(a));
    return c != 0 ? c : a.compareTo(b);
  });
}

/// The strike order of an explicit stroke conversion. When every note of
/// [hit] has an assigned guitar string (gt-002), the real strings decide:
/// down = string 6 → 1 (low E first), up = 1 → 6, ties by list index. If
/// any note is unassigned the whole hit uses [strokeOrder]'s pitch order
/// (no partial mixing). The legacy auto strum ([strumPairs]) always keeps
/// the pitch order.
List<int> strokeConversionOrder(
  List<PitchNote> notes,
  List<int> hit,
  StrokeDir dir,
) {
  if (hit.any((i) => notes[i].guitarString == null)) {
    return strokeOrder(notes, hit, dir);
  }
  return [...hit]..sort((a, b) {
    final sa = notes[a].guitarString!, sb = notes[b].guitarString!;
    final c = dir == StrokeDir.down ? sb.compareTo(sa) : sa.compareTo(sb);
    return c != 0 ? c : a.compareTo(b);
  });
}

GuitarStrokeEdit _strokeHits(
  List<PitchNote> notes,
  Set<PitchNote> selection,
  StrokeSpec Function(int hitIndex) specFor, {
  required int bpm,
}) {
  final scope = selection.isEmpty ? notes.toSet() : selection;
  // Re-apply replaces: convertible tagged notes start from their base. A
  // gt-002 ring is undone first (its base length would be stale after the
  // stroke rewrites the lengths; run the ring again afterwards).
  final work = [
    for (final n in notes)
      if (scope.contains(n) && !n.locked && !n.muted)
        strokeBase(n.ringReverted())
      else
        n,
  ];
  final workScope = {
    for (var i = 0; i < notes.length; i++)
      if (scope.contains(notes[i])) work[i],
  };
  final out = List<PitchNote>.of(work);
  var changed = false;
  var k = 0;
  final stepsPerMs = bpm * kStepsPerBeat / 60000.0;
  for (final hit in strokeChordHits(work, workScope)) {
    if (!hit.any((i) => !work[i].locked)) continue;
    final spec = specFor(k++).clamped;
    final order = strokeConversionOrder(work, hit, spec.dir);
    final count = order.length;
    final hitStart = hit.map((i) => strokeGroupStart(work[i])).reduce(math.min);
    final chordLen = hit
        .where((i) => !work[i].locked)
        .map((i) => work[i].endSteps - hitStart)
        .reduce(math.min);
    var spread = spec.spreadMs * stepsPerMs;
    if (count > 1 && (count - 1) * spread > chordLen - 1 / 16) {
      // the last string still starts before the chord ends
      spread = math.max(0.0, chordLen - 1 / 16) / (count - 1);
    }
    for (var p = 0; p < count; p++) {
      final i = order[p];
      final n = work[i];
      if (n.locked) continue; // keeps its slot, never rewritten
      // A hit can straddle a cell edge (within the tolerance); a string never
      // starts before its own cell, because live playback triggers notes by
      // cell and the offset must stay >= 0 for live == export.
      final start = math.max(hitStart + p * spread, n.step.toDouble());
      final position = count > 1 ? p / (count - 1) : 0.0;
      final velocity = ((n.velocity ?? 100) *
              spec.accent *
              (1 - spec.falloff * position))
          .round()
          .clamp(1, 127);
      out[i] = n.withTiming(
        dur: n.dur,
        offsetSteps: start - n.step,
        velocity: velocity,
        durationSteps: math.max(1 / 16, n.endSteps - start),
        stroke: StrokeTag(
          dir: spec.dir,
          spreadMs: spec.spreadMs,
          falloff: spec.falloff,
          accent: spec.accent,
          order: p,
          baseDur: n.dur,
          baseOffsetSteps: n.offsetSteps,
          baseVelocity: n.velocity,
          baseDurationSteps: n.durationSteps,
        ),
      );
    }
  }
  for (var i = 0; i < notes.length; i++) {
    if (!identical(out[i], notes[i])) changed = true;
  }
  if (!changed) return (notes: notes, selection: selection);
  return (
    notes: out,
    selection: {
      for (var i = 0; i < notes.length; i++)
        if (selection.contains(notes[i])) out[i],
    },
  );
}

/// Convert every chord hit of the selection (nothing selected = the whole
/// track) into a [spec] stroke at [bpm]. Locked notes stay unchanged but
/// keep their string position; muted notes are skipped. Applying again
/// replaces the previous stroke (no accumulation). A no-op returns [notes]
/// itself.
GuitarStrokeEdit applyGuitarStroke(
  List<PitchNote> notes,
  Set<PitchNote> selection,
  StrokeSpec spec, {
  required int bpm,
}) => _strokeHits(notes, selection, (_) => spec, bpm: bpm);

/// Like [applyGuitarStroke], with [pattern]'s directions assigned to
/// successive chord hits in time order ([down] / [up] give the parameters).
GuitarStrokeEdit applyStrokePattern(
  List<PitchNote> notes,
  Set<PitchNote> selection,
  StrokePattern pattern, {
  StrokeSpec down = const StrokeSpec.down(),
  StrokeSpec up = const StrokeSpec.up(),
  required int bpm,
}) => _strokeHits(
  notes,
  selection,
  (k) =>
      pattern.dirs[k % pattern.dirs.length] == StrokeDir.down ? down : up,
  bpm: bpm,
);

/// "일반으로 되돌리기": restore every converted, unlocked note of the
/// selection (nothing selected = whole track) to its exact pre-stroke values.
/// A gt-002 ring applied after the stroke is dropped with it (its base was
/// the stroked length).
GuitarStrokeEdit revertGuitarStroke(
  List<PitchNote> notes,
  Set<PitchNote> selection,
) {
  final scope = selection.isEmpty ? notes.toSet() : selection;
  var changed = false;
  final out = [
    for (final n in notes)
      if (n.stroke != null && !n.locked && scope.contains(n))
        (() {
          changed = true;
          return strokeBase(n.ringReverted());
        })()
      else
        n,
  ];
  if (!changed) return (notes: notes, selection: selection);
  return (
    notes: out,
    selection: {
      for (var i = 0; i < notes.length; i++)
        if (selection.contains(notes[i])) out[i],
    },
  );
}

/// The legacy automatic strum for one chord: [group]'s notes paired with
/// their [strumPlan] entries, ordered like `strumPlan` (by pitch). Pairing
/// is by list index, never by pitch, so duplicate same-pitch notes each keep
/// their own note (a pitch-keyed map used to let the last one overwrite the
/// others). For chords without duplicate pitches the result equals the old
/// pitch-keyed pairing exactly.
List<({PitchNote note, int midi, int delayMs, double velScale})> strumPairs(
  List<PitchNote> group, {
  int Function(PitchNote n)? midiOf,
}) {
  int m(PitchNote n) => midiOf?.call(n) ?? n.midi;
  final order = strokeOrder(
    group,
    [for (var i = 0; i < group.length; i++) i],
    StrokeDir.down,
    midiOf: midiOf,
  );
  final plan = strumPlan([for (final n in group) m(n)]);
  return [
    for (var i = 0; i < plan.length; i++)
      (
        note: group[order[i]],
        midi: plan[i].midi,
        delayMs: plan[i].delayMs,
        velScale: plan[i].velScale,
      ),
  ];
}

/// Live playback's legacy auto strum for the notes [due] at one step: the
/// strum pairs when it applies (a GM-guitar lane, two or more untouched
/// notes), else null and the notes play through the normal offset/velocity
/// path. A converted note never matches (it always carries an explicit
/// velocity and length), and a stroke tag excludes the hit explicitly.
List<({PitchNote note, int midi, int delayMs, double velScale})>?
liveLegacyStrum(
  List<PitchNote> due, {
  required bool guitar,
  int Function(PitchNote n)? midiOf,
}) {
  if (!guitar ||
      due.length < 2 ||
      !due.every(
        (n) =>
            n.velocity == null &&
            n.velocityDeviation == 0 &&
            n.offsetSteps == 0 &&
            n.durationSteps == null &&
            n.stroke == null &&
            // gt-003: articulated notes keep their own gates (no auto strum)
            n.articulation == null,
      )) {
    return null;
  }
  return strumPairs(due, midiOf: midiOf);
}

/// The grid mark of a converted hit: '↓' / '↑' on its first string
/// (order 0), null for every other note.
String? strokeMark(PitchNote n) {
  final t = n.stroke;
  if (t == null || t.order != 0) return null;
  return t.dir == StrokeDir.down ? '↓' : '↑';
}

/// P1 (gt-001 follow-up): a note whose actual onset lies in a later cell than
/// its stored `step` (`offsetSteps >= 1`). Only an explicit stroke
/// conversion writes such offsets (a slow spread can push a string one or
/// more cells past the hit's cell); imported, drawn and edited notes keep
/// their offset inside their own cell, so this never matches legacy data.
bool onsetInLaterCell(PitchNote n) => n.offsetSteps >= 1;

/// Notes live playback's cell-by-cell trigger would never reach in a pass
/// that starts at [from] and triggers cells [firstCell].. up to the range
/// end: [onsetInLaterCell] notes whose trigger cell ([cellOf], default the
/// stored `step`) lies before [firstCell] while their actual onset
/// ([onsetOf], default `startSteps`) is at/after [from] and inside [range].
/// Each is returned once with its onset, so the caller schedules it once per
/// pass; notes whose cell is reached by the pass are never listed (no double
/// trigger). Notes already sounding at [from] stay the chase's job.
List<({PitchNote note, double onset})> laterCellOnsets(
  Iterable<PitchNote> notes,
  PlaybackRange range, {
  required double from,
  required int firstCell,
  int Function(PitchNote n)? cellOf,
  double Function(PitchNote n)? onsetOf,
}) => [
  for (final n in notes)
    if (onsetInLaterCell(n) && (cellOf?.call(n) ?? n.step) < firstCell)
      if ((onsetOf?.call(n) ?? n.startSteps) case final onset
          when onset >= from - 1e-9 && range.contains(onset))
        (note: n, onset: onset),
];
