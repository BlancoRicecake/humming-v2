// Full-song reconstruction v1 of the user-supplied MP3
// (artifacts/gotye-reference-20261023/full-song-v1/).
//
// Bars 1–10: the fixed mallet v2 song (gotye_intro_mallet.dart), notes,
// instruments, vol, tempo and swing unchanged. The only addition there is an
// EMPTY lane for each of the three added tracks, because the app keeps the
// same track list in every section (channel allocation).
// Bars 11–130: transcription.json written by full-song-v1/scripts/f7_transcribe.py
// from measurements on ANALYSIS-ONLY separated stems. Every note carries its
// provenance (measured / pattern-extension) and confidence in that JSON; this
// file only maps it onto 8-bar HumTrack sections. Durations, velocities,
// instruments and vol are chosen approximations.
import 'dart:convert';
import 'dart:io';

import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';

import 'gotye_intro_mallet.dart';

const String fullTranscriptionPath = '../artifacts/gotye-reference-20261023/full-song-v1/transcription.json';
const String fullSongId = 'gotye_full_song_v1_129';
const String fullTitle = 'Gotye full song reconstruction v1';
const int fullBars = 130;
const int fullFirstNewBar = 11;

const String voxMaleId = 'melody_xvoxm';
const String voxFemaleId = 'melody_xvoxf';
const String padId = 'melody_xpad';
const List<TrackRef> fullExtras = [
  TrackRef(voxMaleId, 'melody'),
  TrackRef(voxFemaleId, 'melody'),
  TrackRef(padId, 'melody'),
];

/// Chosen sounds for the added tracks (GM programs), and their vol.
const int voxMaleProgram = 53; // Voice Oohs — an instrument patch, not a voice clone
const int voxFemaleProgram = 73; // Flute — kept distinct from the male guide on purpose
const int padProgram = 89; // Warm Pad
/// The harmony pad is an optional approximation (half-bar chroma of the
/// separated 'other' stem — overtones and melody leak into it). Its notes are
/// kept as candidates with `muted: true`, which flattenSong drops, so they are
/// in neither the WAV nor the MIDI export; unmute them to audition the layer.
///
/// Guide vol: first render at 0.62 put the guides 4.4 dB under the separated
/// vocal-to-mix ratio of the source (ab/levels.json); CC7 gain ≈ 40·log10(vol)
/// → 0.62·10^(4.4/40) ≈ 0.80.
const Map<String, double> fullAddedVol = {voxMaleId: 0.80, voxFemaleId: 0.80, padId: 0.32};

/// Bars 11+ only (bars 1–10 and the shared lane vol stay fixed): the first
/// render had bass +2.4 dB and drums +4.1 dB over the source part-to-mix ratios,
/// corrected through note velocity (≈ 40·log10 gain): ×0.87 and ×0.79.
const Map<String, double> fullNewBarVelocityScale = {'bass': 0.87, 'drums': 0.79};

const Map<String, String> _laneOf = {
  'guitar': 'melody',
  'mallet': 'melodyDec',
  'bass': 'bass',
  'drums': 'drums',
  'vocal_male': voxMaleId,
  'vocal_female': voxFemaleId,
  'pad': padId,
};

Map<String, dynamic> loadFullTranscription([String path = fullTranscriptionPath]) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

String _sectionName(List<dynamic> secs, int first, int last) {
  final names = <String>[];
  for (final s in secs) {
    final m = s as Map<String, dynamic>;
    if ((m['last'] as int) >= first && (m['first'] as int) <= last) names.add(m['name'] as String);
  }
  return 'Bars $first–$last · ${names.join(' / ')}';
}

Song buildGotyeFullSong([Map<String, dynamic>? transcription]) {
  final tr = transcription ?? loadFullTranscription();
  final base = buildGotyeMalletSong();
  for (final s in base.sections) {
    for (final e in fullExtras) {
      s.extras.add(TrackRef(e.id, e.type));
      s.tracks[e.id] = TrackData();
    }
  }
  final tracks = (tr['tracks'] as Map<String, dynamic>);
  final sections = <Section>[...base.sections];
  for (var first = fullFirstNewBar; first <= fullBars; first += 8) {
    final last = first + 7;
    final sec = Section(
      id: 'bars${first}_$last',
      name: _sectionName(tr['sections'] as List<dynamic>, first, last),
      autoName: false,
      bars: 8,
      repeats: 1,
      extras: [for (final e in fullExtras) TrackRef(e.id, e.type)],
    );
    final pitched = <String, List<PitchNote>>{};
    final drums = <DrumNote>[];
    for (final e in tracks.entries) {
      final lane = _laneOf[e.key]!;
      for (final raw in e.value as List<dynamic>) {
        final n = raw as Map<String, dynamic>;
        final bar = n['bar'] as int;
        if (bar < first || bar > last) continue;
        final step = (bar - first) * 16 + (n['step'] as int);
        final dur = n['dur'] as int;
        final scale = fullNewBarVelocityScale[lane] ?? 1.0;
        final vel = ((n['vel'] as int) * scale).round().clamp(1, 127);
        if (lane == 'drums') {
          drums.add(DrumNote(kind: n['kind'] as String, step: step, velocity: vel));
        } else {
          final midi = n['midi'] as int;
          (pitched[lane] ??= []).add(PitchNote(
            midi: midi,
            freq: midiToFreq(midi),
            step: step,
            dur: dur,
            velocity: vel,
            // vocal guides keep the measured stable-segment onset/length
            offsetSteps: (n['offsetSteps'] as num?)?.toDouble() ?? 0,
            durationSteps: (n['durationSteps'] as num?)?.toDouble(),
            muted: lane == padId,
          ));
        }
      }
    }
    sec.tracks['melody'] = TrackData(label: 'Guitar loop', notes: pitched['melody'] ?? []);
    sec.tracks['melodyDec'] = TrackData(label: 'Mallet riff', notes: pitched['melodyDec'] ?? []);
    sec.tracks['bass'] = TrackData(label: 'Bass', notes: pitched['bass'] ?? []);
    sec.tracks['drums'] = TrackData(label: 'Drums', drums: drums, drumKinds: [for (final k in {for (final d in drums) d.kind}) k]);
    sec.tracks[voxMaleId] = TrackData(label: 'Vocal guide (male)', notes: pitched[voxMaleId] ?? []);
    sec.tracks[voxFemaleId] = TrackData(label: 'Vocal guide (female)', notes: pitched[voxFemaleId] ?? []);
    sec.tracks[padId] = TrackData(label: 'Harmony pad', notes: pitched[padId] ?? []);
    sections.add(sec);
  }
  final song = Song(
    id: fullSongId,
    title: fullTitle,
    key: base.key,
    scale: base.scale,
    bpm: base.bpm,
    bars: 8,
    sections: sections,
    instruments: {...base.instruments, voxMaleId: voxMaleProgram, voxFemaleId: voxFemaleProgram, padId: padProgram},
  );
  song.swing = base.swing;
  song.vol.addAll({...base.vol, ...fullAddedVol});
  return song;
}
