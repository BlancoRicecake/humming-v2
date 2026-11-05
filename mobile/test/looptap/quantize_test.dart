// piano-roll-003: quantize with grid and strength.
// docs/specs/piano-roll/pr-003-quantize-strength.md
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/state/loop_prefs.dart';

import '../support/step_grid_harness.dart';

PitchNote span(double start, double end, {int midi = 60, bool locked = false}) {
  final step = start.floor();
  return PitchNote(
    midi: midi,
    freq: midiToFreq(midi),
    step: step,
    dur: math.max(1, (end - start).ceil()),
    offsetSteps: start - step,
    durationSteps: end - start,
    velocity: 88,
    sourceMidi: midi + 1,
    confidence: .5,
    assisted: true,
    locked: locked,
  );
}

List<PitchNote> q(
  List<PitchNote> notes, {
  required double grid,
  double strength = 1,
  bool ends = false,
  int steps = 32,
}) => quantizePitchNotes(
  notes,
  notes.toSet(),
  grid: grid,
  strength: strength,
  ends: ends,
  steps: steps,
);

void bounds(PitchNote n, double start, double end, [double tol = 1e-9]) {
  expect(n.startSteps, closeTo(start, tol));
  expect(n.endSteps, closeTo(end, tol));
}

void main() {
  test('1/16, 100%: (2.3, 3.3) -> (2.0, 3.0)', () {
    final n = q([span(2.3, 3.3)], grid: 1).single;
    bounds(n, 2, 3);
    expect(n.step, 2);
    expect(n.offsetSteps, 0);
    expect(n.dur, 1);
    expect(n.soundingSteps, 1.0);
  });

  test('plain note at 3, 1/8 -> 4 (midpoint goes later), stays plain', () {
    final plain = PitchNote(midi: 60, freq: midiToFreq(60), step: 3, dur: 2);
    final n = q([plain], grid: 2).single;
    bounds(n, 4, 6);
    expect(n.offsetSteps, 0);
    expect(n.durationSteps, isNull);
  });

  test('1/16, 50%: (2.4, 3.4) -> (2.2, 3.2)', () {
    final n = q([span(2.4, 3.4)], grid: 1, strength: .5).single;
    bounds(n, 2.2, 3.2, 1e-9);
    expect(n.step, 2);
    expect(n.offsetSteps, closeTo(.2, 1e-9));
    expect(n.durationSteps, closeTo(1.0, 1e-9));
  });

  test('ends on: (2.3, 4.6) -> (2.0, 5.0)', () {
    bounds(q([span(2.3, 4.6)], grid: 1, ends: true).single, 2, 5);
  });

  test('ends on, short note: end never collapses onto the start line', () {
    bounds(q([span(2.1, 2.3)], grid: 1, ends: true).single, 2, 3);
  });

  test('midpoint goes to the later line: 1/8 (1.0, 2.0) -> (2.0, 3.0)', () {
    bounds(q([span(1, 2)], grid: 2).single, 2, 3);
  });

  test('1/16T: (0.8, 1.3) -> (2/3, 7/6)', () {
    final n = q([span(.8, 1.3)], grid: QuantizeGrid.sixteenthTriplet.steps);
    bounds(n.single, 2 / 3, 7 / 6);
  });

  test('a start target at the loop end falls back to the last line', () {
    bounds(q([span(31, 32)], grid: 4).single, 28, 29);
  });

  test('an end past the loop is cut at steps', () {
    bounds(q([span(30.6, 32)], grid: 1).single, 31, 32);
  });

  test('locked notes keep identity and metadata never changes', () {
    final l = span(2.3, 3.3, locked: true);
    final m = span(2.3, 3.3, midi: 62).copyWith(muted: true);
    final out = q([l, m], grid: 1);
    expect(out[0], same(l));
    final n = out[1];
    expect(n.midi, 62);
    expect(n.velocity, 88);
    expect(n.sourceMidi, 63);
    expect(n.confidence, .5);
    expect(n.assisted, isTrue);
    expect(n.muted, isTrue);
  });

  test('strength 0 and on-grid notes return the input list', () {
    final notes = [span(2.3, 3.3)];
    expect(q(notes, grid: 1, strength: 0), same(notes));
    final onGrid = [span(2, 3), span(4, 6)];
    expect(q(onGrid, grid: 1), same(onGrid));
  });

  test('stacked same-pitch starts are counted, not merged', () {
    final out = q([span(1.9, 2.5), span(2.1, 2.6)], grid: 1);
    expect(out, hasLength(2));
    expect(stackedPitchNoteCount(out), 1);
  });

  group('StepGrid', () {
    setUp(() {
      final p = LoopPrefs.instance;
      p.quantizeGrid.value = 'sixteenth';
      p.quantizeStrength.value = 100;
      p.quantizeEnds.value = false;
    });

    testWidgets('Ctrl+U quantizes the whole track with one commit', (
      tester,
    ) async {
      final key = await mountGrid(tester, [span(1.3, 2.3), span(4.6, 5.1)]);
      await tester.tapAt(gridPoint(tester, 7.5, 64));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final state = key.currentState!;
      expect(state.commits, 1);
      expect(state.notes.map((n) => n.startSteps), [1, 5]);
    });

    testWidgets('settings sheet picks the grid and applies', (tester) async {
      final key = await mountGrid(tester, [span(1.3, 2.3)]);
      await tapGridButton(tester, 'note-quantize-settings');
      await tester.tap(find.byKey(const ValueKey('quantize-grid-eighth')));
      await tester.pumpAndSettle();
      expect(LoopPrefs.instance.quantizeGrid.value, 'eighth');
      await tester.tap(find.byKey(const ValueKey('quantize-apply')));
      await tester.pumpAndSettle();
      final state = key.currentState!;
      expect(state.commits, 1);
      expect(state.notes.single.startSteps, 2);
    });
  });
}
