// Reference reconstruction: the first 8 bars of the user-supplied MP3
// "Somebody That I Used To Know" (artifacts/gotye-reference-20261023/).
//
// What is MEASURED vs CHOSEN:
//   measured  — note pitch (nearest semitone) and onset position (16th slot)
//               of guitar and bass, tempo, origin; for percussion only the
//               slot and the frequency band where energy was added.
//               Evidence: artifacts/gotye-reference-20261023/claude/evidence/
//               (slots16.csv, onset_peaks_0_8s.json, bass_melody_drums_slots.csv,
//               drum_band_delta.json, added_layer_spectrum.json).
//   chosen (approximation, not extracted) — every duration, every velocity,
//               the GM drum kind for each percussive hit, the instruments
//               (FreePats nylon slot 1001, GM 33 bass, GM kit) and the mix vol.
// Per-note confidence is split (pitch / timing / dur+vel / sound) in
// [gotyeNoteTable] → notes.csv.
// Origin: step 0 = the first measured attack at 0.165 s of the MP3.
// Tempo measured 128.98–129.00 BPM; the Song model takes an integer → 129.
// The source sits ~20–30 cents flat; notes are the nearest semitone (D3/C3),
// not forced down. Sounds are the bundled SF2s, not the original samples;
// no audio from the MP3 is used in the render.
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/theory.dart';

const int gotyeBpm = 129;
const double gotyeOriginSec = 0.165;
const double gotyeMeasuredBarSec = 1.8605; // Codex waveform repeat; Claude grid 1.8615
const int gotyeBars = 8;
const int gotyeNylonSlot = 1001; // FreePats nylon (source is a nylon-guitar sample)
const int gotyeBassProgram = 33;
const String gotyeSongId = 'gotye_intro_repro_129';
const String gotyeTitle = 'Gotye intro reproduction';

/// [pc] pitch confidence, [tc] onset-slot confidence (measured). dur/vel are
/// always chosen approximations.
typedef GNote = ({int bar, int step, int midi, int dur, int vel, String pc, String tc, String evidence});

/// [tc] onset-slot confidence (measured); [kc] how well the GM kind matches
/// the measured band (the kind itself is chosen); vel chosen.
typedef GHitR = ({int bar, int step, String kind, int vel, String tc, String kc, String evidence});

/// Guitar loop: identical in every bar (waveform repeat 1.8605 s).
List<GNote> gotyeGuitar() => [
      for (var b = 1; b <= gotyeBars; b++) ...[
        (bar: b, step: 0, midi: 50, dur: 6, vel: 100, pc: 'high', tc: 'high', evidence: 'D3 -18..-34c, onset 0.165/2.027 s'),
        (bar: b, step: 6, midi: 50, dur: 2, vel: 72, pc: 'high', tc: 'high', evidence: 'D3 -18c, onset 0.864/2.693 s'),
        (bar: b, step: 8, midi: 48, dur: 6, vel: 88, pc: 'high', tc: 'high', evidence: 'C3 -18c, onset 1.093/2.949 s'),
        (bar: b, step: 14, midi: 48, dur: 2, vel: 68, pc: 'medium', tc: 'high', evidence: 'C3 -8c, onset 1.792/3.653 s'),
      ],
    ];

/// Bass from bar 3 (pYIN on the lowpassed harmonic part, bars 3–8).
/// Beat-4& note: octave varies by bar in the measurement (C3 bars 4/8,
/// C2 bar 6, none in bars 3/5/7) — kept as measured, low confidence.
List<GNote> gotyeBass() {
  const lastNote = {4: 48, 6: 36, 8: 48};
  return [
    for (var b = 3; b <= gotyeBars; b++) ...[
      (bar: b, step: 0, midi: 38, dur: 4, vel: 92, pc: 'high', tc: 'high', evidence: 'D2 -12..-22c slots 1-4'),
      (bar: b, step: 6, midi: 38, dur: 2, vel: 84, pc: 'high', tc: 'medium', evidence: 'D2 slot 7-8'),
      (bar: b, step: 8, midi: 36, dur: 2, vel: 88, pc: 'high', tc: 'high', evidence: 'C2 -12..-22c slots 9-10'),
      if (lastNote[b] != null)
        (bar: b, step: 14, midi: lastNote[b]!, dur: 2, vel: 76, pc: 'low', tc: 'medium', evidence: 'slot 15-16, octave unstable across bars'),
    ],
  ];
}

/// Percussion. Beats 2/4 of the guitar loop carry a body knock (~95 Hz
/// inharmonic peak, present already in the guitar-only bars) → low floor tom.
/// From bar 3: energy added on the beats in 2.5–6 kHz (hat-like), on 2/4 at
/// 220–300 Hz + 4 kHz (light snare-like), and a broad 160–1000 Hz thump on
/// 3& (tom-like). Kind choice is an approximation of measured bands.
List<GHitR> gotyeDrums() => [
      for (var b = 1; b <= gotyeBars; b++) ...[
        (bar: b, step: 4, kind: 'midi_41', vel: 36, tc: 'high', kc: 'low', evidence: 'guitar-only bars: 94.5 Hz peak on beat 2'),
        (bar: b, step: 12, kind: 'midi_41', vel: 32, tc: 'high', kc: 'low', evidence: 'guitar-only bars: 94.5 Hz peak on beat 4'),
      ],
      for (var b = 3; b <= gotyeBars; b++) ...[
        for (final s in const [0, 4, 8, 12])
          (bar: b, step: s, kind: 'hihat', vel: 40, tc: 'medium', kc: 'low', evidence: 'added 2.5-6k on beats (+14..+21 dB)'),
        for (final s in const [4, 12])
          (bar: b, step: s, kind: 'snare', vel: 40, tc: 'medium', kc: 'low', evidence: 'added 220-300 Hz + 4 kHz on 2/4'),
        (bar: b, step: 10, kind: 'midi_45', vel: 66, tc: 'medium', kc: 'low', evidence: 'added 160-1000 Hz +22..+32 dB on 3&'),
      ],
    ];

PitchNote _pn(GNote n) => PitchNote(
      midi: n.midi,
      freq: midiToFreq(n.midi),
      step: (n.bar - 1) * 16 + n.step,
      dur: n.dur,
      velocity: n.vel,
    );

Song buildGotyeIntroSong() {
  final drums = gotyeDrums();
  final sec = Section(id: 'intro', name: 'Intro (bars 1–8)', autoName: false, bars: gotyeBars, repeats: 1);
  sec.tracks['melody'] = TrackData(label: 'Guitar loop', notes: [for (final n in gotyeGuitar()) _pn(n)]);
  sec.tracks['melodyDec'] = TrackData(label: 'Lead (empty)', notes: const []);
  sec.tracks['bass'] = TrackData(label: 'Bass', notes: [for (final n in gotyeBass()) _pn(n)]);
  sec.tracks['drums'] = TrackData(
    label: 'Percussion',
    drums: [for (final d in drums) DrumNote(kind: d.kind, step: (d.bar - 1) * 16 + d.step, velocity: d.vel)],
    drumKinds: [for (final k in const ['hihat', 'snare', 'midi_41', 'midi_45']) k],
  );
  final song = Song(
    id: gotyeSongId,
    title: gotyeTitle,
    key: 'D',
    scale: 'minor',
    bpm: gotyeBpm,
    bars: gotyeBars,
    sections: [sec],
    instruments: {
      'melody': gotyeNylonSlot,
      'melodyDec': 0,
      'bass': gotyeBassProgram,
      'drums': kDefaultDrumKit,
    },
  );
  // vol is MIDI CC7 (gain ≈ 40·log10(vol), so 0.8→0.27 is −19 dB, not −9.4).
  // draft 1: melody 0.8 / drums 0.45 → entry of bass+percussion only +2.3 dB
  //   (source +8.5 dB, Codex level review).
  // draft 2: melody 0.27 / drums 1.0 → entry +7.8 dB but guitar stem −50.5
  //   dBFS, 14 dB under the bass and under the body knocks in bars 1–2.
  // final: melody 0.44 / drums 1.0 with quieter knocks and hats (below).
  song.vol.addAll({'melody': 0.44, 'melodyDec': 0.0, 'bass': 0.75, 'drums': 1.0});
  return song;
}

/// CSV rows for notes.csv (time in the reconstruction and in the MP3).
List<List<Object>> gotyeNoteTable() {
  const s16 = 60 / gotyeBpm / 4;
  final rows = <List<Object>>[];
  void add(String part, int bar, int step, String what, int vel, int dur, String pc, String tc, String sound, String ev) {
    final abs = (bar - 1) * 16 + step;
    rows.add([part, bar, step + 1, what, (abs * s16).toStringAsFixed(3), (gotyeOriginSec + abs * gotyeMeasuredBarSec / 16).toStringAsFixed(3), pc, tc, dur, vel, 'chosen', sound, ev]);
  }

  for (final n in gotyeGuitar()) {
    add('guitar', n.bar, n.step, midiName(n.midi), n.vel, n.dur, n.pc, n.tc, 'chosen: FreePats nylon slot 1001', n.evidence);
  }
  for (final n in gotyeBass()) {
    add('bass', n.bar, n.step, midiName(n.midi), n.vel, n.dur, n.pc, n.tc, 'chosen: GM 33 bass', n.evidence);
  }
  for (final d in gotyeDrums()) {
    add('drums', d.bar, d.step, d.kind, d.vel, 1, 'n/a', d.tc, 'chosen GM kind (band match ${d.kc})', d.evidence);
  }
  return rows;
}

String midiName(int m) => '${kNoteNames[m % 12]}${m ~/ 12 - 1}';
