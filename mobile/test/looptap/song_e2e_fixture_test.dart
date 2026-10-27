// End-to-end song test data (artifacts/song-e2e-20261023/plan.md, step 1).
//
// An ORIGINAL instrumental, written for this test: 4/4, 103 BPM, E minor,
// acoustic (nylon) guitar centred. Form, as five distinct 4-bar sections:
//   Intro ×1 · Verse ×4 · Chorus ×4 · Break ×2 · Chorus (linked copy) ×4 ·
//   Outro ×1 = 64 bars = 64 × 4 × 60 / 103 = 149.126 s (+1.2 s export tail).
// Lanes (the layout the app's MIDI importer gives the Verse .mid):
//   melody    = Guitar (catalog slot 1001, FreePats nylon; GM 24 in .mid)
//   melodyDec = Lead   (single-line melody, GM 73 flute)
//   bass      = Bass   (GM 33)
//   drums     = Drums  (kick / snare / hihat, ch10)
// Guitar: Verse/Chorus/Outro are chord hits converted with the app's own
// gt-001 applyStrokePattern, then assignStrings and gt-004
// applyStrokeSustain; Intro/Break are chords arpeggiated with the app's
// arpeggiatePitchNotes (Up-Down, 1/8, gate 100 %), then assignStrings and
// applyRing ("울림 아르페지오").
//
// ALWAYS: builds the plain and the processed song with the real models and
// functions and checks them (form, ranges, tools applied, JSON round trip,
// every section .mid parses with the app's midi_import.dart and its 4-bar
// passage gives exactly the expected lanes and notes).
// ONLY with HUMTRACK_E2E_OUT set: writes the section .mid files, the
// 64-bar reference .mid and entry-sheet.md (first test), then the fixture
// Song JSON, the real exportWavSong mix, exportStems, exportMidiSong and
// reference-measurements.json + README.md (second test).
//
// Regenerate (from mobile/):
//   HUMTRACK_E2E_OUT=<dir> /c/src/flutter/bin/flutter test --no-pub \
//     test/looptap/song_e2e_fixture_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/arpeggiate.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/guitar_sustain.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart' show QuantizeGrid;
import 'package:humming/looptap/music/section_links.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

const int _bpm = 103;
const int _bars = 4; // every section
const int _secSteps = _bars * 16;
const int _nylonSlot = 1001;
const int _tpq = 96; // section .mid files: 24 ticks per 16th
const String _songId = 'e2e_song_103';
const String _title = 'E2E Song 103';
const double _barSec = 4 * 60 / _bpm; // 2.3301 s
const double _headroom = 0.94;
const double _lsb = 1 / 32767;

// ── the music ──────────────────────────────────────────────────────────
typedef _N = ({int midi, int step, int dur, int vel});
typedef _D = ({String kind, int step, int vel});

/// Open-position shapes (MIDI, low string first) and their fret diagrams
/// (6th string → 1st, x = not played).
const Map<String, (List<int>, String)> _shapes = {
  'Em': ([40, 47, 52, 55, 59, 64], '022000'),
  'C': ([48, 52, 55, 60, 64], 'x32010'),
  'G': ([43, 47, 50, 55, 59, 67], '320003'),
  'D': ([50, 57, 62, 66], 'xx0232'),
  'Cmaj7': ([48, 52, 55, 59, 64], 'x32000'),
  'Am7': ([45, 52, 55, 60, 64], 'x02010'),
  'B7': ([47, 51, 57, 59, 66], 'x21202'),
};

/// One chord hit: (start step, length in steps, chord name).
typedef _Hit = (int, int, String);

/// Folk strum positions in one bar: beats 1, 2, 2&, 3& (tied over 3), 4, 4&.
const List<(int, int)> _folk = [(0, 4), (4, 2), (6, 4), (10, 2), (12, 2), (14, 2)];

List<_N> _chordNotes(List<_Hit> hits, int vel) => [
  for (final (s, d, c) in hits)
    for (final m in _shapes[c]!.$1) (midi: m, step: s, dur: d, vel: vel),
];

List<_N> _n(int vel, List<(int, int, int)> notes) => [
  for (final (m, s, d) in notes) (midi: m, step: s, dur: d, vel: vel),
];

class _Part {
  const _Part({
    required this.id,
    required this.name,
    required this.repeats,
    required this.chords,
    required this.guitarHits,
    required this.guitarVel,
    required this.arpeggio,
    required this.strokePattern,
    required this.lead,
    required this.bass,
    required this.drums,
  });
  final String id, name;
  final int repeats;

  /// Chord chart, one entry per bar ("Em", "Em–B7" …).
  final List<String> chords;
  final List<_Hit> guitarHits;
  final int guitarVel;

  /// Intro/Break: the hits are arpeggiated (Up-Down, 1/8, gate 100 %).
  final bool arpeggio;

  /// Verse/Chorus/Outro: the gt-001 pattern preset id.
  final String? strokePattern;
  final List<_N> lead, bass;
  final List<_D> drums;
}

List<_D> _drumBars(List<_D> Function(int bar, int o) bar) => [
  for (var b = 0; b < _bars; b++) ...bar(b, b * 16),
];

final List<_Part> _parts = [
  _Part(
    id: 'intro',
    name: 'Intro',
    repeats: 1,
    chords: const ['Em', 'Cmaj7', 'Am7', 'B7'],
    guitarHits: const [(0, 16, 'Em'), (16, 16, 'Cmaj7'), (32, 16, 'Am7'), (48, 16, 'B7')],
    guitarVel: 76,
    arpeggio: true,
    strokePattern: null,
    lead: const [],
    bass: _n(70, const [(40, 0, 16), (36, 16, 16), (33, 32, 16), (35, 48, 16)]),
    drums: _drumBars((b, o) => [
      (kind: 'kick', step: o, vel: 55),
      for (final s in const [0, 4, 8, 12]) (kind: 'hihat', step: o + s, vel: 40),
    ]),
  ),
  _Part(
    id: 'verse',
    name: 'Verse',
    repeats: 4,
    chords: const ['Em', 'C', 'G', 'D'],
    guitarHits: [
      for (final (b, c) in const [(0, 'Em'), (1, 'C'), (2, 'G'), (3, 'D')])
        for (final (s, d) in _folk) (b * 16 + s, d, c),
    ],
    guitarVel: 90,
    arpeggio: false,
    strokePattern: 'folk',
    lead: _n(88, const [
      (71, 0, 4), (67, 4, 2), (69, 6, 2), (71, 8, 6), //
      (72, 16, 4), (71, 20, 2), (69, 22, 2), (67, 24, 6),
      (71, 32, 4), (74, 36, 2), (71, 38, 2), (67, 40, 4), (69, 44, 4),
      (66, 48, 4), (64, 52, 2), (66, 54, 2), (69, 56, 8),
    ]),
    bass: _n(88, const [
      (40, 0, 6), (40, 6, 2), (35, 8, 4), (38, 12, 4), //
      (36, 16, 6), (36, 22, 2), (31, 24, 4), (33, 28, 4),
      (31, 32, 6), (31, 38, 2), (38, 40, 4), (35, 44, 4),
      (38, 48, 6), (38, 54, 2), (33, 56, 4), (39, 60, 4),
    ]),
    drums: _drumBars((b, o) => [
      (kind: 'kick', step: o, vel: 90),
      (kind: 'kick', step: o + 8, vel: 84),
      (kind: 'kick', step: o + 10, vel: 66),
      (kind: 'snare', step: o + 4, vel: 82),
      (kind: 'snare', step: o + 12, vel: 82),
      for (var s = 0; s < 16; s += 2)
        (kind: 'hihat', step: o + s, vel: s % 4 == 0 ? 62 : 46),
    ]),
  ),
  _Part(
    id: 'chorus',
    name: 'Chorus',
    repeats: 4,
    chords: const ['C', 'G/B', 'D', 'Em–B7'],
    guitarHits: [
      for (final (b, c) in const [(0, 'C'), (1, 'G'), (2, 'D')])
        for (var s = 0; s < 16; s += 2) (b * 16 + s, 2, c),
      for (var s = 48; s < 64; s += 2) (s, 2, s < 56 ? 'Em' : 'B7'),
    ],
    guitarVel: 96,
    arpeggio: false,
    strokePattern: 'downUp',
    lead: _n(96, const [
      (76, 0, 4), (72, 4, 2), (74, 6, 2), (76, 8, 6), //
      (74, 16, 4), (71, 20, 2), (72, 22, 2), (74, 24, 6),
      (69, 32, 4), (74, 36, 4), (72, 40, 2), (71, 42, 2), (69, 44, 4),
      (67, 48, 4), (71, 52, 4), (69, 56, 4), (66, 60, 4),
    ]),
    bass: _n(94, const [
      (36, 0, 4), (36, 4, 2), (36, 6, 2), (43, 8, 4), (36, 12, 2), (35, 14, 2),
      (35, 16, 4), (35, 20, 2), (35, 22, 2), (31, 24, 4), (35, 28, 2), (33, 30, 2),
      (38, 32, 4), (38, 36, 2), (38, 38, 2), (45, 40, 4), (38, 44, 2), (42, 46, 2),
      (40, 48, 4), (40, 52, 2), (43, 54, 2), (35, 56, 4), (35, 60, 2), (35, 62, 2),
    ]),
    drums: _drumBars((b, o) => [
      (kind: 'kick', step: o, vel: 96),
      (kind: 'kick', step: o + 6, vel: 72),
      (kind: 'kick', step: o + 8, vel: 90),
      (kind: 'kick', step: o + 10, vel: 70),
      (kind: 'snare', step: o + 4, vel: 90),
      (kind: 'snare', step: o + 12, vel: 90),
      if (b == 3) (kind: 'snare', step: o + 14, vel: 64),
      for (var s = 0; s < 16; s += 2)
        (kind: 'hihat', step: o + s, vel: s % 4 == 0 ? 70 : 54),
    ]),
  ),
  _Part(
    id: 'break',
    name: 'Break',
    repeats: 2,
    chords: const ['Am7', 'Em', 'Cmaj7', 'B7'],
    guitarHits: const [(0, 16, 'Am7'), (16, 16, 'Em'), (32, 16, 'Cmaj7'), (48, 16, 'B7')],
    guitarVel: 72,
    arpeggio: true,
    strokePattern: null,
    lead: _n(72, const [
      (76, 0, 8), (74, 8, 4), (72, 12, 4), //
      (71, 16, 16),
      (72, 32, 4), (71, 36, 4), (69, 40, 8),
      (71, 48, 8),
    ]),
    bass: _n(72, const [
      (33, 0, 8), (40, 8, 8), (40, 16, 8), (35, 24, 8), //
      (36, 32, 8), (43, 40, 8), (35, 48, 8), (33, 56, 4), (35, 60, 4),
    ]),
    drums: _drumBars((b, o) => b < 3
        ? [
          (kind: 'kick', step: o, vel: 60),
          (kind: 'snare', step: o + 12, vel: 45),
          for (final s in const [0, 4, 8, 12]) (kind: 'hihat', step: o + s, vel: 38),
        ]
        : [
          // simple fill into the next section
          (kind: 'kick', step: o, vel: 64),
          (kind: 'hihat', step: o, vel: 38),
          for (final (s, v) in const [
            (4, 52), (6, 56), (8, 60), (10, 66), (12, 72), (13, 76), (14, 82), (15, 88),
          ])
            (kind: 'snare', step: o + s, vel: v),
        ]),
  ),
  _Part(
    id: 'outro',
    name: 'Outro',
    repeats: 1,
    chords: const ['Cmaj7', 'Am7', 'B7', 'Em'],
    guitarHits: const [
      (0, 8, 'Cmaj7'), (8, 8, 'Cmaj7'), (16, 8, 'Am7'), (24, 8, 'Am7'),
      (32, 8, 'B7'), (40, 8, 'B7'), (48, 16, 'Em'),
    ],
    guitarVel: 84,
    arpeggio: false,
    strokePattern: 'down',
    lead: _n(80, const [
      (71, 0, 4), (67, 4, 2), (69, 6, 2), (71, 8, 8), //
      (69, 16, 8), (67, 24, 8),
      (66, 32, 8), (69, 40, 8),
      (64, 48, 16),
    ]),
    bass: _n(72, const [(36, 0, 16), (33, 16, 16), (35, 32, 16), (28, 48, 16)]),
    drums: _drumBars((b, o) => b < 3
        ? [
          (kind: 'kick', step: o, vel: 55),
          for (final s in const [0, 4, 8, 12]) (kind: 'hihat', step: o + s, vel: 36),
        ]
        : [(kind: 'kick', step: o, vel: 68)]),
  ),
];

_Part _part(String id) => _parts.firstWhere((p) => p.id == id);

/// Song order: (section id, part, repeats). chorus2 = linked Chorus.
const List<(String, String)> _form = [
  ('intro', 'intro'),
  ('verse', 'verse'),
  ('chorus', 'chorus'),
  ('break', 'break'),
  ('chorus2', 'chorus'),
  ('outro', 'outro'),
];

PitchNote _pn(_N n) =>
    PitchNote(midi: n.midi, freq: midiToFreq(n.midi), step: n.step, dur: n.dur, velocity: n.vel);

_N _fromPn(PitchNote n) {
  final d = n.soundingSteps;
  // plain grid data only (also runs while building, outside a test body)
  if (n.offsetSteps != 0 || (d - d.roundToDouble()).abs() > 1e-9) {
    throw StateError('off-grid note ${n.midi} @ ${n.startSteps} len $d');
  }
  return (midi: n.midi, step: n.step, dur: d.round(), vel: n.velocity!);
}

/// The guitar notes before any guitar-panel tool: block chords, or for
/// Intro/Break the app's own arpeggiate (Up-Down, 1/8, gate 100 %).
List<_N> _guitarPlain(_Part p) {
  final block = [for (final n in _chordNotes(p.guitarHits, p.guitarVel)) _pn(n)];
  if (!p.arpeggio) return [for (final n in block) _fromPn(n)];
  final arp = arpeggiatePitchNotes(
    block,
    block.toSet(),
    const ArpSettings(style: ArpStyle.upDown, grid: QuantizeGrid.eighth, gate: 1.0),
    seed: 1,
    steps: _secSteps,
  );
  return [for (final n in arp.notes) _fromPn(n)];
}

typedef _GuitarReport = ({
  String tool,
  int notes,
  int unassignable,
  int assignLengthChanges,
  int extended,
  int kept,
  Map<String, int> reasons,
  String summary,
});

/// The guitar-panel tools, in the order the entry sheet tells the UI to use.
({List<PitchNote> notes, _GuitarReport report}) _guitarProcessed(_Part p) {
  var notes = [for (final n in _guitarPlain(p)) _pn(n)];
  final plain = List<PitchNote>.of(notes);
  if (p.strokePattern != null) {
    notes = applyStrokePattern(notes, const {}, strokePatternById(p.strokePattern!), bpm: _bpm).notes;
  }
  final beforeAssign = List<PitchNote>.of(notes);
  final assigned = assignStrings(notes, const {});
  notes = assigned.notes;
  var lengthChanges = 0;
  for (var i = 0; i < notes.length; i++) {
    if ((notes[i].endSteps - beforeAssign[i].endSteps).abs() > 1e-9) lengthChanges++;
  }
  if (p.strokePattern != null) {
    final r = applyStrokeSustain(notes, const {}, sectionSteps: _secSteps);
    return (
      notes: r.notes,
      report: (
        tool: '스트로크 패턴 ${strokePatternById(p.strokePattern!).label} → 줄 배정 → 줄별 울림 유지',
        notes: r.notes.length,
        unassignable: assigned.unassignable.length,
        assignLengthChanges: lengthChanges,
        extended: r.extended,
        kept: r.kept,
        reasons: {for (final e in r.reasons.entries) sustainReasonLabel(e.key): e.value},
        summary: r.summary(),
      ),
    );
  }
  final ring = applyRing(notes, const {}, rangeEnd: ringRangeEnd(notes, const {}, _secSteps)).notes;
  var extended = 0;
  for (var i = 0; i < ring.length; i++) {
    if (ring[i].endSteps > plain[i].endSteps + 1e-9) extended++;
  }
  return (
    notes: ring,
    report: (
      tool: '펼치기(위아래, 1/8, 게이트 100%) → 줄 배정 → 울림 아르페지오',
      notes: ring.length,
      unassignable: assigned.unassignable.length,
      assignLengthChanges: lengthChanges,
      extended: extended,
      kept: ring.length - extended,
      reasons: const {},
      summary: '연장 $extended · 그대로 ${ring.length - extended}',
    ),
  );
}

Section _section(_Part p, String id, {required bool processed, Map<String, _GuitarReport>? reports}) {
  final s = Section(id: id, name: p.name, autoName: false, bars: _bars, repeats: p.repeats);
  final guitar = processed ? _guitarProcessed(p) : null;
  if (guitar != null) reports?[p.id] = guitar.report;
  s.tracks['melody'] = TrackData(
    label: 'Guitar · 1',
    notes: guitar?.notes ?? [for (final n in _guitarPlain(p)) _pn(n)],
  );
  s.tracks['melodyDec'] = TrackData(label: 'Lead · 3', notes: [for (final n in p.lead) _pn(n)]);
  s.tracks['bass'] = TrackData(label: 'Bass · 2', notes: [for (final n in p.bass) _pn(n)]);
  s.tracks['drums'] = TrackData(
    label: 'Drums · 10',
    drums: [for (final d in p.drums) DrumNote(kind: d.kind, step: d.step, velocity: d.vel)],
    drumKinds: const ['kick', 'snare', 'hihat'],
  );
  return s;
}

typedef _Built = ({Song song, Map<String, _GuitarReport> reports});

/// The whole song. [processed] = guitar tools applied (the fixture); plain =
/// exactly the data of the section .mid files.
_Built _buildSong({required bool processed}) {
  final reports = <String, _GuitarReport>{};
  final byId = <String, Section>{};
  final sections = <Section>[];
  for (final (id, partId) in _form) {
    final p = _part(partId);
    if (id == 'chorus2') {
      final src = byId['chorus']!..linkId = 'link_chorus';
      sections.add(duplicateLinked(src, 'chorus2'));
      continue;
    }
    final s = _section(p, id, processed: processed, reports: reports);
    byId[id] = s;
    sections.add(s);
  }
  final song = Song(
    id: processed ? _songId : '${_songId}_plain',
    title: processed ? _title : '$_title (plain)',
    key: 'E',
    scale: 'minor',
    bpm: _bpm,
    bars: _bars,
    sections: sections,
    instruments: {'melody': _nylonSlot, 'melodyDec': 73, 'bass': 33, 'drums': kDefaultDrumKit},
    pan: const {'melody': -0.15, 'melodyDec': 0.15},
  );
  song.vol
    ..['melody'] = 0.7
    ..['melodyDec'] = 1.0
    ..['bass'] = 0.9
    ..['drums'] = 0.9;
  return (song: song, reports: reports);
}

// ── section .mid files (format 1, one named track per lane) ────────────
typedef _Lane = ({String name, int ch, int? program, List<(int, int, int, int)> notes});

List<int> _vlq(int n) {
  final b = [n & 0x7f];
  n >>= 7;
  while (n > 0) {
    b.insert(0, (n & 0x7f) | 0x80);
    n >>= 7;
  }
  return b;
}

List<int> _chunk(String id, List<int> body) => [
  ...ascii.encode(id),
  (body.length >> 24) & 255,
  (body.length >> 16) & 255,
  (body.length >> 8) & 255,
  body.length & 255,
  ...body,
];

List<int> _meta(int type, List<int> data) => [0xFF, type, ..._vlq(data.length), ...data];

/// [lanes] notes are (midi, on tick, off tick, velocity). Tempo 103 and 4/4
/// in the conductor track; offs before ons at equal ticks.
Uint8List _smf(String name, List<_Lane> lanes, int endTick) {
  final mpq = (60000000 / _bpm).round();
  final tracks = <List<int>>[
    [
      0, ..._meta(0x03, utf8.encode(name)),
      0, ..._meta(0x51, [(mpq >> 16) & 255, (mpq >> 8) & 255, mpq & 255]),
      0, ..._meta(0x58, [4, 2, 24, 8]),
      ..._vlq(endTick), ..._meta(0x2F, const []),
    ],
  ];
  for (final l in lanes) {
    final evs = <(int, int, List<int>)>[]; // tick, 0 = off / 1 = on, bytes
    for (final (m, on, off, v) in l.notes) {
      evs.add((on, 1, [0x90 | l.ch, m, v]));
      evs.add((off, 0, [0x80 | l.ch, m, 0]));
    }
    evs.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final body = <int>[0, ..._meta(0x03, utf8.encode(l.name))];
    if (l.program != null) body.addAll([0, 0xC0 | l.ch, l.program!]);
    var t = 0;
    for (final (tick, _, bytes) in evs) {
      body.addAll([..._vlq(tick - t), ...bytes]);
      t = tick;
    }
    body.addAll([..._vlq(math.max(0, endTick - t)), ..._meta(0x2F, const [])]);
    tracks.add(body);
  }
  return Uint8List.fromList([
    ..._chunk('MThd', [0, 1, 0, tracks.length, (_tpq >> 8) & 255, _tpq & 255]),
    for (final t in tracks) ..._chunk('MTrk', t),
  ]);
}

const int _tps = _tpq ~/ 4;

List<_Lane> _lanesOf({
  required List<_N> guitar,
  required List<_N> lead,
  required List<_N> bass,
  required List<_D> drums,
}) {
  List<(int, int, int, int)> p(List<_N> ns) => [
    for (final n in ns) (n.midi, n.step * _tps, (n.step + n.dur) * _tps, n.vel),
  ];
  return [
    (name: 'Guitar', ch: 0, program: 24, notes: p(guitar)),
    if (lead.isNotEmpty) (name: 'Lead', ch: 2, program: 73, notes: p(lead)),
    (name: 'Bass', ch: 1, program: 33, notes: p(bass)),
    (
      name: 'Drums',
      ch: 9,
      program: null,
      notes: [
        for (final d in drums) (_percMidi(d.kind), d.step * _tps, (d.step + 1) * _tps, d.vel),
      ],
    ),
  ];
}

int _percMidi(String kind) => const {'kick': 36, 'snare': 38, 'hihat': 42}[kind]!;

Uint8List _sectionMid(_Part p) => _smf(
  '$_title - ${p.name}',
  _lanesOf(guitar: _guitarPlain(p), lead: p.lead, bass: p.bass, drums: p.drums),
  _secSteps * _tps,
);

/// The 64-bar reference: the plain song flattened by the app's flattenSong.
Uint8List _fullMid(Song plain) {
  final flat = flattenSong(plain.sections);
  List<_N> ns(List<PitchNote> l) => [for (final n in l) _fromPn(n)];
  return _smf(
    '$_title - full 64 bars',
    _lanesOf(
      guitar: ns(flat.melody),
      lead: ns(flat.melodyDec),
      bass: ns(flat.bass),
      drums: [for (final d in flat.drums) (kind: d.kind, step: d.step, vel: d.velocity!)],
    ),
    flat.steps * _tps,
  );
}

/// The base lane each section .mid lands on when imported (pitched lanes
/// take melody, melodyDec, bass in order of their first note; ties by file
/// track order). Intro has no lead, so its bass lands on melodyDec.
Map<String, String> _expectedImportLanes(_Part p) => p.lead.isEmpty
    ? {'Guitar': 'melody', 'Bass': 'melodyDec', 'Drums': 'drums'}
    : {'Guitar': 'melody', 'Lead': 'melodyDec', 'Bass': 'bass', 'Drums': 'drums'};

List<(int, int, int, int)> _sortedNotes(Iterable<_N> ns) =>
    [for (final n in ns) (n.step, n.midi, n.dur, n.vel)]..sort((a, b) {
      for (final c in [a.$1.compareTo(b.$1), a.$2.compareTo(b.$2), a.$3.compareTo(b.$3)]) {
        if (c != 0) return c;
      }
      return a.$4.compareTo(b.$4);
    });

List<(int, String, int)> _sortedDrums(Iterable<_D> ds) =>
    [for (final d in ds) (d.step, d.kind, d.vel)]..sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });

/// Parse [bytes] with the app's importer and check the 4-bar passage.
Song _checkImport(_Part p, Uint8List bytes) {
  final ref = MidiReference.parse(bytes);
  expect(ref.constantTempo, isTrue);
  expect(ref.fourFour, isTrue);
  expect(ref.bpm.round(), _bpm);
  expect((ref.bpm - _bpm).abs(), lessThan(.001));
  expect(ref.bars, _bars);
  expect(ref.warnings, isEmpty, reason: p.name);
  final song = ref.passage(title: p.name, startBar: 1, lengthBars: _bars);
  expect(song.bpm, _bpm);
  final sec = song.sections.single;
  expect(sec.bars, _bars);
  expect(sec.extras, isEmpty);
  final lanes = _expectedImportLanes(p);
  final used = {for (final e in sec.tracks.entries) if (e.value.pitchNotes.isNotEmpty || e.value.drumNotes.isNotEmpty) e.key};
  expect(used, lanes.values.toSet(), reason: p.name);
  for (final e in lanes.entries) {
    final t = sec.tracks[e.value]!;
    expect(t.label, startsWith('${e.key} · '), reason: '${p.name} ${e.key}');
    if (e.key == 'Drums') {
      expect(
        _sortedDrums([for (final d in t.drumNotes) (kind: d.kind, step: d.step, vel: d.velocity!)]),
        _sortedDrums(p.drums),
      );
      for (final d in t.drumNotes) {
        expect(d.offsetSteps, 0);
      }
      continue;
    }
    final want = switch (e.key) {
      'Guitar' => _guitarPlain(p),
      'Lead' => p.lead,
      _ => p.bass,
    };
    for (final n in t.pitchNotes) {
      expect(n.offsetSteps, 0);
      expect(n.durationSteps, n.dur.toDouble());
    }
    expect(_sortedNotes([for (final n in t.pitchNotes) _fromPn(n)]), _sortedNotes(want), reason: '${p.name} ${e.key}');
    final program = {'Guitar': 24, 'Lead': 73, 'Bass': 33}[e.key];
    expect(song.instruments[e.value], program);
  }
  return song;
}

// ── checks shared by the always-run tests ──────────────────────────────
String _noteName(int m) => '${kNoteNames[m % 12]}${m ~/ 12 - 1}';

void _expectMonophonic(List<PitchNote> ns, String what) {
  final l = [...ns]..sort((a, b) => a.startSteps.compareTo(b.startSteps));
  for (var i = 0; i + 1 < l.length; i++) {
    expect(l[i].endSteps, lessThanOrEqualTo(l[i + 1].startSteps + 1e-9), reason: what);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('E2E song 103 fixture', () {
    final plain = _buildSong(processed: false).song;
    final built = _buildSong(processed: true);
    final song = built.song;

    test('form: 64 bars, five distinct 4-bar sections, linked chorus', () {
      expect([for (final s in song.sections) s.name], ['Intro', 'Verse', 'Chorus', 'Break', 'Chorus', 'Outro']);
      expect([for (final s in song.sections) s.repeats], [1, 4, 4, 2, 4, 1]);
      expect(song.sections.every((s) => s.bars == 4), isTrue);
      expect(song.sections.fold(0, (n, s) => n + s.bars * s.repeats), 64);
      final c1 = song.sections[2], c2 = song.sections[4];
      expect(identical(c1.tracks, c2.tracks), isTrue);
      expect(c1.linkId, isNotNull);
      expect(c2.linkId, c1.linkId);
      final flat = flattenSong(song.sections);
      expect(flat.steps, 64 * 16);
      expect(flat.steps / 4 * 60 / _bpm, closeTo(149.126, .001));
    });

    test('ranges, harmony shapes and drum kinds', () {
      for (final (c, (ms, frets)) in _shapes.entries.map((e) => (e.key, e.value))) {
        // the fret diagram spells exactly the shape (standard tuning)
        const open = [40, 45, 50, 55, 59, 64];
        final fromFrets = [
          for (var i = 0; i < 6; i++)
            if (frets[i] != 'x') open[i] + int.parse(frets[i]),
        ];
        expect(fromFrets, ms, reason: c);
      }
      for (final p in _parts) {
        for (final n in _guitarPlain(p)) {
          expect(n.midi, inInclusiveRange(kGuitarLowestMidi, 76));
        }
        for (final n in p.lead) {
          expect(n.midi, inInclusiveRange(64, 76), reason: '${p.name} lead ${_noteName(n.midi)}');
        }
        for (final n in p.bass) {
          expect(n.midi, inInclusiveRange(28, 45), reason: '${p.name} bass');
        }
        for (final n in [..._guitarPlain(p), ...p.lead, ...p.bass]) {
          expect(n.step, inInclusiveRange(0, _secSteps - 1));
          expect(n.step + n.dur, lessThanOrEqualTo(_secSteps));
          expect(n.vel, inInclusiveRange(1, 127));
        }
        for (final d in p.drums) {
          expect(['kick', 'snare', 'hihat'], contains(d.kind));
          expect(d.step, inInclusiveRange(0, _secSteps - 1));
        }
        _expectMonophonic([for (final n in p.lead) _pn(n)], '${p.name} lead');
        _expectMonophonic([for (final n in p.bass) _pn(n)], '${p.name} bass');
        // quieter drums in Intro / Break / Outro
        final maxVel = p.drums.map((d) => d.vel).reduce(math.max);
        if (['intro', 'outro'].contains(p.id)) expect(maxVel, lessThanOrEqualTo(70));
        if (p.id == 'break') {
          expect(p.drums.where((d) => d.step < 48).map((d) => d.vel).reduce(math.max), lessThanOrEqualTo(60));
        }
      }
      // the chorus motif is the verse motif's rhythm, moved up
      List<int> rhythm(_Part p) => [for (final n in p.lead.where((n) => n.step < 16)) n.dur];
      expect(rhythm(_part('chorus')), rhythm(_part('verse')));
    });

    test('Intro/Break guitar is the app arpeggio: 8 eighths per bar, one note at a time', () {
      for (final id in ['intro', 'break']) {
        final g = _guitarPlain(_part(id));
        expect(g.length, 32);
        expect([for (final n in g) n.step], [for (var s = 0; s < 64; s += 2) s]);
        expect(g.every((n) => n.dur == 2), isTrue);
      }
    });

    test('guitar tools applied (stroke, strings, sustain / ring)', () {
      for (final p in _parts) {
        final notes = song.sections.firstWhere((s) => s.id == p.id).tracks['melody']!.pitchNotes;
        final r = built.reports[p.id]!;
        debugPrint('[song-e2e] ${p.name}: ${r.tool}: ${r.summary} '
            'unassignable=${r.unassignable} assignLengthChanges=${r.assignLengthChanges}');
        expect(notes.length, _guitarPlain(p).length);
        expect(r.unassignable, 0, reason: p.name);
        for (final n in notes) {
          expect(n.guitarString, isNotNull, reason: p.name);
          expect(guitarPlayable(n.guitarString!, n.midi), isTrue);
          expect(n.endSteps, lessThanOrEqualTo(_secSteps + 1e-9));
          expect(n.articulation, isNull);
        }
        for (var s = 1; s <= kGuitarStrings; s++) {
          _expectMonophonic(notes.where((n) => n.guitarString == s).toList(), '${p.name} string $s');
        }
        if (p.strokePattern != null) {
          expect(notes.every((n) => n.stroke != null), isTrue, reason: p.name);
          expect(r.extended, greaterThan(0), reason: p.name);
          expect(r.extended + r.kept, notes.length);
        } else {
          expect(notes.every((n) => n.stroke == null), isTrue);
          expect(r.extended, greaterThan(0), reason: p.name);
        }
      }
      // pitches and start cells never move
      for (final p in _parts) {
        final notes = song.sections.firstWhere((s) => s.id == p.id).tracks['melody']!.pitchNotes;
        expect(_sortedNotes([for (final n in notes) (midi: n.midi, step: n.step, dur: 0, vel: 0)]),
            _sortedNotes([for (final n in _guitarPlain(p)) (midi: n.midi, step: n.step, dur: 0, vel: 0)]));
      }
    });

    test('songs survive a JSON round trip (links restored)', () {
      for (final s in [song, plain]) {
        final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
        final back = Song.fromJson(j);
        final relinked = relinkSections(back.sections);
        expect(identical(relinked[2].tracks, relinked[4].tracks), isTrue);
        expect(jsonEncode(Song.fromJson(j).toJson()), jsonEncode(s.toJson()));
      }
    });

    test('every section .mid parses with the app importer and gives its 4 bars', () {
      for (final p in _parts) {
        final song = _checkImport(p, _sectionMid(p));
        debugPrint('[song-e2e] ${p.name}.mid → ${song.sections.single.tracks.entries.where((e) => e.value.pitchNotes.isNotEmpty || e.value.drumNotes.isNotEmpty).map((e) => '${e.value.label}=>${e.key}').join(', ')}');
      }
      // the imported Verse equals the fixture's plain Verse lane for lane
      final imported = _checkImport(_part('verse'), _sectionMid(_part('verse'))).sections.single;
      final verse = plain.sections[1];
      for (final id in ['melody', 'melodyDec', 'bass']) {
        expect(_sortedNotes([for (final n in imported.tracks[id]!.pitchNotes) _fromPn(n)]),
            _sortedNotes([for (final n in verse.tracks[id]!.pitchNotes) _fromPn(n)]));
      }
    });

    test('64-bar reference .mid parses and each passage matches its section', () {
      final ref = MidiReference.parse(_fullMid(plain));
      expect(ref.bars, 64);
      expect(ref.constantTempo && ref.fourFour, isTrue);
      final flat = flattenSong(plain.sections);
      expect(ref.noteCount, flat.melody.length + flat.melodyDec.length + flat.bass.length + flat.drums.length);
      var bar = 1;
      for (final s in plain.sections) {
        final p = _part(s.id == 'chorus2' ? 'chorus' : s.id);
        for (var r = 0; r < s.repeats; r++) {
          final sec = ref.passage(title: p.name, startBar: bar, lengthBars: 4).sections.single;
          final g = sec.tracks.values.firstWhere((t) => t.label!.startsWith('Guitar'));
          expect(_sortedNotes([for (final n in g.pitchNotes) _fromPn(n)]), _sortedNotes(_guitarPlain(p)), reason: 'bar $bar');
          bar += 4;
        }
      }
      expect(bar, 65);
    });
  });

  final out = Platform.environment['HUMTRACK_E2E_OUT'];
  final skip = out == null || out.isEmpty ? 'set HUMTRACK_E2E_OUT to write the files' : false;
  test('write section MIDI files, 64-bar reference .mid and entry sheet', () async {
    final dir = await Directory(out!).create(recursive: true);
    final plain = _buildSong(processed: false).song;
    for (final (i, p) in _parts.indexed) {
      final bytes = _sectionMid(p);
      _checkImport(p, bytes);
      await File('${dir.path}/${i + 1}-${p.id}.mid').writeAsBytes(bytes, flush: true);
    }
    final full = _fullMid(plain);
    expect(MidiReference.parse(full).bars, 64);
    await File('${dir.path}/song-64bars.mid').writeAsBytes(full, flush: true);
    await File('${dir.path}/entry-sheet.md').writeAsString(_entrySheet(_buildSong(processed: true)), flush: true);
    debugPrint('[song-e2e] wrote section .mid files and entry-sheet.md to ${dir.path}');
  }, skip: skip);

  test(
    'write fixture JSON, real WAV mix / stems / MIDI renders and measurements',
    () async {
      await _writeRenders(Directory(out!));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 40)),
  );
}

// ── entry sheet ─────────────────────────────────────────────────────────
String _pos(int step) => '${step ~/ 16 + 1}.${(step % 16) ~/ 4 + 1}.${step % 4 + 1}';

String _entrySheet(_Built built) {
  final b = StringBuffer();
  b.writeln('# E2E Song 103 — 섹션별 입력표');
  b.writeln();
  b.writeln('`mobile/test/looptap/song_e2e_fixture_test.dart`가 만든 파일이다. 직접 고치지 말고 테스트를 다시 실행한다.');
  b.writeln();
  b.writeln('## 읽는 법');
  b.writeln('- **위치** `마디.박.16분` (모두 1부터). 예: `2.3.1` = 2마디 3박 정박, `1.2.3` = 1마디 2박의 "&"(8분 뒤).');
  b.writeln('  그리드의 칸 번호(0부터)로는 `(마디−1)×16 + (박−1)×4 + (16분−1)`.');
  b.writeln('- **음 이름**은 앱 표기와 같다(C4 = MIDI 60). **길이**는 16분음표 칸 수. **세기**는 MIDI 벨로시티(1–127).');
  b.writeln('- 곡: 4/4, **103 BPM**, E 단조(키 E, 스케일 minor). 섹션은 모두 **4마디**.');
  b.writeln('- 트랙 배치(Verse `.mid`를 가져오면 앱이 이렇게 놓는다): **Melody = 기타**, **Melody Fill = 선율(Lead)**, **Bass = 베이스**, **Drums = 드럼**.');
  b.writeln();
  b.writeln('## 곡 구성 (64마디)');
  b.writeln('| 순서 | 섹션 | 반복 | 마디 | 화음 (마디마다) |');
  b.writeln('|---|---|---|---|---|');
  var bar = 1;
  for (final (i, (id, partId)) in _form.indexed) {
    final p = _part(partId);
    final n = p.repeats * _bars;
    final link = id == 'chorus2' ? ' (Chorus 연결 복제)' : '';
    b.writeln('| ${i + 1} | ${p.name}$link | ×${p.repeats} | $bar–${bar + n - 1} | ${p.chords.join(' \\| ')} |');
    bar += n;
  }
  b.writeln();
  b.writeln('## 기타 코드 모양 (6번 줄 → 1번 줄, x = 안 침)');
  b.writeln('| 코드 | 프렛 | 음 (낮은 음부터) |');
  b.writeln('|---|---|---|');
  for (final e in _shapes.entries) {
    b.writeln('| ${e.key} | `${e.value.$2}` | ${e.value.$1.map(_noteName).join(' ')} |');
  }
  b.writeln();
  b.writeln('## 경로 B (권장): Verse `.mid` 가져오기 + UI 편집');
  b.writeln('1. 곡 목록 `MIDI +` → `2-verse.mid` 선택 → 구간 **1마디부터 4마디**, 모든 파트 선택 → 새 곡 만들기.');
  b.writeln('   기대 결과: 섹션 1개(4마디), 103 BPM, Melody = `Guitar · 1`(GM 24), Melody Fill = `Lead · 3`(GM 73 Flute), Bass = `Bass · 2`(GM 33), Drums = `Drums · 10`(kick/snare/hihat).');
  b.writeln('   가져온 곡은 키 C / chromatic이다. 필요하면 키를 E, 스케일 minor로 바꾼다(소리에는 영향 없음).');
  b.writeln('2. 섹션 이름을 `Verse`로 바꾸고 반복 ×4.');
  b.writeln('3. **기타 연주 도구(Verse)**: Melody(기타) 트랙에서 아무것도 선택하지 않은 상태(트랙 전체)로 `기타 연주` 패널 → 패턴 `↓ ↓↑ ↑↓↑` 선택 → `패턴 적용` → `줄 배정` → `줄별 울림 유지`. 패널 값은 기본값(↓ 28 ms/100 %, ↑ 18 ms/80 %, 감쇠 18 %).');
  b.writeln('4. 섹션 추가(복제 후 내용 지우기 또는 새 섹션) → 4마디로 맞춘 뒤 아래 표대로 **Intro, Chorus, Break, Outro**를 입력한다.');
  b.writeln('   - Intro / Break 기타: 마디마다 블록 코드(16칸 길이)를 넣고 모두 선택 → `펼치기(아르페지오)`: **위아래, 1/8, Gate 100 %, 옥타브 1, 원래 코드 남기기 끔** → 선택 해제 → `기타 연주` → `줄 배정` → `울림 아르페지오`.');
  b.writeln('     (아래 표의 기타 음은 펼치기 결과다. 직접 입력해도 같다.)');
  b.writeln('   - Chorus 기타: 표대로 8분 코드 입력 → `기타 연주` → 패턴 `↓↑` → `패턴 적용` → `줄 배정` → `줄별 울림 유지`.');
  b.writeln('   - Outro 기타: 표대로 입력 → 패턴 `↓` → `패턴 적용` → `줄 배정` → `줄별 울림 유지`.');
  b.writeln('5. 순서와 반복: Intro ×1 → Verse ×4 → Chorus ×4 → Break ×2 → Chorus **연결 복제**(Ctrl+Shift+D) ×4 → Outro ×1. 합계 64마디.');
  b.writeln('6. 악기: Melody → Guitar → **Nylon (FreePats)**(슬롯 1001). Melody Fill = Flute(73), Bass = Fingered Bass(33), Drums = Standard.');
  b.writeln('7. 믹스(기준 fixture 값): 볼륨 Melody 0.70, Melody Fill 1.00, Bass 0.90, Drums 0.90 · Pan Melody −0.15(왼쪽), Melody Fill +0.15(오른쪽). 나머지는 가운데.');
  b.writeln('8. Play Song으로 확인 → 저장.');
  b.writeln();
  b.writeln('기타 도구 결과(기준 fixture, 섹션 1회분):');
  b.writeln('| 섹션 | 도구 | 결과 |');
  b.writeln('|---|---|---|');
  for (final p in _parts) {
    final r = built.reports[p.id]!;
    b.writeln('| ${p.name} | ${r.tool} | ${r.summary} |');
  }
  b.writeln();
  for (final p in _parts) {
    b.writeln('---');
    b.writeln();
    b.writeln('## ${p.name} (${_parts.indexOf(p) + 1}-${p.id}.mid) — ×${p.repeats}');
    b.writeln('화음: ${p.chords.join(' | ')}');
    b.writeln();
    b.writeln('### 기타 (Melody 트랙)');
    if (p.arpeggio) {
      b.writeln('블록 코드(펼치기 전): ${[for (final (s, d, c) in p.guitarHits) '`${_pos(s)}` $c 길이 $d'].join(', ')}, 세기 ${p.guitarVel}.');
      b.writeln();
      b.writeln('펼치기 결과(위아래 1/8, 각 음 길이 2, 세기 ${p.guitarVel}):');
      b.writeln();
      b.writeln('| 마디 | 화음 | 1 | 1& | 2 | 2& | 3 | 3& | 4 | 4& |');
      b.writeln('|---|---|---|---|---|---|---|---|---|---|');
      final g = _guitarPlain(p);
      for (var m = 0; m < _bars; m++) {
        final row = g.where((n) => n.step ~/ 16 == m).toList()..sort((a, c) => a.step.compareTo(c.step));
        b.writeln('| ${m + 1} | ${p.chords[m]} | ${row.map((n) => _noteName(n.midi)).join(' | ')} |');
      }
    } else {
      b.writeln('코드 타격 (각 타격 = 그 코드 모양의 모든 음을 같은 위치·같은 길이로, 세기 ${p.guitarVel}):');
      b.writeln();
      b.writeln('| 위치 | 코드 | 길이 | 음 |');
      b.writeln('|---|---|---|---|');
      for (final (s, d, c) in p.guitarHits) {
        b.writeln('| ${_pos(s)} | $c | $d | ${_shapes[c]!.$1.map(_noteName).join(' ')} |');
      }
    }
    b.writeln();
    b.writeln('### 선율 (Melody Fill 트랙, Lead)');
    if (p.lead.isEmpty) {
      b.writeln('없음 (쉼).');
    } else {
      b.writeln('| 위치 | 음 | 길이 | 세기 |');
      b.writeln('|---|---|---|---|');
      for (final n in p.lead) {
        b.writeln('| ${_pos(n.step)} | ${_noteName(n.midi)} | ${n.dur} | ${n.vel} |');
      }
    }
    b.writeln();
    b.writeln('### 베이스 (Bass 트랙)');
    b.writeln('| 위치 | 음 | 길이 | 세기 |');
    b.writeln('|---|---|---|---|');
    for (final n in p.bass) {
      b.writeln('| ${_pos(n.step)} | ${_noteName(n.midi)} | ${n.dur} | ${n.vel} |');
    }
    b.writeln();
    b.writeln('### 드럼 (Drums 트랙, 길이 1칸)');
    b.writeln('16칸 격자(마디마다, `x` = 타격, 칸 1–16). 세기는 아래 목록.');
    b.writeln();
    b.writeln('| 마디 | 소리 | 격자 |');
    b.writeln('|---|---|---|');
    for (var m = 0; m < _bars; m++) {
      for (final k in ['hihat', 'snare', 'kick']) {
        final steps = {for (final d in p.drums) if (d.kind == k && d.step ~/ 16 == m) d.step % 16};
        if (steps.isEmpty) continue;
        final grid = [for (var s = 0; s < 16; s++) steps.contains(s) ? 'x' : '.'].join();
        b.writeln('| ${m + 1} | $k | `${grid.substring(0, 4)} ${grid.substring(4, 8)} ${grid.substring(8, 12)} ${grid.substring(12)}` |');
      }
    }
    b.writeln();
    final byKindVel = <String, Set<String>>{};
    for (final d in _sortedDrums(p.drums)) {
      (byKindVel[d.$2] ??= <String>{}).add('${_pos(d.$1)}=${d.$3}');
    }
    for (final e in byKindVel.entries) {
      b.writeln('- ${e.key} 세기: ${e.value.join(', ')}');
    }
    b.writeln();
  }
  return b.toString();
}

// ── renders and measurements ────────────────────────────────────────────
typedef _Pcm = ({Float32List left, Float32List right, int sampleRate});

_Pcm _readStereo16(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  expect(bd.getUint16(22, Endian.little), 2);
  expect(bd.getUint16(34, Endian.little), 16);
  final sr = bd.getUint32(24, Endian.little);
  var p = 12;
  while (String.fromCharCodes(bytes.sublist(p, p + 4)) != 'data') {
    p += 8 + bd.getUint32(p + 4, Endian.little);
  }
  final frames = bd.getUint32(p + 4, Endian.little) ~/ 4;
  p += 8;
  final l = Float32List(frames), r = Float32List(frames);
  double f(int v) => v < 0 ? v / 0x8000 : v / 0x7fff;
  for (var i = 0; i < frames; i++) {
    l[i] = f(bd.getInt16(p + i * 4, Endian.little));
    r[i] = f(bd.getInt16(p + i * 4 + 2, Endian.little));
  }
  return (left: l, right: r, sampleRate: sr);
}

({double peak, double rms}) _levels(_Pcm x) {
  var peak = 0.0, sum = 0.0;
  for (final ch in [x.left, x.right]) {
    for (final v in ch) {
      final a = v.abs();
      if (a > peak) peak = a;
      sum += v * v;
    }
  }
  return (peak: peak, rms: math.sqrt(sum / (2 * x.left.length)));
}

double _db(double v) => v <= 0 ? -999 : 20 * math.log(v) / math.ln10;
double _r(double v, [int d = 4]) => double.parse(v.toStringAsFixed(d));

Future<void> _writeRenders(Directory outDir) async {
  await outDir.create(recursive: true);
  final temp = Directory('${outDir.path}/temp/render-work');
  if (await temp.exists()) await temp.delete(recursive: true);
  await temp.create(recursive: true);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) {
    final path = utf8.decode(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
    final file = File(path);
    return SynchronousFuture(file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null);
  });
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => temp.path,
  );
  LoopStorage.rootOverride = temp;
  addTearDown(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    LoopStorage.rootOverride = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  // slot 1001 offline: install the bundled FreePats nylon (as the demo tests)
  final catalog = SoundfontCatalog.instance;
  catalog.debugSetDirectory(await Directory('${temp.path}/soundfonts').create(recursive: true));
  await catalog.warm();
  expect(catalog.bySlot(_nylonSlot)!.id, 'freepats_nylon');
  expect(await catalog.ensureDownloaded(_nylonSlot), isNotNull);
  expect(isGuitarProgram(_nylonSlot), isTrue);

  final built = _buildSong(processed: true);
  final s = built.song;
  final plan = ArticulationPlan.of(s); // as the editor passes it
  final vol = Map.of(s.vol);
  for (final e in s.mutes.entries) {
    if (e.value) vol[e.key] = 0.0;
  }
  final extras = <TrackRef>[];
  int melodyProgram() => s.instruments['melody'] ?? 0;

  await File('${outDir.path}/fixture.song.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()), flush: true);

  // ── WAV mix ──
  final sw = Stopwatch()..start();
  final wav = await exportWavSong(
    s.sections,
    s.bpm,
    s.swing,
    vol,
    s.title,
    melodyProgram: melodyProgram(),
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: extras,
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: plan,
  );
  final mixSec = sw.elapsedMilliseconds / 1000;
  expect(wav.skippedVocals, 0);
  final mixBytes = await wav.file.readAsBytes();
  await File('${outDir.path}/fixture.mix.wav').writeAsBytes(mixBytes, flush: true);
  final mix = _readStereo16(mixBytes);
  final mixLv = _levels(mix);
  final frames = mix.left.length;
  final musicSec = 64 * _barSec;
  final mpq = (60000000 / _bpm).round();
  final midiSec = 64 * 4 * mpq / 1e6; // what the SMF tempo actually encodes
  final expectedFrames = ((midiSec + 1.2) * 44100).ceil();
  expect(mix.sampleRate, 44100);
  expect((frames / 44100 - (musicSec + 1.2)).abs(), lessThan(.005));
  expect(mixLv.peak, lessThanOrEqualTo(_headroom + _lsb + 1e-9));

  // ── stems ──
  sw.reset();
  final stems = await exportStems(
    s.sections,
    s.bpm,
    s.swing,
    vol,
    s.title,
    melodyProgram: melodyProgram(),
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: extras,
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: plan,
  );
  final stemSec = sw.elapsedMilliseconds / 1000;
  final sumL = Float64List(frames), sumR = Float64List(frames);
  final stemInfo = <String, Object>{};
  for (final f in stems) {
    final label = f.path.split(RegExp(r'[\\/]')).last.replaceFirst('${s.title} - ', '').replaceFirst('.wav', '');
    final bytes = await f.readAsBytes();
    await File('${outDir.path}/fixture.stem.$label.wav').writeAsBytes(bytes, flush: true);
    final pcm = _readStereo16(bytes);
    final lv = _levels(pcm);
    for (var i = 0; i < math.min(frames, pcm.left.length); i++) {
      sumL[i] += pcm.left[i];
      sumR[i] += pcm.right[i];
    }
    final attenuated = lv.peak >= _headroom - _lsb;
    stemInfo[label] = {
      'frames': pcm.left.length,
      'seconds': _r(pcm.left.length / pcm.sampleRate),
      'peak': _r(lv.peak),
      'peak_dbfs': _r(_db(lv.peak), 2),
      'rms': _r(lv.rms),
      'rms_dbfs': _r(_db(lv.rms), 2),
      'attenuated_by_stem_limiter': attenuated,
      'note': attenuated
          ? 'peak sits at the 0.94 ceiling: exportStems pulled this stem down (gain unknown)'
          : 'peak below 0.94: no stem gain applied (stems keep their raw level)',
    };
    expect(lv.peak, lessThanOrEqualTo(_headroom + _lsb + 1e-9));
  }
  // mix ≈ g × Σ stems (holds when no stem was attenuated)
  var dot = 0.0, den = 0.0, sumPeak = 0.0;
  for (var i = 0; i < frames; i++) {
    dot += mix.left[i] * sumL[i] + mix.right[i] * sumR[i];
    den += sumL[i] * sumL[i] + sumR[i] * sumR[i];
    sumPeak = math.max(sumPeak, math.max(sumL[i].abs(), sumR[i].abs()));
  }
  final g = den == 0 ? 0.0 : dot / den;
  var res = 0.0;
  for (var i = 0; i < frames; i++) {
    final a = mix.left[i] - g * sumL[i], b = mix.right[i] - g * sumR[i];
    res += a * a + b * b;
  }
  final resRms = math.sqrt(res / (2 * frames));

  // ── MIDI export ──
  final mid = await exportMidiSong(
    s.sections,
    s.bpm,
    s.title,
    melodyProgram: melodyProgram(),
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: extras,
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: plan,
  );
  final midBytes = await mid.readAsBytes();
  await File('${outDir.path}/fixture.export.mid').writeAsBytes(midBytes, flush: true);
  final midRef = MidiReference.parse(midBytes);
  final flat = flattenSong(s.sections, variationSeed: s.effectiveVariationSeed, groove: s.grooveContext);
  final flatNotes = flat.melody.length + flat.melodyDec.length + flat.bass.length + flat.drums.length;
  expect(midRef.noteCount, flatNotes);
  expect(midRef.bpm.round(), _bpm);

  // ── section boundaries from flattenSong ──
  final bounds = <Map<String, Object>>[];
  var expectedBar = 0;
  for (var k = 0; k <= s.sections.length; k++) {
    final steps = k == 0 ? 0 : flattenSong(s.sections.sublist(0, k)).steps;
    final sec = steps / 4 * 60 / _bpm;
    final exp = expectedBar * _barSec;
    expect(steps, expectedBar * 16);
    bounds.add({
      'boundary': k == 0 ? 'start' : 'end of $k. ${s.sections[k - 1].name} (×${s.sections[k - 1].repeats})',
      'bar': expectedBar,
      'step': steps,
      'seconds': _r(sec),
      'expected_seconds': _r(exp),
      'diff_ms': _r((sec - exp) * 1000, 6),
    });
    if (k < s.sections.length) expectedBar += s.sections[k].bars * s.sections[k].repeats;
  }

  // ── note counts ──
  final counts = <String, Object>{};
  for (final sec in s.sections) {
    final t = sec.tracks;
    counts['${sec.id} (${sec.name} ×${sec.repeats})'] = {
      'per_pass': {
        'guitar': t['melody']!.pitchNotes.length,
        'lead': t['melodyDec']!.pitchNotes.length,
        'bass': t['bass']!.pitchNotes.length,
        'drums': t['drums']!.drumNotes.length,
      },
      'in_song': {
        'guitar': t['melody']!.pitchNotes.length * sec.repeats,
        'lead': t['melodyDec']!.pitchNotes.length * sec.repeats,
        'bass': t['bass']!.pitchNotes.length * sec.repeats,
        'drums': t['drums']!.drumNotes.length * sec.repeats,
      },
    };
  }
  counts['total (flattenSong)'] = {
    'guitar': flat.melody.length,
    'lead': flat.melodyDec.length,
    'bass': flat.bass.length,
    'drums': flat.drums.length,
    'all': flatNotes,
  };

  final measurements = <String, Object>{
    'song': {'id': s.id, 'title': s.title, 'bpm': s.bpm, 'bars': 64, 'key': '${s.key} ${s.scale}'},
    'render_paths': {
      'mix': 'exportWavSong (vol = song.vol with mutes folded to 0, pan, ArticulationPlan.of(song), variationSeed = effectiveVariationSeed)',
      'stems': 'exportStems (same arguments)',
      'midi': 'exportMidiSong (same arguments, includeAllNotes false)',
      'guitar_sf2': 'catalog slot 1001 freepats_nylon, installed offline from the bundled asset',
      'render_seconds': {'mix': mixSec, 'stems': stemSec},
    },
    'duration': {
      'frames': frames,
      'seconds': _r(frames / 44100, 6),
      'expected_seconds_exact_tempo': _r(musicSec + 1.2, 6),
      'expected_frames_from_smf_tempo': expectedFrames,
      'diff_ms_vs_exact': _r((frames / 44100 - musicSec - 1.2) * 1000, 3),
      'explanation':
          'Length = MIDI length + 1.2 s tail, rounded up to whole frames. The SMF tempo is an integer '
          'microseconds per quarter ($mpq µs = round(60e6/103)), so 256 quarters last ${_r(midiSec, 6)} s '
          'instead of ${_r(musicSec, 6)} s (${_r((midiSec - musicSec) * 1000, 3)} ms).',
    },
    'mix': {
      'peak': _r(mixLv.peak, 6),
      'peak_dbfs': _r(_db(mixLv.peak), 3),
      'rms': _r(mixLv.rms, 6),
      'rms_dbfs': _r(_db(mixLv.rms), 2),
      'ceiling': _headroom,
      'peak_within_ceiling_plus_1_lsb': mixLv.peak <= _headroom + _lsb + 1e-9,
    },
    'stems': stemInfo,
    'stems_vs_mix': {
      'sum_of_stems_peak': _r(sumPeak, 6),
      'fitted_mix_gain_over_stem_sum': _r(g, 6),
      'fitted_gain_db': _r(_db(g), 3),
      'expected_gain_if_no_stem_attenuated': _r(sumPeak == 0 ? 0 : _headroom / sumPeak, 6),
      'residual_rms': _r(resRms, 8),
      'residual_rms_dbfs': _r(_db(resRms), 2),
      'note': 'mix = normalize(Σ raw lanes); stems = raw lanes (pulled down only above 0.94). A small residual means the stems sum to the mix up to one gain.',
    },
    'section_boundaries': bounds,
    'note_counts': counts,
    'guitar_tools': {
      for (final e in built.reports.entries)
        e.key: {
          'tool': e.value.tool,
          'notes': e.value.notes,
          'unassignable': e.value.unassignable,
          'length_changes_from_assign_strings': e.value.assignLengthChanges,
          'extended': e.value.extended,
          'kept': e.value.kept,
          'kept_reasons': e.value.reasons,
          'summary': e.value.summary,
        },
    },
    'export_midi': {
      'bytes': midBytes.length,
      'ppq': midRef.ppq,
      'bpm_read_back': midRef.bpm,
      'notes': midRef.noteCount,
      'lanes': [for (final l in midRef.lanes) '${l.name} (${l.notes.length})'],
      'warnings': midRef.warnings,
    },
  };
  await File('${outDir.path}/reference-measurements.json')
      .writeAsString(const JsonEncoder.withIndent('  ').convert(measurements), flush: true);
  await File('${outDir.path}/README.md').writeAsString(_readme(built, measurements), flush: true);
  debugPrint('[song-e2e] ${jsonEncode(measurements['duration'])}');
  debugPrint('[song-e2e] mix ${jsonEncode(measurements['mix'])}');
  debugPrint('[song-e2e] stems ${jsonEncode(stemInfo)}');
  debugPrint('[song-e2e] stems_vs_mix ${jsonEncode(measurements['stems_vs_mix'])}');
}

String _readme(_Built built, Map<String, Object> m) {
  final d = m['duration'] as Map;
  final mix = m['mix'] as Map;
  final svm = m['stems_vs_mix'] as Map;
  final stems = m['stems'] as Map;
  final b = StringBuffer();
  b.writeln('# E2E Song 103 — 자작 연주곡 실증 데이터 (2026-10-23)');
  b.writeln();
  b.writeln('계획: `plan.md` 1단계. 생성기: `mobile/test/looptap/song_e2e_fixture_test.dart` (앱 코드 변경 없음).');
  b.writeln();
  b.writeln('## 무엇을 작곡했나 (원본, 이 실증용으로 새로 씀)');
  b.writeln('- 4/4, **103 BPM**, **E 단조**, 나일론 기타 중심의 연주곡. 64마디 = 149.126초 (+ 내보내기 꼬리 1.2초).');
  b.writeln('- 구성 (4마디 섹션 5종 + 반복):');
  b.writeln();
  b.writeln('| 섹션 | 반복 | 화음 (마디마다) | 기타 | 드럼 |');
  b.writeln('|---|---|---|---|---|');
  const drumsText = {
    'intro': '하이햇 4분 + 킥, 작게',
    'verse': '킥·스네어 2/4박·하이햇 8분',
    'chorus': '조금 더 촘촘한 킥, 4마디째 스네어 픽업',
    'break': '작게, 4마디째 스네어 필',
    'outro': '작게, 마지막 마디 킥 한 번',
  };
  for (final (id, partId) in _form) {
    final p = _part(partId);
    final guitar = p.arpeggio ? '아르페지오(위아래 8분) + 울림' : '코드 스트로크 `${strokePatternById(p.strokePattern!).label}` + 줄별 울림 유지';
    b.writeln('| ${p.name}${id == 'chorus2' ? ' (연결 복제)' : ''} | ×${p.repeats} | ${p.chords.join(' – ')} | $guitar | ${drumsText[p.id]} |');
  }
  b.writeln();
  b.writeln('- 선율(Lead, Flute 73): Verse 동기 "B4 – G4 A4 – B4"(4분·8분·8분·점4분)를 Chorus에서 같은 리듬으로 E5에서 다시 부른다. 음역 E4–E5(부르기 쉬운 범위). Intro는 쉼.');
  b.writeln('- 베이스(GM 33): 코드 근음 중심, Chorus 2마디는 G/B 전위, 경과음(D#2 → E, A → B 등).');
  b.writeln('- 기타 코드 모양은 실제 오픈 포지션(Em 022000, C x32010, G 320003, D xx0232, Cmaj7 x32000, Am7 x02010, B7 x21202).');
  b.writeln();
  b.writeln('## 파일');
  b.writeln('| 파일 | 내용 |');
  b.writeln('|---|---|');
  b.writeln('| `1-intro.mid` … `5-outro.mid` | 섹션별 4마디 MIDI (format 1, 트랙 이름 Guitar/Lead/Bass/Drums, GM 24/73/33/ch10, 103 BPM, 4/4). 기타는 **도구 적용 전** 데이터(코드 타격, Intro/Break는 펼치기 결과). 모두 앱의 `midi_import.dart`로 파싱 + 1–4마디 구간 변환을 테스트에서 확인. |');
  b.writeln('| `song-64bars.mid` | 같은 데이터의 64마디 전체 참고본 (`flattenSong` 결과). 앱 가져오기는 한 번에 최대 8마디 구간만 받는다. |');
  b.writeln('| `entry-sheet.md` | 섹션·트랙별 입력표(마디.박.16분, 음 이름, 길이, 세기)와 경로 B UI 순서 |');
  b.writeln('| `fixture.song.json` | 기준 Song JSON (id `$_songId`, 제목 "$_title"). 사용자 저장소에는 쓰지 않았다. 기타 도구 적용 후 데이터. |');
  b.writeln('| `fixture.mix.wav` | 실제 `exportWavSong` 믹스 |');
  b.writeln('| `fixture.stem.*.wav` | 실제 `exportStems` 스템 |');
  b.writeln('| `fixture.export.mid` | 실제 `exportMidiSong` 결과 (슬롯 1001 → GM 24) |');
  b.writeln('| `reference-measurements.json` | 길이·피크·RMS·스템·섹션 경계·음 수·기타 도구 결과 |');
  b.writeln();
  b.writeln('## 기준 측정값 (요약)');
  b.writeln('- 길이: **${d['seconds']} s** (${d['frames']} 프레임). 정확한 템포 기준 기대값 ${d['expected_seconds_exact_tempo']} s, 차이 ${d['diff_ms_vs_exact']} ms.');
  b.writeln('  ${d['explanation']}');
  b.writeln('- 믹스 피크 **${mix['peak']}** (${mix['peak_dbfs']} dBFS, 상한 0.94 + 1 LSB 이내: ${mix['peak_within_ceiling_plus_1_lsb']}), RMS ${mix['rms']} (${mix['rms_dbfs']} dBFS).');
  b.writeln('- 스템:');
  for (final e in stems.entries) {
    final v = e.value as Map;
    b.writeln('  - `${e.key}`: 피크 ${v['peak']} (${v['peak_dbfs']} dBFS), RMS ${v['rms_dbfs']} dBFS, 스템 리미터 감쇠: ${v['attenuated_by_stem_limiter']}');
  }
  final stemFrames = {for (final e in stems.entries) e.key: (e.value as Map)['frames'] as int};
  if (stemFrames.values.toSet().length > 1 || stemFrames.values.any((f) => f != d['frames'])) {
    b.writeln('  - 관찰: 스템 길이가 서로 다르다 (프레임 ${jsonEncode(stemFrames)}, 믹스 ${d['frames']}). '
        '각 렌더 작업 길이 = 그 MIDI 길이(MeltySynth 계산) + 1.2 s이고, 이벤트가 촘촘한 레인은 시간 계산 반올림이 쌓여 몇 프레임 짧아질 수 있다. '
        '음악 내용과는 무관한 꼬리 끝 차이다.');
  }
  b.writeln('- 스템 합 ×${svm['fitted_mix_gain_over_stem_sum']} (${svm['fitted_gain_db']} dB) ≈ 믹스, 잔차 RMS ${svm['residual_rms_dbfs']} dBFS. 감쇠된 스템이 없으면 기대 게인 = 0.94 / 스템합 피크 = ${svm['expected_gain_if_no_stem_attenuated']}.');
  b.writeln('- 섹션 경계(`flattenSong`): 0, 4, 20, 36, 44, 60, 64마디 = 마디 × ${_barSec.toStringAsFixed(4)} s. 자세한 값은 JSON.');
  b.writeln('- 기타 도구 (섹션 1회분):');
  for (final p in _parts) {
    final r = built.reports[p.id]!;
    b.writeln('  - ${p.name}: ${r.tool} → ${r.summary} (줄 배정 불가 ${r.unassignable}, 줄 배정으로 길이 바뀐 음 ${r.assignLengthChanges})');
  }
  b.writeln();
  b.writeln('## 데이터만으로 된 것 / 실제 UI에서 해야 하는 것');
  b.writeln('- **데이터만 (UI 완료 아님):** 위 fixture JSON과 렌더는 테스트 안에서 앱의 실제 모델·함수·내보내기 함수로 만든 **비교 기준**이다. 앱에는 곡 JSON을 가져오는 기능이 없어 이 곡을 UI로 열 수 없다.');
  b.writeln('- **실제 UI (Codex):** `2-verse.mid`를 `MIDI +`로 가져와 새 곡을 만들고, 나머지 섹션은 `entry-sheet.md`대로 입력, 기타 연주 도구 적용, 섹션 순서·반복·연결 복제, 악기(Nylon FreePats)·믹스 설정, Play Song, 저장 → 재시작 → 다시 열기, WAV 믹스·스템 내보내기(Pro일 때).');
  b.writeln('- 가져온 곡은 키 C / chromatic, 트랙 볼륨 1.0으로 시작한다(가져오기 규칙). fixture는 E minor, 볼륨 Melody 0.70 / Melody Fill 1.00 / Bass 0.90 / Drums 0.90, Pan −0.15/+0.15. 키·스케일은 렌더에 영향 없음. 볼륨·Pan을 fixture와 같게 맞추면 레벨 비교가 의미 있다.');
  b.writeln('- UI로 손으로 넣은 음은 세기가 비어 있을 수 있다(기본 100). fixture는 모든 음에 세기를 넣었으므로, 세기를 표대로 맞추지 않으면 RMS·피크 분포가 달라진다(길이·경계는 같다).');
  b.writeln('- 다른 섹션 `.mid`도 가져올 수는 있지만 앱은 **새 곡**을 만든다. Intro `.mid`는 선율이 없어서 Bass 파트가 Melody Fill 레인에 놓인다(가져오기 규칙: 첫 음 순서대로 melody → melodyDec → bass).');
  b.writeln();
  b.writeln('## 다시 만들기');
  b.writeln('```');
  b.writeln('cd C:/src/humming-v2/mobile && TMP=C:/src/humming-v2/artifacts/song-e2e-20261023/temp TEMP=C:/src/humming-v2/artifacts/song-e2e-20261023/temp HUMTRACK_E2E_OUT=C:/src/humming-v2/artifacts/song-e2e-20261023 /c/src/flutter/bin/flutter test --no-pub test/looptap/song_e2e_fixture_test.dart');
  b.writeln('```');
  b.writeln('`HUMTRACK_E2E_OUT`이 없으면 같은 테스트가 곡을 만들고 검사만 한다(파일 쓰기 없음). 렌더 작업 폴더는 `temp/render-work`(끝나면 삭제).');
  b.writeln();
  b.writeln('## 한계');
  b.writeln('- 사람 보컬·허밍 없음. 허밍 변환은 이번 범위가 아니다.');
  b.writeln('- **청취 검증 안 함.** 음악성(소리가 좋은지)은 사용자가 들어 봐야 한다. 여기 숫자는 길이·레벨·이벤트 검증뿐이다.');
  b.writeln('- WAV는 MeltySynth 오프라인 렌더(앱 내보내기와 같은 경로)다. 실시간 재생과 최종 레벨 경로는 다르다.');
  b.writeln('- Break의 드럼 필은 4마디 섹션 안에 있으므로 Break ×2의 두 번 모두(42마디·44마디째) 나온다.');
  return b.toString();
}
