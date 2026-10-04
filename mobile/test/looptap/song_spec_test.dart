import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/song_spec.dart';
import 'package:humming/looptap/music/theory.dart';

void main() {
  test(
    'exports a versioned model-neutral spec with locked melody provenance',
    () {
      final song = Song(
        id: 's1',
        title: 'My hum',
        key: 'C',
        scale: 'major',
        bpm: 96,
      );
      song.sections.first.tracks['melody']!.pitchNotes.add(
        PitchNote(
          midi: 62,
          freq: midiToFreq(62),
          step: 0,
          dur: 4,
          sourceMidi: 61,
          confidence: .8,
          assisted: true,
        ),
      );
      final spec = SongSpec.fromSong(song);
      final json = jsonDecode(spec.encode()) as Map<String, dynamic>;
      expect(json['schema'], 'humtrack.song-spec');
      expect(json['version'], 1);
      expect(json['locks']['melody'], isTrue);
      final note = json['sections'][0]['tracks']['melody']['notes'][0];
      expect(note['sourceMidi'], 61);
      expect(note['locked'], isTrue);
    },
  );

  test('ABC preserves melody and chord voices on the 16th-note grid', () {
    final song = Song(
      id: 's1',
      title: 'Plan',
      key: 'C',
      scale: 'major',
      bpm: 100,
    );
    final section = song.sections.first;
    section.tracks['melody']!.pitchNotes.add(
      PitchNote(midi: 60, freq: midiToFreq(60), step: 0, dur: 4),
    );
    section.tracks['melodyDec']!.pitchNotes.addAll([
      PitchNote(midi: 60, freq: midiToFreq(60), step: 0, dur: 16),
      PitchNote(midi: 64, freq: midiToFreq(64), step: 0, dur: 16),
      PitchNote(midi: 67, freq: midiToFreq(67), step: 0, dur: 16),
    ]);
    final abc = SongSpec.fromSong(song).toAbc();
    expect(abc, contains('Q:1/4=100'));
    expect(abc, contains('V:1 name="Melody"'));
    expect(abc, contains('C4'));
    expect(abc, contains('V:2 name="Chords"'));
    expect(abc, contains('[CEG]16'));
  });
}
