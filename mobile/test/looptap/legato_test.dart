// piano-roll-005: legato. docs/specs/piano-roll/pr-005-legato.md
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';

import '../support/step_grid_harness.dart';

PitchNote span(
  int midi,
  double start,
  double end, {
  bool locked = false,
  bool muted = false,
}) {
  final step = start.floor();
  final precise = start != step || end - start != (end - start).roundToDouble();
  return PitchNote(
    midi: midi,
    freq: midiToFreq(midi),
    step: step,
    dur: math.max(1, (end - start).ceil()),
    offsetSteps: start - step,
    durationSteps: precise ? end - start : null,
    locked: locked,
    muted: muted,
  );
}

List<PitchNote> legato(List<PitchNote> notes, [Set<PitchNote>? sel]) =>
    legatoPitchNotes(notes, sel ?? notes.toSet(), steps: 16);

void ends(List<PitchNote> notes, List<List<double>> expected) {
  expect(notes.length, expected.length);
  for (var i = 0; i < notes.length; i++) {
    expect(notes[i].startSteps, closeTo(expected[i][0], 1e-9));
    expect(notes[i].endSteps, closeTo(expected[i][1], 1e-9));
  }
}

void main() {
  test('monophonic line', () {
    ends(legato([span(60, 0, 1), span(62, 4, 5), span(64, 6, 6.5)]), [
      [0, 4],
      [4, 6],
      [6, 16],
    ]);
  });

  test('shortens an overlapping note', () {
    ends(legato([span(60, 0, 8), span(62, 2, 3)]), [
      [0, 2],
      [2, 16],
    ]);
  });

  test('chords extend as blocks', () {
    ends(
      legato([
        span(60, 0, 1),
        span(64, 0, 1),
        span(67, 0, 1),
        span(65, 8, 9),
        span(69, 8, 9),
      ]),
      [
        [0, 8],
        [0, 8],
        [0, 8],
        [8, 16],
        [8, 16],
      ],
    );
  });

  test('unselected notes are ignored', () {
    final a = span(60, 0, 1), b = span(62, 4, 5);
    final out = legato([a, b], {a});
    ends(out, [
      [0, 16],
      [4, 5],
    ]);
    expect(out[1], same(b));
  });

  test('a locked note is a target but keeps its length', () {
    final a = span(60, 0, 1), l = span(62, 4, 5, locked: true);
    final out = legato([a, l]);
    ends(out, [
      [0, 4],
      [4, 5],
    ]);
    expect(out[1], same(l));
  });

  test('muted notes are resized but are not targets', () {
    ends(
      legato([span(60, 0, 1), span(62, 4, 5, muted: true), span(64, 8, 9)]),
      [
        [0, 8],
        [4, 8],
        [8, 16],
      ],
    );
  });

  test('a precise start is kept', () {
    final out = legato([span(60, .25, 1), span(62, 2.5, 3)]);
    expect(out[0].step, 0);
    expect(out[0].offsetSteps, .25);
    expect(out[0].soundingSteps, closeTo(2.25, 1e-9));
  });

  test('already legato returns the input list', () {
    final notes = [span(60, 0, 4), span(62, 4, 16)];
    expect(legato(notes), same(notes));
  });

  test('pitch, velocity and metadata are unchanged', () {
    final a = span(60, 0, 1).copyWith(
      velocity: 33,
      sourceMidi: 59,
      confidence: .4,
      assisted: true,
      muted: true,
      chance: .3,
      velocityDeviation: 9,
    );
    final out = legato([a]).single;
    expect(out.midi, 60);
    expect(out.velocity, 33);
    expect(out.sourceMidi, 59);
    expect(out.confidence, .4);
    expect(out.assisted, isTrue);
    expect(out.muted, isTrue);
    expect(out.chance, .3);
    expect(out.velocityDeviation, 9);
  });

  testWidgets('Ctrl+L applies legato to the whole track in one commit', (
    tester,
  ) async {
    final key = await mountGrid(tester, [span(60, 0, 1), span(62, 3, 4)]);
    await tester.tapAt(gridPoint(tester, 7.5, 64));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(state.notes.map((n) => n.endSteps), [3, 8]);
  });
}
