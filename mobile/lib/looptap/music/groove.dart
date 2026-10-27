// groove-001: groove templates — non-destructive timing/velocity feel per
// track (and per-section override), plus extraction from a take or a track.
// docs/specs/groove/gr-001-groove-templates.md
//
// A groove REPLACES the song Swing on the tracks it is assigned to (never
// added on top). Tracks without a groove keep following Swing exactly as
// before, so songs that never use grooves play and export unchanged.
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'theory.dart' show TrackKind, kStepsPerBeat, stepsForBars, trackById;

/// One groove: per-sixteenth timing shift (steps, −1..1) and accent (−1..1)
/// over [length] positions (16 or 32), counted from the section start.
class GrooveTemplate {
  GrooveTemplate({
    required this.id,
    required this.name,
    required this.length,
    required List<double> timing,
    required List<double> accent,
    this.origin = 'user',
  }) : timing = _fit(timing, length, -1, 1),
       accent = _fit(accent, length, -1, 1);

  final String id;
  final String name;
  final int length;
  final List<double> timing, accent;

  /// 'builtin' | 'take' (from a recording) | 'track' (from notes) | 'user'.
  final String origin;

  static List<double> _fit(List<double> v, int n, double lo, double hi) => [
    for (var i = 0; i < n; i++)
      i < v.length ? v[i].clamp(lo, hi).toDouble() : 0.0,
  ];

  GrooveTemplate copyWith({String? name}) => GrooveTemplate(
    id: id,
    name: name ?? this.name,
    length: length,
    timing: timing,
    accent: accent,
    origin: origin,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'length': length,
    'timing': timing,
    'accent': accent,
    'origin': origin,
  };

  static GrooveTemplate fromJson(Map<String, dynamic> j) {
    final length = (j['length'] as num?)?.toInt() ?? 16;
    List<double> list(String k) => [
      for (final v in (j[k] as List?) ?? const []) (v as num).toDouble(),
    ];
    return GrooveTemplate(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? 'Groove',
      length: length < 1 ? 16 : length,
      timing: list('timing'),
      accent: list('accent'),
      origin: (j['origin'] as String?) ?? 'user',
    );
  }
}

/// A groove assigned to a track (or a section override): which template and
/// how much of it. [timing] 0..1, [velocity] −1..1 (negative inverts the
/// accents), [quantize] 0..1 (pull toward the straight grid first).
class GrooveAssign {
  const GrooveAssign({
    required this.grooveId,
    this.timing = 1.0,
    this.velocity = 1.0,
    this.quantize = 0.0,
  });
  final String grooveId;
  final double timing, velocity, quantize;

  GrooveAssign copyWith({
    String? grooveId,
    double? timing,
    double? velocity,
    double? quantize,
  }) => GrooveAssign(
    grooveId: grooveId ?? this.grooveId,
    timing: timing ?? this.timing,
    velocity: velocity ?? this.velocity,
    quantize: quantize ?? this.quantize,
  );

  @override
  bool operator ==(Object other) =>
      other is GrooveAssign &&
      other.grooveId == grooveId &&
      other.timing == timing &&
      other.velocity == velocity &&
      other.quantize == quantize;

  @override
  int get hashCode => Object.hash(grooveId, timing, velocity, quantize);

  Map<String, dynamic> toJson() => {
    'grooveId': grooveId,
    if (timing != 1.0) 'timing': timing,
    if (velocity != 1.0) 'velocity': velocity,
    if (quantize != 0.0) 'quantize': quantize,
  };

  static GrooveAssign fromJson(Map<String, dynamic> j) => GrooveAssign(
    grooveId: j['grooveId'] as String,
    timing: ((j['timing'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0),
    velocity: ((j['velocity'] as num?)?.toDouble() ?? 1.0).clamp(-1.0, 1.0),
    quantize: ((j['quantize'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
  );
}

GrooveTemplate _formula(
  String key,
  String name,
  double Function(int p) timing, [
  double Function(int p)? accent,
]) => GrooveTemplate(
  id: 'builtin:$key',
  name: name,
  length: 16,
  timing: [for (var p = 0; p < 16; p++) timing(p)],
  accent: [for (var p = 0; p < 16; p++) accent?.call(p) ?? 0],
  origin: 'builtin',
);

/// Built-in templates (HumTrack's own formulas, never stored in songs —
/// referenced by their `builtin:` id).
final List<GrooveTemplate> kBuiltinGrooves = [
  _formula('straight', 'Straight', (_) => 0),
  _formula('swing16-light', 'Swing 16 light', (p) => p.isOdd ? .1 : 0),
  _formula('swing16-medium', 'Swing 16 medium', (p) => p.isOdd ? .2 : 0),
  _formula('swing16-heavy', 'Swing 16 heavy', (p) => p.isOdd ? .3 : 0),
  _formula('swing8', 'Swing 8', (p) => p % 4 == 2 ? .67 : 0),
  _formula('laidback', 'Laid-back', (p) => p == 4 || p == 12 ? .15 : 0),
  _formula(
    'pulse',
    'Pulse',
    (_) => 0,
    (p) =>
        p % 4 == 0
            ? 1
            : p.isOdd
            ? -.5
            : 0,
  ),
];

/// The template for [id]: a built-in or one of the song's [custom] ones.
/// Unknown ids resolve to null ("no groove": Swing applies).
GrooveTemplate? findGroove(String id, List<GrooveTemplate> custom) {
  for (final t in kBuiltinGrooves) {
    if (t.id == id) return t;
  }
  for (final t in custom) {
    if (t.id == id) return t;
  }
  return null;
}

/// Nearest sixteenth, a tie going up.
int _cell(double s) => (s + .5).floor();

/// Where a note starting at [s] (steps from its section start) lands, and
/// with what velocity, under [t] assigned with [a] at song [amount].
({double start, int? velocity}) applyGroove(
  double s,
  int? velocity,
  GrooveTemplate t,
  GrooveAssign a, {
  double amount = 1,
}) {
  final g = _cell(s);
  final p = ((g % t.length) + t.length) % t.length;
  var start = s + (g - s) * a.quantize + t.timing[p] * a.timing * amount;
  if (start < 0) start = 0;
  final va = a.velocity * amount * t.accent[p];
  if (va == 0) return (start: start, velocity: velocity);
  return (
    start: start,
    velocity: ((velocity ?? 100) * (1 + .5 * va)).round().clamp(1, 127),
  );
}

double _median(List<double> v) {
  final s = [...v]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

/// Build a template from played beats (position in sixteenth steps from the
/// section start, velocity). Beats outside [0, sectionSteps) are ignored;
/// fewer than 4 → null. The overall median offset (recording latency, a
/// uniformly late performance) is removed first, so only the relative feel
/// remains. Timing per position = median offset there, cut to ±0.5. Accents
/// follow the per-position mean velocity around the overall mean, scaled so
/// the largest is ±1 (all 0 with fewer than two distinct velocities).
GrooveTemplate? extractGroove(
  List<({double steps, int velocity})> beats, {
  required int length,
  required String name,
  required String id,
  int? sectionSteps,
  String origin = 'user',
}) {
  final used = [
    for (final b in beats)
      if (b.steps >= 0 && (sectionSteps == null || b.steps < sectionSteps)) b,
  ];
  if (used.length < 4) return null;
  final offsets = [for (final b in used) b.steps - _cell(b.steps)];
  final latency = _median(offsets);
  final byPos = <int, List<double>>{};
  final velByPos = <int, List<int>>{};
  for (var i = 0; i < used.length; i++) {
    final p = _cell(used[i].steps) % length;
    (byPos[p] ??= []).add(offsets[i] - latency);
    (velByPos[p] ??= []).add(used[i].velocity);
  }
  final timing = [
    for (var p = 0; p < length; p++)
      byPos[p] == null ? 0.0 : _median(byPos[p]!).clamp(-.5, .5).toDouble(),
  ];
  var accent = List<double>.filled(length, 0);
  if (used.map((b) => b.velocity).toSet().length >= 2) {
    final mu = used.map((b) => b.velocity).reduce((a, b) => a + b) / used.length;
    final means = {
      for (final e in velByPos.entries)
        e.key: e.value.reduce((a, b) => a + b) / e.value.length,
    };
    final d = means.values.map((m) => (m - mu).abs()).reduce(math.max);
    if (d > 0) {
      accent = [
        for (var p = 0; p < length; p++)
          means[p] == null ? 0.0 : (means[p]! - mu) / d,
      ];
    }
  }
  return GrooveTemplate(
    id: id,
    name: name,
    length: length,
    timing: timing,
    accent: accent,
    origin: origin,
  );
}

/// Odd sixteenths are late by `swing × 0.5` step (the Swing knob).
double swingOffset(int step, double swing) => step.isOdd ? swing * .5 : 0;

/// Everything flatten / playback need to resolve grooves.
class GrooveContext {
  const GrooveContext({
    this.grooves = const [],
    this.trackGrooves = const {},
    this.amount = 1.0,
    this.swing = 0,
  });

  /// The song's own (extracted / user) templates.
  final List<GrooveTemplate> grooves;
  final Map<String, GrooveAssign> trackGrooves;

  /// Song-wide Amount, 0..1.3.
  final double amount;

  /// Swing baked into the non-groove sections of a groove lane.
  final double swing;

  /// The groove of [trackId] in [section]: the section override if it has
  /// one (null value = "no groove"), else the track assignment. Unknown
  /// template ids count as no groove.
  ({GrooveTemplate template, GrooveAssign assign})? resolve(
    Section section,
    String trackId,
  ) {
    final GrooveAssign? a =
        section.grooveOverrides.containsKey(trackId)
            ? section.grooveOverrides[trackId]
            : trackGrooves[trackId];
    if (a == null) return null;
    final t = findGroove(a.grooveId, grooves);
    return t == null ? null : (template: t, assign: a);
  }
}

/// Live playback slot of a grooved note whose effective start is [start]
/// (steps in the loop): the clock step whose trigger fires it — the last
/// step whose swung trigger time is not after [start] — and the delay
/// (steps) after that trigger. A note pulled before its own step's trigger
/// is therefore scheduled one step early.
({int trigger, double delay}) liveGrooveSlot(
  double start,
  double swing,
  int steps,
) {
  var k = start.floor().clamp(0, math.max(0, steps - 1)).toInt();
  while (k > 0 && k + swingOffset(k, swing) > start + 1e-9) {
    k--;
  }
  return (trigger: k, delay: math.max(0, start - k - swingOffset(k, swing)));
}

/// The track ids of a section that carry notes (base tracks + extras).
Iterable<(String, TrackKind)> _lanes(Section s) sync* {
  for (final id in const ['melody', 'melodyDec', 'bass', 'drums', 'beatDec']) {
    yield (id, trackById(id).kind);
  }
  for (final ref in s.extras) {
    yield (ref.id, trackById(ref.type).kind);
  }
}

/// What live playback does with one section's grooved lanes: each note's
/// sounding time in seconds from the loop start (clock trigger + scheduled
/// delay, see [liveGrooveSlot]) and velocity. Muted notes are left out;
/// lanes without a groove in this section are not listed (they follow the
/// clock's Swing).
List<({String trackId, Object note, double seconds, int? velocity})>
liveGrooveSchedule(Section section, int bpm, double swing, GrooveContext groove) {
  final sps = 60 / bpm / kStepsPerBeat;
  final steps = stepsForBars(section.bars);
  final out =
      <({String trackId, Object note, double seconds, int? velocity})>[];
  for (final (id, kind) in _lanes(section)) {
    final g = groove.resolve(section, id);
    final data = section.tracks[id];
    if (g == null || data == null) continue;
    void add(Object note, double start, int? velocity) {
      final r = applyGroove(
        start,
        velocity,
        g.template,
        g.assign,
        amount: groove.amount,
      );
      final slot = liveGrooveSlot(r.start, swing, steps);
      final trig = slot.trigger + swingOffset(slot.trigger, swing);
      out.add((
        trackId: id,
        note: note,
        seconds: (trig + slot.delay) * sps,
        velocity: r.velocity,
      ));
    }

    if (kind == TrackKind.drums) {
      for (final n in data.drumNotes) {
        if (!n.muted && n.step >= 0 && n.step < steps) {
          add(n, n.startSteps, n.velocity);
        }
      }
    } else if (kind != TrackKind.vocal) {
      for (final n in data.pitchNotes) {
        if (!n.muted && n.step >= 0 && n.step < steps) {
          add(n, n.startSteps, n.velocity);
        }
      }
    }
  }
  return out;
}
