// piano-roll-001: note mute (deactivate notes). docs/specs/piano-roll/pr-001-note-mute.md
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import '../support/step_grid_harness.dart';

PitchNote n(
  int midi,
  int step, {
  int dur = 1,
  bool muted = false,
  bool locked = false,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  muted: muted,
  locked: locked,
);

void main() {
  test('setPitchNotesMuted mutes only the selection and keeps every field', () {
    final a = PitchNote(
      midi: 60,
      freq: midiToFreq(60),
      step: 0,
      dur: 3,
      velocity: 77,
      offsetSteps: .25,
      durationSteps: 2.5,
      sourceMidi: 61,
      confidence: .6,
      assisted: true,
    );
    final b = n(62, 4);
    final out = setPitchNotesMuted([a, b], {a}, true);
    final a2 = out[0];
    expect(a2.muted, isTrue);
    expect(a2.midi, a.midi);
    expect(a2.step, a.step);
    expect(a2.dur, a.dur);
    expect(a2.velocity, a.velocity);
    expect(a2.offsetSteps, a.offsetSteps);
    expect(a2.durationSteps, a.durationSteps);
    expect(a2.sourceMidi, a.sourceMidi);
    expect(a2.confidence, a.confidence);
    expect(a2.assisted, a.assisted);
    expect(out[1], same(b));
  });

  test('muting an already muted selection is a no-op (identical)', () {
    final m = n(60, 0, muted: true);
    final notes = [m, n(62, 4)];
    expect(setPitchNotesMuted(notes, {m}, true), same(notes));
  });

  test('locked notes are skipped', () {
    final l = n(60, 0, locked: true);
    final notes = [l];
    final out = setPitchNotesMuted(notes, {l}, true);
    expect(out, same(notes));
    expect(out.single, same(l));
    expect(out.single.muted, isFalse);
  });

  test('muted round-trips through JSON and defaults to false', () {
    expect(n(60, 0, muted: true).toJson()['muted'], true);
    expect(n(60, 0).toJson().containsKey('muted'), isFalse);
    final j = n(60, 0).toJson();
    expect(PitchNote.fromJson(j).muted, isFalse);
    expect(PitchNote.fromJson(n(60, 0, muted: true).toJson()).muted, isTrue);
    expect(n(60, 0, muted: true).copyWith().muted, isTrue);
  });

  test('flattenSong and MIDI export drop muted notes', () {
    final section = Section(id: 'a', name: 'A');
    section.tracks['melody'] = TrackData(
      notes: [n(60, 0, dur: 2), n(62, 4, dur: 2, muted: true)],
    );
    final flat = flattenSong([section]);
    expect(flat.melody.map((x) => x.midi), [60]);
    final midi = MidiReference.parse(buildMidi(flat, 120));
    final pitches = midi.lanes.expand((l) => l.notes).map((x) => x.pitch);
    expect(pitches, contains(60));
    expect(pitches, isNot(contains(62)));
  });

  test('painting over a muted note adds a separate audible note', () {
    final m = n(60, 0, dur: 4, muted: true);
    final incoming = n(60, 2, dur: 2);
    final out = paintPitchSpan([m], incoming);
    expect(out, hasLength(2));
    expect(out[0], same(m));
    expect(out[1], same(incoming));
    expect(out[1].muted, isFalse);
  });

  test('the eraser cuts muted notes and the fragments stay muted', () {
    final m = n(60, 0, dur: 4, muted: true);
    final out = erasePitchCell([m], 60, 1);
    expect(out, hasLength(2));
    expect([out[0].startSteps, out[0].endSteps], [0, 1]);
    expect([out[1].startSteps, out[1].endSteps], [2, 4]);
    expect(out.every((x) => x.muted), isTrue);
  });

  testWidgets('M key in select mode toggles mute with one commit', (
    tester,
  ) async {
    final key = await mountGrid(tester, [n(60, 1, dur: 2), n(62, 5)]);
    await tester.tapAt(gridPoint(tester, 1.5, 60));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(state.notes[0].muted, isTrue);
    expect(state.notes[1].muted, isFalse);
    // pressing again unmutes (the whole selection is muted)
    await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
    await tester.pump();
    expect(state.commits, 2);
    expect(state.notes[0].muted, isFalse);
    // inspector button does the same
    await tapGridButton(tester, 'note-mute');
    expect(state.commits, 3);
    expect(state.notes[0].muted, isTrue);
  });

  group('schema v3', () {
    late Directory root;
    setUp(() async {
      root = await Directory.systemTemp.createTemp('lt_schema_');
      LoopStorage.rootOverride = root;
    });
    tearDown(() async {
      LoopStorage.rootOverride = null;
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });
    File songsFile() => File('${root.path}/looptap/songs.json');

    test('saves as v3 and still reads a v2 file', () async {
      expect(Song.kSchemaVersion, 3);
      await Directory('${root.path}/looptap').create(recursive: true);
      await songsFile().writeAsString(
        jsonEncode({
          'v': 2,
          'songs': [Song(id: 'old', title: 'Old').toJson()],
        }),
      );
      final loaded = await LoopStorage.load();
      expect(loaded.map((s) => s.id), ['old']);
      await LoopStorage.save(loaded);
      final j = jsonDecode(await songsFile().readAsString()) as Map;
      expect(j['v'], 3);
    });

    test('refuses to overwrite a newer-schema songs.json', () async {
      await Directory('${root.path}/looptap').create(recursive: true);
      final newer = jsonEncode({
        'v': Song.kSchemaVersion + 1,
        'songs': [
          {'id': 'future', 'title': 'From a newer app', 'futureField': 1},
        ],
      });
      await songsFile().writeAsString(newer);
      await expectLater(
        LoopStorage.save([Song(id: 'a', title: 'a')]),
        throwsA(isA<NewerSongsSchemaException>()),
      );
      expect(await songsFile().readAsString(), newer);
      // the queue keeps working for later saves
      await songsFile().delete();
      await LoopStorage.save([Song(id: 'a', title: 'a')]);
      expect(await songsFile().exists(), isTrue);
    });
  });
}
