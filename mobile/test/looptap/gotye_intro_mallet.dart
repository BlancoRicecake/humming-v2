// Mallet v2 of the reference reconstruction: adds the main mallet melody
// (artifacts/gotye-reference-20261023/claude-mallet-v2/) on melodyDec.
//
// Accompaniment: bars 1–8 are the v1 section of gotye_intro_repro.dart,
// unchanged (notes, instruments, vol 0.44/0.75/1.0). Bars 9–10 continue the
// same measured accompaniment pattern (guitar loop every bar; bass bar 9 like
// bar 3, bar 10 with the C2 on 4& measured there; drums as bars 3–8).
//
// What is MEASURED vs CHOSEN for the melody:
//   measured — pitch (nearest semitone; the source sits ~25 cents flat) and
//              16th-slot onset of each mallet attack (evidence:
//              claude-mallet-v2/evidence/mallet_attacks*.csv, high_roll_slots.csv,
//              high_band_slots.csv, wide_peaks_selected.json).
//   chosen   — every duration and velocity, GM 12 Marimba (13 Xylophone for a
//              comparison render), the melodyDec vol.
// Attacks with low confidence are NOT in the song; they are listed in
// [malletCandidatesOmitted].
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';

import 'gotye_intro_repro.dart';

const int malletBars = 10;
const int malletMarimba = 12;
const int malletXylophone = 13;
// 0.55 rendered the mallet +4.0 dB (median note-band salience) above the source;
// CC7 gain ≈ 40·log10(vol) → 0.55·10^(−4/40) ≈ 0.45.
const double malletVol = 0.45;
const String malletSongId = 'gotye_intro_mallet_129';
const String malletTitle = 'Gotye intro + mallet';

/// [pc] pitch confidence, [tc] onset confidence (both measured). dur/vel chosen.
typedef MNote = ({int bar, int step, int midi, int dur, int vel, String pc, String tc, String evidence});

List<MNote> _phraseA(int bar) => [
      (bar: bar, step: 0, midi: 84, dur: 4, vel: 96, pc: 'high', tc: 'high', evidence: 'C6 loudest, side rise 55/33 dB'),
      (bar: bar, step: 4, midi: 84, dur: 4, vel: 80, pc: 'high', tc: 'medium', evidence: 'C6 re-attack, side rise 18-19 dB rel0'),
      (bar: bar, step: 8, midi: 91, dur: 8, vel: 96, pc: 'high', tc: 'high', evidence: 'G6 side rise 34-38 dB rel0'),
    ];

List<MNote> _phraseB(int bar) => [
      (bar: bar, step: 0, midi: 93, dur: 2, vel: 96, pc: 'high', tc: 'high', evidence: 'A6 side rise 35-39 dB'),
      (bar: bar, step: 2, midi: 94, dur: 2, vel: 92, pc: 'high', tc: 'high', evidence: 'A#6 side rise 27 dB'),
      (bar: bar, step: 4, midi: 96, dur: 2, vel: 96, pc: 'high', tc: 'high', evidence: 'C7 side rise 33-34 dB'),
      (bar: bar, step: 6, midi: 93, dur: 2, vel: 90, pc: 'high', tc: 'high', evidence: 'A6 side rise 27-28 dB'),
      (bar: bar, step: 8, midi: 91, dur: 8, vel: 94, pc: 'high', tc: 'high', evidence: 'G6 side rise 34-36 dB'),
    ];

List<MNote> malletMelody() => [
      ..._phraseA(3),
      ..._phraseB(4),
      (bar: 5, step: 0, midi: 89, dur: 4, vel: 96, pc: 'high', tc: 'high', evidence: 'F6 side rise 37 dB'),
      (bar: 5, step: 4, midi: 89, dur: 4, vel: 80, pc: 'high', tc: 'medium', evidence: 'F6 re-attack, side rise 18 dB rel0'),
      (bar: 5, step: 8, midi: 88, dur: 8, vel: 94, pc: 'high', tc: 'high', evidence: 'E6 side rise 24 dB, mid 35 dB'),
      (bar: 6, step: 0, midi: 86, dur: 4, vel: 96, pc: 'high', tc: 'high', evidence: 'D6 side rise 31 dB'),
      (bar: 6, step: 4, midi: 86, dur: 4, vel: 80, pc: 'high', tc: 'medium', evidence: 'D6 re-attack, side rise 21 dB rel0'),
      (bar: 6, step: 8, midi: 84, dur: 4, vel: 94, pc: 'high', tc: 'high', evidence: 'C6 side rise 24 dB, mid 33 dB'),
      (bar: 6, step: 12, midi: 91, dur: 4, vel: 78, pc: 'medium', tc: 'medium', evidence: 'G6 side rise 18 dB rel0, mid 29 dB rel0'),
      ..._phraseA(7),
      ..._phraseB(8),
      (bar: 9, step: 0, midi: 86, dur: 4, vel: 96, pc: 'high', tc: 'high', evidence: 'D6 side rise 37 dB'),
      (bar: 9, step: 4, midi: 86, dur: 8, vel: 80, pc: 'high', tc: 'medium', evidence: 'D6 re-attack, side rise 19 dB rel0'),
      (bar: 9, step: 12, midi: 88, dur: 4, vel: 92, pc: 'high', tc: 'high', evidence: 'E6 side rise 33 dB rel0'),
      (bar: 10, step: 0, midi: 86, dur: 4, vel: 96, pc: 'high', tc: 'high', evidence: 'D6 side rise 33 dB'),
      (bar: 10, step: 4, midi: 86, dur: 7, vel: 80, pc: 'high', tc: 'medium', evidence: 'D6 re-attack, side rise 19 dB rel0'),
      (bar: 10, step: 11, midi: 89, dur: 1, vel: 78, pc: 'medium', tc: 'medium', evidence: 'F6 side rise 15 dB rel0 (16th pickup)'),
      (bar: 10, step: 12, midi: 93, dur: 4, vel: 92, pc: 'high', tc: 'high', evidence: 'A6 side rise 23 dB rel0'),
    ];

/// Low-confidence attacks seen in only one channel or one of two repeats.
const List<String> malletCandidatesOmitted = [
  'bars 3/7 slot 13: G6 re-attack (mid rise 28-29 dB rel0; side not loudest)',
  'bars 4/8 slot 11 or 13: A6 (becomes loudest after G6; rise 10-14 dB, inconsistent between repeats)',
  'bar 5 slot 13: G6 (mid rise 35 dB rel-3; E6 stays loudest)',
  'bar 9 slot 9: D#6/E6 (mid rise 18-20 dB rel-2; side none)',
];

PitchNote _pn(int bar, int step, int midi, int dur, int vel, {int firstBar = 1}) => PitchNote(
      midi: midi,
      freq: midiToFreq(midi),
      step: (bar - firstBar) * 16 + step,
      dur: dur,
      velocity: vel,
    );

/// Bars 9–10 accompaniment from the v1 measured pattern (see header).
Section _bars9to10() {
  final g = [for (final n in gotyeGuitar().where((n) => n.bar <= 2)) _pn(n.bar + 8, n.step, n.midi, n.dur, n.vel, firstBar: 9)];
  final b = [
    for (final n in gotyeBass().where((n) => n.bar == 3)) _pn(9, n.step, n.midi, n.dur, n.vel, firstBar: 9),
    for (final n in gotyeBass().where((n) => n.bar == 6)) _pn(10, n.step, n.midi, n.dur, n.vel, firstBar: 9),
  ];
  final d = [
    for (final h in gotyeDrums().where((h) => h.bar == 3 || h.bar == 4))
      DrumNote(kind: h.kind, step: (h.bar - 3) * 16 + h.step, velocity: h.vel),
  ];
  final m = [for (final n in malletMelody().where((n) => n.bar >= 9)) _pn(n.bar, n.step, n.midi, n.dur, n.vel, firstBar: 9)];
  final sec = Section(id: 'bars9_10', name: 'Bars 9–10', autoName: false, bars: 2, repeats: 1);
  sec.tracks['melody'] = TrackData(label: 'Guitar loop', notes: g);
  sec.tracks['melodyDec'] = TrackData(label: 'Mallet melody', notes: m);
  sec.tracks['bass'] = TrackData(label: 'Bass', notes: b);
  sec.tracks['drums'] = TrackData(label: 'Percussion', drums: d, drumKinds: const ['hihat', 'snare', 'midi_41', 'midi_45']);
  return sec;
}

Song buildGotyeMalletSong({int malletProgram = malletMarimba}) {
  final v1 = buildGotyeIntroSong();
  final first = v1.sections.single;
  first.tracks['melodyDec'] = TrackData(
    label: 'Mallet melody',
    notes: [for (final n in malletMelody().where((n) => n.bar <= 8)) _pn(n.bar, n.step, n.midi, n.dur, n.vel)],
  );
  final song = Song(
    id: malletSongId,
    title: malletTitle,
    key: v1.key,
    scale: v1.scale,
    bpm: v1.bpm,
    bars: 8,
    sections: [first, _bars9to10()],
    instruments: {...v1.instruments, 'melodyDec': malletProgram},
  );
  song.vol.addAll({...v1.vol, 'melodyDec': malletVol});
  return song;
}

/// notes.csv rows for the bars 9–10 accompaniment. These notes are the v1
/// pattern extended (same sources as [_bars9to10]), not a separate
/// transcription: the bass was checked against the bars 9–10 rows of
/// claude/evidence/bass_melody_drums_slots.csv (D2 slots 1–4 and 7–8, C2 9–10;
/// bar 10 C2 at 15–16), the guitar loop and percussion were not re-measured.
List<List<Object>> accompanimentBars9to10Table() {
  const s16 = 60 / gotyeBpm / 4;
  final rows = <List<Object>>[];
  void add(String part, int bar, int step, String what, int vel, int dur, String sound, String ev) {
    final abs = (bar - 1) * 16 + step;
    rows.add([part, bar, step + 1, what, (abs * s16).toStringAsFixed(3), (gotyeOriginSec + abs * gotyeMeasuredBarSec / 16).toStringAsFixed(3), 'pattern-extension', 'pattern-extension', dur, vel, 'chosen', sound, ev]);
  }

  for (final n in gotyeGuitar().where((n) => n.bar <= 2)) {
    add('guitar', n.bar + 8, n.step, midiName(n.midi), n.vel, n.dur, 'chosen: FreePats nylon slot 1001', 'v1 guitar loop bar ${n.bar} repeated (loop assumed, not re-measured)');
  }
  for (final (bar, src) in const [(9, 3), (10, 6)]) {
    for (final n in gotyeBass().where((n) => n.bar == src)) {
      add('bass', bar, n.step, midiName(n.midi), n.vel, n.dur, 'chosen: GM 33 bass', 'v1 bass bar $src pattern; matches bars 9-10 pYIN rows (v1 pitch conf ${n.pc})');
    }
  }
  for (final h in gotyeDrums().where((h) => h.bar == 3 || h.bar == 4)) {
    add('drums', h.bar + 6, h.step, h.kind, h.vel, 1, 'chosen GM kind (band match ${h.kc})', 'v1 percussion bar ${h.bar} pattern repeated (not re-measured)');
  }
  return rows;
}

/// notes.csv rows for the melody (time in the reconstruction and in the MP3).
List<List<Object>> malletNoteTable() {
  const s16 = 60 / gotyeBpm / 4;
  return [
    for (final n in malletMelody())
      [
        'mallet',
        n.bar,
        n.step + 1,
        midiName(n.midi),
        (((n.bar - 1) * 16 + n.step) * s16).toStringAsFixed(3),
        (gotyeOriginSec + ((n.bar - 1) * 16 + n.step) * gotyeMeasuredBarSec / 16).toStringAsFixed(3),
        n.pc,
        n.tc,
        n.dur,
        n.vel,
        'chosen',
        'chosen: GM 12 Marimba',
        n.evidence,
      ],
  ];
}
