import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/percussion.dart';
import 'package:humming/looptap/music/song_util.dart';

Uint8List smf(List<List<int>> tracks, {int format = 1}) => Uint8List.fromList([
  ...'MThd'.codeUnits,
  0,
  0,
  0,
  6,
  0,
  format,
  0,
  tracks.length,
  1,
  224,
  for (final t in tracks) ...[
    ...'MTrk'.codeUnits,
    (t.length >> 24) & 255,
    (t.length >> 16) & 255,
    (t.length >> 8) & 255,
    t.length & 255,
    ...t,
  ],
]);

void main() {
  test(
    'format 1 separates parts and preserves fractional starts, gates and velocity',
    () {
      final ref = MidiReference.parse(
        smf([
          [
            0,
            0xff,
            0x51,
            3,
            9,
            39,
            192,
            0,
            0xff,
            0x58,
            4,
            4,
            2,
            24,
            8,
            0,
            0xff,
            0x2f,
            0,
          ], // 100 BPM, 4/4
          [
            0, 0xc2, 33, 61, 0x92, 60, 47, 121, 0x82, 60, 0,
            58,
            0x92,
            60,
            101,
            120,
            60,
            0, // running note-on status, zero velocity
            0, 0xff, 0x2f, 0,
          ],
          [61, 0x99, 46, 79, 121, 0x89, 46, 0, 0, 0xff, 0x2f, 0],
        ]),
      );
      expect(ref.bpm, 100);
      expect(ref.noteCount, 3);
      expect(ref.lanes.length, 2);
      final song = ref.passage(title: 'Reference', startBar: 1, lengthBars: 1);
      final restored = Song.fromJson(jsonDecode(jsonEncode(song.toJson())));
      final flat = flattenSong(restored.sections);
      expect(flat.melody.first.offsetSteps, closeTo(61 / 120, 1e-10));
      expect(flat.melody.first.soundingSteps, closeTo(121 / 120, 1e-10));
      expect(flat.melody.map((n) => n.velocity), [47, 101]);
      expect(
        percussionMidi(flat.drums.single.kind),
        46,
      ); // open hat, never closed-hat fallback
      final again = MidiReference.parse(
        buildMidi(flat, 100, melodyProgram: 33),
      );
      expect(again.noteCount, 3);
      final pitches =
          again.lanes
              .expand((l) => l.notes)
              .where((n) => n.channel != 9)
              .toList();
      expect(pitches.first.tick / again.ppq, closeTo(61 / 480, 1e-8));
      expect(pitches.first.endTick / again.ppq, closeTo(182 / 480, 1e-8));
      expect(pitches.first.velocity, 47);
    },
  );

  test(
    'same pitch overlaps pair note-offs FIFO; crop keeps leading sustained notes',
    () {
      final ref = MidiReference.parse(
        smf([
          [
            0,
            0x90,
            60,
            50,
            120,
            60,
            80,
            120,
            0x80,
            60,
            0,
            0x90,
            0,
            60,
            0,
            0,
            0xff,
            0x2f,
            0,
          ],
        ]),
      );
      final notes = ref.lanes.single.notes;
      expect(notes.first.endTick, 240);
      expect(notes.last.endTick, 2288);
      final song = ref.passage(title: 'crop', startBar: 2, lengthBars: 1);
      final n = song.sections.single.tracks['melody']!.pitchNotes.single;
      expect(n.step, 0);
      expect(n.velocity, 80);
      expect(n.soundingSteps, closeTo((2288 - 1920) / 120, 1e-9));
    },
  );

  test(
    'unsupported automation is surfaced and tempo maps never silently flattened',
    () {
      final ref = MidiReference.parse(
        smf([
          [
            0,
            0xff,
            0x51,
            3,
            7,
            161,
            32,
            0,
            0xb0,
            64,
            127,
            0,
            0x90,
            60,
            100,
            120,
            0xff,
            0x51,
            3,
            9,
            39,
            192,
            0,
            0x80,
            60,
            0,
            0,
            0xff,
            0x2f,
            0,
          ],
        ]),
      );
      expect(ref.warnings.join(' '), contains('64'));
      expect(ref.constantTempo, isFalse);
      expect(
        () => ref.passage(title: 'bad', startBar: 1, lengthBars: 1),
        throwsFormatException,
      );
    },
  );

  test(
    'too many independent instruments fail instead of sharing a channel',
    () {
      final ref = MidiReference.parse(
        smf([
          for (var channel = 0; channel < 16; channel++)
            if (channel != 9)
              [
                0,
                0x90 | channel,
                60,
                100,
                120,
                0x80 | channel,
                60,
                0,
                0,
                0xff,
                0x2f,
                0,
              ],
        ]),
      );
      expect(
        () => ref.passage(title: 'too many', startBar: 1, lengthBars: 1),
        throwsFormatException,
      );
      final one = ref.passage(
        title: 'one',
        startBar: 1,
        lengthBars: 1,
        selectedLanes: {ref.lanes.first.id},
      );
      expect(flattenSong(one.sections).melody.length, 1);
    },
  );

  test('reject truncated, malformed and asynchronous MIDI safely', () {
    expect(
      () => MidiReference.parse(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(
      () => MidiReference.parse(
        smf([
          [0, 60, 100],
        ], format: 2),
      ),
      throwsFormatException,
    );
    expect(
      () => MidiReference.parse(
        smf([
          [0, 60, 100],
        ]),
      ),
      throwsFormatException,
    );
    expect(
      () => MidiReference.parse(
        smf([
          [0x80, 0x80, 0x80, 0x80, 0],
        ]),
      ),
      throwsFormatException,
    );
  });

  test(
    'legacy notes keep default playback while imported MIDI scales to true zero',
    () {
      expect(
        PitchNote.fromJson({'midi': 60, 'freq': 261.63, 'step': 0}).velocity,
        isNull,
      );
      expect(DrumNote.fromJson({'kind': 'kick', 'step': 0}).offsetSteps, 0);
      expect(noteVelocity(null, .85), 106);
      expect(noteVelocity(50, 1), 50);
      expect(noteVelocity(50, 0), 0);
      for (var midi = 0; midi < 128; midi++) {
        expect(percussionMidi(percussionKind(midi)), midi);
      }
    },
  );

  const source = String.fromEnvironment('REFERENCE_MIDI');
  const evidence = String.fromEnvironment('REFERENCE_EVIDENCE');
  test(
    'local reference: independent source audit and editable passage',
    () async {
      final ref = MidiReference.parse(await File(source).readAsBytes());
      expect(ref.noteCount, 1176);
      final song = ref.passage(
        title: 'Attention · bars 5–8',
        startBar: 5,
        lengthBars: 4,
      );
      final flat = flattenSong(song.sections);
      final noteCount =
          flat.melody.length +
          flat.melodyDec.length +
          flat.bass.length +
          flat.drums.length +
          flat.beatDec.length +
          flat.extraPitched.values.fold(0, (a, b) => a + b.length) +
          flat.extraDrums.values.fold(0, (a, b) => a + b.length);
      expect(noteCount, greaterThan(0));
      if (evidence.isNotEmpty) {
        final dir = Directory(evidence)..createSync(recursive: true);
        await File(
          '${dir.path}/attention-humtrack.json',
        ).writeAsString(jsonEncode(song.toJson()));
        await File('${dir.path}/attention-humtrack.mid').writeAsBytes(
          buildMidi(
            flat,
            song.bpm,
            melodyProgram: song.instruments['melody'] ?? 0,
            melodyDecProgram: song.instruments['melodyDec'] ?? 48,
            bassProgram: song.instruments['bass'] ?? 33,
            extras: song.sections.single.extras,
            extraInstruments: song.instruments,
          ),
        );
        await File('${dir.path}/source-audit.json').writeAsString(
          jsonEncode({
            'ppq': ref.ppq,
            'bpm': ref.bpm,
            'noteCount': ref.noteCount,
            'warnings': ref.warnings,
            'passageNoteCount': noteCount,
            'lanes': [
              for (final l in ref.lanes)
                {
                  'id': l.id,
                  'name': l.name,
                  'channel': l.channel,
                  'program': l.program,
                  'notes': [
                    for (final n in l.notes)
                      {
                        'pitch': n.pitch,
                        'velocity': n.velocity,
                        'tick': n.tick,
                        'endTick': n.endTick,
                      },
                  ],
                },
            ],
          }),
        );
      }
    },
    skip:
        source.isEmpty
            ? 'Pass REFERENCE_MIDI for a downloaded reference audit.'
            : false,
  );
}
