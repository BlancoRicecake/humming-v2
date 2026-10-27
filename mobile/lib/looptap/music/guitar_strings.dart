// gt-002 guitar strings: standard-tuning string assignment, the ringing
// arpeggio ("울림 아르페지오") and same-string choke. Every result is
// written into note data (string number, realized length), so live
// playback, MIDI export and WAV render read the same events. Opt-in only:
// nothing here runs unless the user assigns strings or applies a ring.
//
// Rules (see docs/specs/guitar/gt-002-string-assignment-ring.md):
// - A note is never moved in pitch or time and never deleted. A note that
//   cannot be placed stays unassigned and is reported (unassignable).
// - A chord hit is identified by its pre-stroke start (gt-001
//   [strokeGroupStart]); notes of one hit always get distinct strings even
//   when a stroke staggered their actual starts.
// - Two notes whose sounding intervals overlap go on different strings,
//   unless no other string fits: then the later one chokes the earlier one
//   (it is cut at the later onset). A note outside the edit (unselected,
//   locked or muted) is never cut, so its string is blocked while it sounds.
// - Intervals are half-open: an onset exactly at a note's end does not
//   overlap it (and stops a ring there).
// - Same pitch on one MIDI channel cannot sound twice at once: an edited
//   note is ended at the next same-pitch onset in its realized length. Every
//   shortened or extended length keeps its exact original in the ring base,
//   so "울림 되돌리기" restores it (no data loss).
// - Groove (limitation): ring and choke are computed on the note data. A
//   groove moves onsets at playback/export, so a choke boundary can drift by
//   up to the groove's shift. The MIDI export writes a same-tick note-off
//   before the next note-on of that pitch, so a choke never kills the new
//   note.
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'guitar_stroke.dart' show kStrokeHitTolerance, strokeGroupStart;
import 'guitar_tuning.dart';

export 'guitar_tuning.dart';

/// Hard limit of the fretted span (highest − lowest non-open fret) of one
/// hit. Spans up to 4 are preferred by the search (lowest span first).
const int kGuitarMaxSpan = 5;

/// At most this many notes of one hit enter the search; the rest are
/// unassignable ([UnassignableReason.tooMany]).
const int kGuitarHitSearchNotes = kGuitarStrings;

/// Search nodes per hit before the best assignment so far is kept (bound
/// on pathological hits; a normal hit needs far fewer).
const int kGuitarHitNodeCap = 4000;

const double _eps = 1e-9;

/// Why a note was left without a string.
enum UnassignableReason {
  /// Outside MIDI 40..86 (standard tuning, frets 0..22).
  outOfRange,

  /// More notes in the hit than the 6 searched.
  tooMany,

  /// No free string: the hit's other notes, a sounding note that must not
  /// be cut, or the fret span left no place.
  noString,

  /// A locked note without a string (locked notes are never changed).
  locked,

  /// A non-finite or non-positive start/length.
  invalid,
}

/// An assignment result: the new notes, the selection remapped to them and
/// the notes (output identities) left unassigned with the reason.
typedef GuitarStringEdit = ({
  List<PitchNote> notes,
  Set<PitchNote> selection,
  Map<PitchNote, UnassignableReason> unassignable,
});

/// A ring/choke/override result with the selection remapped.
typedef GuitarRingEdit = ({List<PitchNote> notes, Set<PitchNote> selection});

/// Whether [n]'s timing is usable (finite start, positive finite length).
bool guitarTimingValid(PitchNote n) =>
    n.startSteps.isFinite &&
    n.soundingSteps.isFinite &&
    n.soundingSteps > 0 &&
    n.startSteps >= 0;

/// The fret of an assigned note (null when unassigned).
int? noteFret(PitchNote n) =>
    n.guitarString == null ? null : guitarFret(n.guitarString!, n.midi);

/// Chord hits over [idx] (indices into [notes], all valid): grouped by
/// [strokeGroupStart] within [kStrokeHitTolerance] of the hit's earliest
/// note, time order; within a hit list order.
List<List<int>> _hits(List<PitchNote> notes, List<int> idx) {
  final start = {for (final i in idx) i: strokeGroupStart(notes[i])};
  final sorted = [...idx]..sort((a, b) {
    final c = start[a]!.compareTo(start[b]!);
    return c != 0 ? c : a.compareTo(b);
  });
  final hits = <List<int>>[];
  double? anchor;
  for (final i in sorted) {
    if (anchor == null || start[i]! - anchor > kStrokeHitTolerance + _eps) {
      hits.add(<int>[]);
      anchor = start[i];
    }
    hits.last.add(i);
  }
  return [for (final h in hits) h..sort()];
}

/// One note on a string's timeline during assignment. [end] shrinks when a
/// later note on the string chokes it.
class _Slot {
  _Slot(this.start, this.end, this.cuttable);
  final double start;
  double end;

  /// The note may be shortened (inside the edit: selected, unlocked).
  final bool cuttable;
}

/// Per-string timeline: every note on the string (fixed ones and those
/// placed by this run), kept sorted by ACTUAL start on insert. Hits are
/// processed in pre-stroke order, so a slow stroke's late strings can start
/// after the next hit's notes; the sorted insert keeps lookups correct.
/// Collisions are interval-based: every note sounding over the new one's
/// interval is checked, not only the latest-started one.
class _Lane {
  final List<_Slot> slots = [];

  /// Longest original length on the string: no note starting more than this
  /// before an onset can still sound there (bounds the backward scan).
  double _maxLen = 0;

  int _firstFrom(double t) {
    var lo = 0, hi = slots.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (slots[mid].start < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Fixed notes before the run (sorted once by [sortFixed]).
  void addFixed(_Slot s) {
    slots.add(s);
    _maxLen = math.max(_maxLen, s.end - s.start);
  }

  void sortFixed() => slots.sort((x, y) => x.start.compareTo(y.start));

  /// Notes of this string sounding during [a, b) (half-open).
  Iterable<_Slot> _overlapping(double a, double b) sync* {
    for (var i = _firstFrom(b - _eps) - 1; i >= 0; i--) {
      final s = slots[i];
      if (s.start < a - _maxLen - _eps) break;
      if (s.end > a + _eps && s.start < b - _eps) yield s;
    }
  }

  /// Cost of putting a note sounding [a, b) here: null = forbidden, else the
  /// number of chokes it causes (an earlier note cut at [a], or this note
  /// cut by a later onset).
  int? cost(double a, double b) {
    var chokes = 0;
    for (final s in _overlapping(a, b)) {
      if ((s.start - a).abs() <= _eps) return null; // same onset, one string
      if (s.start < a) {
        if (!s.cuttable) return null;
      }
      chokes++;
    }
    return chokes;
  }

  void place(_Slot n) {
    for (final s in _overlapping(n.start, n.end).toList()) {
      if (s.start < n.start) {
        s.end = n.start;
      } else {
        n.end = math.min(n.end, s.start);
      }
    }
    _maxLen = math.max(_maxLen, n.end - n.start);
    slots.insert(_firstFrom(n.start + _eps), n);
  }
}

/// "줄 배정": give each note of the selection (nothing selected = the whole
/// track) a string 1–6 in standard tuning. Muted notes are skipped. Locked
/// notes and user-chosen strings ([PitchNote.stringLocked]) are kept as
/// they are and constrain the others, like assigned notes outside the
/// selection. Within a hit the search prefers, in order: more notes placed,
/// fewer chokes, the lowest fretted span, lower frets, then the fret
/// position closest to the previous hit. Notes that cannot be placed are
/// unassigned and returned in `unassignable`; nothing is moved or dropped.
/// Afterwards [enforceStringChoke] runs on the edited notes. A no-op returns
/// [notes] itself.
GuitarStringEdit assignStrings(
  List<PitchNote> notes,
  Set<PitchNote> selection,
) {
  final scope = selection.isEmpty ? notes.toSet() : selection;
  bool movable(PitchNote n) =>
      scope.contains(n) && !n.locked && !n.stringLocked && !n.muted;
  final unassignable = <int, UnassignableReason>{};
  final valid = <int>[];
  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    if (n.muted) continue;
    if (!guitarTimingValid(n)) {
      if (scope.contains(n)) unassignable[i] = UnassignableReason.invalid;
      continue;
    }
    valid.add(i);
  }
  final lanes = List.generate(kGuitarStrings, (_) => _Lane());
  for (final i in valid) {
    final n = notes[i];
    if (movable(n) || n.guitarString == null) continue;
    lanes[n.guitarString! - 1].addFixed(
      _Slot(
        n.startSteps,
        n.endSteps,
        scope.contains(n) && !n.locked, // a user-chosen string in the edit
      ),
    );
  }
  for (final l in lanes) {
    l.sortFixed();
  }

  final chosen = <int, int>{}; // note index -> string
  double? prevMean;
  for (final hit in _hits(notes, valid)) {
    final taken = <int>{
      for (final i in hit)
        if (!movable(notes[i]) && notes[i].guitarString != null)
          notes[i].guitarString!,
    };
    final cand = <int>[];
    for (final i in hit) {
      final n = notes[i];
      if (!scope.contains(n)) continue;
      if (n.locked && n.guitarString == null) {
        unassignable[i] = UnassignableReason.locked;
      } else if (!movable(n)) {
        continue;
      } else if (n.midi < kGuitarLowestMidi || n.midi > kGuitarHighestMidi) {
        unassignable[i] = UnassignableReason.outOfRange;
      } else {
        cand.add(i);
      }
    }
    if (cand.isEmpty) continue;
    cand.sort((a, b) {
      final c = notes[a].midi.compareTo(notes[b].midi);
      return c != 0 ? c : a.compareTo(b);
    });
    for (final i in cand.skip(kGuitarHitSearchNotes)) {
      unassignable[i] = UnassignableReason.tooMany;
    }
    final search = cand.take(kGuitarHitSearchNotes).toList();
    // options per note: (string, fret, chokes), lower frets first
    final options = [
      for (final i in search)
        [
          for (var s = 1; s <= kGuitarStrings; s++)
            if (!taken.contains(s) && guitarFret(s, notes[i].midi) != null)
              if (lanes[s - 1].cost(notes[i].startSteps, notes[i].endSteps)
                  case final c?)
                (s: s, fret: guitarFret(s, notes[i].midi)!, chokes: c),
        ]..sort((x, y) => x.fret != y.fret ? x.fret - y.fret : x.s - y.s),
    ];
    final best = _searchHit(options, prevMean);
    var sum = 0, count = 0;
    for (var k = 0; k < search.length; k++) {
      final o = best[k];
      final i = search[k];
      if (o == null) {
        unassignable[i] = UnassignableReason.noString;
        continue;
      }
      chosen[i] = o.s;
      sum += o.fret;
      count++;
      lanes[o.s - 1].place(
        _Slot(notes[i].startSteps, notes[i].endSteps, true),
      );
    }
    if (count > 0) prevMean = sum / count;
  }

  var changed = false;
  final out = [
    for (var i = 0; i < notes.length; i++)
      (() {
        final n = notes[i];
        if (!movable(n) || !guitarTimingValid(n)) return n;
        final s = chosen[i];
        if (s == n.guitarString) return n;
        changed = true;
        return s == null
            ? n.copyWith(clearGuitarString: true)
            : n.copyWith(guitarString: s, stringLocked: false);
      })(),
  ];
  final editScope = {
    for (var i = 0; i < notes.length; i++)
      if (scope.contains(notes[i])) out[i],
  };
  final choked = enforceStringChoke(out, editScope);
  final result = choked.notes;
  if (!identical(result, out)) changed = true;
  final unassignedOut = {
    for (final e in unassignable.entries) result[e.key]: e.value,
  };
  if (!changed) {
    return (
      notes: notes,
      selection: selection,
      unassignable: {
        for (final e in unassignable.entries) notes[e.key]: e.value,
      },
    );
  }
  return (
    notes: result,
    selection: {
      for (var i = 0; i < notes.length; i++)
        if (selection.contains(notes[i])) result[i],
    },
    unassignable: unassignedOut,
  );
}

typedef _Opt = ({int s, int fret, int chokes});

/// Bounded depth-first search over one hit's options (each note: one of its
/// strings or none). Lexicographic cost: placed (more), chokes, fretted
/// span, fret sum, distance to [prevMean]. At most [kGuitarHitNodeCap]
/// nodes; the best leaf so far wins.
List<_Opt?> _searchHit(List<List<_Opt>> options, double? prevMean) {
  final m = options.length;
  final cur = List<_Opt?>.filled(m, null);
  var best = List<_Opt?>.filled(m, null);
  var bestPlaced = -1, bestChokes = 0, bestSpan = 0, bestSum = 0;
  var bestCont = 0.0;
  var nodes = 0;

  void leaf(int placed, int chokes, int lo, int hi, int sum) {
    final span = hi >= lo ? hi - lo : 0;
    final mean = placed == 0 ? 0.0 : sum / placed;
    final cont = prevMean == null || placed == 0 ? 0.0 : (mean - prevMean).abs();
    var better = placed > bestPlaced;
    if (placed == bestPlaced) {
      if (chokes != bestChokes) {
        better = chokes < bestChokes;
      } else if (span != bestSpan) {
        better = span < bestSpan;
      } else if (sum != bestSum) {
        better = sum < bestSum;
      } else {
        better = cont < bestCont - _eps;
      }
    }
    if (!better) return;
    best = List.of(cur);
    bestPlaced = placed;
    bestChokes = chokes;
    bestSpan = span;
    bestSum = sum;
    bestCont = cont;
  }

  // lo/hi: lowest/highest fretted (non-open) fret so far (hi < lo = none)
  void dfs(int k, int used, int placed, int chokes, int lo, int hi, int sum) {
    if (++nodes > kGuitarHitNodeCap) return;
    final remaining = m - k;
    if (placed + remaining < bestPlaced) return;
    if (placed + remaining == bestPlaced && chokes > bestChokes) return;
    if (k == m) {
      leaf(placed, chokes, lo, hi, sum);
      return;
    }
    for (final o in options[k]) {
      if (used & (1 << o.s) != 0) continue;
      var nlo = lo, nhi = hi;
      if (o.fret > 0) {
        nlo = math.min(lo, o.fret);
        nhi = math.max(hi, o.fret);
        if (nhi - nlo > kGuitarMaxSpan) continue;
      }
      cur[k] = o;
      dfs(k + 1, used | (1 << o.s), placed + 1, chokes + o.chokes, nlo, nhi,
          sum + o.fret);
      cur[k] = null;
    }
    dfs(k + 1, used, placed, chokes, lo, hi, sum);
  }

  dfs(0, 0, 0, 0, 1 << 30, -1, 0);
  return best;
}

/// Sorted onsets of the unmuted, valid notes of [notes] per string and per
/// pitch, for "next onset after t" lookups over the whole track.
class _Onsets {
  _Onsets(List<PitchNote> notes) {
    for (final n in notes) {
      if (n.muted || !guitarTimingValid(n)) continue;
      (_byPitch[n.midi] ??= []).add(n.startSteps);
      if (n.guitarString != null) {
        (_byString[n.guitarString!] ??= []).add(n.startSteps);
      }
    }
    for (final l in [..._byPitch.values, ..._byString.values]) {
      l.sort();
    }
  }

  final Map<int, List<double>> _byPitch = {};
  final Map<int, List<double>> _byString = {};

  static double? _after(List<double>? list, double t) {
    if (list == null) return null;
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (list[mid] <= t + _eps) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == list.length ? null : list[lo];
  }

  /// The first onset after [n]'s start on its string or at its pitch.
  double? nextFor(PitchNote n) {
    final a = _after(_byPitch[n.midi], n.startSteps);
    final b =
        n.guitarString == null
            ? null
            : _after(_byString[n.guitarString!], n.startSteps);
    if (a == null) return b;
    if (b == null) return a;
    return math.min(a, b);
  }
}

/// [n] with its realized end at [end] (start unchanged), remembering its
/// exact pre-ring length (an existing ring base is kept). Returns the
/// ring-free base itself when [end] is the base end.
PitchNote _withRingEnd(PitchNote n, double end) {
  final base = n.ringReverted();
  if ((end - base.endSteps).abs() < _eps) return base;
  final length = end - n.startSteps;
  return n.withRing(
    dur: math.max(1, (length - 1e-6).ceil()),
    durationSteps: length,
    ringBaseDur: base.dur,
    ringBaseDurationSteps: base.durationSteps,
  );
}

/// Public form of the ring-end rewrite for gt-004 "줄별 울림 유지": [n]
/// ending at [end] with its exact pre-ring length kept in the ring base, so
/// "울림 되돌리기" restores it. Same arithmetic as [applyRing].
PitchNote ringNoteToEnd(PitchNote n, double end) => _withRingEnd(n, end);

GuitarRingEdit _mapScope(
  List<PitchNote> notes,
  Set<PitchNote> selection,
  PitchNote Function(PitchNote n) edit,
) {
  final scope = selection.isEmpty ? notes.toSet() : selection;
  var changed = false;
  final out = [
    for (final n in notes)
      if (!scope.contains(n) || n.locked || n.muted)
        n
      else
        (() {
          final e = edit(n);
          if (!identical(e, n)) changed = true;
          return e;
        })(),
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

/// Same-string re-pluck (and same-pitch unison) cut: every assigned,
/// unlocked, unmuted note of the selection (nothing selected = whole track)
/// that still sounds at the next onset on its string or at its pitch — found
/// across the whole track, muted notes ignored — ends at that onset. Only
/// those notes change; the cut keeps the original in the ring base. A no-op
/// returns [notes] itself.
GuitarRingEdit enforceStringChoke(
  List<PitchNote> notes,
  Set<PitchNote> selection,
) {
  final onsets = _Onsets(notes);
  return _mapScope(notes, selection, (n) {
    if (n.guitarString == null || !guitarTimingValid(n)) return n;
    final next = onsets.nextFor(n);
    if (next == null || next >= n.endSteps - _eps) return n;
    return _withRingEnd(n, next);
  });
}

/// "울림 아르페지오": each assigned, unlocked, unmuted note of the selection
/// (nothing selected = whole track) rings until the next onset on its
/// string or at its pitch (searched across the whole track, including
/// unselected and locked notes; muted notes never choke), or until
/// [rangeEnd], whichever is first. A note already longer than that keeps
/// its length unless an onset chokes it earlier. Unassigned notes and data
/// outside the selection are never changed. Re-applying starts from each
/// note's ring base (no accumulation). [rangeEnd] must be finite and > 0.
GuitarRingEdit applyRing(
  List<PitchNote> notes,
  Set<PitchNote> selection, {
  required double rangeEnd,
}) {
  if (!rangeEnd.isFinite || rangeEnd <= 0) {
    throw ArgumentError.value(rangeEnd, 'rangeEnd', 'must be finite and > 0');
  }
  final onsets = _Onsets(notes);
  return _mapScope(notes, selection, (n) {
    if (n.guitarString == null || !guitarTimingValid(n)) return n;
    final base = n.ringReverted();
    final next = onsets.nextFor(n);
    double end;
    if (next != null && next < base.endSteps - _eps) {
      end = next; // choke
    } else {
      end = math.max(base.endSteps, math.min(next ?? rangeEnd, rangeEnd));
    }
    final out = _withRingEnd(n, end);
    // unchanged values keep the note's identity
    if (out.ringBaseDur == n.ringBaseDur &&
        out.ringBaseDurationSteps == n.ringBaseDurationSteps &&
        out.dur == n.dur &&
        out.durationSteps == n.durationSteps) {
      return n;
    }
    return out;
  });
}

/// The range end the editor uses for a ring: the latest base end of the
/// selection's unmuted notes (nothing selected = the section end), never
/// past [steps].
double ringRangeEnd(
  List<PitchNote> notes,
  Set<PitchNote> selection,
  int steps,
) {
  if (selection.isEmpty) return steps.toDouble();
  var end = 0.0;
  for (final n in notes) {
    if (!selection.contains(n) || n.muted) continue;
    final b = n.ringReverted();
    if (guitarTimingValid(b)) end = math.max(end, b.endSteps);
  }
  return end <= 0 ? steps.toDouble() : math.min(end, steps.toDouble());
}

/// "울림 되돌리기": restore the exact pre-ring length of every unlocked note
/// of the selection (nothing selected = whole track) that has a ring base.
GuitarRingEdit revertRing(List<PitchNote> notes, Set<PitchNote> selection) =>
    _mapScope(notes, selection, (n) => n.ringReverted());

/// A manual string choice result: the edit plus how many selected notes
/// were refused (pitch not playable on that string, or another note of the
/// same hit already holds it).
typedef GuitarStringOverride = ({
  List<PitchNote> notes,
  Set<PitchNote> selection,
  int refused,
});

/// Manual override: put the selected, unlocked notes on [string] (1..6) as
/// a user choice ([PitchNote.stringLocked]); the fret follows from the
/// pitch. A note whose pitch cannot sound on [string], or whose hit already
/// has another note there, is refused (unchanged) and counted. [string]
/// null returns the notes to automatic assignment (keeps the string, clears
/// the user mark).
GuitarStringOverride setGuitarString(
  List<PitchNote> notes,
  Set<PitchNote> selection,
  int? string,
) {
  if (string != null && (string < 1 || string > kGuitarStrings)) {
    throw ArgumentError.value(string, 'string', 'must be 1..$kGuitarStrings');
  }
  var refused = 0;
  final out = List<PitchNote>.of(notes);
  var changed = false;
  final valid = [
    for (var i = 0; i < notes.length; i++)
      if (!notes[i].muted && guitarTimingValid(notes[i])) i,
  ];
  final hitOf = <int, int>{};
  final hits = _hits(notes, valid);
  for (var h = 0; h < hits.length; h++) {
    for (final i in hits[h]) {
      hitOf[i] = h;
    }
  }
  final holders = <(int, int)>{
    for (var i = 0; i < notes.length; i++)
      if (hitOf[i] != null &&
          notes[i].guitarString != null &&
          !(selection.contains(notes[i]) && !notes[i].locked))
        (hitOf[i]!, notes[i].guitarString!),
  };
  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    if (!selection.contains(n) || n.locked) continue;
    if (string == null) {
      if (n.stringLocked) {
        out[i] = n.copyWith(stringLocked: false);
        changed = true;
      }
      continue;
    }
    final h = hitOf[i];
    if (!guitarPlayable(string, n.midi) ||
        (h != null && holders.contains((h, string)))) {
      refused++;
      continue;
    }
    if (h != null) holders.add((h, string));
    if (n.guitarString == string && n.stringLocked) continue;
    out[i] = n.copyWith(guitarString: string, stringLocked: true);
    changed = true;
  }
  if (!changed) return (notes: notes, selection: selection, refused: refused);
  return (
    notes: out,
    selection: {
      for (var i = 0; i < notes.length; i++)
        if (selection.contains(notes[i])) out[i],
    },
    refused: refused,
  );
}

/// Strings every selected, unlocked note could be put on (for the override
/// menu).
Set<int> playableStringsFor(Iterable<PitchNote> notes) {
  final list = notes.where((n) => !n.locked).toList();
  if (list.isEmpty) return {};
  return {
    for (var s = 1; s <= kGuitarStrings; s++)
      if (list.every((n) => guitarPlayable(s, n.midi))) s,
  };
}
