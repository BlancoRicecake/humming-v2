// gt-004 "줄별 울림 유지": each string of a stroke-converted chord keeps
// ringing until the same chord (exactly the same sounding pitches) is
// struck again on that string. Opt-in only: nothing here runs unless the
// user presses the button; existing songs are never converted in the
// background. See docs/specs/guitar/gt-004-stroke-sustain.md.
//
// Rule (spec + binding review amendments, 2026-10-23):
// - Hits: the whole track's sounding (unmuted, valid) notes grouped by
//   [strokeChordHits] ([strokeGroupStart], 0.05 step). The next hit B of a
//   hit A is the next hit on the whole track; the selection is not
//   considered there.
// - Eligible note: in scope, has a [StrokeTag], not muted, not locked, no
//   articulation.
// - A and B connect only when: B exists inside the section; neither hit has
//   an articulated note; every sounding note of both hits is stroke-tagged
//   (an untagged member plays the legacy auto strum, so its stored onset is
//   not the real strike: "스트로크 미적용"); with a selection, both hits lie fully inside it
//   (A or B partly inside = "부분 선택", B outside = "선택 경계": separated
//   selected regions are never bridged); the multisets of sounding pitches
//   are exactly equal (notes outside the scope count).
// - Per note: its own original end (StrokeTag base end, or the actual end
//   for an untagged note) must reach B's base start within 0.05 step, else
//   it was cut on purpose and stays ("쉼/끊김"). The target is the note of B
//   on the same string with the same pitch; nothing on that string or at
//   that pitch may start between the note's onset and the target
//   ("충돌"). The end moves to exactly the target's onset (never earlier:
//   a note already reaching it is "이미 연결됨"). Onsets, velocities, tags
//   and every other field stay as they are.
// - Strings: [assignStrings] runs on a temporary analysis copy of the whole
//   track (notes without a string, unlocked, not user-chosen). Only the
//   string numbers are used; a note whose length the assignment would have
//   changed (choke) is refused ("줄 배정 불가") and gets no string. A string
//   is written only to a note that is actually extended (narrowest rule);
//   every other note (targets, refused, locked, muted, articulated,
//   untagged, outside the scope) keeps byte-identical JSON.
// - The extension goes through [ringNoteToEnd] (the [applyRing] arithmetic),
//   so the ring base keeps the original length for "울림 되돌리기".
import '../models/loop_models.dart';
import 'guitar_stroke.dart' show kStrokeHitTolerance, strokeBase, strokeChordHits, strokeGroupStart;
import 'guitar_strings.dart';

const double _eps = 1e-9;

/// Why a note in scope was left as it is.
enum SustainReason {
  /// The next chord's sounding pitches differ (or this string plays another
  /// pitch in it).
  chordChange,

  /// The note (its original end) stops before the next hit: a rest or cut.
  rest,

  /// The note has no stroke conversion (v1 is limited to stroked notes).
  noStroke,

  /// The note, or a note of this or the next hit, has an articulation.
  articulation,

  /// Locked or muted.
  lockedMuted,

  /// No string could be assigned (or the assignment would cut a length).
  noString,

  /// Another onset on the same string or at the same pitch comes first.
  conflict,

  /// The note already reaches (or passes) the re-strike.
  alreadyConnected,

  /// Last hit in the section.
  sectionEnd,

  /// This hit or the next one is only partly selected.
  partialSelection,

  /// The next hit lies outside the selection.
  selectionBoundary,
}

/// The user-facing label of [r].
String sustainReasonLabel(SustainReason r, {bool ko = true}) => switch (r) {
  SustainReason.chordChange => ko ? '화음 변경' : 'chord change',
  SustainReason.rest => ko ? '쉼/끊김' : 'rest/cut',
  SustainReason.noStroke => ko ? '스트로크 미적용' : 'no stroke',
  SustainReason.articulation => ko ? '연주법' : 'technique',
  SustainReason.lockedMuted => ko ? '잠김/음소거' : 'locked/muted',
  SustainReason.noString => ko ? '줄 배정 불가' : 'no string',
  SustainReason.conflict => ko ? '충돌' : 'conflict',
  SustainReason.alreadyConnected => ko ? '이미 연결됨' : 'already connected',
  SustainReason.sectionEnd => ko ? '섹션 끝' : 'section end',
  SustainReason.partialSelection => ko ? '부분 선택' : 'partial selection',
  SustainReason.selectionBoundary => ko ? '선택 경계' : 'selection boundary',
};

/// The result of [applyStrokeSustain]: the notes (the input list itself
/// when nothing is extended), the remapped selection, how many notes were
/// extended, and every other note of the scope by reason.
class StrokeSustainResult {
  StrokeSustainResult({
    required this.notes,
    required this.selection,
    required this.extended,
    required this.reasons,
    required this.stringsAssigned,
  });

  final List<PitchNote> notes;
  final Set<PitchNote> selection;
  final int extended;
  final Map<SustainReason, int> reasons;

  /// Notes that received an automatic string (part of the same edit).
  final int stringsAssigned;

  int get kept => reasons.values.fold(0, (a, b) => a + b);

  /// "연장 N · 그대로 M" plus the reasons, most frequent first.
  String summary({bool ko = true}) {
    final head = ko ? '연장 $extended · 그대로 $kept' : 'Extended $extended · kept $kept';
    final list = reasons.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.index.compareTo(b.key.index);
      });
    if (list.isEmpty) return head;
    final why = list.map((e) => '${sustainReasonLabel(e.key, ko: ko)} ${e.value}').join(', ');
    return '$head ($why)';
  }
}

/// "줄별 울림 유지" over the selection (nothing selected = the whole track).
/// [sectionSteps] is the section length; a hit starting at or after it, or
/// a re-strike past it, counts as the section end. See the file header for
/// the rule.
StrokeSustainResult applyStrokeSustain(
  List<PitchNote> notes,
  Set<PitchNote> selection, {
  required int sectionSteps,
}) {
  final scope = selection.isEmpty ? notes.toSet() : selection;
  final selected = selection.isNotEmpty;
  final reasons = <SustainReason, int>{};
  void keep(SustainReason r) => reasons[r] = (reasons[r] ?? 0) + 1;

  // ── analysis copy with temporary strings ──
  bool soundingValid(PitchNote n) => !n.muted && guitarTimingValid(n);
  final toAssign = <PitchNote>{
    for (final n in notes)
      if (soundingValid(n) && n.guitarString == null && !n.locked && !n.stringLocked) n,
  };
  final an = List<PitchNote>.of(notes);
  final lengthChanged = <int>{};
  if (toAssign.isNotEmpty) {
    final a = assignStrings(notes, toAssign).notes;
    for (var i = 0; i < notes.length; i++) {
      final o = notes[i], r = a[i];
      if (r.guitarString != null && r.guitarString != o.guitarString) {
        an[i] = o.copyWith(guitarString: r.guitarString, stringLocked: false);
      }
      if (r.dur != o.dur ||
          r.durationSteps != o.durationSteps ||
          r.ringBaseDur != o.ringBaseDur ||
          r.ringBaseDurationSteps != o.ringBaseDurationSteps) {
        lengthChanged.add(i);
      }
    }
  }

  // ── hits over the whole track (sounding notes only) ──
  final sounding = {
    for (final n in notes)
      if (soundingValid(n)) n,
  };
  final hits = strokeChordHits(notes, sounding);
  final hitBase = [
    for (final h in hits) h.map((i) => strokeGroupStart(notes[i])).reduce((a, b) => a < b ? a : b),
  ];

  // onsets per string / per pitch on the analysis copy, for conflicts
  final byString = <int, List<double>>{}, byPitch = <int, List<double>>{};
  for (final n in an) {
    if (!soundingValid(n)) continue;
    (byPitch[n.midi] ??= []).add(n.startSteps);
    if (n.guitarString != null) (byString[n.guitarString!] ??= []).add(n.startSteps);
  }
  bool blocked(List<double>? list, double from, double to) =>
      list != null && list.any((t) => t > from + _eps && t < to - _eps);

  Map<int, int> multiset(List<int> hit) {
    final m = <int, int>{};
    for (final i in hit) {
      m[notes[i].midi] = (m[notes[i].midi] ?? 0) + 1;
    }
    return m;
  }

  bool sameMultiset(Map<int, int> a, Map<int, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);

  final newEnd = <int, double>{};
  final writeString = <int>{};
  final hitOf = <int, int>{};
  for (var h = 0; h < hits.length; h++) {
    for (final i in hits[h]) {
      hitOf[i] = h;
    }
  }

  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    if (!scope.contains(n)) continue;
    if (n.muted || n.locked) {
      keep(SustainReason.lockedMuted);
      continue;
    }
    if (n.articulation != null) {
      keep(SustainReason.articulation);
      continue;
    }
    if (n.stroke == null) {
      keep(SustainReason.noStroke);
      continue;
    }
    final h = hitOf[i];
    if (h == null) {
      keep(SustainReason.noString); // invalid timing
      continue;
    }
    final a = hits[h];
    if (h + 1 >= hits.length || hitBase[h + 1] >= sectionSteps - _eps) {
      keep(SustainReason.sectionEnd);
      continue;
    }
    final b = hits[h + 1];
    if ([...a, ...b].any((j) => notes[j].articulation != null)) {
      keep(SustainReason.articulation);
      continue;
    }
    if (selected) {
      if (!a.every((j) => scope.contains(notes[j]))) {
        keep(SustainReason.partialSelection);
        continue;
      }
      final inB = b.where((j) => scope.contains(notes[j])).length;
      if (inB == 0) {
        keep(SustainReason.selectionBoundary);
        continue;
      }
      if (inB < b.length) {
        keep(SustainReason.partialSelection);
        continue;
      }
    }
    // v1 is explicit-stroke only: an untagged member (legacy auto strum at
    // playback, so its stored onset is not the real strike) refuses the pair
    if ([...a, ...b].any((j) => notes[j].stroke == null)) {
      keep(SustainReason.noStroke);
      continue;
    }
    if (!sameMultiset(multiset(a), multiset(b))) {
      keep(SustainReason.chordChange);
      continue;
    }
    if (strokeBase(n).endSteps < hitBase[h + 1] - kStrokeHitTolerance - _eps) {
      keep(SustainReason.rest);
      continue;
    }
    final s = an[i].guitarString;
    if (s == null || lengthChanged.contains(i)) {
      keep(SustainReason.noString);
      continue;
    }
    final samePitch = b.where((j) => notes[j].midi == n.midi).toList();
    final targets = samePitch.where((j) => an[j].guitarString == s).toList();
    if (targets.isEmpty) {
      keep(
        samePitch.any((j) => an[j].guitarString == null || lengthChanged.contains(j))
            ? SustainReason.noString
            : SustainReason.chordChange,
      );
      continue;
    }
    if (targets.length > 1 || lengthChanged.contains(targets.single)) {
      keep(targets.length > 1 ? SustainReason.conflict : SustainReason.noString);
      continue;
    }
    final t = notes[targets.single].startSteps;
    if (t > sectionSteps + _eps) {
      keep(SustainReason.sectionEnd);
      continue;
    }
    if (blocked(byString[s], n.startSteps, t) || blocked(byPitch[n.midi], n.startSteps, t)) {
      keep(SustainReason.conflict);
      continue;
    }
    if (n.endSteps >= t - _eps) {
      keep(SustainReason.alreadyConnected);
      continue;
    }
    newEnd[i] = t;
    // narrowest rule: only an extended note receives its automatic string
    if (n.guitarString == null) writeString.add(i);
  }

  if (newEnd.isEmpty) {
    return StrokeSustainResult(
      notes: notes,
      selection: selection,
      extended: 0,
      reasons: reasons,
      stringsAssigned: 0,
    );
  }
  final out = List<PitchNote>.of(notes);
  for (final i in writeString) {
    out[i] = out[i].copyWith(guitarString: an[i].guitarString, stringLocked: false);
  }
  for (final e in newEnd.entries) {
    out[e.key] = ringNoteToEnd(out[e.key], e.value);
  }
  return StrokeSustainResult(
    notes: out,
    selection: {
      for (var i = 0; i < notes.length; i++)
        if (selection.contains(notes[i])) out[i],
    },
    extended: newEnd.length,
    reasons: reasons,
    stringsAssigned: writeString.length,
  );
}
