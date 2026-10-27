import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';

import '../support/offline_fonts.dart';

PitchNote plain(int step, int dur, {int midi = 60}) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

PitchNote expressive() => PitchNote(
  midi: 60,
  freq: midiToFreq(60),
  step: 2,
  dur: 5,
  offsetSteps: .3,
  durationSteps: 4.4,
  velocity: 47,
  sourceMidi: 61,
  confidence: .72,
  assisted: true,
);

void bounds(PitchNote note, double start, double end) {
  expect(note.startSteps, closeTo(start, 1e-10));
  expect(note.endSteps, closeTo(end, 1e-10));
}

void expression(PitchNote actual, PitchNote source) {
  // Compare the complete persisted non-time payload, including future fields.
  Map<String, dynamic> payload(PitchNote n) =>
      Map.of(n.toJson())
        ..remove('step')
        ..remove('dur')
        ..remove('offsetSteps')
        ..remove('durationSteps');
  expect(payload(actual), payload(source));
}

void main() {
  test(
    'partial erase keeps both fractional outer boundaries and expression',
    () {
      final source = expressive();
      final other = plain(8, 2, midi: 64);
      final before = jsonEncode(source.toJson());
      final result = erasePitchCell([source, other], 60, 4);
      expect(result, hasLength(3));
      bounds(result[0], 2.3, 4);
      bounds(result[1], 5, 6.7);
      expression(result[0], source);
      expression(result[1], source);
      expect(result[2], same(other));
      expect(jsonEncode(source.toJson()), before);
    },
  );

  test('erase catches a short note crossing beyond its integer envelope', () {
    final source = plain(
      0,
      1,
    ).copyWith(offsetSteps: .8, durationSteps: .5, velocity: 79);
    expect(source.overlapsCell(1), isTrue);
    final result = erasePitchCell([source], 60, 1);
    bounds(result.single, .8, 1);
    expression(result.single, source);
    expect(result.single.offsetSteps, .8);
    expect(source.overlapsCell(2), isFalse);
  });

  test('fractional tail erase preserves start; head erase preserves end', () {
    final source = expressive();
    final tail = erasePitchCell([source], 60, 6).single;
    bounds(tail, 2.3, 6);
    final head = erasePitchCell([source], 60, 2).single;
    bounds(head, 3, 6.7);
    expression(tail, source);
    expression(head, source);
    expect(
      erasePitchCell(
        [
          plain(
            0,
            1,
          ).copyWith(offsetSteps: .2, durationSteps: .4, velocity: 80),
        ],
        60,
        0,
      ),
      isEmpty,
    );
  });

  test('erasing an empty cell or a locked note is a no-op', () {
    final notes = [expressive().copyWith(locked: true)];
    expect(erasePitchCell(notes, 60, 4), same(notes));
    expect(erasePitchCell(notes, 60, 7), same(notes));
    expect(erasePitchCell(notes, 62, 4), same(notes));
  });

  test(
    'one erase removes all overlapping unlocked voices at the same pitch',
    () {
      final a = plain(0, 3).copyWith(velocity: 40);
      final b = plain(
        1,
        3,
      ).copyWith(velocity: 110, offsetSteps: .5, durationSteps: 2.2);
      final locked = a.copyWith(locked: true);
      final result = erasePitchCell([a, b, locked], 60, 2);
      expect(result, hasLength(4));
      bounds(result[0], 0, 2);
      bounds(result[1], 1.5, 2);
      bounds(result[2], 3, 3.7);
      expression(result[0], a);
      expression(result[1], b);
      expression(result[2], b);
      expect(result[3], same(locked));
    },
  );

  test('legacy cell erase retains legacy gain and gate representation', () {
    final result = erasePitchCell([plain(1, 5)], 60, 3);
    expect(result.map((n) => (n.step, n.dur)), [(1, 2), (4, 2)]);
    for (final n in result) {
      expect(n.velocity, isNull);
      expect(n.durationSteps, isNull);
      expect(n.offsetSteps, 0);
    }
  });

  test(
    'extending one expressive note inherits strength and untouched endpoint',
    () {
      final source = expressive();
      final right = paintPitchSpan([source], plain(5, 3)).single;
      bounds(right, 2.3, 8);
      expression(right, source);
      final left = paintPitchSpan([source], plain(1, 2)).single;
      bounds(left, 1, 6.7);
      expression(left, source);
      final notes = [source];
      expect(paintPitchSpan(notes, plain(3, 1)), same(notes));
    },
  );

  test(
    'multiple expressive attacks stay distinct; paint fills only their gaps',
    () {
      final a = plain(
        0,
        2,
      ).copyWith(offsetSteps: .2, durationSteps: 1.2, velocity: 40);
      final b = plain(
        1,
        2,
      ).copyWith(offsetSteps: .6, durationSteps: 1.2, velocity: 110);
      for (final second in [b, b.copyWith(velocity: 40)]) {
        final result = paintPitchSpan([a, second], plain(0, 3));
        expect(result, hasLength(5));
        expect(result[0], same(a));
        expect(result[1], same(second));
        bounds(result[2], 0, .2);
        bounds(result[3], 1.4, 1.6);
        bounds(result[4], 2.8, 3);
      }
    },
  );

  test(
    'locked notes block painting without losing their timing or metadata',
    () {
      final source = expressive().copyWith(locked: true);
      final result = paintPitchSpan([source], plain(1, 7));
      expect(result[0], same(source));
      bounds(result[1], 1, 2.3);
      bounds(result[2], 6.7, 8);
      final notes = [source];
      expect(paintPitchSpan(notes, plain(3, 1)), same(notes));
    },
  );

  test('legacy connected-overlap merge is independent of list order', () {
    final a = plain(0, 2), b = plain(4, 2), bridge = plain(1, 4);
    for (final notes in [
      [a, b, bridge],
      [b, bridge, a],
      [bridge, a, b],
    ]) {
      final result = paintPitchSpan(notes, plain(2, 1));
      bounds(result.single, 0, 6);
      expect(result.single.velocity, isNull);
      expect(result.single.durationSteps, isNull);
    }
    // Adjacent notes do not overlap and must not lose their separate attacks.
    expect(paintPitchSpan([plain(0, 1)], plain(1, 1)), hasLength(2));
  });

  test(
    'import -> edit -> save/copy -> MIDI export keeps fractional gates and velocity',
    () {
      // 480 PPQ: C4 starts at 61, ends at 422; E4 starts at 422, ends at 542.
      final track = [
        61,
        0x90,
        60,
        47,
        0x82,
        0x69,
        0x80,
        60,
        0,
        0,
        0x90,
        64,
        101,
        120,
        0x80,
        64,
        0,
        0,
        0xff,
        0x2f,
        0,
      ];
      final ref = MidiReference.parse(
        Uint8List.fromList([
          ...'MThd'.codeUnits,
          0,
          0,
          0,
          6,
          0,
          0,
          0,
          1,
          1,
          224,
          ...'MTrk'.codeUnits,
          0,
          0,
          0,
          track.length,
          ...track,
        ]),
      );
      final song = ref.passage(
        title: 'Edit regression',
        startBar: 1,
        lengthBars: 1,
      );
      final data = song.sections.single.tracks['melody']!;
      final original = data.deepCopy();
      final edited = erasePitchCell(data.pitchNotes, 60, 1);
      data.pitchNotes
        ..clear()
        ..addAll(edited);
      final redo = data.deepCopy();
      // Snapshots must not mutate the original or alias the edited list.
      expect(original.pitchNotes, hasLength(2));
      expect(redo.pitchNotes, hasLength(3));
      final restored = Song.fromJson(jsonDecode(jsonEncode(song.toJson())));
      final exported = MidiReference.parse(
        buildMidi(flattenSong(restored.sections), 120),
      );
      final notes =
          exported.lanes.expand((l) => l.notes).toList()
            ..sort((a, b) => a.tick.compareTo(b.tick));
      expect(notes.map((n) => (n.pitch, n.velocity)), [
        (60, 47),
        (60, 47),
        (64, 101),
      ]);
      final expected = [(61, 120), (240, 422), (422, 542)];
      for (var i = 0; i < expected.length; i++) {
        expect(
          notes[i].tick / exported.ppq,
          closeTo(expected[i].$1 / 480, 1e-8),
        );
        expect(
          notes[i].endTick / exported.ppq,
          closeTo(expected[i].$2 / 480, 1e-8),
        );
      }
    },
  );

  test(
    'fractional notes with legacy strength keep timing on guitar export',
    () {
      final section = Section(id: 'g', name: 'G', bars: 1);
      section.tracks['melody'] = TrackData(
        notes: [
          plain(0, 1).copyWith(offsetSteps: .8, durationSteps: .5),
          plain(0, 1, midi: 64).copyWith(offsetSteps: .2, durationSteps: .4),
        ],
      );
      final exported = MidiReference.parse(
        buildMidi(flattenSong([section]), 120, melodyProgram: 24),
      );
      final notes = exported.lanes.single.notes;
      final c = notes.singleWhere((n) => n.pitch == 60);
      final e = notes.singleWhere((n) => n.pitch == 64);
      expect(c.tick / exported.ppq * 4, closeTo(.8, 1e-8));
      expect(c.endTick / exported.ppq * 4, closeTo(1.3, 1e-8));
      expect(e.tick / exported.ppq * 4, closeTo(.2, 1e-8));
      expect(e.endTick / exported.ppq * 4, closeTo(.6, 1e-8));
    },
  );

  test(
    'a precise guitar edit leaves another legacy chord strumming unchanged',
    () {
      final section = Section(id: 'mixed', name: 'Mixed', bars: 1);
      final chord = [
        for (final pitch in [60, 64, 67]) plain(4, 2, midi: pitch),
      ];
      section.tracks['melody'] = TrackData(notes: chord);
      final before = MidiReference.parse(
        buildMidi(flattenSong([section]), 120, melodyProgram: 24),
      );
      section.tracks['melody']!.pitchNotes.add(
        plain(
          0,
          1,
          midi: 72,
        ).copyWith(offsetSteps: .3, durationSteps: .4, velocity: 47),
      );
      final after = MidiReference.parse(
        buildMidi(flattenSong([section]), 120, melodyProgram: 24),
      );
      for (final original in before.lanes.single.notes) {
        final n = after.lanes.single.notes.singleWhere(
          (n) => n.pitch == original.pitch,
        );
        expect(n.velocity, original.velocity);
        // Adding precision raises PPQ; allow one tick of the legacy 96-PPQ file.
        expect(
          n.tick / after.ppq,
          closeTo(original.tick / before.ppq, 1 / before.ppq),
        );
        expect(
          n.endTick / after.ppq,
          closeTo(original.endTick / before.ppq, 1 / before.ppq),
        );
      }
      final edited = after.lanes.single.notes.singleWhere((n) => n.pitch == 72);
      expect(edited.velocity, 47);
      expect(edited.tick / after.ppq * 4, closeTo(.3, 1e-8));
      expect(edited.endTick / after.ppq * 4, closeTo(.7, 1e-8));
    },
  );

  testWidgets('grid routes a tap on a fractional tail to erase, not paint', (
    tester,
  ) async {
    useOfflineTestFonts();
    var erased = -1, placed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 500,
            height: 200,
            child: StepGrid(
              ladder: [
                Rung(
                  midi: 60,
                  freq: midiToFreq(60),
                  name: 'C4',
                  degree: 0,
                  index: 0,
                ),
              ],
              notes: [plain(0, 1).copyWith(offsetSteps: .8, durationSteps: .5)],
              onPlace: (_, _, _) => placed++,
              onErase: (_, step) => erased = step,
              playStep: 0,
              accent: Colors.green,
              steps: 4,
              bars: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    await tester.tapAt(
      Offset(lane.left + lane.width * 1.1 / 4, lane.center.dy),
    );
    await tester.pumpAndSettle();
    expect(erased, 1);
    expect(placed, 0);
    expect(tester.takeException(), isNull);
  });
}
