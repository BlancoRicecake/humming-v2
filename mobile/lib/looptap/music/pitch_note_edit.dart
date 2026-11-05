import 'dart:math' as math;

import '../models/loop_models.dart';
import 'note_random.dart';
import 'theory.dart'
    show ChordType, chordBelow, midiToFreq, nearestInScale, stepInScale;

/// Move the editable selection as one group, clamping its relative spacing at
/// loop/MIDI boundaries. Moving on the grid preserves each note's micro-offset.
/// gt-001: a move that changes the start drops a guitar stroke tag (its base
/// timing would be stale); a pitch-only move keeps it.
List<PitchNote> movePitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected, {
  required double deltaSteps,
  required int semitones,
  required int steps,
}) {
  final targets =
      notes.where((n) => selected.contains(n) && !n.locked).toList();
  if (targets.isEmpty) return notes;
  final first = targets.map((n) => n.startSteps).reduce(math.min);
  final last = targets.map((n) => n.endSteps).reduce(math.max);
  if (last - first > steps) return notes;
  final shift = deltaSteps.clamp(-first, steps - last).toDouble();
  final low = targets.map((n) => n.midi).reduce(math.min);
  final high = targets.map((n) => n.midi).reduce(math.max);
  final pitch = semitones.clamp(-low, 127 - high);
  if (shift == 0 && pitch == 0) return notes;
  return [
    for (final n in notes)
      if (!selected.contains(n) || n.locked)
        n
      else
        _moveNote(n, shift, pitch, keepStroke: shift == 0),
  ];
}

PitchNote _moveNote(
  PitchNote n,
  double delta,
  int pitch, {
  bool keepStroke = true,
}) {
  final whole = delta == delta.roundToDouble();
  final start = n.startSteps + delta;
  final step = whole ? n.step + delta.toInt() : start.floor();
  return n.copyWith(
    midi: n.midi + pitch,
    freq: pitch == 0 ? n.freq : midiToFreq(n.midi + pitch),
    step: step,
    offsetSteps: whole ? n.offsetSteps : start - step,
    clearStroke: !keepStroke,
  );
}

/// Resize ends together, preserving starts and allowing existing tiny MIDI
/// gates. Editing never merges overlapping attacks or edits locked notes.
List<PitchNote> resizePitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected, {
  required double deltaSteps,
  required int steps,
}) {
  final targets =
      notes.where((n) => selected.contains(n) && !n.locked).toList();
  if (targets.isEmpty) return notes;
  final lower = targets
      .map((n) => math.min(1 / 16, n.soundingSteps) - n.soundingSteps)
      .reduce(math.max);
  final upper = targets.map((n) => steps - n.endSteps).reduce(math.min);
  if (upper < lower) return notes;
  final delta = deltaSteps.clamp(lower, upper).toDouble();
  if (delta == 0) return notes;
  return [
    for (final n in notes)
      if (!selected.contains(n) || n.locked)
        n
      else
        _withBounds(n, n.startSteps, n.endSteps + delta),
  ];
}

/// Relative velocity edit for selected notes. Keep their expressive differences
/// and all timing/provenance fields; a cancelled/no-op gesture changes nothing.
/// gt-001: an edited note drops its guitar stroke tag (velocity edits make the
/// stored base stale; the explicit velocity/length stay, so the legacy strum
/// still never re-applies).
List<PitchNote> shiftPitchVelocities(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  int delta,
) {
  if (delta == 0) return notes;
  return [
    for (final n in notes)
      if (!selected.contains(n) ||
          n.locked ||
          (n.velocity ?? 100) == ((n.velocity ?? 100) + delta).clamp(1, 127))
        n
      else
        n.copyWith(
          velocity: ((n.velocity ?? 100) + delta).clamp(1, 127),
          clearStroke: true,
        ),
  ];
}

List<PitchNote> setPitchVelocity(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  int velocity,
) {
  final strength = velocity.clamp(1, 127);
  var changed = false;
  final edited = [
    for (final n in notes)
      if (!selected.contains(n) || n.locked || n.velocity == strength)
        n
      else
        (() {
          changed = true;
          return n.copyWith(velocity: strength, clearStroke: true);
        })(),
  ];
  return changed ? edited : notes;
}

/// Shared shape of the per-note property setters: skip unselected/locked
/// notes and unchanged values; a no-op returns [notes] itself.
List<PitchNote> _mapEditable(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  PitchNote? Function(PitchNote n) edit,
) {
  var changed = false;
  final out = [
    for (final n in notes)
      if (!selected.contains(n) || n.locked)
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

/// Set the play probability (0..1) of the selection.
List<PitchNote> setPitchChance(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  double chance,
) {
  final c = chance.clamp(0.0, 1.0).toDouble();
  return _mapEditable(
    notes,
    selected,
    (n) => n.chance == c ? null : n.copyWith(chance: c),
  );
}

/// Relative chance edit (e.g. ±0.1), each note clamped to 0..1.
List<PitchNote> shiftPitchChance(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  double delta,
) {
  if (delta == 0) return notes;
  return _mapEditable(notes, selected, (n) {
    // round away float noise so ten +0.1 steps land exactly on 1.0
    final c = ((n.chance + delta).clamp(0.0, 1.0) * 1e6).round() / 1e6;
    return c == n.chance ? null : n.copyWith(chance: c);
  });
}

/// Set the per-pass velocity variation range of the selection.
List<PitchNote> setPitchVelocityDeviation(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  int deviation,
) {
  final d = deviation.clamp(-127, 127).toInt();
  return _mapEditable(
    notes,
    selected,
    (n) => n.velocityDeviation == d ? null : n.copyWith(velocityDeviation: d),
  );
}

List<PitchNote> deletePitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected,
) {
  final edited = notes.where((n) => !selected.contains(n) || n.locked).toList();
  return edited.length == notes.length ? notes : edited;
}

/// Only an explicit lock/unlock command changes protection; ordinary edits
/// continue to skip locked notes.
List<PitchNote> setPitchNotesLocked(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  bool locked,
) {
  if (!notes.any((n) => selected.contains(n) && n.locked != locked)) {
    return notes;
  }
  return [
    for (final n in notes)
      if (selected.contains(n) && n.locked != locked)
        n.copyWith(locked: locked)
      else
        n,
  ];
}

/// Deactivate/reactivate selected notes. Locked notes are skipped like any
/// other edit; unchanged notes keep their identity, and a no-op returns
/// [notes] itself.
List<PitchNote> setPitchNotesMuted(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  bool muted,
) {
  bool target(PitchNote n) =>
      selected.contains(n) && !n.locked && n.muted != muted;
  if (!notes.any(target)) return notes;
  return [
    for (final n in notes) if (target(n)) n.copyWith(muted: muted) else n,
  ];
}

/// Fit to scale: move each selected, unlocked note that is outside
/// [root] + [scale] to the nearest scale pitch (ties go down). Timing,
/// strength and mute state stay; the first pre-correction pitch is kept in
/// `sourceMidi` so raw/corrected listening still works. Chromatic or nothing
/// to change returns [notes] itself.
List<PitchNote> fitPitchNotesToScale(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  String root,
  String scale,
) {
  var changed = false;
  final edited = [
    for (final n in notes)
      if (!selected.contains(n) || n.locked)
        n
      else
        (() {
          final to = nearestInScale(n.midi, root, scale);
          if (to == n.midi) return n;
          changed = true;
          return n.copyWith(
            midi: to,
            freq: midiToFreq(to),
            sourceMidi: n.sourceMidi ?? n.midi,
            assisted: true,
          );
        })(),
  ];
  return changed ? edited : notes;
}

/// Scale-snap transpose: each selected, unlocked note moves to the next scale
/// pitch above/below (per-note distance can differ). If any note would leave
/// 0..127 the whole move is rejected, like [movePitchNotes]'s group clamp.
List<PitchNote> movePitchNotesInScale(
  List<PitchNote> notes,
  Set<PitchNote> selected, {
  required String root,
  required String scale,
  required int dir,
}) {
  final moved = <PitchNote, int>{
    for (final n in notes)
      if (selected.contains(n) && !n.locked)
        n: stepInScale(n.midi, root, scale, dir),
  };
  if (moved.isEmpty || moved.values.any((m) => m < 0 || m > 127)) {
    return notes;
  }
  return [
    for (final n in notes)
      if (moved[n] case final to?)
        n.copyWith(midi: to, freq: midiToFreq(to))
      else
        n,
  ];
}

/// Quantize grid sizes in sixteenth steps (triplets included).
enum QuantizeGrid {
  quarter(4, '1/4'),
  eighth(2, '1/8'),
  sixteenth(1, '1/16'),
  thirtySecond(.5, '1/32'),
  eighthTriplet(4 / 3, '1/8T'),
  sixteenthTriplet(2 / 3, '1/16T');

  const QuantizeGrid(this.steps, this.label);
  final double steps;
  final String label;

  static QuantizeGrid byName(String name) => QuantizeGrid.values.firstWhere(
    (g) => g.name == name,
    orElse: () => QuantizeGrid.sixteenth,
  );
}

/// Nearest multiple of [grid]; an exact midpoint goes to the later line.
double _nearestLine(double x, double grid) {
  final q = x / grid;
  final f = q.floor();
  return (q - f >= .5 - 1e-9 ? f + 1 : f) * grid;
}

double _tidy(double x) {
  final r = x.roundToDouble();
  return (x - r).abs() < 1e-6 ? r : x;
}

/// Move selected, unlocked note starts toward the nearest [grid] line by
/// [strength] (0..1). With [ends] the end moves toward its own nearest line
/// (never onto or before the start's line); otherwise the length is kept.
/// Ends are cut at [steps]; lengths never drop below 1/16 step. Pitch,
/// strength and metadata are untouched; notes are never merged or removed.
/// Returns [notes] itself when nothing moves.
List<PitchNote> quantizePitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected, {
  required double grid,
  required double strength,
  required bool ends,
  required int steps,
}) {
  final k = strength.clamp(0.0, 1.0).toDouble();
  if (k == 0 || grid <= 0) return notes;
  var changed = false;
  final out = <PitchNote>[];
  for (final n in notes) {
    if (!selected.contains(n) || n.locked) {
      out.add(n);
      continue;
    }
    final s = n.startSteps, e = n.endSteps;
    var target = _nearestLine(s, grid);
    if (target >= steps - 1e-9) {
      target = ((steps / grid - 1e-9).ceil() - 1) * grid;
    }
    final start = _tidy(s + (target - s) * k);
    double end;
    if (ends) {
      var endTarget = _nearestLine(e, grid);
      if (endTarget <= target + 1e-9) endTarget = target + grid;
      end = e + (endTarget - e) * k;
    } else {
      end = start + (e - s);
    }
    end = _tidy(math.max(start + 1 / 16, math.min(end, steps.toDouble())));
    if ((start - s).abs() < 1e-9 && (end - e).abs() < 1e-9) {
      out.add(n);
      continue;
    }
    changed = true;
    out.add(_withBounds(n, start, end));
  }
  return changed ? out : notes;
}

/// Public forms of the quantize helpers, shared by the drum and arpeggiate
/// tools so every editor rounds the same way.
double nearestGridLine(double x, double grid) => _nearestLine(x, grid);
double tidySteps(double x) => _tidy(x);

/// [source] re-timed to [start, end) with the editor's step/offset/length
/// rules; every other field is kept (`copyWith`).
PitchNote pitchNoteWithBounds(PitchNote source, double start, double end) =>
    _withBounds(source, start, end);

/// Notes that share a pitch and start (±1e-6) with an earlier note in the
/// list — the stacks a quantize may create (they are kept, only reported).
int stackedPitchNoteCount(List<PitchNote> notes) {
  final seen = <(int, int)>{};
  var stacked = 0;
  for (final n in notes) {
    if (!seen.add((n.midi, (n.startSteps * 1e6).round()))) stacked++;
  }
  return stacked;
}

/// A note edit that also reports the resulting selection (the note count may
/// change, so index-based selection tracking would be wrong).
typedef PitchNoteEdit = ({List<PitchNote> notes, Set<PitchNote> selection});

/// Cut each selected, unlocked note at the given boundaries. Every piece is a
/// `copyWith` of the source (velocity, provenance, mute, chance… inherited);
/// the first keeps the source's step/offset. A note whose cuts would leave a
/// piece shorter than 1/16 step, or that has no interior cut, is left whole.
PitchNoteEdit _cutPitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  List<double> Function(PitchNote n) cutsOf,
) {
  var changed = false;
  final out = <PitchNote>[];
  final selection = <PitchNote>{};
  for (final n in notes) {
    final s = n.startSteps, e = n.endSteps;
    final cuts =
        !selected.contains(n) || n.locked
            ? const <double>[]
            : ([
                for (final c in cutsOf(n))
                  if (c > s + 1e-6 && c < e - 1e-6) _tidy(c),
              ]..sort());
    final edges = [s, ...cuts, e];
    var ok = cuts.isNotEmpty;
    for (var i = 0; ok && i + 1 < edges.length; i++) {
      if (edges[i + 1] - edges[i] < 1 / 16 - 1e-9) ok = false;
    }
    if (!ok) {
      out.add(n);
      if (selected.contains(n)) selection.add(n);
      continue;
    }
    changed = true;
    for (var i = 0; i + 1 < edges.length; i++) {
      final piece = _withBounds(n, edges[i], edges[i + 1]);
      out.add(piece);
      selection.add(piece);
    }
  }
  return changed
      ? (notes: out, selection: selection)
      : (notes: notes, selection: selected);
}

/// Split selected notes that strictly contain [at] into two pieces there.
PitchNoteEdit splitPitchNotesAt(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  double at,
) => _cutPitchNotes(notes, selected, (_) => [at]);

/// Split each selected note at its own position (e.g. its middle).
PitchNoteEdit splitPitchNotesEach(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  double Function(PitchNote n) at,
) => _cutPitchNotes(notes, selected, (n) => [at(n)]);

/// Chop selected notes into [parts] equal pieces, or at every absolute
/// [grid] line inside them (the last piece may be shorter).
PitchNoteEdit chopPitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected, {
  int? parts,
  double? grid,
}) => _cutPitchNotes(notes, selected, (n) {
  final s = n.startSteps, e = n.endSteps;
  if (parts != null && parts >= 2) {
    return [for (var i = 1; i < parts; i++) s + (e - s) * i / parts];
  }
  if (grid != null && grid > 0) {
    return [
      for (var i = (s / grid).floor() + 1; i * grid < e - 1e-6; i++)
        i * grid,
    ];
  }
  return const [];
});

/// Glue selected, unlocked notes of the same pitch into one per run. A run is
/// broken by an unselected or locked same-pitch note starting between them.
/// The earliest note is the anchor (its velocity, provenance, offset, chance
/// are kept); the end is the run's latest end; confidence is the minimum,
/// `assisted` if any, `muted` only if all were muted.
PitchNoteEdit gluePitchNotes(List<PitchNote> notes, Set<PitchNote> selected) {
  final index = {for (var i = 0; i < notes.length; i++) notes[i]: i};
  final byPitch = <int, List<PitchNote>>{};
  for (final n in notes) {
    byPitch.putIfAbsent(n.midi, () => []).add(n);
  }
  final replace = <PitchNote, PitchNote>{};
  final drop = <PitchNote>{};
  for (final row in byPitch.values) {
    if (!row.any((n) => selected.contains(n) && !n.locked)) continue;
    row.sort((a, b) {
      final c = a.startSteps.compareTo(b.startSteps);
      return c != 0 ? c : index[a]!.compareTo(index[b]!);
    });
    var run = <PitchNote>[];
    void flush() {
      if (run.length >= 2) {
        final anchor = run.first;
        final end = run.map((n) => n.endSteps).reduce(math.max);
        replace[anchor] = _withBounds(
          anchor,
          anchor.startSteps,
          end,
        ).copyWith(
          confidence: run.map((n) => n.confidence).reduce(math.min),
          assisted: run.any((n) => n.assisted),
          muted: run.every((n) => n.muted),
          stroke: anchor.stroke, // gt-001: the earliest part's tag
        );
        drop.addAll(run.skip(1));
      }
      run = [];
    }

    for (final n in row) {
      if (selected.contains(n) && !n.locked) {
        run.add(n);
      } else {
        flush();
      }
    }
    flush();
  }
  if (replace.isEmpty) return (notes: notes, selection: selected);
  final out = [
    for (final n in notes)
      if (!drop.contains(n)) replace[n] ?? n,
  ];
  return (
    notes: out,
    selection: {
      for (final n in out)
        if (replace.containsValue(n) || selected.contains(n)) n,
    },
  );
}

/// Legato: each selected, unlocked note ends where the next later-starting
/// selected note begins (pitch ignored), the last ones at [steps]. Notes
/// starting together (±1e-6) share the same end, so chords move as blocks.
/// Locked notes keep their length but still mark a start; muted notes are
/// resized but never mark one. Starts never move.
List<PitchNote> legatoPitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected, {
  required int steps,
}) {
  final starts =
      notes
          .where((n) => selected.contains(n) && !n.muted)
          .map((n) => n.startSteps)
          .toList()
        ..sort();
  var changed = false;
  final out = [
    for (final n in notes)
      if (!selected.contains(n) || n.locked)
        n
      else
        (() {
          final s = n.startSteps;
          final next = starts.firstWhere(
            (r) => r > s + 1e-6,
            orElse: () => steps.toDouble(),
          );
          final end = math.max(next, s + 1 / 16);
          if ((end - n.endSteps).abs() < 1e-9) return n;
          changed = true;
          return _withBounds(n, s, end);
        })(),
  ];
  return changed ? out : notes;
}

/// Humanize (destructive, applied once): each selected, unlocked note's
/// start moves by up to ±[timingSteps] (length kept, clamped inside the
/// loop) and its velocity by up to ±[velocityRange]. Deterministic for a
/// given [seed]: targets are ordered by (start, pitch, list index) and each
/// draws exactly two values (timing, then velocity) even when a range is 0,
/// so one setting never reshuffles the other. Locked notes draw nothing.
List<PitchNote> humanizePitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected, {
  required double timingSteps,
  required int velocityRange,
  required int seed,
  required int steps,
}) {
  if (timingSteps <= 0 && velocityRange <= 0) return notes;
  final order = [
    for (var i = 0; i < notes.length; i++)
      if (selected.contains(notes[i]) && !notes[i].locked) i,
  ]..sort((a, b) {
    final x = notes[a], y = notes[b];
    final c = x.startSteps.compareTo(y.startSteps);
    if (c != 0) return c;
    return x.midi != y.midi ? x.midi.compareTo(y.midi) : a.compareTo(b);
  });
  final rng = HumRng(seed);
  final out = List<PitchNote>.of(notes);
  var changed = false;
  for (final i in order) {
    final n = notes[i];
    final dt = (2 * rng.nextDouble() - 1) * timingSteps;
    final dv = ((2 * rng.nextDouble() - 1) * velocityRange).round();
    final length = n.soundingSteps;
    var start = n.startSteps;
    if (dt != 0) {
      start =
          length >= steps
              ? 0
              : (start + dt).clamp(0, steps - length).toDouble();
    }
    final moved = start != n.startSteps;
    final velocity =
        dv == 0 ? n.velocity : ((n.velocity ?? 100) + dv).clamp(1, 127);
    if (!moved && velocity == n.velocity) continue;
    var edited = n;
    if (moved) {
      edited = _withBounds(n, start, start + length);
      // keep the exact length (start + length - start can round)
      if (edited.durationSteps != null) {
        edited = edited.copyWith(
          dur: math.max(1, length.ceil()),
          durationSteps: length,
        );
      }
    }
    if (velocity != n.velocity) {
      edited = edited.copyWith(velocity: velocity, clearStroke: true);
    }
    out[i] = edited;
    changed = true;
  }
  return changed ? out : notes;
}

/// Duplicate into the following selection-sized span. Reject a partial copy
/// at the loop edge rather than shifting/clipping the copy onto its source.
List<PitchNote> duplicatePitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  int steps,
) {
  final targets =
      notes.where((n) => selected.contains(n) && !n.locked).toList();
  if (targets.isEmpty) return notes;
  final first = targets.map((n) => n.startSteps).reduce(math.min);
  final last = targets.map((n) => n.endSteps).reduce(math.max);
  final distance = math.max(1, (last - first).ceil());
  if (last + distance > steps) return notes;
  return [
    ...notes,
    for (final n in targets) _moveNote(n, distance.toDouble(), 0),
  ];
}

/// Remove only the audible intersection with [cell, cell + 1).
/// Untouched notes keep their identity; fragments keep the source's expression.
/// Returning [notes] itself denotes a no-op (including edits to locked notes).
List<PitchNote> erasePitchCell(List<PitchNote> notes, int midi, int cell) {
  final result = <PitchNote>[];
  var changed = false;
  for (final note in notes) {
    if (note.midi != midi || note.locked || !note.overlapsCell(cell)) {
      result.add(note);
      continue;
    }
    changed = true;
    if (note.startSteps < cell) {
      result.add(_withBounds(note, note.startSteps, cell.toDouble()));
    }
    if (note.endSteps > cell + 1) {
      result.add(_withBounds(note, cell + 1.0, note.endSteps));
    }
  }
  return changed ? result : notes;
}

/// Paint an inclusive integer-cell span without discarding existing expression.
/// A single touched note can be extended using its own strength and metadata.
/// Plain hand-drawn notes retain the legacy connected-overlap merge behavior.
/// Multiple expressive attacks, or locked notes, stay separate: only uncovered
/// parts of the drawn span are filled, rather than choosing one note's velocity
/// and silently replacing all the others.
List<PitchNote> paintPitchSpan(List<PitchNote> notes, PitchNote incoming) {
  var lo = incoming.startSteps;
  var hi = incoming.endSteps;
  final touched = <PitchNote>{};
  // Fixed point: list order must not affect which overlapping notes are merged.
  var grew = true;
  while (grew) {
    grew = false;
    for (final note in notes) {
      // A deactivated note neither merges with nor blocks a new audible one.
      if (note.midi != incoming.midi ||
          note.muted ||
          touched.contains(note)) {
        continue;
      }
      if (note.startSteps < hi && note.endSteps > lo) {
        touched.add(note);
        lo = math.min(lo, note.startSteps);
        hi = math.max(hi, note.endSteps);
        grew = true;
      }
    }
  }
  if (touched.isEmpty) return [...notes, incoming];
  final canMerge =
      touched.length == 1 && !touched.single.locked ||
      touched.every(_plainNote) && _plainNote(incoming);
  if (canMerge) {
    final anchor = touched.reduce(
      (a, b) => a.startSteps <= b.startSteps ? a : b,
    );
    if (touched.length == 1 &&
        lo == anchor.startSteps &&
        hi == anchor.endSteps) {
      return notes;
    }
    return [
      for (final note in notes)
        if (!touched.contains(note)) note,
      _withBounds(anchor, lo, hi),
    ];
  }

  // Keep every existing attack (and locked span). Add only new audible gaps.
  final covered =
      notes.where((n) => n.midi == incoming.midi && !n.muted).toList()
        ..sort((a, b) => a.startSteps.compareTo(b.startSteps));
  var cursor = incoming.startSteps;
  final added = <PitchNote>[];
  for (final note in covered) {
    if (note.endSteps <= cursor) continue;
    if (note.startSteps >= incoming.endSteps) break;
    if (note.startSteps > cursor) {
      added.add(_withBounds(incoming, cursor, note.startSteps));
    }
    cursor = math.max(cursor, note.endSteps);
    if (cursor >= incoming.endSteps) break;
  }
  if (cursor < incoming.endSteps) {
    added.add(_withBounds(incoming, cursor, incoming.endSteps));
  }
  return added.isEmpty ? notes : [...notes, ...added];
}

/// A chord member made from [base]: same timing and expression (velocity,
/// mute, chance, variation), new pitch, and reset provenance (it is not an
/// analysis result) and lock.
PitchNote _chordMember(PitchNote base, int midi) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: base.step,
  dur: base.dur,
  offsetSteps: base.offsetSteps,
  durationSteps: base.durationSteps,
  velocity: base.velocity,
  muted: base.muted,
  chance: base.chance,
  velocityDeviation: base.velocityDeviation,
);

/// Chord stamp, top-down (harmony-001): under each selected melody note add
/// the other [type] chord members (see `chordBelow`) with the same start and
/// length. Among selected notes starting together (±1e-6) only the highest
/// is used. Locked notes can be the melody (they are not changed). Members
/// that already exist (same pitch and start) or fall outside 0..127 are
/// skipped. The selection becomes the added notes; nothing to add returns
/// [notes] itself.
PitchNoteEdit stampChordsBelow(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  ChordType type, {
  required String key,
  required String? scale,
}) {
  final tops = <int, PitchNote>{};
  for (final n in notes) {
    if (!selected.contains(n)) continue;
    final at = (n.startSteps * 1e6).round();
    final other = tops.entries
        .where((e) => (e.key - at).abs() <= 1)
        .map((e) => e.key)
        .firstOrNull;
    if (other == null) {
      tops[at] = n;
    } else if (n.midi > tops[other]!.midi) {
      tops[other] = n;
    }
  }
  final taken = {
    for (final n in notes) (n.midi, (n.startSteps * 1e6).round()),
  };
  bool exists(int midi, double start) {
    final at = (start * 1e6).round();
    return taken.contains((midi, at)) ||
        taken.contains((midi, at - 1)) ||
        taken.contains((midi, at + 1));
  }

  final added = <PitchNote>[];
  for (final top in tops.values) {
    for (final m in chordBelow(type, top.midi, key: key, scale: scale)) {
      if (m < 0 || m > 127 || exists(m, top.startSteps)) continue;
      final member = _chordMember(top, m);
      added.add(member);
      taken.add((m, (member.startSteps * 1e6).round()));
    }
  }
  if (added.isEmpty) return (notes: notes, selection: selected);
  return (notes: [...notes, ...added], selection: added.toSet());
}

/// Chord stamp, bottom-up (harmony-001): paint [seed] once per pitch in
/// [midis] with the normal drawing rules (`paintPitchSpan`). Pitches outside
/// 0..127 are skipped. The selection is the notes this created or extended;
/// a no-op returns [notes] itself.
PitchNoteEdit stampChordAt(
  List<PitchNote> notes,
  PitchNote seed,
  List<int> midis,
) {
  var out = notes;
  for (final m in midis) {
    if (m < 0 || m > 127) continue;
    out = paintPitchSpan(out, _chordMember(seed, m));
  }
  if (identical(out, notes)) return (notes: notes, selection: const {});
  final before = notes.toSet();
  return (
    notes: out,
    selection: {
      for (final n in out)
        if (!before.contains(n)) n,
    },
  );
}

bool _plainNote(PitchNote note) =>
    note.velocity == null &&
    note.offsetSteps == 0 &&
    note.durationSteps == null &&
    note.sourceMidi == null &&
    note.confidence == 1 &&
    !note.assisted &&
    !note.locked &&
    !note.muted &&
    note.chance == 1 &&
    note.velocityDeviation == 0 &&
    // gt-003: an articulated note is expressive; never merged away
    note.articulation == null;

/// Re-timing drops a guitar stroke tag (gt-001: split/chop/quantize/
/// humanize/legato/resize keep the concrete timing, not the stroke) and a
/// gt-002 ring base (the new length is the note's own); the guitar string
/// is kept.
PitchNote _withBounds(PitchNote source, double start, double end) {
  final sameStart = start == source.startSteps;
  final step = sameStart ? source.step : start.floor();
  final duration = end - start;
  final precise =
      source.durationSteps != null ||
      source.offsetSteps != 0 ||
      start != step ||
      duration != duration.roundToDouble();
  return source.copyWith(
    step: step,
    dur: math.max(1, duration.ceil()),
    offsetSteps: sameStart ? source.offsetSteps : start - step,
    durationSteps: precise ? duration : null,
    clearStroke: true,
    clearRing: true,
  );
}
