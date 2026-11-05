// harmony-002: Arpeggiate — rewrite selected chords as broken-chord runs.
// docs/specs/harmony/hm-002-arpeggiate.md
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'note_random.dart';
import 'pitch_note_edit.dart';
import 'theory.dart' show midiToFreq;

enum ArpStyle {
  up('Up', '위로'),
  down('Down', '아래로'),
  upDown('Up-Down', '위아래'),
  downUp('Down-Up', '아래위'),
  random('Random', '무작위');

  const ArpStyle(this.label, this.labelKo);
  final String label, labelKo;

  static ArpStyle byName(String name) => ArpStyle.values.firstWhere(
    (s) => s.name == name,
    orElse: () => ArpStyle.up,
  );
}

class ArpSettings {
  const ArpSettings({
    this.style = ArpStyle.up,
    this.grid = QuantizeGrid.sixteenth,
    this.gate = .9,
    this.octaves = 1,
    this.keepOriginalMuted = false,
  });
  final ArpStyle style;

  /// Rate: one run note per grid line.
  final QuantizeGrid grid;

  /// Note length as a fraction of the rate (0.1..2.0).
  final double gate;

  /// 1..4: the chord is repeated this many octaves up inside the pattern.
  final int octaves;

  /// Keep the source chord as muted notes instead of deleting it.
  final bool keepOriginalMuted;
}

/// The pitch order for one chord: Up / Down / Up-Down / Down-Up. Random is
/// generated per round by [_RandomOrder].
List<int> _order(List<int> p, ArpStyle style) {
  final rev = p.reversed.toList();
  switch (style) {
    case ArpStyle.down:
      return rev;
    case ArpStyle.upDown:
      return p.length <= 2 ? p : [...p, ...rev.sublist(1, rev.length - 1)];
    case ArpStyle.downUp:
      return p.length <= 2 ? rev : [...rev, ...p.sublist(1, p.length - 1)];
    case ArpStyle.up:
    case ArpStyle.random:
      return p;
  }
}

/// Random order: each round of |P| notes is a shuffle of P (no repeat inside
/// a round); a round never starts on the pitch the previous one ended on.
class _RandomOrder {
  _RandomOrder(this.p, this.rng);
  final List<int> p;
  final HumRng rng;
  final List<int> _seq = [];

  int at(int i) {
    while (_seq.length <= i) {
      final round = List<int>.of(p);
      for (var k = round.length - 1; k > 0; k--) {
        final j = rng.nextUint32() % (k + 1);
        final t = round[k];
        round[k] = round[j];
        round[j] = t;
      }
      if (_seq.isNotEmpty && round.length > 1 && round.first == _seq.last) {
        final j = 1 + rng.nextUint32() % (round.length - 1);
        final t = round[0];
        round[0] = round[j];
        round[j] = t;
      }
      _seq.addAll(round);
    }
    return _seq[i];
  }
}

/// Arpeggiate the selected chords. Selected notes that are neither locked
/// nor muted are grouped by start (within 0.05 step of the group's first
/// start); a group spans [earliest start, latest end] cut at [steps]. Each
/// group becomes a run on the [ArpSettings.grid] from its start: note i
/// plays the pattern's i-th pitch for `min(grid × gate, end − start_i)`
/// steps (runs shorter than 1/16 step are not created). Run notes are
/// `copyWith`s of the source note of their pitch (velocity, provenance,
/// chance, variation kept; sources are never locked or muted). A one-note
/// group only spreads with octaves ≥ 2. The run takes the place of the
/// group's first note; the other sources are removed — or, with
/// [ArpSettings.keepOriginalMuted], all stay in place muted and the run
/// follows them. Returns the run as the selection; nothing to do returns
/// [notes] itself. [seed] drives the Random style.
PitchNoteEdit arpeggiatePitchNotes(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  ArpSettings s, {
  required int seed,
  required int steps,
}) {
  final pool =
      notes.where((n) => selected.contains(n) && !n.locked && !n.muted).toList()
        ..sort((a, b) => a.startSteps.compareTo(b.startSteps));
  final groups = <List<PitchNote>>[];
  for (final n in pool) {
    if (groups.isNotEmpty &&
        n.startSteps - groups.last.first.startSteps <= .05 + 1e-9) {
      groups.last.add(n);
    } else {
      groups.add([n]);
    }
  }
  final octaves = s.octaves.clamp(1, 4);
  final gate = s.gate.clamp(.1, 2.0);
  final g = s.grid.steps;
  final rng = HumRng(seed);
  final runs = <PitchNote, List<PitchNote>>{}; // anchor → run
  final sources = <PitchNote>{};
  for (final group in groups) {
    if (group.length < 2 && octaves < 2) continue;
    final s0 = group.map((n) => n.startSteps).reduce(math.min);
    final e0 = math.min(
      group.map((n) => n.endSteps).reduce(math.max),
      steps.toDouble(),
    );
    final base = group.map((n) => n.midi).toSet().toList()..sort();
    final byPitch = <int, PitchNote>{};
    for (final n in group) {
      byPitch.putIfAbsent(n.midi, () => n);
    }
    // an octave copy inherits from the note it copies
    PitchNote sourceOf(int pitch) {
      for (var m = pitch; m >= 0; m -= 12) {
        if (byPitch[m] case final n?) return n;
      }
      return group.first;
    }

    final p = [
      for (var j = 0; j < octaves; j++)
        for (final m in base)
          if (m + 12 * j <= 127) m + 12 * j,
    ];
    final q = _order(p, s.style);
    final random = s.style == ArpStyle.random ? _RandomOrder(p, rng) : null;
    final run = <PitchNote>[];
    for (var i = 0; ; i++) {
      final t = tidySteps(s0 + i * g);
      if (t >= e0 - 1e-9) break;
      final length = math.min(g * gate, e0 - t);
      if (length < 1 / 16 - 1e-9) continue;
      final pitch = random?.at(i) ?? q[i % q.length];
      final source = sourceOf(pitch);
      var n = pitchNoteWithBounds(source, t, tidySteps(t + length));
      if (pitch != source.midi) {
        n = n.copyWith(midi: pitch, freq: midiToFreq(pitch));
      }
      run.add(n);
    }
    if (run.isEmpty) continue;
    sources.addAll(group);
    // the run goes where the group's first (keep: last) list entry was
    final members = notes.where(group.contains);
    runs[s.keepOriginalMuted ? members.last : members.first] = run;
  }
  if (runs.isEmpty) return (notes: notes, selection: selected);
  final out = <PitchNote>[];
  final selection = <PitchNote>{};
  for (final n in notes) {
    final run = runs[n];
    if (!sources.contains(n)) {
      out.add(n);
    } else if (s.keepOriginalMuted) {
      out.add(n.copyWith(muted: true));
    }
    if (run != null) {
      out.addAll(run);
      selection.addAll(run);
    }
  }
  return (notes: out, selection: selection);
}
