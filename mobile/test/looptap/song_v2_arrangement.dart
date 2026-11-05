// HumTrack song v2 — an ORIGINAL 64-bar acoustic-pop / melodic hip-hop
// instrumental (artifacts/song-arrangement-v2-20261023/design.md).
//
// 103 BPM, E minor, 4/4. Ten sections, every one played once:
//   Intro 4 · Verse1 8 · Lift 4 · Chorus1 8 · Post 4 · Verse2 8 · Bridge 8 ·
//   FinalChorusA 8 · FinalChorusB 8 · Outro 4 = 64 bars.
// Lanes (the layout the app's MIDI importer gives a guitar-first .mid):
//   melody          = Guitar (catalog slot 1001, FreePats nylon; GM 24 in .mid)
//   melodyDec       = Lead   (GM 4 Electric Piano 1)
//   bass            = Bass   (GM 33)
//   drums           = Drums  (GM standard kit, ch10)
//   melody_xcounter = Counter (one added "melody" instance, GM 48 strings;
//                     notes only in the two final choruses)
//
// The music is written as text (see [line] and [drumBars]) so every bar can be
// read and checked; the guitar goes through the app's own tools
// (arpeggiatePitchNotes, applyStrokePattern / applyGuitarStroke,
// assignStrings, applyRing, applyStrokeSustain). The companion test is
// song_v2_arrangement_test.dart.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/arpeggiate.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/guitar_sustain.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/percussion.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart' show QuantizeGrid;
import 'package:humming/looptap/music/theory.dart';

const int v2Bpm = 103;
const int v2NylonSlot = 1001;
const int v2LeadProgram = 4; // GM Electric Piano 1
const int v2FluteProgram = 73; // v1's lead, for the comparison render
const int v2BassProgram = 33;
const int v2CounterProgram = 48; // GM String Ensemble 1
const String v2CounterId = 'melody_xcounter';
const String v2SongId = 'humtrack_song_v2_103';
const String v2Title = 'HumTrack Song v2';
const int v2Tpq = 96; // section .mid files: 24 ticks per 16th
const int v2Tps = v2Tpq ~/ 4;
const double v2BarSec = 4 * 60 / v2Bpm;

/// Mix: song.vol / song.pan (what the editor's export passes). Tuned from
/// the per-stem / per-section RMS numbers (see README "믹스").
const Map<String, double> v2Vol = {
  'melody': 0.35,
  'melodyDec': 1.0,
  'bass': 0.54,
  'drums': 0.53,
  v2CounterId: 0.58,
};
const Map<String, double> v2Pan = {
  'melody': -0.22,
  'melodyDec': 0.12,
  v2CounterId: 0.32,
};

// ── notation ────────────────────────────────────────────────────────────
typedef V2Note = ({int midi, int step, int dur, int vel});

/// A drum hit; [tick] is a deliberate late offset in 1/24 of a 16th (0 = on
/// the grid), stored in the song as `offsetSteps = tick / 24`.
typedef V2Hit = ({String kind, int step, int vel, int tick});

int noteMidi(String name) {
  final m = RegExp(r'^([A-G])([#b]?)(\d)$').firstMatch(name);
  if (m == null) throw ArgumentError.value(name, 'name');
  const base = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
  final acc = m[2] == '#' ? 1 : (m[2] == 'b' ? -1 : 0);
  return (int.parse(m[3]!) + 1) * 12 + base[m[1]]! + acc;
}

String noteName(int m) => '${kNoteNames[m % 12]}${m ~/ 12 - 1}';

/// A monophonic line: bars separated by `|`, tokens `E5/6` (pitch / length in
/// 16ths) or `r/4` (rest); a trailing `>` accents (+10), `<` softens (−12).
/// Every bar must add up to exactly 16. Velocity = [vel] + a small metric
/// shape (bar downbeat +4, beat 0, offbeat 8th −6, 16th −10).
List<V2Note> line(String src, int vel, {int startBar = 0}) {
  final out = <V2Note>[];
  final bars = src.split('|');
  for (var b = 0; b < bars.length; b++) {
    var pos = 0;
    for (final tok in bars[b].trim().split(RegExp(r'\s+'))) {
      if (tok.isEmpty) continue;
      final m = RegExp(r'^(r|[A-G][#b]?\d)/(\d+)([<>]?)$').firstMatch(tok);
      if (m == null) throw FormatException('bad token "$tok" in "$src"');
      final d = int.parse(m[2]!);
      if (m[1] != 'r') {
        var v = vel + (pos == 0 ? 4 : (pos % 4 == 0 ? 0 : (pos % 2 == 0 ? -6 : -10)));
        if (m[3] == '>') v += 10;
        if (m[3] == '<') v -= 12;
        out.add((midi: noteMidi(m[1]!), step: (startBar + b) * 16 + pos, dur: d, vel: v.clamp(1, 127)));
      }
      pos += d;
    }
    if (pos != 16) throw FormatException('bar ${b + 1} adds up to $pos in "$src"');
  }
  return out;
}

const Map<String, int> _velOf = {'g': 30, 'q': 42, 'l': 54, 'm': 68, 'h': 82, 'x': 96, 'X': 110};

/// Drum bars as 16-cell grids per kind (`.` = none, g q l m h x X = velocity
/// 30 42 54 68 82 96 110). [late]: kind → ticks (1/24 of a 16th) added to
/// that kind's backbeat hits (beats 2 and 4, velocity ≥ 68) — a small
/// laid-back snare/clap; ghost notes stay on the grid.
List<V2Hit> drumBars(List<Map<String, String>> bars, {Map<String, int> late = const {}}) {
  final out = <V2Hit>[];
  for (var b = 0; b < bars.length; b++) {
    for (final e in bars[b].entries) {
      final g = e.value;
      if (g.length != 16) throw FormatException('grid "${e.key}" bar ${b + 1}: "$g"');
      for (var s = 0; s < 16; s++) {
        if (g[s] == '.') continue;
        final v = _velOf[g[s]] ?? (throw FormatException('cell "${g[s]}" in "$g"'));
        final backbeat = (s == 4 || s == 12) && v >= 68;
        out.add((kind: e.key, step: b * 16 + s, vel: v, tick: backbeat ? (late[e.key] ?? 0) : 0));
      }
    }
  }
  out.sort((a, b) => a.step != b.step ? a.step.compareTo(b.step) : a.kind.compareTo(b.kind));
  return out;
}

// ── guitar ──────────────────────────────────────────────────────────────
/// Open-position shapes (MIDI, low string first) and fret diagrams (6th
/// string → 1st, x = not played).
const Map<String, (List<int>, String)> v2Shapes = {
  'Em': ([40, 47, 52, 55, 59, 64], '022000'),
  'Em(add9)': ([40, 47, 52, 55, 59, 66], '022002'),
  'C': ([48, 52, 55, 60, 64], 'x32010'),
  'Cmaj7': ([48, 52, 55, 59, 64], 'x32000'),
  'G': ([43, 47, 50, 55, 59, 67], '320003'),
  'G/B': ([47, 50, 55, 62, 67], 'x20033'),
  'D': ([50, 57, 62, 66], 'xx0232'),
  'Dsus4': ([50, 57, 62, 67], 'xx0233'),
  'D/F#': ([42, 50, 57, 62, 66], '2x0232'),
  'Am': ([45, 52, 57, 60, 64], 'x02210'),
  'Am7': ([45, 52, 55, 60, 64], 'x02010'),
  'Bm7': ([47, 54, 57, 62, 66], 'x24232'),
  'B7': ([47, 51, 57, 59, 66], 'x21202'),
  'B7sus4': ([47, 52, 57, 59, 64], 'x22200'),
  'F#m7b5': ([42, 52, 57, 60], '2x221x'),
};

/// One chord hit: start step, length, chord, velocity.
typedef GHit = (int, int, String, int);

/// How a block of hits is played. [arp] = the app's arpeggiate (1/8, gate
/// 100 %) then 줄 배정 + 울림 아르페지오; else a stroke: a gt-001 preset id
/// ('down', 'downUp', 'folk') or 'beat' (↓ on hits that start on a beat,
/// ↑ on the others — applyGuitarStroke on the two selections), then 줄 배정 +
/// 줄별 울림 유지.
class GBlock {
  const GBlock(this.hits, {this.arp, this.stroke, this.down = const StrokeSpec.down(), this.up = const StrokeSpec.up()})
      : assert((arp == null) != (stroke == null));
  final List<GHit> hits;
  final ArpStyle? arp;
  final String? stroke;
  final StrokeSpec down, up;
  int get start => hits.map((h) => h.$1).reduce(math.min);
  int get end => hits.map((h) => h.$1 + h.$2).reduce(math.max);
  String get label => arp != null
      ? '펼치기(${arp!.labelKo}, 1/8, 게이트 100%) → 줄 배정 → 울림 아르페지오'
      : stroke == 'beat'
          ? '스트로크(정박 ↓ / 엇박 ↑, ↓ ${down.spreadMs.round()} ms ${(down.accent * 100).round()}%) → 줄 배정 → 줄별 울림 유지'
          : '스트로크 패턴 ${strokePatternById(stroke!).label} (↓ ${down.spreadMs.round()} ms ${(down.accent * 100).round()}%) → 줄 배정 → 줄별 울림 유지';
}

/// Hits from a per-bar rhythm: [rhythm] = (start in bar, length, velocity
/// offset); [chords] one per bar.
List<GHit> strum(List<String> chords, List<(int, int, int)> rhythm, int vel, {int startBar = 0}) => [
      for (var b = 0; b < chords.length; b++)
        for (final (s, d, dv) in rhythm) ((startBar + b) * 16 + s, d, chords[b], vel + dv),
    ];

// ── parts ───────────────────────────────────────────────────────────────
class V2Part {
  V2Part({
    required this.id,
    required this.name,
    required this.bars,
    required this.chords,
    required this.guitar,
    required this.lead,
    required this.bass,
    required this.drums,
    this.counter = const [],
    required this.desc,
  });
  final String id, name;
  final int bars;

  /// Chord chart, one entry per bar ("Dsus4→D" …).
  final List<String> chords;
  final List<GBlock> guitar;
  final List<V2Note> lead, bass, counter;
  final List<V2Hit> drums;

  /// Korean arrangement notes: lead / guitar / bass / drums / change.
  final Map<String, String> desc;
  int get steps => bars * 16;
}

// Drum building blocks
const _hat8 = 'm.q.m.l.m.q.m.l.';
const _rim24 = '....h.......h...';
const _sn24 = '....x.......x...';
const _clap24 = '....h.......h...';

final List<V2Part> v2Parts = [
  // ── Intro: hook preview (bars 1–2 = the chorus hook over the chorus's own
  // Cmaj7 → G/B colour), answer, then a bar of air with a rim/hat pickup.
  V2Part(
    id: 'intro',
    name: 'Intro',
    bars: 4,
    chords: const ['Cmaj7', 'G/B', 'Am7', 'B7sus4→B7'],
    guitar: [
      GBlock(const [(0, 16, 'Cmaj7', 70), (16, 16, 'G/B', 70), (32, 16, 'Am7', 72), (48, 8, 'B7sus4', 74), (56, 8, 'B7', 76)],
          arp: ArpStyle.up),
    ],
    lead: line('E5/6 G5/2 F#5/2 E5/2 B4/4 | D5/4 B4/2 A4/2 G4/4 r/4 | C5/4 B4/4 A4/8 | r/16', 60),
    bass: line('r/16 | r/16 | A1/16 | B1/16', 66),
    drums: drumBars([
      {},
      {},
      {},
      {'hihat': '........q.l.m.h.', 'rimshot': '...............m'},
    ]),
    desc: const {
      'lead': '후렴 훅 앞 2마디(E5 점4분–G5–F#5–E5–B4 / D5–B4–A4–G4)를 작게(세기 60대) 예고, 3마디 C5–B4–A4 응답, 4마디 쉼',
      'guitar': '펼치기 위로(1/8) + 울림 아르페지오',
      'bass': '1–2마디 쉼, 3마디 A1, 4마디 B1 롱톤',
      'drums': '1–3마디 없음, 4마디 후반 햇 크레셴도 + 림 픽업',
      'change': '(시작)',
    },
  ),
  // ── Verse 1: the motif in the lower register (B4 D5 C5 B4 G4 = same rhythm
  // and contour as the hook), 4-bar question ending open on F#4 (over
  // D/F#), 8-bar answer ending on a long B4 (over B7).
  V2Part(
    id: 'verse1',
    name: 'Verse 1',
    bars: 8,
    chords: const ['Em', 'C', 'G', 'D/F#', 'Em', 'C', 'Am7', 'B7'],
    guitar: [
      GBlock(
        [
          ...strum(const ['Em', 'C', 'G', 'D/F#'], const [(0, 4, 0), (4, 2, 0), (6, 4, 0), (10, 2, 0), (12, 2, 0), (14, 2, 0)], 74),
          ...strum(const ['Em', 'C', 'Am7', 'B7'], const [(0, 4, 0), (4, 2, 0), (6, 4, 0), (10, 2, 0), (12, 2, 0), (14, 2, 0)], 84,
              startBar: 4),
        ],
        stroke: 'folk',
      ),
    ],
    lead: line(
      'B4/6 D5/2 C5/2 B4/2 G4/4 | G4/4 E4/2 D4/2 E4/4 r/4 | B4/6 D5/2 C5/2 B4/2 D5/4 | A4/4 F#4/2 E4/2 F#4/6 r/2 | '
      'B4/6 D5/2 C5/2 B4/2 G4/4 | E5/4 D5/2 C5/2 G4/4 r/2 A4/2 | C5/6 B4/2 A4/4 G4/2 A4/2 | B4/12 r/4',
      80,
    ),
    bass: line(
      'E2/6 E2/4 D2/6 | C2/6 C2/8 D2/2 | G1/6 D2/4 G2/6 | F#2/6 F#2/8 D#2/2 | '
      'E2/6 E2/4 G2/6 | C2/6 C2/8 B1/2 | A1/6 A1/4 G1/6 | B1/6 B1/4 D#2/2 F#2/2 A2/2',
      84,
    ),
    drums: drumBars([
      {'kick': 'x.....h...m.....', 'rimshot': _rim24, 'hihat': _hat8},
      {'kick': 'x.....h.......l.', 'rimshot': _rim24, 'hihat': 'm.q.m.l.m.q.m.lq'},
      {'kick': 'x.....h...m.....', 'rimshot': _rim24, 'hihat': _hat8},
      {'kick': 'x.....h...m.....', 'rimshot': _rim24, 'snare': '..............lm', 'hihat': 'm.q.m.l.m.q.....'},
      {'kick': 'x.....h...m.....', 'snare': _sn24, 'hihat': _hat8},
      {'kick': 'x.....h.......l.', 'snare': '....x......gx...', 'hihat': 'm.q.m.l.m.q.m.lq'},
      {'kick': 'x.....h...m...l.', 'snare': _sn24, 'hihat': _hat8},
      {'kick': 'x.....h...m.....', 'snare': '....x.....g.x.mh', 'hihat': 'm.q.m.l.m.q.m...'},
    ], late: const {'rimshot': 1}),
    desc: const {
      'lead': '동기를 낮은 음역(B4–D5–C5–B4–G4, 훅과 같은 리듬)으로. 4마디 질문은 D/F# 위 F#4에서 열린 채 멈춤, 8마디 응답은 B4 롱톤(B7)',
      'guitar': 'folk 스트로크 ↓ ↓↑ ↑↓↑ (1–4마디 세기 74, 5–8마디 84) + 줄별 울림 유지',
      'bass': '킥(1·2&·3&)에 맞춘 근음, D→C, D#→E 같은 접근음, 8마디 B–D#–F#–A로 Lift에 연결',
      'drums': '1–4마디 사이드스틱(림) 2·4(1/24칸 늦게), 5–8마디 스네어로 교체 + 고스트, 4마디 끝 짧은 스네어 픽업, 8마디 끝 필',
      'change': 'Intro의 아르페지오에서 스트로크로, 드럼·베이스 본격 시작',
    },
  ),
  // ── Lift: rising sequence (A–C–E, B–D–F#, C–E–G), Dsus4 → D with the 4–3
  // resolution G5 → F#5, then everything stops on the last beat.
  V2Part(
    id: 'lift',
    name: 'Lift',
    bars: 4,
    chords: const ['Am7', 'Bm7', 'Cmaj7', 'Dsus4→D'],
    guitar: [
      GBlock(
        [
          ...strum(const ['Am7', 'Bm7', 'Cmaj7'], const [(0, 2, 0), (2, 2, -4), (4, 2, 2), (6, 2, -4), (8, 2, 0), (10, 2, -4), (12, 2, 2), (14, 2, -4)], 80),
          (48, 2, 'Dsus4', 90), (50, 2, 'Dsus4', 84), (52, 2, 'Dsus4', 90), (54, 2, 'Dsus4', 84),
          (56, 2, 'D', 94), (58, 2, 'D', 88),
        ],
        stroke: 'downUp',
      ),
    ],
    lead: line('A4/2 C5/2 E5/8 D5/4 | B4/2 D5/2 F#5/8 E5/4 | C5/2 E5/2 G5/8 E5/4 | r/2 D5/2 G5/4 F#5/4 r/4', 84),
    bass: line('A1/6 A1/4 E2/4 A#1/2 | B1/6 D2/4 B1/6 | C2/6 C2/4 G1/4 C#2/2 | D2/6 D2/2 D2/4 r/4', 86),
    drums: drumBars([
      {'kick': 'x.....h...m.....', 'snare': _sn24, 'hihat': 'm.l.m.l.m.l.m...', 'midi_46': '..............m.'},
      {'kick': 'x.....h...m.....', 'snare': _sn24, 'hihat': 'm.l.m...m.l.m...', 'midi_46': '......m.......h.'},
      {'kick': 'x.....h...m...l.', 'snare': '....x.......x..g', 'hihat': 'm.l.m...m.l.m...', 'midi_46': '......h.......h.', 'tambourine': '....m.......m...'},
      {'kick': 'x.....h.x.......', 'snare': '....x...m.x.....', 'hihat': 'm.l.m.l.........'},
    ]),
    desc: const {
      'lead': '상행 시퀀스 A–C–E / B–D–F# / C–E–G(긴 음), 4마디 Dsus4→D 위 G5→F#5 해결, 4박 전체 쉼',
      'guitar': '↓↑ 8분 스트로크, 4마디는 3박 끝에서 멈춤(Dsus4 4번 → D 2번, 4박째 음 없음)',
      'bass': 'A–E–(A#) · B–D–B · C–G–(C#) · D: 마디 끝 8분만 반음 접근음, D까지 상행, 4박째 쉼',
      'drums': '오픈햇(midi_46) 액센트를 2&·4&로 쌓고 3마디 탬버린 추가, 4마디 3&의 스네어 뒤 **완전한 쉼**(마지막 박 드럼·베이스·리드 모두 없음)',
      'change': '화성이 처음으로 버금딸림 쪽(Am7–Bm7–Cmaj7–D)으로 상행, 스트로크가 8분 ↓↑로 촘촘해짐, 오픈햇 등장',
    },
  ),
  // ── Chorus 1: the hook at E5 (same rhythm as the motif), high point A5 in
  // bar 3, second peak A5 in bar 6, leading tone D#5 over B7, long E5.
  V2Part(
    id: 'chorus1',
    name: 'Chorus 1',
    bars: 8,
    chords: const ['C', 'D', 'Bm7', 'Em', 'C', 'D', 'B7', 'Em'],
    guitar: [
      GBlock(
        strum(const ['C', 'D', 'Bm7', 'Em', 'C', 'D', 'B7', 'Em'], const [(0, 2, 4), (2, 2, -6), (4, 2, 8), (6, 4, -2), (10, 2, -6), (12, 2, 8), (14, 2, -6)], 88),
        stroke: 'beat',
        down: const StrokeSpec.down(accent: 1.05),
      ),
    ],
    lead: line(
      'E5/6 G5/2 F#5/2 E5/2 B4/4 | D5/4 B4/2 A4/2 D5/4 r/2 E5/2 | F#5/2 A5/6> G5/2 F#5/2 D5/4 | G5/4 E5/2 D5/2 B4/6 r/2 | '
      'E5/6 G5/2 F#5/2 E5/2 B4/4 | D5/4 E5/2 F#5/2 A5/6 G5/2 | F#5/6 E5/2 D#5/8 | E5/14 r/2',
      92,
    ),
    bass: line(
      'C2/7 C2/3 G1/4 C#2/2 | D2/3 A1/4 D2/3 D2/4 C#2/2 | B1/7 B1/3 F#2/4 D2/2 | E2/3 E2/4 B1/3 E2/4 D2/2 | '
      'C2/7 C2/3 E2/6 | F#2/3 F#2/4 D2/3 F#2/4 E2/2 | D#2/7 D#2/3 B1/4 D#2/2 | E2/7 E2/3 B1/4 D2/2',
      90,
    ),
    drums: drumBars([
      {'crash': 'x...............', 'kick': 'X......h..x.....', 'snare': _sn24, 'clap': _clap24, 'hihat': '..m.h.m.h.m.h.m.'},
      {'kick': 'X..m...h..x...l.', 'snare': '....x.......x..g', 'clap': _clap24, 'hihat': 'h.m.h.mlh.m.h.ml'},
      {'kick': 'X......h..x.....', 'snare': _sn24, 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.h.m.'},
      {'kick': 'X..m...h..x...l.', 'snare': '....x.......x.mh', 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.h...'},
      {'kick': 'X......h..x.....', 'snare': '....x..g....x...', 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.h.m.'},
      {'kick': 'X..m...h..x...l.', 'snare': _sn24, 'clap': _clap24, 'hihat': 'h.m.h.mlh.m.h.ml'},
      {'kick': 'X......h..x.....', 'snare': '....x.......x..g', 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.h.m.'},
      {'kick': 'X......h..x.....', 'snare': '....x.....g.x.mx', 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.....'},
    ], late: const {'snare': 2, 'clap': 2}),
    desc: const {
      'lead': '훅을 E5에서(동기와 같은 리듬), 3마디 Bm7 위 최고음 A5(엇박 진입), 4마디 B4에서 열린 질문 + 쉼, 6마디 두 번째 정점 A5, 7마디 이끎음 D#5, 8마디 E5 14칸 해결',
      'guitar': '8분 스트로크(정박 ↓ / 엇박 ↑, 2·4박 액센트, 3박을 비워 2&을 끌기) + 줄별 울림 유지',
      'bass': '킥의 당김(1·2e·2&·3&)에 맞춘 패턴, 6마디 D/F#(F#2)·7마디 B7/D#(D#2) 전위 → E2, C#·D# 반음 접근',
      'drums': '1마디 크래시, 킥 당김 2종 교대, 스네어+클랩 2·4(2/24칸 늦게), 햇 8분 + 일부 16분, 고스트, 4·8마디 끝 필',
      'change': 'Lift 끝의 1박 정지 뒤 크래시로 진입, 선율이 한 옥타브 위 훅으로, 클랩·크래시·16분 햇 액센트 처음 등장',
    },
  ),
  // ── Post-chorus: half-time echo of the hook's answer, displaced to beat 2.
  V2Part(
    id: 'post',
    name: 'Post',
    bars: 4,
    chords: const ['Em', 'C', 'G', 'D'],
    guitar: [
      GBlock(strum(const ['Em', 'C', 'G', 'D'], const [(0, 6, 0), (6, 4, -8), (10, 6, -4)], 80), stroke: 'down',
          down: const StrokeSpec.down(spreadMs: 34)),
    ],
    lead: line('r/4 D5/4 B4/2 A4/2 G4/4 | E4/8 r/8 | r/4 D5/4 B4/2 A4/2 B4/4 | A4/12 r/4', 74),
    bass: line('E2/6 G2/6 F#2/4 | C2/6 E2/6 B1/4 | G1/6 B1/6 D2/2 C#2/2 | D2/6 F#2/6 A1/2 D#2/2', 80),
    drums: drumBars([
      {'kick': 'x.....m.........', 'snare': '........x.......', 'hihat': 'm...l...m...l...'},
      {'kick': 'x.....m.....l...', 'snare': '........x.......', 'hihat': 'm...l...m...l.l.'},
      {'kick': 'x.....m.........', 'snare': '........x......g', 'hihat': 'm...l...m...l...'},
      {'kick': 'x.....m.....l...', 'snare': '........x...g.lm', 'hihat': 'm...l...m.......'},
    ], late: const {'snare': 2}),
    desc: const {
      'lead': '훅 응답(D5–B4–A4)만 2박으로 밀어 메아리처럼 2번, 사이에 E4·A4 긴 음',
      'guitar': '다운 스트로크 3–3–2 리듬(↓ 34 ms, 느슨하게)',
      'bass': 'E–G–F# / C–E–B / G–B–D–C# / D–F#–A–D# 걷는 선으로 Em 복귀(접근음은 마디 끝 8분만)',
      'drums': '하프타임: 스네어 3박만, 햇 4분, 킥 1·2&, 4마디 끝 스네어 픽업',
      'change': '밀도를 반으로(하프타임), 리드는 짧은 메아리만 — 후렴 뒤 숨 쉬는 구간',
    },
  ),
  // ── Verse 2: same rhythm, new pitches and a new answer; bass octave jumps
  // and more syncopation; ghost snare, tambourine, shaker.
  V2Part(
    id: 'verse2',
    name: 'Verse 2',
    bars: 8,
    chords: const ['Em', 'Cmaj7', 'G/B', 'D/F#', 'Em', 'C', 'Am7', 'B7'],
    guitar: [
      GBlock(
        [
          ...strum(const ['Em', 'Cmaj7', 'G/B', 'D/F#'], const [(0, 3, 0), (3, 3, -10), (6, 2, -4), (8, 2, 0), (10, 2, -6), (12, 2, 2), (14, 2, -6)], 76),
          ...strum(const ['Em', 'C', 'Am7', 'B7'], const [(0, 3, 0), (3, 3, -10), (6, 2, -4), (8, 2, 0), (10, 2, -6), (12, 2, 2), (14, 2, -6)], 82,
              startBar: 4),
        ],
        stroke: 'beat',
      ),
    ],
    lead: line(
      'B4/6 D5/2 C5/2 B4/2 E5/4 | D5/4 B4/2 G4/2 E4/4 r/2 G4/2 | B4/6 D5/2 C5/2 B4/2 G4/4 | A4/4 F#4/2 G4/2 A4/6 r/2 | '
      'B4/6 D5/2 C5/2 B4/2 G4/2 A4/2 | B4/4 C5/2 D5/2 E5/6 r/2 | E5/4 D5/2 C5/2 B4/2 A4/2 C5/4 | D#5/4 B4/4 F#4/6 r/2',
      82,
    ),
    bass: line(
      'E1/3 E2/3 B1/3 D2/7 | C2/3 C3/3 C2/4 G1/4 A1/2 | B1/3 B2/3 B1/3 D2/5 E2/2 | F#2/3 F#1/3 F#2/4 A1/4 D#2/2 | '
      'E2/3 E1/3 E2/3 G1/7 | C2/3 C3/3 C2/4 G1/4 B1/2 | A1/3 A2/3 A1/3 E2/5 A#1/2 | B1/3 B2/3 B1/4 F#2/4 B1/2',
      84,
    ),
    drums: drumBars([
      {'kick': 'x.....h..m......', 'snare': '....x..g....x...', 'tambourine': '....m.......m...', 'hihat': 'm.q.m.q.m.q.m.q.', 'shaker': '...q...q...q...q'},
      {'kick': 'x..l..h...m...m.', 'snare': '....x......gx..g', 'tambourine': '....m.......m...', 'hihat': 'm.q.m.q.m.q.m.q.', 'shaker': '...q...q...q...q'},
      {'kick': 'x.....h..m......', 'snare': '....x..g....x...', 'tambourine': '....m.......m...', 'hihat': 'm.q.m.q.m.q.m.q.', 'shaker': '...q...q...q...q'},
      {'kick': 'x..l..h...m...m.', 'snare': '....x.......xgmh', 'tambourine': '....m.......m...', 'hihat': 'm.q.m.q.m.q.m...', 'shaker': '...q...q...q....'},
      {'kick': 'x.....h..m......', 'snare': '....x..g....x...', 'tambourine': '....m.......m...', 'hihat': 'm.q.m.q.m.q.m...', 'midi_46': '..............l.', 'shaker': '...q...q...q...q'},
      {'kick': 'x..l..h...m...m.', 'snare': '....x......gx..g', 'tambourine': '....m.......m...', 'hihat': 'm.q.m.q.m.q.m.q.', 'shaker': '...q...q...q...q'},
      {'kick': 'x.....h..m....l.', 'snare': '....x..g....x...', 'tambourine': '....m.......m...', 'hihat': 'm.q.m.q.m.q.m.q.', 'shaker': '...q...q...q...q'},
      {'kick': 'x.....h.........', 'snare': _sn24, 'tambourine': '....m...........', 'hihat': 'm.q.m.q.m.q.m...', 'midi_46': '..............m.'},
    ], late: const {'snare': 2}),
    desc: const {
      'lead': '같은 리듬, 음정 변주(1마디 끝 E5로 위로, 4마디 질문은 A4에서), 새 응답 B4–C5–D5–E5 상행, 8마디 D#5–B4–F#4로 Bridge에 넘김',
      'guitar': '16분 당김 스트로크(1·1a·2&·3·3&·4·4&, 정박 ↓ / 엇박 ↑) + 줄별 울림 유지 — Verse 1의 folk 패턴과 다름',
      'bass': '옥타브 도약(E1↔E2, C2↔C3), 1e·2&·3e 당김 증가, A#·D# 반음 접근',
      'drums': '스네어 2·4 + 고스트(2e·3a), 탬버린 2·4, 셰이커 16분 "a"만, 킥 당김 2종, 8마디 끝 오픈햇으로 드롭 준비',
      'change': 'Verse 1과 화성 일부 교체(Cmaj7, G/B), 기타·베이스·드럼 패턴 전부 새로, 퍼커션(탬버린·셰이커) 추가',
    },
  ),
  // ── Bridge: new harmony (Am, F#m7b5, B7sus4), sparse long notes. Bars 1–4
  // drum drop (shaker only), 5–8 build, bar 8 tom fill.
  V2Part(
    id: 'bridge',
    name: 'Bridge',
    bars: 8,
    chords: const ['Am', 'C', 'G/B', 'F#m7b5', 'Cmaj7', 'D', 'B7sus4', 'B7'],
    guitar: [
      GBlock(const [(0, 16, 'Am', 66), (16, 16, 'C', 66), (32, 16, 'G/B', 68), (48, 16, 'F#m7b5', 70)], arp: ArpStyle.downUp),
      GBlock(
        [
          ...strum(const ['Cmaj7', 'D'], const [(0, 4, 0), (4, 4, -6), (8, 2, -2), (10, 2, -8), (12, 4, 0)], 78, startBar: 4),
          ...strum(const ['B7sus4'], const [(0, 2, 0), (2, 2, -6), (4, 2, 4), (6, 2, -6), (8, 2, 0), (10, 2, -6), (12, 2, 4), (14, 2, -6)], 84, startBar: 6),
          ...strum(const ['B7'], const [(0, 4, 4), (4, 4, 0), (8, 2, 4), (10, 2, -2), (12, 4, 8)], 88, startBar: 7),
        ],
        stroke: 'beat',
      ),
    ],
    lead: line('C5/12 B4/4 | E5/8 G5/4 E5/4 | D5/12 r/4 | C5/6 A4/2 E5/8 | B4/4 E5/4 G5/8 | F#5/6 E5/2 D5/8 | E5/12 r/4 | D#5/8 F#5/2 r/6', 76),
    bass: line('A1/16 | C2/16 | B1/16 | F#1/16 | C2/10 G1/6 | D2/6 D2/4 F#1/4 A1/2 | B1/6 B1/4 E2/4 B1/2 | B1/8 F#1/2 A1/2 B1/2 D#2/2', 80),
    drums: drumBars([
      {'shaker': 'l.q.l.q.l.q.l.q.'},
      {'shaker': 'l.q.l.q.l.q.l.q.'},
      {'shaker': 'm.q.l.q.m.q.l.q.'},
      {'shaker': 'm.q.l.q.m.q.l.ql'},
      {'kick': 'x.........m.....', 'rimshot': '............m...', 'hihat': 'l...l...l...l...', 'shaker': 'm.q.l.q.m.q.l.q.'},
      {'kick': 'x.....h...m.....', 'snare': '....m.......m...', 'hihat': 'm.l.m.l.m.l.m.l.', 'shaker': 'm.q.l.q.m.q.l.q.'},
      {'kick': 'x.....h...m...l.', 'snare': '....h.......h...', 'hihat': 'h.m.h.m.h.m.....', 'midi_46': '..............h.'},
      {'kick': 'x.......x.......', 'midi_50': '....hm..........', 'midi_47': '......hm........', 'midi_45': '........hm......', 'snare': '..........m.hhxX'},
    ]),
    desc: const {
      'lead': '드문 긴 음(C5 12칸, D5 12칸, E5 12칸), 새 화성 위 대비, 8마디 D#5–F#5 뒤 쉼',
      'guitar': '1–4마디 펼치기 아래위(1/8) + 울림 아르페지오, 5–8마디 스트로크로 점점 촘촘(4분 → 8분)',
      'bass': '1–4마디 롱톤 A–C–B–F#, 5–8마디 진행 + 8마디 B–F#–A–B–D# 상행으로 E 준비',
      'drums': '**1–4마디 드럼 드롭(셰이커만)**, 5마디 킥·림·햇 4분, 6마디 스네어(약), 7마디 8분 + 오픈햇, 8마디 탐 필(midi_50→47→45) + 스네어 크레셴도',
      'change': '처음 나오는 화성(Am, F#m7b5, B7sus4), 드럼이 빠졌다가 다시 쌓임',
    },
  ),
  // ── Final chorus A: same hook (identity), new answer in bars 4–8,
  // counter-melody (strings) underneath, open hats, tambourine.
  V2Part(
    id: 'finalA',
    name: 'Final Chorus A',
    bars: 8,
    chords: const ['C', 'D', 'Bm7', 'Em', 'C', 'D', 'B7', 'Em'],
    guitar: [
      GBlock(
        strum(const ['C', 'D', 'Bm7', 'Em', 'C', 'D', 'B7', 'Em'], const [(0, 2, 4), (2, 2, -6), (4, 2, 8), (6, 2, -6), (8, 2, 2), (10, 2, -6), (12, 2, 8), (14, 2, -6)], 90),
        stroke: 'beat',
        down: const StrokeSpec.down(accent: 1.05),
      ),
    ],
    lead: line(
      'E5/6 G5/2 F#5/2 E5/2 B4/4 | D5/4 B4/2 A4/2 D5/4 r/2 E5/2 | F#5/2 A5/6> G5/2 F#5/2 D5/4 | E5/4 G5/2 F#5/2 E5/6 r/2 | '
      'E5/6 G5/2 F#5/2 E5/2 B4/4 | D5/4 F#5/2 A5/2 G5/4 F#5/4 | E5/4 D#5/2 E5/2 F#5/8 | G5/2 F#5/2 E5/8 r/2 B4/2',
      94,
    ),
    counter: line('G4/8 E4/8 | F#4/16 | D4/8 F#4/8 | G4/12 r/4 | E4/8 G4/8 | A4/8 F#4/8 | D#4/8 F#4/8 | G4/8 E4/6 r/2', 70),
    bass: line(
      'C2/7 C2/3 G2/2 E2/2 C#2/2 | D2/3 A1/4 D2/3 D3/2 D2/2 C#2/2 | B1/7 B1/3 F#2/2 A2/2 D2/2 | E2/3 E2/4 B1/3 E2/2 G2/2 D2/2 | '
      'C2/7 C2/3 E2/4 E2/2 | F#2/3 F#2/4 A2/3 F#2/4 E2/2 | D#2/7 D#2/3 F#2/2 B1/2 D#2/2 | E2/7 E2/3 D2/4 B1/2',
      92,
    ),
    drums: drumBars([
      {'crash': 'X...............', 'kick': 'X......h..x.....', 'snare': _sn24, 'clap': _clap24, 'hihat': '..m.h.m.h.m.h...', 'midi_46': '..............m.', 'tambourine': '....m.......m...'},
      {'kick': 'X..m...h..x...l.', 'snare': '....x.......x..g', 'clap': _clap24, 'hihat': 'h.m.h.mlh.m.h.ml', 'tambourine': '....m.......m...'},
      {'kick': 'X......h..x.....', 'snare': _sn24, 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.h...', 'midi_46': '..............m.', 'tambourine': '....m.......m...'},
      {'kick': 'X..m...h..x...l.', 'snare': '....x......gx.mh', 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.h...', 'tambourine': '....m.......m...'},
      {'crash': 'h...............', 'kick': 'X......h..x.....', 'snare': '....x..g....x...', 'clap': _clap24, 'hihat': '..m.h.m.h.m.h...', 'midi_46': '..............m.', 'tambourine': '....m.......m...'},
      {'kick': 'X..m...h..x...l.', 'snare': _sn24, 'clap': _clap24, 'hihat': 'h.m.h.mlh.m.h.ml', 'tambourine': '....m.......m...'},
      {'kick': 'X......h..x.....', 'snare': '....x.......x..g', 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.h...', 'midi_46': '..............m.', 'tambourine': '....m.......m...'},
      {'kick': 'X......h..x.....', 'snare': '....x.......x.mx', 'clap': _clap24, 'hihat': 'h.m.h.m.h.m.....', 'tambourine': '....m.......m...'},
    ], late: const {'snare': 2, 'clap': 2}),
    desc: const {
      'lead': '1–3마디 훅 그대로(정체성), 4마디 새 응답 E5–G5–F#5–E5(닫힌 해결), 6–7마디 새 응답 A5 정점 → D#5–E5–F#5, 8마디 끝 B4 픽업',
      'guitar': '8분 전부 스트로크(정박 ↓ / 엇박 ↑, 2·4박 액센트) + 줄별 울림 유지',
      'bass': '후렴 골격 + 장식(옥타브 D3, 16분 접근 G2–E2–C#2), 전위 D/F#·B7/D# 유지',
      'drums': '후렴 + 오픈햇 4&, 탬버린 2·4, 1·5마디 크래시, 4마디 끝 필',
      'change': '드럼 드롭 뒤 탐 필에서 진입, 카운터멜로디(현악 GM 48, 추가 트랙 1개) 등장, 응답 선율 새로',
    },
  ),
  // ── Final chorus B: climax — hook with B5 as the song's peak (bar 3), a
  // last new answer climbing to B5 (bar 5), counter answers in the lead's
  // rests, ride instead of hats in bars 5–8, short stop at the end.
  V2Part(
    id: 'finalB',
    name: 'Final Chorus B',
    bars: 8,
    chords: const ['C', 'D', 'Bm7', 'Em', 'C', 'D', 'B7', 'Em'],
    guitar: [
      GBlock(
        [
          ...strum(const ['C', 'D', 'Bm7', 'Em', 'C', 'D', 'B7'], const [(0, 3, 6), (3, 1, -8), (4, 2, 8), (6, 2, -6), (8, 3, 4), (11, 1, -8), (12, 2, 8), (14, 2, -6)], 92),
          (112, 4, 'Em', 100), (116, 4, 'Em', 94), (120, 3, 'Em', 100),
        ],
        stroke: 'beat',
        down: const StrokeSpec.down(spreadMs: 24, accent: 1.1),
      ),
    ],
    lead: line(
      'E5/6 G5/2 F#5/2 E5/2 B4/4 | D5/4 B4/2 A4/2 D5/4 r/2 E5/2 | F#5/2 B5/6> A5/2 F#5/2 D5/4 | G5/4 E5/2 D5/2 B4/6 r/2 | '
      'G5/4 E5/2 G5/2 B5/6> A5/2 | F#5/4 A5/4 G5/2 F#5/2 E5/2 D5/2 | D#5/6 E5/2 F#5/4 B4/4 | E5/12 r/4',
      96,
    ),
    counter: line('E4/8 G4/8 | A4/8 r/4 F#4/2 A4/2 | B4/12 A4/4 | G4/8 r/4 B4/2 A4/2 | G4/8 E4/8 | F#4/8 A4/8 | B4/8 A4/4 F#4/4 | G4/12 r/4', 74),
    bass: line(
      'C2/2 C2/2 C3/2 C2/2 C2/2 C2/2 C3/2 C#2/2 | D2/2 D2/2 D3/2 D2/2 D2/2 D2/2 A1/2 C#2/2 | B1/2 B1/2 B2/2 B1/2 B1/2 F#2/2 D2/2 D#2/2 | '
      'E2/2 E2/2 E3/2 E2/2 E2/2 E2/2 D2/2 B1/2 | C2/2 C2/2 C3/2 C2/2 C2/2 C2/2 E2/2 E2/2 | F#2/2 F#2/2 A2/2 F#2/2 F#2/2 F#2/2 E2/2 E2/2 | '
      'D#2/2 D#2/2 F#2/2 D#2/2 B1/2 B1/2 A1/2 B1/2 | E2/4 E2/4 E2/3 r/5',
      92,
    ),
    drums: drumBars([
      {'crash': 'X...............', 'kick': 'X......h..x.....', 'snare': _sn24, 'clap': _clap24, 'hihat': '..h.x.h.x.h.x.h.', 'tambourine': '....m.......m...'},
      {'kick': 'X..m...h..x...l.', 'snare': '....x.......x..g', 'clap': _clap24, 'hihat': 'x.h.x.hmx.h.x.hm', 'tambourine': '....m.......m...'},
      {'kick': 'X......h..x.....', 'snare': _sn24, 'clap': _clap24, 'hihat': 'x.h.x.h.x.h.x...', 'midi_46': '..............h.', 'tambourine': '....m.......m...'},
      {'kick': 'X..m...h..x.....', 'snare': '....x.......x...', 'clap': _clap24, 'hihat': 'x.h.x.h.x.h.....', 'midi_50': '.............h..', 'midi_47': '..............h.', 'midi_45': '...............x'},
      {'crash': 'X...............', 'kick': 'X......h..x.....', 'snare': _sn24, 'clap': _clap24, 'ride': '..m.h.m.h.m.h.m.', 'tambourine': '....m.......m...'},
      {'kick': 'X..m...h..x...l.', 'snare': '....x.......x..g', 'clap': _clap24, 'ride': 'h.m.h.m.h.m.h.m.', 'tambourine': '....m.......m...'},
      {'kick': 'X......h..x.....', 'snare': '....x.......x.gm', 'clap': _clap24, 'ride': 'h.m.h.m.h.m.h.m.', 'tambourine': '....m.......m...'},
      {'crash': 'X...............', 'kick': 'X.......x.......', 'snare': '....x.....x.....', 'clap': '....h...........', 'hihat': '..h.h.h.h.h.....'},
    ], late: const {'snare': 2, 'clap': 2}),
    desc: const {
      'lead': '훅 그대로 + 3마디 정점을 B5로(곡 최고음), 5마디 마지막 새 응답 G5–E5–G5–B5(두 번째 B5) → 6–7마디 하행, D#5 이끎음, 8마디 E5 12칸 해결 + 쉼',
      'guitar': '16분 밀기(1·1a·2·2&·3·3a·4·4&) 스트로크, ↓ 24 ms 110% — 가장 강하게, 8마디는 3박 반에서 멈춤',
      'bass': '8분 추진 + 옥타브(C3·D3·E3), 같은 진행, 8마디 E2 세 번 뒤 쉼',
      'drums': '가장 크게: 1·5·8마디 크래시, 1–4마디 햇 강하게, 5–7마디 라이드로 교체, 4마디 끝 탐 필, **8마디 3박 반부터 짧은 쉼**',
      'change': '최고음 B5(A→B), 카운터가 리드 쉼표 자리에서 응답, 햇 → 라이드, 베이스 8분 추진',
    },
  ),
  // ── Outro: motif fragment → long E4; arpeggio → one slow Em(add9) strum;
  // B → E in the bass; last bar kick + crash only.
  V2Part(
    id: 'outro',
    name: 'Outro',
    bars: 4,
    chords: const ['Cmaj7', 'Am7', 'B7', 'Em(add9)'],
    guitar: [
      GBlock(const [(0, 16, 'Cmaj7', 70), (16, 16, 'Am7', 68), (32, 16, 'B7', 70)], arp: ArpStyle.up),
      GBlock(const [(48, 16, 'Em(add9)', 80)], stroke: 'down', down: StrokeSpec.down(spreadMs: 48, accent: .95)),
    ],
    lead: line('E5/6 G5/2 F#5/2 E5/2 B4/4 | C5/4 B4/2 A4/2 G4/8 | A4/4 F#4/4 D#4/8 | E4/16', 68),
    bass: line('C2/10 G1/6 | A1/16 | B1/16 | E1/16', 70),
    drums: drumBars([
      {'kick': 'm.........l.....', 'rimshot': '....l.......l...', 'hihat': 'l...q...l...q...'},
      {'kick': 'm.........l.....', 'rimshot': '....q.......q...', 'hihat': 'l...q...l...q...'},
      {'kick': 'm...............', 'rimshot': '....q.......q...', 'hihat': 'q...q...q.......'},
      {'kick': 'x...............', 'crash': 'm...............'},
    ]),
    desc: const {
      'lead': '훅 앞마디 조각(작게) → C5–B4–A4–G4 → A4–F#4–D#4 → **E4 16칸 해결**',
      'guitar': '1–3마디 펼치기 위로 + 울림, 4마디 Em(add9) 느린 다운 스트로크 한 번(48 ms) 울림',
      'bass': 'C–G / A / B → **E1** (B→E 해결)',
      'drums': '햇 4분·림으로 줄이고, 마지막 마디 킥 + 크래시 한 번 후 정지',
      'change': '모든 파트가 줄어들고 Em으로 닫힘',
    },
  ),
];

V2Part v2Part(String id) => v2Parts.firstWhere((p) => p.id == id);

// ── building ────────────────────────────────────────────────────────────
PitchNote pn(V2Note n) => PitchNote(midi: n.midi, freq: midiToFreq(n.midi), step: n.step, dur: n.dur, velocity: n.vel);

V2Note fromPn(PitchNote n) {
  final d = n.soundingSteps;
  if (n.offsetSteps != 0 || (d - d.roundToDouble()).abs() > 1e-9) {
    throw StateError('off-grid note ${n.midi} @ ${n.startSteps} len $d');
  }
  return (midi: n.midi, step: n.step, dur: d.round(), vel: n.velocity!);
}

DrumNote dn(V2Hit h) => DrumNote(kind: h.kind, step: h.step, velocity: h.vel, offsetSteps: h.tick / 24);

Set<PitchNote> _inRange(List<PitchNote> ns, int a, int b, [bool Function(PitchNote)? also]) => {
      for (final n in ns)
        if (n.step >= a && n.step < b && (also == null || also(n))) n,
    };

/// The guitar before the stroke / string / ring tools: chord hits, with the
/// arpeggio blocks already run through the app's arpeggiate. This is what
/// the section .mid files carry (the UI applies the tools afterwards).
List<PitchNote> guitarPlain(V2Part p) {
  var notes = <PitchNote>[
    for (final b in p.guitar)
      for (final (s, d, c, v) in b.hits)
        for (final m in v2Shapes[c]!.$1) PitchNote(midi: m, freq: midiToFreq(m), step: s, dur: d, velocity: v),
  ];
  for (final b in p.guitar.where((b) => b.arp != null)) {
    notes = arpeggiatePitchNotes(
      notes,
      _inRange(notes, b.start, b.end),
      ArpSettings(style: b.arp!, grid: QuantizeGrid.eighth, gate: 1.0),
      seed: 1,
      steps: p.steps,
    ).notes;
  }
  return notes;
}

typedef GuitarReport = ({
  List<String> tools,
  int notes,
  int unassignable,
  int assignLengthChanges,
  int extended,
  int kept,
  Map<String, int> reasons,
});

/// The guitar-panel tools in the order the UI would use them.
({List<PitchNote> notes, GuitarReport report}) guitarProcessed(V2Part p) {
  var notes = guitarPlain(p);
  final plainEnds = {for (final n in notes) (n.midi, n.step): n.endSteps};
  final whole = p.guitar.length == 1;
  // 1. strokes
  for (final b in p.guitar.where((b) => b.stroke != null)) {
    if (b.stroke == 'beat') {
      notes = applyGuitarStroke(notes, _inRange(notes, b.start, b.end, (n) => n.step % 4 == 0), b.down, bpm: v2Bpm).notes;
      notes = applyGuitarStroke(notes, _inRange(notes, b.start, b.end, (n) => n.step % 4 != 0), b.up, bpm: v2Bpm).notes;
    } else {
      notes = applyStrokePattern(notes, whole ? const {} : _inRange(notes, b.start, b.end), strokePatternById(b.stroke!),
              down: b.down, up: b.up, bpm: v2Bpm)
          .notes;
    }
  }
  // 2. strings (whole track)
  final before = List<PitchNote>.of(notes);
  final assigned = assignStrings(notes, const {});
  notes = assigned.notes;
  var lengthChanges = 0;
  for (var i = 0; i < notes.length; i++) {
    if ((notes[i].endSteps - before[i].endSteps).abs() > 1e-9) lengthChanges++;
  }
  // 3. ring / sustain per block
  var extended = 0, kept = 0;
  final reasons = <String, int>{};
  for (final b in p.guitar) {
    if (b.arp != null) {
      final sel = whole ? <PitchNote>{} : _inRange(notes, b.start, b.end);
      final r = applyRing(notes, sel, rangeEnd: ringRangeEnd(notes, sel, p.steps)).notes;
      final scope = whole ? r : _inRange(r, b.start, b.end).toList();
      for (final n in scope) {
        if (n.endSteps > (plainEnds[(n.midi, n.step)] ?? n.endSteps) + 1e-9) {
          extended++;
        } else {
          kept++;
        }
      }
      notes = r;
    } else {
      final r = applyStrokeSustain(notes, whole ? const {} : _inRange(notes, b.start, b.end), sectionSteps: p.steps);
      extended += r.extended;
      kept += r.kept;
      for (final e in r.reasons.entries) {
        if (e.value > 0) reasons[sustainReasonLabel(e.key)] = (reasons[sustainReasonLabel(e.key)] ?? 0) + e.value;
      }
      notes = r.notes;
    }
  }
  return (
    notes: notes,
    report: (
      tools: [for (final b in p.guitar) '${b.start ~/ 16 + 1}–${(b.end - 1) ~/ 16 + 1}마디: ${b.label}'],
      notes: notes.length,
      unassignable: assigned.unassignable.length,
      assignLengthChanges: lengthChanges,
      extended: extended,
      kept: kept,
      reasons: reasons,
    ),
  );
}

List<String> drumKindsOf(V2Part p) {
  final used = {for (final d in p.drums) d.kind};
  return [
    for (final k in const ['kick', 'snare', 'hihat', 'midi_46', 'rimshot', 'clap', 'tambourine', 'shaker', 'ride', 'crash', 'midi_50', 'midi_47', 'midi_45'])
      if (used.contains(k)) k,
  ];
}

const List<TrackRef> v2Extras = [TrackRef(v2CounterId, 'melody')];

Section v2Section(V2Part p, {required bool processed, Map<String, GuitarReport>? reports}) {
  final s = Section(id: p.id, name: p.name, autoName: false, bars: p.bars, repeats: 1, extras: [for (final e in v2Extras) TrackRef(e.id, e.type)]);
  final g = processed ? guitarProcessed(p) : null;
  if (g != null) reports?[p.id] = g.report;
  s.tracks['melody'] = TrackData(label: 'Guitar · 1', notes: g?.notes ?? guitarPlain(p));
  s.tracks['melodyDec'] = TrackData(label: 'Lead · 3', notes: [for (final n in p.lead) pn(n)]);
  s.tracks['bass'] = TrackData(label: 'Bass · 2', notes: [for (final n in p.bass) pn(n)]);
  s.tracks['drums'] = TrackData(label: 'Drums · 10', drums: [for (final d in p.drums) dn(d)], drumKinds: drumKindsOf(p));
  s.tracks[v2CounterId] = TrackData(label: 'Counter · 4', notes: [for (final n in p.counter) pn(n)]);
  return s;
}

typedef V2Built = ({Song song, Map<String, GuitarReport> reports});

V2Built buildV2Song({required bool processed}) {
  final reports = <String, GuitarReport>{};
  final song = Song(
    id: processed ? v2SongId : '${v2SongId}_plain',
    title: processed ? v2Title : '$v2Title (plain)',
    key: 'E',
    scale: 'minor',
    bpm: v2Bpm,
    bars: 4,
    sections: [for (final p in v2Parts) v2Section(p, processed: processed, reports: reports)],
    instruments: {
      'melody': v2NylonSlot,
      'melodyDec': v2LeadProgram,
      'bass': v2BassProgram,
      'drums': kDefaultDrumKit,
      v2CounterId: v2CounterProgram,
    },
    pan: v2Pan,
  );
  song.vol.addAll(v2Vol);
  return (song: song, reports: reports);
}

// ── section / full .mid files (format 1, one named track per part) ──────
typedef MidLane = ({String name, int ch, int? program, List<(int, int, int, int)> notes});

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
Uint8List smf(String name, List<MidLane> lanes, int endTick) {
  final mpq = (60000000 / v2Bpm).round();
  final tracks = <List<int>>[
    [
      0, ..._meta(0x03, utf8.encode(name)),
      0, ..._meta(0x51, [(mpq >> 16) & 255, (mpq >> 8) & 255, mpq & 255]),
      0, ..._meta(0x58, [4, 2, 24, 8]),
      ..._vlq(endTick), ..._meta(0x2F, const []),
    ],
  ];
  for (final l in lanes) {
    final evs = <(int, int, List<int>)>[];
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
    ..._chunk('MThd', [0, 1, 0, tracks.length, (v2Tpq >> 8) & 255, v2Tpq & 255]),
    for (final t in tracks) ..._chunk('MTrk', t),
  ]);
}

/// The lanes of one section .mid, in file order. Guitar = [guitarPlain].
List<MidLane> sectionLanes(V2Part p) {
  List<(int, int, int, int)> ps(Iterable<V2Note> ns) => [
        for (final n in ns) (n.midi, n.step * v2Tps, (n.step + n.dur) * v2Tps, n.vel),
      ];
  return [
    (name: 'Guitar', ch: 0, program: 24, notes: ps([for (final n in guitarPlain(p)) fromPn(n)])),
    if (p.lead.isNotEmpty) (name: 'Lead', ch: 2, program: v2LeadProgram, notes: ps(p.lead)),
    (name: 'Bass', ch: 1, program: v2BassProgram, notes: ps(p.bass)),
    if (p.counter.isNotEmpty) (name: 'Counter', ch: 3, program: v2CounterProgram, notes: ps(p.counter)),
    (
      name: 'Drums',
      ch: 9,
      program: null,
      notes: [
        for (final d in p.drums) (percussionMidi(d.kind)!, d.step * v2Tps + d.tick, (d.step + 1) * v2Tps + d.tick, d.vel),
      ],
    ),
  ];
}

Uint8List sectionMid(V2Part p) => smf('$v2Title - ${p.name}', sectionLanes(p), p.steps * v2Tps);
