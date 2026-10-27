// A/B listening comparison: the gt-003 demo's normal folk strum (A3-normal)
// BEFORE versus the same song with per-string ringing AFTER.
// Context: docs/product/guitar-listening-evaluation.md, last section
// ("첫 의견: 일반 스트로크의 5→6번째 타격"); specs gt-001 (stroke), gt-002
// (strings, ring) and gt-003 (articulations) in docs/specs/guitar/.
//
// BEFORE is built exactly like guitar_articulation_demo_test.dart builds
// A3-normal (applyStrokePattern only), so its files regenerate the existing
// demo bit for bit. AFTER uses only the existing G2 functions, no new
// feature: assignStrings, then applyRing once per chord region (one chord
// per bar) with
//   selection = the region's notes that are re-struck later in the region on
//               the SAME string with the SAME pitch (the held chord), and
//   rangeEnd  = the region's latest original (pre-ring) note end.
// A selected note then rings exactly to its re-strike. Kept as they are:
// notes whose string is not re-struck before the chord changes (or is next
// struck with another pitch), muted and locked notes, and every articulated
// note (짧게 / 팜뮤트 / 하모닉스 keep their gate). The selection filter is
// needed because applyRing alone would also extend a note that is not
// re-struck up to rangeEnd (see the variant test).
//
// ALWAYS: builds BEFORE/AFTER and a small variant and checks the rule, the
// hit 5→6 and 2→3 connections, that only lengths (plus string and ring-base
// metadata) differ, the .mid (same-tick same-key note-off before note-on,
// no same-pitch overlap), and that revertRing restores BEFORE exactly.
// ONLY with HUMTRACK_DEMO_OUT set: writes .mid (exportMidiSong), .wav (the
// real exportWavSong mix), loudness-matched .matched.wav, excerpts, the
// .song.json files, levels.json and a Korean README.md, and compares BEFORE
// with the baseline A3-normal files (HUMTRACK_DEMO_BASELINE, default
// <out>/../guitar-articulation-demo-20261022).
//
// Regenerate (from mobile/):
//   HUMTRACK_DEMO_OUT=<dir> /c/src/flutter/bin/flutter test --no-pub \
//     test/looptap/guitar_stroke_ring_demo_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import '../support/midi_all_events.dart';

// ── the A3-normal song, exactly as guitar_articulation_demo_test.dart ────
const int _bpm = 80;
const int _bars = 8;
const int _nylonSlot = 1001;
const int _nylonGm = 24;
const String _key = 'E';
const String _scale = 'minor';
const List<String> _chordRoots = ['E', 'A', 'C', 'G', 'E', 'A', 'C', 'G'];
const List<(int, int)> _folkHits = [
  (0, 4),
  (4, 2),
  (6, 4),
  (10, 2),
  (12, 2),
  (14, 2),
];

/// The baseline's song name (id/title). BEFORE and AFTER both keep it, so
/// their song JSON differs only in the notes.
const String _a3n = 'A3-normal';
const String _before = 'BEFORE-A3-normal';
const String _after = 'AFTER-A3-normal-ring';

/// One step at 80 BPM = 187.5 ms.
const double _stepSec = 60 / _bpm / kStepsPerBeat;
const double _eps = 1e-9;

/// Excerpt window (s) covering hits 2..6 of bar 1 (hit 5 = 2.25 s, hit 6 =
/// 2.625 s) and the first hit of bar 2 (3.0 s).
const double _ex0 = 1.5, _ex1 = 3.3, _fadeMs = 10;

List<int> _voicing(int bar) =>
    guitarVoicing(rootMidi(_chordRoots[bar], 2), _key, _scale);

PitchNote _note(int midi, int step, int dur) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

List<PitchNote> _blockChords() => [
  for (var bar = 0; bar < _bars; bar++)
    for (final (s, d) in _folkHits)
      for (final m in _voicing(bar)) _note(m, bar * 16 + s, d),
];

Section _section(List<PitchNote> notes, int bars) {
  final sec = Section(id: 'A', name: 'A', bars: bars);
  sec.tracks['melody']!.pitchNotes.addAll(notes);
  return sec;
}

Song _song(String name, List<PitchNote> notes, {int bars = _bars}) {
  final song = Song(
    id: 'gt3_demo_${name.replaceAll('-', '_').replaceAll('.', '_')}',
    title: name,
    key: _key,
    scale: _scale,
    bpm: _bpm,
    bars: bars,
    sections: [_section(notes, bars)],
  );
  song.instruments['melody'] = _nylonSlot;
  for (final id in ['bass', 'melodyDec', 'drums', 'beatDec']) {
    song.mutes[id] = true;
  }
  return song;
}

List<PitchNote> _strummed(List<PitchNote> notes, StrokePattern pattern) =>
    applyStrokePattern(notes, const {}, pattern, bpm: _bpm).notes;

// ── the held-chord ring rule ─────────────────────────────────────────────
/// A chord region by pre-stroke start ([strokeGroupStart]), half-open.
typedef _Span = ({double start, double end});

List<_Span> _barRegions(int bars) => [
  for (var b = 0; b < bars; b++) (start: b * 16.0, end: b * 16.0 + 16),
];

bool _inSpan(PitchNote n, _Span r) {
  final s = strokeGroupStart(n);
  return s >= r.start - _eps && s < r.end - _eps;
}

/// The next sounding (unmuted, valid) note on [n]'s string after its start.
int? _nextOnString(List<PitchNote> notes, PitchNote n) {
  int? best;
  for (var j = 0; j < notes.length; j++) {
    final m = notes[j];
    if (m.muted || !guitarTimingValid(m) || m.guitarString != n.guitarString) {
      continue;
    }
    if (m.startSteps <= n.startSteps + _eps) continue;
    if (best == null || m.startSteps < notes[best].startSteps) best = j;
  }
  return best;
}

/// The held-chord rule: the index of the note that re-strikes [notes][i]
/// (same string, same pitch, inside region [r]), or null when the note keeps
/// its length (no string, muted, locked, articulated, not re-struck in the
/// region, or next struck with another pitch).
int? _restrike(List<PitchNote> notes, int i, _Span r) {
  final n = notes[i];
  if (n.muted ||
      n.locked ||
      n.articulation != null ||
      n.guitarString == null ||
      !guitarTimingValid(n) ||
      !_inSpan(n, r)) {
    return null;
  }
  final j = _nextOnString(notes, n);
  if (j == null || !_inSpan(notes[j], r) || notes[j].midi != n.midi) {
    return null;
  }
  return j;
}

/// AFTER: applyRing per region, selection = the notes [_restrike] extends,
/// rangeEnd = the region's latest original end. Returns the notes and the
/// re-strike index of every extended note.
({List<PitchNote> notes, Map<int, int> restrike}) _ringHeldChords(
  List<PitchNote> notes,
  List<_Span> regions,
) {
  var out = notes;
  final restrike = <int, int>{};
  for (final r in regions) {
    final sel = <int, int>{};
    var rangeEnd = 0.0;
    for (var i = 0; i < out.length; i++) {
      if (!_inSpan(out[i], r)) continue;
      if (!out[i].muted) {
        rangeEnd = math.max(rangeEnd, out[i].ringReverted().endSteps);
      }
      final j = _restrike(out, i, r);
      if (j != null) sel[i] = j;
    }
    // an empty selection would mean the whole track to applyRing
    if (sel.isEmpty) continue;
    out =
        applyRing(out, {
          for (final i in sel.keys) out[i],
        }, rangeEnd: rangeEnd).notes;
    restrike.addAll(sel);
  }
  return (notes: out, restrike: restrike);
}

// ── the A/B pair ─────────────────────────────────────────────────────────
typedef _Pair = ({
  List<PitchNote> before,
  List<PitchNote> assigned,
  List<PitchNote> after,
  Map<int, int> restrike,
  Map<PitchNote, UnassignableReason> unassignable,
  Song beforeSong,
  Song afterSong,
});

_Pair _buildPair() {
  final before = _strummed(_blockChords(), strokePatternById('folk'));
  final a = assignStrings(before, const {});
  final ring = _ringHeldChords(a.notes, _barRegions(_bars));
  return (
    before: before,
    assigned: a.notes,
    after: ring.notes,
    restrike: ring.restrike,
    unassignable: a.unassignable,
    beforeSong: _song(_a3n, before),
    afterSong: _song(_a3n, ring.notes),
  );
}

/// Ringing notes whose length actually grew (a note whose original end
/// already equals its re-strike onset, e.g. string 1 before an up stroke,
/// keeps its exact data).
Set<int> _lengthened(_Pair p) => {
  for (final i in p.restrike.keys)
    if (p.after[i].endSteps > p.before[i].endSteps + _eps) i,
};

List<PitchNote> _guitar(Song s) =>
    s.sections.single.tracks['melody']!.pitchNotes;

Map<String, double> _exportVol(Song s) => {
  for (final e in s.vol.entries) e.key: s.mutes[e.key] == true ? 0.0 : e.value,
};

const _lengthKeys = ['dur', 'durationSteps'];
const _stringKeys = [
  'guitarString',
  'stringLocked',
  'ringBaseDur',
  'ringBaseDurationSteps',
];

Map<String, dynamic> _without(PitchNote n, List<String> keys) {
  final j = n.toJson();
  for (final k in keys) {
    j.remove(k);
  }
  return j;
}

/// Pre-stroke hit start of note [n] in steps (bar * 16 + hit step).
double _hitStart(PitchNote n) => strokeGroupStart(n);

/// The notes (indices) of bar [bar]'s hit [hit] (0-based), pitch order.
List<int> _hitNotes(List<PitchNote> notes, int bar, int hit) {
  final at = bar * 16 + _folkHits[hit].$1;
  return [
    for (var i = 0; i < notes.length; i++)
      if ((_hitStart(notes[i]) - at).abs() < _eps) i,
  ]..sort((x, y) => notes[x].midi.compareTo(notes[y].midi));
}

const _names = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B', //
];
String _pitchName(int midi) => '${_names[midi % 12]}${midi ~/ 12 - 1}';
double _sec(double steps) => steps * _stepSec;

// ── .mid helpers ─────────────────────────────────────────────────────────
typedef _N = ({int channel, int key, int velocity, int on, int off});

/// The guitar lane's `.mid` bytes as exportMidiSong builds them, without the
/// file write.
Uint8List _laneMid(Song s) => buildMidi(
  flattenSong(
    s.sections,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
  ),
  _bpm,
  melodyProgram: _nylonGm,
  pan: s.pan,
  articulations: ArticulationPlan.of(s),
);

/// The note list a `.mid` must hold for [notes] (track channel 0, start =
/// step + offset, end = start + length, tick-rounded like buildMidi).
List<_N> _expectedMid(List<PitchNote> notes, int tpq) {
  final tps = tpq / kStepsPerBeat;
  final out = <_N>[
    for (final n in notes)
      if (!n.muted)
        (() {
          final on = n.step * tps + n.offsetSteps * tps;
          return (
            channel: 0,
            key: n.midi,
            velocity: n.velocity ?? 100,
            on: on.round(),
            off: (on + n.soundingSteps * tps).round(),
          );
        })(),
  ];
  out.sort((x, y) => x.on != y.on ? x.on.compareTo(y.on) : x.key - y.key);
  return out;
}

/// Same channel+key note-off/note-on pairs at one tick, and how many of them
/// have the note-on written before the note-off (must be 0).
({int pairs, int onFirst}) _sameTickOffOn(List<MidiEvent> events) {
  final firstOn = <(int, int, int), int>{};
  final firstOff = <(int, int, int), int>{};
  for (var i = 0; i < events.length; i++) {
    final e = events[i];
    final k = (e.tick, e.channel, e.a);
    if (e.kind == 0x90 && e.b > 0) {
      firstOn.putIfAbsent(k, () => i);
    } else if (e.kind == 0x80 || (e.kind == 0x90 && e.b == 0)) {
      firstOff.putIfAbsent(k, () => i);
    }
  }
  var pairs = 0, onFirst = 0;
  for (final k in firstOn.keys) {
    final off = firstOff[k];
    if (off == null) continue;
    pairs++;
    if (firstOn[k]! < off) onFirst++;
  }
  return (pairs: pairs, onFirst: onFirst);
}

/// Same channel+key notes that overlap (a later note-on before the earlier
/// note's off).
int _sameKeyOverlaps(List<_N> notes) {
  final byKey = <(int, int), List<_N>>{};
  for (final n in notes) {
    (byKey[(n.channel, n.key)] ??= []).add(n);
  }
  var count = 0;
  for (final list in byKey.values) {
    list.sort((x, y) => x.on.compareTo(y.on));
    for (var k = 0; k + 1 < list.length; k++) {
      if (list[k + 1].on < list[k].off) count++;
    }
  }
  return count;
}

// ── the variant (preserved items) ────────────────────────────────────────
typedef _Variant = ({
  List<PitchNote> assigned,
  List<PitchNote> after,
  Map<int, int> restrike,
  Map<String, int> idx,
});

/// Two chord regions. Region A [0, 16): hits h0 (step 0) and h1 (4) play
/// E2 A2 D3 G3 B3 E5, h2 (8) and h3 (12, ends at 14, rest until 16) the
/// same without E5. Region B [16, 32): E2 A2 D3 G3 B3 E4 at 16 and 24.
/// h0 E5 = harmonic, h1 B3 = muted, h1 G3 = staccato, h1 A2 = palm,
/// h1 D3 = locked after assignment. ↓↑ stroke.
_Variant _buildVariant() {
  const chordA = [40, 45, 50, 55, 59, 76];
  const chordA2 = [40, 45, 50, 55, 59];
  const chordB = [40, 45, 50, 55, 59, 64];
  final raw = <PitchNote>[];
  final idx = <String, int>{};
  void hit(String h, List<int> chord, int step, int dur) {
    for (final m in chord) {
      idx['$h:$m'] = raw.length;
      raw.add(_note(m, step, dur));
    }
  }

  hit('h0', chordA, 0, 4);
  hit('h1', chordA, 4, 4);
  hit('h2', chordA2, 8, 4);
  hit('h3', chordA2, 12, 2);
  hit('h4', chordB, 16, 8);
  hit('h5', chordB, 24, 8);
  void mod(String k, PitchNote Function(PitchNote) f) =>
      raw[idx[k]!] = f(raw[idx[k]!]);
  mod('h0:76', (n) => n.withArticulation(
      newArticulation(ArticulationKind.harmonicTone)));
  mod('h1:59', (n) => n.copyWith(muted: true));
  mod('h1:55', (n) => n.withArticulation(
      newArticulation(ArticulationKind.staccato)));
  mod('h1:45', (n) => n.withArticulation(
      newArticulation(ArticulationKind.palmTone)));
  final stroked = _strummed(raw, strokePatternById('downUp'));
  final assigned = [...assignStrings(stroked, const {}).notes];
  final locked = idx['h1:50']!;
  assigned[locked] = assigned[locked].copyWith(locked: true);
  final ring = _ringHeldChords(assigned, _barRegions(2));
  return (
    assigned: assigned,
    after: ring.notes,
    restrike: ring.restrike,
    idx: idx,
  );
}

// ── WAV helpers ──────────────────────────────────────────────────────────
typedef _Pcm = ({
  Float32List left,
  Float32List right,
  int sampleRate,
  int dataOffset,
});

_Pcm _readStereo16(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  final channels = bd.getUint16(22, Endian.little);
  final sr = bd.getUint32(24, Endian.little);
  final bits = bd.getUint16(34, Endian.little);
  expect(channels, 2);
  expect(bits, 16);
  var p = 12;
  while (String.fromCharCodes(bytes.sublist(p, p + 4)) != 'data') {
    p += 8 + bd.getUint32(p + 4, Endian.little);
  }
  final len = bd.getUint32(p + 4, Endian.little);
  p += 8;
  final frames = len ~/ 4;
  final l = Float32List(frames), r = Float32List(frames);
  double f(int v) => v < 0 ? v / 0x8000 : v / 0x7fff;
  for (var i = 0; i < frames; i++) {
    l[i] = f(bd.getInt16(p + i * 4, Endian.little));
    r[i] = f(bd.getInt16(p + i * 4 + 2, Endian.little));
  }
  return (left: l, right: r, sampleRate: sr, dataOffset: p);
}

({double peak, double rms}) _levels(Float32List l, Float32List r) {
  var peak = 0.0, sum = 0.0;
  for (final ch in [l, r]) {
    for (final v in ch) {
      final a = v.abs();
      if (a > peak) peak = a;
      sum += v * v;
    }
  }
  return (peak: peak, rms: math.sqrt(sum / (2 * l.length)));
}

double _rmsAt(_Pcm x, double t0, double t1) {
  final a = (t0 * x.sampleRate).round();
  final b = math.min((t1 * x.sampleRate).round(), x.left.length);
  var acc = 0.0;
  for (var i = a; i < b; i++) {
    acc += x.left[i] * x.left[i] + x.right[i] * x.right[i];
  }
  return math.sqrt(acc / (2 * (b - a)));
}

double _db(double v) => v <= 0 ? -999 : 20 * math.log(v) / math.ln10;
double _r2(double v) => (v * 100).round() / 100;
double _r3(double v) => (v * 1000).round() / 1000;

/// 16-bit stereo WAV with no gain applied (samples clamped only).
Uint8List _encodeWavStereo16Raw(Float32List l, Float32List r, int sr) {
  final n = l.length;
  final data = ByteData(44 + n * 4);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 4, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, sr, Endian.little);
  data.setUint32(28, sr * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 4, Endian.little);
  int pcm(double x) {
    final s = x.clamp(-1.0, 1.0);
    return (s < 0 ? s * 0x8000 : s * 0x7fff).round();
  }

  for (var i = 0; i < n; i++) {
    data.setInt16(44 + i * 4, pcm(l[i]), Endian.little);
    data.setInt16(46 + i * 4, pcm(r[i]), Endian.little);
  }
  return data.buffer.asUint8List();
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // slot 1001 must resolve as a guitar for the plan (read-only catalog
  // metadata; nothing is written without the env var)
  setUpAll(() async {
    messenger.setMockMessageHandler('flutter/assets', (message) {
      final path = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      final file = File(path);
      return SynchronousFuture(
        file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null,
      );
    });
    await SoundfontCatalog.instance.warm();
    expect(isGuitarProgram(_nylonSlot), isTrue);
  });
  tearDownAll(() => messenger.setMockMessageHandler('flutter/assets', null));

  group('A3-normal BEFORE vs per-string ring AFTER', () {
    late _Pair p;
    setUpAll(() => p = _buildPair());

    test('strings: every note assigned, assignment changes no length', () {
      expect(p.unassignable, isEmpty);
      expect(p.assigned.length, p.before.length);
      expect(p.before.length, _bars * _folkHits.length * 6);
      for (var i = 0; i < p.before.length; i++) {
        expect(p.assigned[i].guitarString, isNotNull, reason: '#$i');
        expect(p.assigned[i].ringBaseDur, isNull, reason: '#$i');
        expect(
          _without(p.assigned[i], _stringKeys),
          p.before[i].toJson(),
          reason: 'assignment only adds the string #$i',
        );
      }
      // Em, bar 1: the open shape, E2 on string 6 ... E4 on string 1
      final em = _hitNotes(p.assigned, 0, 4);
      expect(
        [for (final i in em) (p.assigned[i].midi, p.assigned[i].guitarString)],
        [(40, 6), (47, 5), (52, 4), (55, 3), (59, 2), (64, 1)],
      );
      for (var bar = 0; bar < _bars; bar++) {
        final strings = [
          for (final i in _hitNotes(p.assigned, bar, 0))
            '${_pitchName(p.assigned[i].midi)}/s${p.assigned[i].guitarString}',
        ].join(' ');
        debugPrint('[ring-demo] bar ${bar + 1} ${_chordRoots[bar]}: $strings');
      }
    });

    test('AFTER differs from BEFORE only in note lengths', () {
      expect(p.after.length, p.before.length);
      for (var i = 0; i < p.before.length; i++) {
        final b = p.before[i], a = p.after[i];
        expect(
          _without(a, [..._lengthKeys, ..._stringKeys]),
          _without(b, _lengthKeys),
          reason: 'pitch, onset, velocity, stroke tag #$i',
        );
        expect((a.midi, a.step, a.offsetSteps, a.velocity),
            (b.midi, b.step, b.offsetSteps, b.velocity));
        expect(a.stroke, b.stroke);
        expect(a.articulation, isNull);
        expect(a.endSteps, greaterThanOrEqualTo(b.endSteps - _eps),
            reason: 'ring only extends #$i');
        if (!p.restrike.containsKey(i)) {
          expect(a.toJson(), p.assigned[i].toJson(), reason: 'kept #$i');
        }
      }
      // the rest of the song is identical
      final reverted = [
        for (final n in revertRing(p.after, const {}).notes)
          n.copyWith(clearGuitarString: true),
      ];
      expect(_song(_a3n, reverted).toJson(), p.beforeSong.toJson());
    });

    test('rule: every held-chord note rings exactly to its re-strike; the '
        'last hit of each chord keeps its note-off', () {
      // 5 of 6 hits per bar ring, the last hit of a chord never does
      expect(p.restrike.length, _bars * 5 * 6);
      for (var bar = 0; bar < _bars; bar++) {
        for (var h = 0; h < _folkHits.length; h++) {
          final cur = _hitNotes(p.after, bar, h);
          expect(cur.length, 6);
          for (final i in cur) {
            final a = p.after[i], b = p.before[i];
            if (h == _folkHits.length - 1) {
              // chord change: the original note-off (bar end) stays
              expect(a.toJson(), p.assigned[i].toJson());
              expect(a.endSteps, closeTo(bar * 16 + 16.0, 1e-9));
              expect(p.restrike.containsKey(i), isFalse);
              continue;
            }
            final next = _hitNotes(p.after, bar, h + 1)
                .where((j) => p.after[j].midi == a.midi)
                .single;
            expect(p.after[next].guitarString, a.guitarString);
            expect(p.restrike[i], next, reason: 'bar $bar hit $h #$i');
            // the realized end IS the re-strike onset (same double)
            expect(a.endSteps, closeTo(p.after[next].startSteps, 1e-9));
            if (a.endSteps > b.endSteps + _eps) {
              expect(a.ringBaseDur, b.dur);
              expect(a.ringBaseDurationSteps, b.durationSteps);
            } else {
              // already ends at the re-strike (0 ms gap): data unchanged
              expect(a.toJson(), p.assigned[i].toJson());
            }
            expect(b.endSteps, closeTo(bar * 16 + _folkHits[h + 1].$1, 1e-9),
                reason: 'BEFORE ends at the next hit\'s pre-stroke start');
          }
        }
      }
    });

    test('hit 5 -> 6 (Em, 2.250 s -> 2.625 s) and hit 2 -> 3 connections', () {
      // seconds: hit 6 is an up stroke, E4 first at 2.625 s, E2 last 2.715 s
      const hit6On = {
        40: 2.715, 47: 2.697, 52: 2.679, 55: 2.661, 59: 2.643, 64: 2.625, //
      };
      final h5 = _hitNotes(p.after, 0, 4), h6 = _hitNotes(p.after, 0, 5);
      expect([for (final i in h5) p.after[i].midi], hit6On.keys.toList());
      for (final i in h5) {
        final a = p.after[i], b = p.before[i];
        final j = h6.singleWhere((j) => p.after[j].midi == a.midi);
        expect(_sec(p.after[j].startSteps), closeTo(hit6On[a.midi]!, 5e-4));
        expect(_sec(b.endSteps), closeTo(2.625, 1e-9), reason: 'BEFORE');
        expect(_sec(a.endSteps), closeTo(hit6On[a.midi]!, 5e-4), reason: 'AFTER');
        expect(a.endSteps, closeTo(p.after[j].startSteps, 1e-9));
        expect(a.guitarString, p.after[j].guitarString);
      }
      // hit 2 (down, 0.75 s) -> hit 3 (up, 1.125 s): same connection
      final h2 = _hitNotes(p.after, 0, 1), h3 = _hitNotes(p.after, 0, 2);
      for (final i in h2) {
        final a = p.after[i];
        final j = h3.singleWhere((j) => p.after[j].midi == a.midi);
        expect(_sec(p.before[i].endSteps), closeTo(1.125, 1e-9));
        expect(a.endSteps, closeTo(p.after[j].startSteps, 1e-9));
        expect(_sec(a.endSteps), closeTo(hit6On[a.midi]! - 1.5, 5e-4));
      }
      for (final row in _connectionRows(p, 0, 4)) {
        debugPrint('[ring-demo] 5->6 $row');
      }
      for (final row in _connectionRows(p, 0, 1)) {
        debugPrint('[ring-demo] 2->3 $row');
      }
    });

    test('.mid: only note-offs differ; same-key note-off before note-on; no '
        'same-pitch overlap', () {
      final rb = readMidiEvents(_laneMid(p.beforeSong));
      final ra = readMidiEvents(_laneMid(p.afterSong));
      expect(ra.tpq, rb.tpq);
      final nb = midiNotes(rb.events), na = midiNotes(ra.events);
      expect(nb, _expectedMid(p.before, rb.tpq));
      expect(na, _expectedMid(p.after, ra.tpq));
      expect(na.length, nb.length);
      var changed = 0;
      for (var k = 0; k < na.length; k++) {
        expect((na[k].channel, na[k].key, na[k].velocity, na[k].on),
            (nb[k].channel, nb[k].key, nb[k].velocity, nb[k].on));
        expect(na[k].off, greaterThanOrEqualTo(nb[k].off));
        if (na[k].off != nb[k].off) changed++;
      }
      expect(changed, _lengthened(p).length);
      expect(changed, greaterThan(0));
      // each extended note's off tick == its re-strike's on tick
      final tps = ra.tpq / kStepsPerBeat;
      for (final e in p.restrike.entries) {
        final n = p.after[e.key], r = p.after[e.value];
        final off = (n.step * tps + n.offsetSteps * tps + n.soundingSteps * tps)
            .round();
        final on = (r.step * tps + r.offsetSteps * tps).round();
        expect(off, on, reason: 'note ${e.key}');
      }
      final pa = _sameTickOffOn(ra.events), pb = _sameTickOffOn(rb.events);
      expect(pa.onFirst, 0, reason: 'AFTER: note-off first');
      expect(pb.onFirst, 0, reason: 'BEFORE: note-off first');
      expect(pa.pairs, greaterThanOrEqualTo(p.restrike.length));
      expect(_sameKeyOverlaps(na), 0);
      expect(_sameKeyOverlaps(nb), 0);
      debugPrint(
        '[ring-demo] mid notes ${na.length}, offs changed $changed, '
        'same-tick off/on pairs before ${pb.pairs} after ${pa.pairs}',
      );
    });

    test('undo path: revertRing restores BEFORE exactly', () {
      final reverted = revertRing(p.after, const {}).notes;
      for (var i = 0; i < reverted.length; i++) {
        expect(reverted[i].toJson(), p.assigned[i].toJson(), reason: '#$i');
        expect(
          reverted[i].copyWith(clearGuitarString: true).toJson(),
          p.before[i].toJson(),
          reason: '#$i',
        );
      }
      // the editor's undo restores its snapshot; the song JSON round trips
      for (final s in [p.beforeSong, p.afterSong]) {
        final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
        expect(Song.fromJson(j).toJson(), s.toJson());
      }
    });

    test('report only: the app\'s one-click ring over the whole track crosses '
        'chord changes', () {
      final app = applyRing(p.assigned, const {}, rangeEnd: _bars * 16.0).notes;
      var crossing = 0, otherPitch = 0;
      var maxOver = 0.0;
      for (var i = 0; i < app.length; i++) {
        final barEnd = (_hitStart(app[i]) ~/ 16) * 16 + 16.0;
        if (app[i].endSteps > barEnd + _eps) {
          crossing++;
          maxOver = math.max(maxOver, app[i].endSteps - barEnd);
          final j = _nextOnString(app, app[i]);
          if (j != null && app[j].midi != app[i].midi) otherPitch++;
        }
      }
      debugPrint(
        '[ring-demo] one-click ring (whole track): $crossing notes ring past '
        'their bar end ($otherPitch into a different pitch on the same string), '
        'up to ${(_sec(maxOver) * 1000).round()} ms',
      );
      expect(crossing, greaterThan(0));
    });
  });

  group('variant: preserved items', () {
    late _Variant v;
    setUpAll(() => v = _buildVariant());
    int at(String k) => v.idx[k]!;

    test('strings as expected', () {
      for (final (k, s) in [
        ('h0:40', 6), ('h0:45', 5), ('h0:50', 4), ('h0:55', 3), ('h0:59', 2),
        ('h0:76', 1), ('h1:76', 1), ('h4:64', 1), ('h3:59', 2), //
      ]) {
        expect(v.assigned[at(k)].guitarString, s, reason: k);
      }
      expect(v.assigned[at('h1:59')].guitarString, isNull, reason: 'muted');
      expect(v.assigned[at('h1:50')].locked, isTrue);
    });

    test('muted, locked, articulated, not re-struck and chord-change notes '
        'keep their lengths', () {
      for (final k in [
        'h0:76', // harmonic (would ring to h1 E5)
        'h1:59', // muted
        'h1:55', // staccato (would ring to h2 G3)
        'h1:45', // palm (would ring to h2 A2)
        'h1:50', // locked (would ring to h2 D3)
        'h1:76', // string 1 not re-struck before the chord change
        'h3:40', 'h3:45', 'h3:50', 'h3:55', 'h3:59', // last hit, rest 14..16
        'h5:40', 'h5:64', // last hit of the song
      ]) {
        expect(v.after[at(k)].toJson(), v.assigned[at(k)].toJson(), reason: k);
        expect(v.restrike.containsKey(at(k)), isFalse, reason: k);
      }
      expect(v.after[at('h3:40')].endSteps, closeTo(14, 1e-9));
      // articulations and gates untouched
      expect(v.after[at('h1:55')].articulation?.kind, ArticulationKind.staccato);
      expect(v.after[at('h1:45')].articulation?.kind, ArticulationKind.palmTone);
      expect(v.after[at('h0:76')].articulation?.kind,
          ArticulationKind.harmonicTone);
    });

    test('held notes ring to the same-string same-pitch re-strike', () {
      for (final (k, to) in [
        ('h0:40', 'h1:40'),
        ('h0:50', 'h1:50'), // a locked note still re-strikes
        ('h0:59', 'h2:59'), // the muted h1 B3 is silent: no re-strike
        ('h1:40', 'h2:40'),
        ('h2:59', 'h3:59'),
        ('h4:64', 'h5:64'),
        ('h0:55', 'h1:55'), // a staccato note still re-strikes
      ]) {
        expect(v.restrike[at(k)], at(to), reason: k);
        expect(v.after[at(k)].endSteps,
            closeTo(v.after[at(to)].startSteps, 1e-9), reason: k);
      }
      // independent expectation for every note
      for (var i = 0; i < v.after.length; i++) {
        final j = v.restrike[i];
        expect(
          v.after[i].endSteps,
          closeTo(
            j == null ? v.assigned[i].endSteps : v.after[j].startSteps,
            1e-9,
          ),
          reason: '#$i',
        );
        if (j == null) expect(v.after[i].toJson(), v.assigned[i].toJson());
      }
      final reverted = revertRing(v.after, const {}).notes;
      for (var i = 0; i < reverted.length; i++) {
        expect(reverted[i].toJson(), v.assigned[i].toJson(), reason: '#$i');
      }
    });

    test('report only: plain applyRing per region (no selection filter) and '
        'the one-click ring would extend notes the rule keeps', () {
      // per region over all region notes, rangeEnd = latest original end
      var perRegion = v.assigned;
      for (final r in _barRegions(2)) {
        final sel = {
          for (final n in perRegion)
            if (_inSpan(n, r)) n,
        };
        final end = sel
            .where((n) => !n.muted)
            .map((n) => n.ringReverted().endSteps)
            .reduce(math.max);
        perRegion = applyRing(perRegion, sel, rangeEnd: end).notes;
      }
      // h1 E5 is never re-struck in region A: extended to the region's
      // latest end (14), not kept
      expect(perRegion[at('h1:76')].endSteps, closeTo(14, 1e-9));
      expect(v.assigned[at('h1:76')].endSteps, closeTo(8, 1e-9));
      // articulated notes get longer data (their gate still caps the sound)
      expect(perRegion[at('h1:55')].endSteps,
          greaterThan(v.assigned[at('h1:55')].endSteps));
      // the one-click ring (nothing selected, rangeEnd = section end)
      final app = applyRing(v.assigned, const {}, rangeEnd: 32).notes;
      expect(app[at('h3:40')].endSteps, greaterThanOrEqualTo(16));
      expect(app[at('h1:76')].endSteps,
          closeTo(app[at('h4:64')].startSteps, 1e-9),
          reason: 'E5 rings into the next chord until string 1 plays E4');
      expect(app[at('h0:76')].endSteps,
          closeTo(app[at('h1:76')].startSteps, 1e-9));
      expect(app[at('h1:59')].toJson(), v.assigned[at('h1:59')].toJson());
      expect(app[at('h1:50')].toJson(), v.assigned[at('h1:50')].toJson());
    });
  });

  final out = Platform.environment['HUMTRACK_DEMO_OUT'];
  test(
    'write the BEFORE/AFTER ring demo (MIDI, WAV, matched, excerpts, README)',
    () async {
      final dir = Directory(out!);
      final base =
          Platform.environment['HUMTRACK_DEMO_BASELINE'] ??
          '${dir.absolute.parent.path}/guitar-articulation-demo-20261022';
      await _writeDemo(dir, Directory(base), _buildPair());
    },
    skip:
        out == null || out.isEmpty
            ? 'set HUMTRACK_DEMO_OUT to write the demo'
            : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

/// Per-note rows of bar [bar], hit [h] -> hit [h] + 1 (pitch order).
List<Map<String, Object>> _connectionRows(_Pair p, int bar, int h) {
  final cur = _hitNotes(p.after, bar, h), nxt = _hitNotes(p.after, bar, h + 1);
  return [
    for (final i in cur)
      (() {
        final a = p.after[i], b = p.before[i];
        final j = nxt.singleWhere((j) => p.after[j].midi == a.midi);
        final on2 = _sec(p.after[j].startSteps);
        return <String, Object>{
          'note': _pitchName(a.midi),
          'string': a.guitarString!,
          'on_s': _r3(_sec(a.startSteps)),
          'off_before_s': _r3(_sec(b.endSteps)),
          'off_after_s': _r3(_sec(a.endSteps)),
          'next_on_s': _r3(on2),
          'gap_before_ms': ((on2 - _sec(b.endSteps)) * 1000).round(),
          'gap_after_ms': ((on2 - _sec(a.endSteps)) * 1000).round(),
          'velocity': '${a.velocity}->${p.after[j].velocity}',
        };
      })(),
  ];
}

Future<void> _writeDemo(Directory outDir, Directory baseDir, _Pair p) async {
  await outDir.create(recursive: true);
  final work = Directory('${outDir.path}/.work');
  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => work.path,
  );
  LoopStorage.rootOverride = work;
  addTearDown(() async {
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    LoopStorage.rootOverride = null;
    if (await work.exists()) await work.delete(recursive: true);
  });

  final catalog = SoundfontCatalog.instance;
  catalog.debugSetDirectory(
    await Directory('${work.path}/soundfonts').create(recursive: true),
  );
  await catalog.warm();
  expect(catalog.bySlot(_nylonSlot)!.id, 'freepats_nylon');
  expect(await catalog.ensureDownloaded(_nylonSlot), isNotNull);
  expect(catalog.midiFallback(_nylonSlot), _nylonGm);

  final sizes = <String, int>{};
  Future<void> put(String name, List<int> bytes) async {
    await File('${outDir.path}/$name').writeAsBytes(bytes, flush: true);
    sizes[name] = bytes.length;
  }

  final songs = {_before: p.beforeSong, _after: p.afterSong};
  final mids = <String, Uint8List>{};
  final wavs = <String, Uint8List>{};
  final jsons = <String, List<int>>{};
  final pcms = <String, _Pcm>{};
  final measured = <String, ({double peak, double rms})>{};
  for (final e in songs.entries) {
    final name = e.key, s = e.value;
    final sec = s.sections.single;
    // the editor passes its ArticulationPlan; for this song it equals .of
    final plan = ArticulationPlan.of(s);
    final mid = await (await exportMidiSong(
      s.sections,
      s.bpm,
      name,
      melodyProgram: s.instruments['melody'] ?? 0,
      bassProgram: s.instruments['bass'] ?? 33,
      melodyDecProgram: s.instruments['melodyDec'] ?? 48,
      drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
      extras: sec.extras,
      instruments: s.instruments,
      fallbackName: s.id,
      variationSeed: s.effectiveVariationSeed,
      groove: s.grooveContext,
      pan: s.pan,
      articulations: plan,
    )).readAsBytes();
    final read = readMidiEvents(mid);
    expect(midiNotes(read.events), _expectedMid(_guitar(s), read.tpq),
        reason: '$name exportMidiSong');
    expect(_sameTickOffOn(read.events).onFirst, 0, reason: name);
    mids[name] = mid;
    await put('$name.mid', mid);

    final wav = await exportWavSong(
      s.sections,
      s.bpm,
      s.swing,
      _exportVol(s),
      name,
      melodyProgram: s.instruments['melody'] ?? 0,
      bassProgram: s.instruments['bass'] ?? 33,
      melodyDecProgram: s.instruments['melodyDec'] ?? 48,
      drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
      extras: sec.extras,
      instruments: s.instruments,
      fallbackName: s.id,
      variationSeed: s.effectiveVariationSeed,
      groove: s.grooveContext,
      pan: s.pan,
      articulations: plan,
    );
    expect(wav.skippedVocals, 0);
    final wavBytes = await wav.file.readAsBytes();
    wavs[name] = wavBytes;
    await put('$name.wav', wavBytes);
    final pcm = _readStereo16(wavBytes);
    expect(pcm.sampleRate, 44100);
    expect(_levels(pcm.left, pcm.right).peak, greaterThan(.01));
    pcms[name] = pcm;
    measured[name] = _levels(pcm.left, pcm.right);

    final json = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(s.toJson()),
    );
    jsons[name] = json;
    await put('$name.song.json', json);
  }
  expect(pcms[_before]!.left.length, pcms[_after]!.left.length);

  // ── loudness match: one RMS target for both, lowered if a peak would
  // pass the ceiling ──
  const ceilingDb = -1.0;
  final ceiling = math.pow(10, ceilingDb / 20).toDouble();
  var targetDb = -20.0;
  for (final m in measured.values) {
    final peakAfter = m.peak * math.pow(10, targetDb / 20) / m.rms;
    if (peakAfter > ceiling) {
      targetDb = math.min(targetDb, _db(m.rms * ceiling / m.peak));
    }
  }
  final target = math.pow(10, targetDb / 20).toDouble();
  final files = <String, Object>{};
  final matched = <String, _Pcm>{};
  final excerptLevels = <String, Object>{};
  final windows = <String, Object>{};
  int? excerptFrames;
  for (final name in songs.keys) {
    final m = measured[name]!, pcm = pcms[name]!;
    final gain = target / m.rms;
    final l = Float32List(pcm.left.length), r = Float32List(pcm.right.length);
    for (var i = 0; i < l.length; i++) {
      l[i] = pcm.left[i] * gain;
      r[i] = pcm.right[i] * gain;
    }
    final bytes = _encodeWavStereo16Raw(l, r, pcm.sampleRate);
    await put('$name.matched.wav', bytes);
    final mp = _readStereo16(bytes);
    matched[name] = mp;
    final after = _levels(mp.left, mp.right);
    expect(after.peak, lessThanOrEqualTo(ceiling + 1e-4), reason: name);
    expect(_db(after.rms), closeTo(targetDb, .05), reason: name);
    files[name] = {
      'seconds': _r2(pcm.left.length / pcm.sampleRate),
      'before': {'peak_dbfs': _r2(_db(m.peak)), 'rms_dbfs': _r2(_db(m.rms))},
      'gain_db': _r3(_db(gain)),
      'after': {
        'peak_dbfs': _r2(_db(after.peak)),
        'rms_dbfs': _r2(_db(after.rms)),
      },
    };

    // ── excerpt from the matched file: same window, same fades ──
    final sr = mp.sampleRate;
    final a = (_ex0 * sr).round(), b = (_ex1 * sr).round();
    final n = b - a;
    final fade = (_fadeMs / 1000 * sr).round();
    final el = Float32List(n), er = Float32List(n);
    for (var i = 0; i < n; i++) {
      var g = 1.0;
      if (i < fade) g = i / fade;
      if (i >= n - fade) g = math.min(g, (n - 1 - i) / fade);
      el[i] = mp.left[a + i] * g;
      er[i] = mp.right[a + i] * g;
    }
    final ex = _encodeWavStereo16Raw(el, er, sr);
    await put('$name.excerpt.wav', ex);
    excerptFrames ??= n;
    expect(n, excerptFrames);
    final exl = _levels(el, er);
    expect(exl.peak, lessThanOrEqualTo(ceiling + 1e-4));
    excerptLevels[name] = {
      'frames': n,
      'peak_dbfs': _r2(_db(exl.peak)),
      'rms_dbfs': _r2(_db(exl.rms)),
    };
    windows[name] = {
      for (final (t0, t1) in [
        (2.25, 2.625),
        (2.625, 2.715),
        (2.715, 3.0),
        (0.75, 1.125),
        (1.125, 1.215),
      ])
        '$t0-$t1': _r2(_db(_rmsAt(mp, t0, t1))),
    };
  }

  // ── baseline: BEFORE regenerates A3-normal ──
  Future<List<int>?> baseline(String ext) async {
    final f = File('${baseDir.path}/$_a3n.$ext');
    return await f.exists() ? f.readAsBytes() : null;
  }

  final baseJson = await baseline('song.json');
  final baseMid = await baseline('mid');
  final baseWav = await baseline('wav');
  bool? sampleExact;
  bool? headerSame;
  if (baseWav != null) {
    final x = _readStereo16(Uint8List.fromList(baseWav));
    final y = pcms[_before]!;
    final bw = wavs[_before]!;
    headerSame =
        x.dataOffset == y.dataOffset &&
        _sameBytes(baseWav.sublist(0, x.dataOffset), bw.sublist(0, y.dataOffset));
    sampleExact =
        _sameBytes(baseWav.sublist(x.dataOffset), bw.sublist(y.dataOffset));
  }
  final baselineCheck = {
    'baseline_dir': baseDir.path,
    'song_json_byte_identical':
        baseJson == null ? null : _sameBytes(baseJson, jsons[_before]!),
    'mid_byte_identical':
        baseMid == null ? null : _sameBytes(baseMid, mids[_before]!),
    'wav_byte_identical':
        baseWav == null ? null : _sameBytes(baseWav, wavs[_before]!),
    'wav_header_identical': headerSame,
    'wav_samples_identical': sampleExact,
    'note':
        'null = baseline file not found. matched.wav is not compared: its '
        'target was common to the gt-003 demo set.',
  };
  debugPrint('[ring-demo] baseline ${jsonEncode(baselineCheck)}');

  final rows56 = _connectionRows(p, 0, 4);
  final rows23 = _connectionRows(p, 0, 1);
  final app = applyRing(p.assigned, const {}, rangeEnd: _bars * 16.0).notes;
  var crossing = 0;
  var maxOver = 0.0;
  for (final n in app) {
    final barEnd = (_hitStart(n) ~/ 16) * 16 + 16.0;
    if (n.endSteps > barEnd + _eps) {
      crossing++;
      maxOver = math.max(maxOver, n.endSteps - barEnd);
    }
  }
  final levelsJson = {
    'method':
        'RMS over every sample of both channels of the whole file (render tail '
        'included), dBFS. One common RMS target for BEFORE and AFTER, lowered '
        'if a gain would put a peak above the ceiling. 16-bit PCM, no limiter.',
    'target_rms_dbfs': _r2(targetDb),
    'requested_target_rms_dbfs': -20.0,
    'peak_ceiling_dbfs': ceilingDb,
    'files': files,
    'excerpt': {
      'from_s': _ex0,
      'to_s': _ex1,
      'fade_ms': _fadeMs,
      'source': 'the .matched.wav files',
      'files': excerptLevels,
    },
    'window_rms_dbfs_matched': windows,
    'baseline_check': baselineCheck,
    'ring': {
      'notes': p.after.length,
      'ring_to_restrike': p.restrike.length,
      'already_end_at_restrike': p.restrike.length - _lengthened(p).length,
      'extended': _lengthened(p).length,
      'kept': p.after.length - _lengthened(p).length,
      'one_click_ring_notes_past_bar_end': crossing,
      'one_click_ring_max_overrun_ms': (_sec(maxOver) * 1000).round(),
    },
    'hit5_to_6': rows56,
    'hit2_to_3': rows23,
  };
  await put(
    'levels.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(levelsJson)),
  );
  await File('${outDir.path}/README.md').writeAsString(
    _readme(p, levelsJson, sizes),
    flush: true,
  );
  debugPrint('[ring-demo] wrote ${sizes.length + 1} files to ${outDir.path}');
  for (final s in sizes.entries) {
    debugPrint('[ring-demo]   ${s.key}: ${s.value} B');
  }
  for (final l in files.entries) {
    debugPrint('[ring-demo]   ${l.key}: ${jsonEncode(l.value)}');
  }
  debugPrint('[ring-demo] excerpt ${jsonEncode(excerptLevels)}');
  debugPrint('[ring-demo] windows ${jsonEncode(windows)}');

  // the baseline must regenerate exactly (checked after everything is
  // written, so the record exists either way)
  expect(baselineCheck['song_json_byte_identical'], isTrue);
  expect(baselineCheck['mid_byte_identical'], isTrue);
  expect(baselineCheck['wav_samples_identical'], isTrue);
}

String _kb(int b) => '${(b / 1024).toStringAsFixed(1)} KB';

String _table(List<Map<String, Object>> rows, String a, String b) {
  final s = StringBuffer()
    ..writeln(
      '| 음 | 줄 | $a번째 시작(s) | BEFORE note-off(s) | AFTER note-off(s) | '
      '$b번째 시작(s) | BEFORE 공백(ms) | AFTER 공백(ms) | velocity $a→$b |',
    )
    ..writeln('|---|---:|---:|---:|---:|---:|---:|---:|---:|');
  for (final r in rows) {
    s.writeln(
      '| ${r['note']} | ${r['string']} | ${r['on_s']} | ${r['off_before_s']} | '
      '${r['off_after_s']} | ${r['next_on_s']} | ${r['gap_before_ms']} | '
      '${r['gap_after_ms']} | ${(r['velocity'] as String).replaceAll('->', '→')} |',
    );
  }
  return s.toString();
}

String _readme(_Pair p, Map<String, Object> lv, Map<String, int> sizes) {
  final files = lv['files'] as Map<String, Object>;
  final rows = StringBuffer();
  for (final e in files.entries) {
    final v = e.value as Map;
    final b = v['before'] as Map, a = v['after'] as Map;
    rows.writeln(
      '| ${e.key} | ${v['seconds']} | ${b['peak_dbfs']} | ${b['rms_dbfs']} | '
      '${v['gain_db']} | ${a['peak_dbfs']} | ${a['rms_dbfs']} |',
    );
  }
  final ex = lv['excerpt'] as Map;
  final exRows = StringBuffer();
  for (final e in (ex['files'] as Map).entries) {
    final v = e.value as Map;
    exRows.writeln(
      '| `${e.key}.excerpt.wav` | ${v['frames']} | ${v['peak_dbfs']} | '
      '${v['rms_dbfs']} |',
    );
  }
  final win = lv['window_rms_dbfs_matched'] as Map;
  final winKeys = (win[_before] as Map).keys.toList();
  final winRows = StringBuffer();
  for (final k in winKeys) {
    winRows.writeln(
      '| $k | ${(win[_before] as Map)[k]} | ${(win[_after] as Map)[k]} |',
    );
  }
  final fileRows = StringBuffer();
  for (final e in sizes.entries) {
    fileRows.writeln('| `${e.key}` | ${_kb(e.value)} |');
  }
  final bc = lv['baseline_check'] as Map;
  String yn(Object? v) => v == null ? '기준 파일 없음' : (v == true ? '동일' : '다름');
  final ring = lv['ring'] as Map;
  final strings = [
    for (var bar = 0; bar < 4; bar++)
      '${_chordRoots[bar]} ${[
        for (final i in _hitNotes(p.assigned, bar, 0))
          '${_pitchName(p.assigned[i].midi)}(${p.assigned[i].guitarString})',
      ].join(' ')}',
  ].join(' · ');
  return '''
# 일반 스트로크 줄별 울림 A/B 비교 (2026-10-22)

`docs/product/guitar-listening-evaluation.md`의 "첫 의견: 일반 스트로크의 5→6번째 타격"에 대한 첫 비교안.
**청취 검증은 하지 않았다.** 아래 내용은 음 데이터·이벤트·파형 측정 사실뿐이며, 5→6번째 연결이 어색한 원인은 여전히 **가설**이다.

- **BEFORE** (`$_before.*`): 기존 `A3-normal`과 같은 곡을 같은 코드로 다시 만든 것 (기존 파일과의 비교는 아래 "기준선 확인").
- **AFTER** (`$_after.*`): 같은 곡에서 **음 길이(note-off)만** 바꾼 것. 각 줄이 같은 코드 안에서 같은 줄·같은 음으로 다시 쳐질 때까지 울린다.

## 정확한 규칙 (AFTER)
기존 G2 함수만 사용했다. 새 기능이나 앱 코드 변경은 없다.
1. `assignStrings(전체 트랙)` — 표준 조율 줄 배정. 모든 음이 배정되었고(배정 불가 0) 배정 자체는 길이를 바꾸지 않았다.
   첫 타격 기준 줄: $strings (괄호 = 줄 번호, 1 = 높은 E).
2. 코드 구간 = 한 마디(한 마디에 한 코드, 스트로크 전 시작 기준). 구간마다 `applyRing`을 한 번 호출한다.
   - 선택: 그 구간의 음 중 **다음으로 같은 줄에서 울리는 음(음소거 음 제외)이 같은 구간 안에 있고 음높이가 같은** 음만.
   - `rangeEnd`: 그 구간 음들의 원래(울림 전) 끝 중 가장 늦은 값. 선택된 음의 재타격은 항상 그보다 앞이므로 실제 끝 = 재타격 시작.
3. 늘리지 않는 음(원래 note-off 유지): 코드가 바뀌기 전 같은 줄에서 다시 쳐지지 않는 음(각 마디 마지막 타격 포함),
   다음 타격이 다른 음높이인 음, 음소거 음, 잠긴 음, 연주법(짧게·팜뮤트·하모닉스)이 붙은 음.
   이 데모 곡에는 음소거·잠금·연주법 음이 없으므로, 보존 규칙은 별도의 작은 변형 곡으로 테스트했다.
4. 모든 음을 일괄로 늘리지 않는다. 결과: 전체 ${ring['notes']}음 중 **${ring['extended']}음 연장**, ${ring['kept']}음 그대로
   마디마다 앞 5타격 × 6줄 = ${ring['ring_to_restrike']}음이 재타격까지 울리도록 선택되었고, 그중 ${ring['already_end_at_restrike']}음은
   원래 끝이 이미 재타격 시작과 같아(예: 업스트로크 직전의 1번 줄 E4, 공백 0 ms) 데이터가 그대로다.
   마지막 타격 6줄은 마디 끝(코드 전환)에서 원래대로 끝난다.

`applyRing`만 구간 전체 선택으로 부르면, 구간 안에서 다시 쳐지지 않는 줄도 `rangeEnd`까지 늘어난다(변형 곡 테스트로 확인).
그래서 위 2의 선택 필터를 두었다. 이것은 앱 결함이 아니라 `applyRing`의 정의(선택 범위 끝까지 울림)와 이번 규칙의 차이다.

## 무엇이 다르고 무엇이 같은가
- 다른 것: 연장된 음의 `dur`/`durationSteps`(곡 JSON), 그 음의 note-off tick(`.mid`), 그에 따른 WAV 파형.
  추가 메타데이터: 모든 음의 `guitarString`, 연장된 음의 `ringBaseDur`/`ringBaseDurationSteps`(원래 길이 기록).
- 같은 것(테스트로 확인): 음 개수, 음높이, 시작(step·offset), velocity, 스트로크 태그(StrokeTag), 연주법 없음,
  곡 id·제목·템포 80 BPM·키·음색(슬롯 1001 FreePats nylon, `.mid`는 GM 24)·음소거·볼륨·팬 등 곡의 나머지 전부.
  `.mid`에서 BEFORE와 AFTER는 note-on(채널·키·velocity·tick)이 모두 같고 note-off만 다르다.
- 곡 JSON의 id·제목은 두 파일 모두 기준선과 같은 `A3-normal`이다(곡 내용 비교를 위해 일부러 유지). 파일 이름으로 구분한다.

## 5→6번째 타격 (첫 마디 Em, 2.250 s ↓ → 2.625 s ↑)
${_table(lv['hit5_to_6'] as List<Map<String, Object>>, '5', '6')}
공백 = 다음 시작 − note-off (게이트 공백일 뿐, 음원 릴리스까지 끊긴 무음 구간이라는 뜻은 아니다).
`.mid`에서 연장된 음의 note-off tick은 재타격 note-on tick과 같고, 같은 tick에서 같은 키의 note-off가 note-on보다 먼저 기록된다(테스트로 확인).

## 2→3번째 타격 (0.750 s ↓ → 1.125 s ↑, 같은 규칙)
${_table(lv['hit2_to_3'] as List<Map<String, Object>>, '2', '3')}
## 기준선 확인 (BEFORE = 기존 A3-normal)
기준 폴더: `${bc['baseline_dir']}`
| 항목 | 결과 |
|---|---|
| `.song.json` 바이트 | ${yn(bc['song_json_byte_identical'])} |
| `.mid` 바이트 | ${yn(bc['mid_byte_identical'])} |
| `.wav` 바이트 | ${yn(bc['wav_byte_identical'])} |
| `.wav` 헤더 | ${yn(bc['wav_header_identical'])} |
| `.wav` 샘플 | ${yn(bc['wav_samples_identical'])} |

`A3-normal.matched.wav`는 비교하지 않았다(그 파일은 gt-003 데모 전체에 공통 목표로 맞춘 것이라 이번 두 파일의 목표와 다르다).

## 음량 맞추기
파일 전체(렌더 꼬리 포함), 양 채널 모든 샘플의 RMS. BEFORE와 AFTER에 **같은 RMS 목표**를 쓰고, 피크가 ${lv['peak_ceiling_dbfs']} dBFS를 넘으면 둘 다 낮춘다.
**적용 목표: ${lv['target_rms_dbfs']} dBFS RMS.** 리미터 없음, 클리핑 없음.

| 파일 | 길이(s) | 원본 피크 | 원본 RMS | 게인 dB | 맞춘 후 피크 | 맞춘 후 RMS |
|---|---|---|---|---|---|---|
$rows
`.wav`는 내보내기 규칙대로 각자 피크 정규화된 상태라, 원본끼리 직접 비교하지 말고 `.matched.wav`로 들을 것.

## 발췌 (5→6번째 포함)
`.matched.wav`에서 같은 위치 ${ex['from_s']}–${ex['to_s']} s를 잘라냈다. 길이 동일, 앞뒤 ${ex['fade_ms']} ms 선형 페이드 동일.
구간: 2번째 타격(0.75 s)은 빠지고 3번째 일부(1.5 s~), 4번째(1.875 s), **5번째(2.25 s) → 6번째(2.625 s)**, 다음 마디 Am 첫 타격(3.0 s)까지.

| 파일 | 프레임 | 피크 dBFS | RMS dBFS |
|---|---|---|---|
$exRows
짧은 구간 RMS (맞춘 파일, dBFS; 측정값일 뿐 청감 판단이 아님):

| 구간(s) | BEFORE | AFTER |
|---|---|---|
$winRows
## 앱의 한 번 누르기 "울림 아르페지오"와의 차이 (보고만, 변경 없음)
선택 없이 트랙 전체에 실행하면 `rangeEnd` = 섹션 끝, 각 음은 같은 줄(또는 같은 음높이)의 다음 시작까지 울린다. 코드 구간을 모른다.
- 이 곡에서는 ${ring['one_click_ring_notes_past_bar_end']}음이 자기 마디 끝을 넘어 다음 코드로 울린다(최대 ${ring['one_click_ring_max_overrun_ms']} ms).
  다음 마디의 같은 줄이 다른 음이면 그 음이 쳐질 때까지 이전 코드 음이 겹친다. 다음 코드에서 쓰지 않는 줄은 그 줄이 다시 쳐지거나 섹션이 끝날 때까지 울린다.
- 코드 사이에 쉼이 있으면(변형 곡) 마지막 타격도 다음 코드까지 늘어난다.
- 연주법 음도 데이터 길이는 늘어난다(소리는 gt-003 게이트가 짧게 자름). 음소거·잠긴 음은 바뀌지 않는다.
- 즉 한 번 누르기 결과는 이번 AFTER와 같지 않다. 코드 전환을 넘어 울리는 것을 원하지 않으면 마디(코드)별로 선택해 실행해야 하며,
  그래도 구간 안에서 다시 쳐지지 않는 줄은 선택 끝까지 늘어난다.

## 검사 (항상 실행)
- 5→6, 2→3 및 모든 마디의 앞 5타격: 연장된 음의 끝 = 같은 줄·같은 음의 다음 타격 시작(예: E2 2.715 s), 마지막 타격은 원래 끝(마디 끝).
- BEFORE↔AFTER: 음높이·시작·velocity·개수·스트로크 태그 동일, 길이만 증가. 곡 나머지 JSON 동일.
- `.mid`: note-on 동일, 바뀐 note-off 수 = 연장 음 수, 연장 음 note-off tick = 재타격 tick, 같은 tick 같은 키는 note-off 먼저, 같은 채널 같은 음높이 겹침 0.
- `revertRing`(울림 되돌리기) → 줄 정보만 남은 BEFORE와 JSON 완전 일치, 줄 정보까지 지우면 BEFORE와 완전 일치.
- 변형 곡: 음소거·잠금·짧게·팜뮤트·하모닉스 음, 구간 안에서 다시 쳐지지 않는 줄, 코드 전 쉼이 있는 마지막 타격은 그대로.

## 파일
| 파일 | 크기 |
|---|---|
$fileRows| `README.md` | (이 파일) |
| `test-output.log` | 아래 명령의 실행 로그 |
| `test-output-noenv.log` | 같은 테스트를 `HUMTRACK_DEMO_OUT` 없이 실행한 로그(검사만) |
| `regression-*.log`, `analyze.log` | 회귀 테스트·정적 분석 로그 |

## 다시 만들기
```
cd C:/src/humming-v2/mobile && TMP=C:/src/humming-v2/artifacts/guitar-stroke-ring-20261022/temp TEMP=C:/src/humming-v2/artifacts/guitar-stroke-ring-20261022/temp HUMTRACK_DEMO_OUT=C:/src/humming-v2/artifacts/guitar-stroke-ring-20261022 /c/src/flutter/bin/flutter test --no-pub test/looptap/guitar_stroke_ring_demo_test.dart
```
`HUMTRACK_DEMO_OUT`이 없으면 같은 테스트가 곡을 만들고 검사만 한다(파일 쓰기 없음).
기준 폴더는 `HUMTRACK_DEMO_BASELINE`으로 바꿀 수 있다(기본: 출력 폴더 옆 `guitar-articulation-demo-20261022`).

## 한계 (정직하게)
- **청취 검증 안 됨.** AFTER가 더 자연스러운지는 사용자의 청취로만 판단할 수 있다.
- 원인은 **가설**이다(저음 줄 울림의 조기 종료 + 업스트로크 저음 velocity 감소). 이 비교는 첫 번째 요인만 바꾼다.
  AFTER도 어색하면 업스트로크 저음 세기와 줄별 시간차를 따로 비교해야 한다.
- 한 MIDI 채널에서 같은 음높이는 동시에 두 번 울릴 수 없다. AFTER의 연장은 재타격 시점에서 끝나므로 겹침은 없다.
- WAV는 MeltySynth 오프라인 렌더(앱 내보내기와 같은 경로). 실시간 재생 엔진과 미세한 차이가 있을 수 있다.
- RMS는 단순 음량 지표다(청감 가중 LUFS 아님).
''';
}
