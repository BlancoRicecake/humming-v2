// drums-001: selection-based edits for drum hits, the drum counterpart of
// pitch_note_edit.dart. docs/specs/drums/dr-001-drum-selection-velocity.md
//
// Every function is pure: hits that change become new objects (`copyWith`),
// the rest keep their identity, and a no-op returns the input list itself
// (the editor then records no undo step). Drum hits have no lock.
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'note_random.dart';
import 'percussion.dart';
import 'pitch_note_edit.dart' show nearestGridLine, tidySteps;

/// A hit placed at [start] (in steps): integer cell + fractional offset.
DrumNote _drumAt(DrumNote n, double start) {
  final t = tidySteps(start);
  final step = t.floor();
  return n.copyWith(step: step, offsetSteps: tidySteps(t - step));
}

/// Apply [edit] to each selected hit; null = unchanged.
List<DrumNote> _mapSelected(
  List<DrumNote> notes,
  Set<DrumNote> selected,
  DrumNote? Function(DrumNote n) edit,
) {
  var changed = false;
  final out = [
    for (final n in notes)
      if (!selected.contains(n))
        n
      else
        (() {
          final e = edit(n);
          if (e == null) return n;
          changed = true;
          return e;
        })(),
  ];
  return changed ? out : notes;
}

/// Move the selection in time as one group. A whole-step move keeps each
/// hit's micro offset. The group stops at the section edges: no hit starts
/// before 0 or after the start of the last cell.
List<DrumNote> moveDrumNotes(
  List<DrumNote> notes,
  Set<DrumNote> selected, {
  required double deltaSteps,
  required int steps,
}) {
  final targets = notes.where(selected.contains).toList();
  if (targets.isEmpty || deltaSteps == 0) return notes;
  final first = targets.map((n) => n.startSteps).reduce(math.min);
  final last = targets.map((n) => n.startSteps).reduce(math.max);
  final shift =
      deltaSteps > 0
          ? math.min(deltaSteps, math.max(0.0, steps - 1 - last))
          : math.max(deltaSteps, -first);
  if (shift == 0) return notes;
  final whole = shift == shift.roundToDouble();
  return _mapSelected(
    notes,
    selected,
    (n) =>
        whole
            ? n.copyWith(step: n.step + shift.toInt())
            : _drumAt(n, n.startSteps + shift),
  );
}

List<DrumNote> deleteDrumNotes(List<DrumNote> notes, Set<DrumNote> selected) {
  final out = notes.where((n) => !selected.contains(n)).toList();
  return out.length == notes.length ? notes : out;
}

/// Set the selection's velocity (1..127).
List<DrumNote> setDrumVelocity(
  List<DrumNote> notes,
  Set<DrumNote> selected,
  int velocity,
) {
  final v = velocity.clamp(1, 127);
  return _mapSelected(
    notes,
    selected,
    (n) => n.velocity == v ? null : n.copyWith(velocity: v),
  );
}

/// Relative velocity edit (same rule as `shiftPitchVelocities`): each hit
/// moves by [delta] from its own value (null counts as 100), clamped 1..127.
List<DrumNote> shiftDrumVelocities(
  List<DrumNote> notes,
  Set<DrumNote> selected,
  int delta,
) {
  if (delta == 0) return notes;
  return _mapSelected(notes, selected, (n) {
    final from = n.velocity ?? 100;
    final to = (from + delta).clamp(1, 127);
    return to == from ? null : n.copyWith(velocity: to);
  });
}

/// Deactivate/reactivate the selection.
List<DrumNote> setDrumNotesMuted(
  List<DrumNote> notes,
  Set<DrumNote> selected,
  bool muted,
) => _mapSelected(
  notes,
  selected,
  (n) => n.muted == muted ? null : n.copyWith(muted: muted),
);

/// Set the play probability (0..1) of the selection.
List<DrumNote> setDrumChance(
  List<DrumNote> notes,
  Set<DrumNote> selected,
  double chance,
) {
  final c = chance.clamp(0.0, 1.0).toDouble();
  return _mapSelected(
    notes,
    selected,
    (n) => n.chance == c ? null : n.copyWith(chance: c),
  );
}

/// Relative chance edit (e.g. ±0.1), each hit clamped to 0..1.
List<DrumNote> shiftDrumChance(
  List<DrumNote> notes,
  Set<DrumNote> selected,
  double delta,
) {
  if (delta == 0) return notes;
  return _mapSelected(notes, selected, (n) {
    final c = ((n.chance + delta).clamp(0.0, 1.0) * 1e6).round() / 1e6;
    return c == n.chance ? null : n.copyWith(chance: c);
  });
}

/// Set the per-pass velocity variation range of the selection.
List<DrumNote> setDrumVelocityDeviation(
  List<DrumNote> notes,
  Set<DrumNote> selected,
  int deviation,
) {
  final d = deviation.clamp(-127, 127).toInt();
  return _mapSelected(
    notes,
    selected,
    (n) => n.velocityDeviation == d ? null : n.copyWith(velocityDeviation: d),
  );
}

/// Move selected hit starts toward the nearest [grid] line by [strength]
/// (0..1). Starts only (drum hits have no musical end); hits are never
/// merged or removed. Same grid, strength and tie rules as
/// `quantizePitchNotes`.
List<DrumNote> quantizeDrumNotes(
  List<DrumNote> notes,
  Set<DrumNote> selected, {
  required double grid,
  required double strength,
  required int steps,
}) {
  final k = strength.clamp(0.0, 1.0).toDouble();
  if (k == 0 || grid <= 0) return notes;
  return _mapSelected(notes, selected, (n) {
    final s = n.startSteps;
    var target = nearestGridLine(s, grid);
    if (target >= steps - 1e-9) {
      target = ((steps / grid - 1e-9).ceil() - 1) * grid;
    }
    final start = tidySteps(s + (target - s) * k);
    if ((start - s).abs() < 1e-9) return null;
    return _drumAt(n, start);
  });
}

/// Hits that share a kind and start (±1e-6) with an earlier hit.
int stackedDrumNoteCount(List<DrumNote> notes) {
  final seen = <(String, int)>{};
  var stacked = 0;
  for (final n in notes) {
    if (!seen.add((n.kind, (n.startSteps * 1e6).round()))) stacked++;
  }
  return stacked;
}

/// Humanize (destructive, applied once): timing + velocity, no length.
/// Targets are ordered by (start, GM percussion key, list index) and each
/// draws exactly two values (timing, then velocity), like
/// `humanizePitchNotes`.
List<DrumNote> humanizeDrumNotes(
  List<DrumNote> notes,
  Set<DrumNote> selected, {
  required double timingSteps,
  required int velocityRange,
  required int seed,
  required int steps,
}) {
  if (timingSteps <= 0 && velocityRange <= 0) return notes;
  final order = [
    for (var i = 0; i < notes.length; i++)
      if (selected.contains(notes[i])) i,
  ]..sort((a, b) {
    final x = notes[a], y = notes[b];
    final c = x.startSteps.compareTo(y.startSteps);
    if (c != 0) return c;
    final kx = percussionMidi(x.kind) ?? 0, ky = percussionMidi(y.kind) ?? 0;
    return kx != ky ? kx.compareTo(ky) : a.compareTo(b);
  });
  final rng = HumRng(seed);
  final out = List<DrumNote>.of(notes);
  var changed = false;
  final latest = math.max(0.0, steps - 1 / 16);
  for (final i in order) {
    final n = notes[i];
    final dt = (2 * rng.nextDouble() - 1) * timingSteps;
    final dv = ((2 * rng.nextDouble() - 1) * velocityRange).round();
    var start = n.startSteps;
    if (dt != 0) start = (start + dt).clamp(0.0, latest).toDouble();
    final moved = (start - n.startSteps).abs() > 1e-12;
    final velocity =
        dv == 0 ? n.velocity : ((n.velocity ?? 100) + dv).clamp(1, 127);
    if (!moved && velocity == n.velocity) continue;
    var edited = moved ? _drumAt(n, start) : n;
    if (velocity != n.velocity) edited = edited.copyWith(velocity: velocity);
    out[i] = edited;
    changed = true;
  }
  return changed ? out : notes;
}

/// Beat-Fill pad sound swap: hits of [from] become [to], keeping velocity,
/// micro timing, chance, variation and mute. A hit that would land on a
/// (kind, step) already taken is dropped, as before.
List<DrumNote> remapDrumKind(List<DrumNote> notes, String from, String to) {
  final seen = <String>{};
  final out = <DrumNote>[];
  for (final n in notes) {
    final k = n.kind == from ? to : n.kind;
    if (seen.add('$k:${n.step}')) {
      out.add(k == n.kind ? n : n.copyWith(kind: k));
    }
  }
  return out;
}
