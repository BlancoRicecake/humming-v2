// piano-roll-002: Fit to scale / Scale snap. docs/specs/piano-roll/pr-002-scale-snap.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/state/loop_prefs.dart';

import '../support/step_grid_harness.dart';

PitchNote n(
  int midi, {
  int step = 0,
  int? sourceMidi,
  bool locked = false,
  bool muted = false,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: 2,
  offsetSteps: .25,
  durationSteps: 1.5,
  velocity: 70,
  sourceMidi: sourceMidi,
  locked: locked,
  muted: muted,
);

List<PitchNote> fit(List<PitchNote> notes, [String root = 'A', String s = 'minor']) =>
    fitPitchNotesToScale(notes, notes.toSet(), root, s);

void main() {
  test('A minor: G#4 -> G4 (tie goes down) with provenance', () {
    final out = fit([n(68)]).single;
    expect(out.midi, 67);
    expect(out.sourceMidi, 68);
    expect(out.assisted, isTrue);
    expect(out.freq, midiToFreq(67));
  });

  test('A minor: A#4 -> A4 and C#5 -> C5', () {
    expect(fit([n(70), n(73)]).map((x) => x.midi), [69, 72]);
  });

  test('in-scale notes keep identity', () {
    final a = n(69);
    final out = fit([a, n(68)]);
    expect(out[0], same(a));
    final only = [a];
    expect(fit(only), same(only));
  });

  test('C minor pentatonic ties and directions', () {
    expect(
      fit([n(61), n(62), n(71)], 'C', 'pentatonic').map((x) => x.midi),
      [60, 63, 70],
    );
  });

  test('an existing sourceMidi is kept', () {
    final out = fit([n(68, sourceMidi: 66)]).single;
    expect(out.midi, 67);
    expect(out.sourceMidi, 66);
  });

  test('locked notes are not fitted', () {
    final l = n(68, locked: true);
    expect(fit([l]).single, same(l));
  });

  test('chromatic scale returns the input list', () {
    final notes = [n(68), n(61)];
    expect(fit(notes, 'A', 'chromatic'), same(notes));
  });

  test('range edge: midi 0 in D major moves up to C#', () {
    expect(fit([n(0)], 'D', 'major').single.midi, 1);
  });

  test('movePitchNotesInScale steps to the next scale pitch', () {
    final notes = [n(69), n(72)];
    final out = movePitchNotesInScale(
      notes,
      notes.toSet(),
      root: 'A',
      scale: 'minor',
      dir: 1,
    );
    expect(out.map((x) => x.midi), [71, 74]);
    final down = movePitchNotesInScale(
      notes,
      notes.toSet(),
      root: 'A',
      scale: 'minor',
      dir: -1,
    );
    expect(down.map((x) => x.midi), [67, 71]);
    // any note leaving 0..127 rejects the whole move
    final top = [n(127), n(60)];
    expect(
      movePitchNotesInScale(
        top,
        top.toSet(),
        root: 'C',
        scale: 'chromatic',
        dir: 1,
      ),
      same(top),
    );
  });

  test('timing, velocity and mute state are unchanged', () {
    final src = n(68, step: 3, muted: true);
    for (final out in [
      fit([src]).single,
      movePitchNotesInScale(
        [src],
        {src},
        root: 'A',
        scale: 'minor',
        dir: 1,
      ).single,
    ]) {
      expect(out.step, 3);
      expect(out.offsetSteps, .25);
      expect(out.durationSteps, 1.5);
      expect(out.dur, 2);
      expect(out.velocity, 70);
      expect(out.muted, isTrue);
    }
  });

  group('StepGrid', () {
    setUp(() => LoopPrefs.instance.scaleSnap.value = false);
    tearDown(() => LoopPrefs.instance.scaleSnap.value = false);

    testWidgets('K fits the whole track when nothing is selected', (
      tester,
    ) async {
      // C major: 61 (C#) -> 60, 63 (D#) -> 62
      final key = await mountGrid(
        tester,
        [n(61, step: 1), n(63, step: 4)],
        scaleRoot: 'C',
        scaleName: 'major',
      );
      await tester.tapAt(gridPoint(tester, 7.5, 64)); // empty: focus, no selection
      await tester.pump();
      await _ctrl(tester, LogicalKeyboardKey.keyK);
      await tester.pump();
      final state = key.currentState!;
      expect(state.commits, 1);
      expect(state.notes.map((x) => x.midi), [60, 62]);
      // nothing left to fit: no further commit
      await _ctrl(tester, LogicalKeyboardKey.keyK);
      await tester.pump();
      expect(state.commits, 1);
    });

    testWidgets('Fit to scale is disabled for a chromatic song', (
      tester,
    ) async {
      await mountGrid(
        tester,
        [n(61)],
        scaleRoot: 'C',
        scaleName: 'chromatic',
      );
      final button = tester.widget<TextButton>(
        find.byKey(const ValueKey('note-fit-scale')),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('Scale snap: arrow keys step by scale, drawing snaps', (
      tester,
    ) async {
      final key = await mountGrid(
        tester,
        [n(60, step: 1)],
        scaleRoot: 'C',
        scaleName: 'major',
      );
      await tapGridButton(tester, 'note-scale-snap');
      expect(LoopPrefs.instance.scaleSnap.value, isTrue);
      await tester.tapAt(gridPoint(tester, 1.8, 60));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      final state = key.currentState!;
      expect(state.notes.single.midi, 62); // C -> D, skipping C#
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(state.notes.single.midi, 64); // D -> E
      expect(state.commits, 2);
      // Shift+arrow still moves an octave
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(state.notes.single.midi, 52);
      // Draw mode: tapping the C# row places on C
      await tapGridButton(tester, 'note-draw');
      await tester.tapAt(gridPoint(tester, 5.5, 61));
      await tester.pumpAndSettle();
      expect(state.placed.map((p) => p.$1), [60]);
    });
  });
}

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
}
