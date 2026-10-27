// Full-song reconstruction v2 (artifacts/gotye-reference-20261023/full-song-v2/):
// v1 (gotye_full_song.dart, unchanged) + two measured accompaniment lanes +
// per-section / per-lane note velocity for the section dynamics.
//
// Bars 1–10 stay exactly the fixed mallet v2 notes (only empty lanes are
// added, as in v1). Bars 11–130:
//  - counter : stable-F0 line of the separated 'other' stem's side channel
//              (v2_additions.json 'counter'); sound is a timbre approximation.
//  - sustain : per-section stable sustained semitones C4..C5 of that stem, on
//              the beats where they are measured ('sustain'); timbre approx.
//  - velocity: v2_dynamics.json factors per section × lane, derived from the
//              ANALYSIS-ONLY stems' section levels relative to the intro
//              (bass/drums/guitar/mallet) or verse 1 (guides). These are
//              approximate targets, not exact track levels. The pad candidates
//              stay muted. 'barFactors' adds a per-bar factor on all lanes
//              (bar 90's crescendo into the climax).
import 'dart:convert';
import 'dart:io';

import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';

import 'gotye_full_song.dart';

const String v2Root = '../artifacts/gotye-reference-20261023/full-song-v2';
const String v2AdditionsPath = '$v2Root/v2_additions.json';
const String v2DynamicsPath = '$v2Root/v2_dynamics.json';
const String fullV2SongId = 'gotye_full_song_v2_129';
const String fullV2Title = 'Gotye full song reconstruction v2';

const String counterId = 'melody_xcounter';
const String sustainId = 'melody_xsustain';
const List<TrackRef> fullV2NewExtras = [TrackRef(counterId, 'melody'), TrackRef(sustainId, 'melody')];
const int counterProgram = 49; // String Ensemble 2 — timbre approximation for a sustained stereo line
const int sustainProgram = 48; // String Ensemble 1 — timbre approximation for held harmony tones
const Map<String, double> fullV2NewVol = {counterId: 0.7, sustainId: 0.55};

/// Section names of v2_dynamics.json (bar ranges as in the transcription).
const List<(int, int, String)> v2DynSections = [
  (11, 26, 'verse1'),
  (27, 34, 'interlude'),
  (35, 48, 'verse2'),
  (49, 50, 'break'),
  (51, 74, 'chorus1'),
  (75, 90, 'female-verse'),
  (91, 98, 'female-climax'),
  (99, 122, 'chorus2'),
  (123, 130, 'outro'),
];
String v2DynSectionOf(int bar) => v2DynSections.firstWhere((s) => s.$1 <= bar && bar <= s.$2).$3;

Map<String, dynamic> _load(String p) => jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;

Song buildGotyeFullSongV2({Map<String, dynamic>? additions, Map<String, dynamic>? dynamics}) {
  final add = additions ?? _load(v2AdditionsPath);
  final dynAll = dynamics ?? _load(v2DynamicsPath);
  final dyn = dynAll['factors'] as Map<String, dynamic>;
  // single-bar factors (all lanes) for bars whose source level departs from their section, e.g. the bar-90 crescendo
  final barF = (dynAll['barFactors'] as Map<String, dynamic>?) ?? const {};
  final s = buildGotyeFullSong();
  var firstBar = 1;
  for (final (i, sec) in s.sections.indexed) {
    for (final e in fullV2NewExtras) {
      sec.extras.add(TrackRef(e.id, e.type));
      sec.tracks[e.id] = TrackData(label: e.id == counterId ? 'Counter line (other stem)' : 'Sustain (other stem)');
    }
    final lastBar = firstBar + sec.bars - 1;
    if (i >= 2) {
      for (final (key, lane) in [('counter', counterId), ('sustain', sustainId)]) {
        final notes = sec.tracks[lane]!.pitchNotes;
        for (final raw in add[key] as List<dynamic>) {
          final n = raw as Map<String, dynamic>;
          final bar = n['bar'] as int;
          if (bar < firstBar || bar > lastBar) continue;
          final midi = n['midi'] as int;
          notes.add(PitchNote(
            midi: midi,
            freq: midiToFreq(midi),
            step: (bar - firstBar) * 16 + (n['step'] as int),
            dur: n['dur'] as int,
            velocity: n['vel'] as int,
            offsetSteps: (n['offsetSteps'] as num?)?.toDouble() ?? 0,
            durationSteps: (n['durationSteps'] as num?)?.toDouble(),
          ));
        }
      }
      // per-section / per-lane velocity (bars 11+ only)
      double f(int bar, String lane) =>
          (((dyn[v2DynSectionOf(bar)] as Map<String, dynamic>?)?[lane] as num?)?.toDouble() ?? 1.0) *
          ((barF['$bar'] as num?)?.toDouble() ?? 1.0);
      int scaled(int? v, double k) => (((v ?? 100) * k).round()).clamp(1, 127);
      for (final e in sec.tracks.entries) {
        final p = e.value.pitchNotes;
        for (var j = 0; j < p.length; j++) {
          final k = f(firstBar + p[j].step ~/ 16, e.key);
          if (k != 1.0) p[j] = p[j].copyWith(velocity: scaled(p[j].velocity, k));
        }
        final d = e.value.drumNotes;
        for (var j = 0; j < d.length; j++) {
          final k = f(firstBar + d[j].step ~/ 16, e.key);
          if (k != 1.0) d[j] = d[j].copyWith(velocity: scaled(d[j].velocity, k));
        }
      }
    }
    firstBar = lastBar + 1;
  }
  final song = Song(
    id: fullV2SongId,
    title: fullV2Title,
    key: s.key,
    scale: s.scale,
    bpm: s.bpm,
    bars: s.bars,
    sections: s.sections,
    instruments: {...s.instruments, counterId: counterProgram, sustainId: sustainProgram},
  );
  song.swing = s.swing;
  song.vol.addAll({...s.vol, ...fullV2NewVol});
  return song;
}
