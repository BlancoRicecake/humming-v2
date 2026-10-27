// piano-roll-004: split, chop and glue. docs/specs/piano-roll/pr-004-split-glue.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';

import '../support/step_grid_harness.dart';

PitchNote at(
  int midi,
  int step,
  int dur, {
  int? velocity,
  double confidence = 1,
  bool locked = false,
  bool muted = false,
  int? sourceMidi,
  bool assisted = false,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  velocity: velocity,
  confidence: confidence,
  locked: locked,
  muted: muted,
  sourceMidi: sourceMidi,
  assisted: assisted,
);

void bounds(PitchNote n, double start, double end) {
  expect(n.startSteps, closeTo(start, 1e-9));
  expect(n.endSteps, closeTo(end, 1e-9));
}

void inherits(PitchNote piece, PitchNote src) {
  expect(piece.midi, src.midi);
  expect(piece.freq, src.freq);
  expect(piece.velocity, src.velocity);
  expect(piece.sourceMidi, src.sourceMidi);
  expect(piece.confidence, src.confidence);
  expect(piece.assisted, src.assisted);
  expect(piece.muted, src.muted);
  expect(piece.chance, src.chance);
  expect(piece.velocityDeviation, src.velocityDeviation);
}

void main() {
  test('split at 2.0 keeps every attribute on both pieces', () {
    final a = at(
      60,
      0,
      4,
      velocity: 90,
      sourceMidi: 61,
      confidence: .7,
      assisted: true,
    );
    final r = splitPitchNotesAt([a], {a}, 2);
    expect(r.notes, hasLength(2));
    bounds(r.notes[0], 0, 2);
    bounds(r.notes[1], 2, 4);
    for (final p in r.notes) {
      inherits(p, a);
    }
    expect(r.notes[0].step, a.step);
    expect(r.notes[0].offsetSteps, a.offsetSteps);
    expect(r.selection, r.notes.toSet());
  });

  test('split keeps precise boundaries', () {
    final a = PitchNote(
      midi: 60,
      freq: midiToFreq(60),
      step: 1,
      dur: 3,
      offsetSteps: .25,
      durationSteps: 2.5,
    );
    final r = splitPitchNotesAt([a], {a}, 2);
    final (x, y) = (r.notes[0], r.notes[1]);
    expect([x.step, x.offsetSteps, x.durationSteps], [1, .25, .75]);
    expect([y.step, y.offsetSteps, y.durationSteps], [2, 0, 1.75]);
  });

  test('split outside or on a boundary is a no-op', () {
    final a = at(60, 0, 4);
    final notes = [a];
    for (final t in [-1.0, 0.0, 4.0, 5.0]) {
      expect(splitPitchNotesAt(notes, {a}, t).notes, same(notes));
    }
  });

  test('a piece shorter than 1/16 step is not created', () {
    final notes = [at(60, 0, 1)];
    expect(splitPitchNotesAt(notes, notes.toSet(), .03).notes, same(notes));
  });

  test('chop into 4 equal parts', () {
    final a = at(
      60,
      0,
      4,
      velocity: 50,
      muted: true,
    ).copyWith(chance: .4, velocityDeviation: -8);
    final r = chopPitchNotes([a], {a}, parts: 4);
    expect(r.notes, hasLength(4));
    for (var i = 0; i < 4; i++) {
      bounds(r.notes[i], i.toDouble(), i + 1.0);
      inherits(r.notes[i], a);
    }
  });

  test('chop on the absolute 1/8 grid', () {
    final a = at(60, 1, 5);
    final r = chopPitchNotes([a], {a}, grid: 2);
    expect(r.notes, hasLength(3));
    bounds(r.notes[0], 1, 2);
    bounds(r.notes[1], 2, 4);
    bounds(r.notes[2], 4, 6);
  });

  test('glue keeps the first note and the lowest confidence', () {
    final a = at(
      60,
      0,
      1,
      velocity: 80,
      confidence: .9,
    ).copyWith(chance: .7, velocityDeviation: 5);
    final b = PitchNote(
      midi: 60,
      freq: midiToFreq(60),
      step: 1,
      dur: 2,
      offsetSteps: .5,
      durationSteps: 1.5,
      velocity: 40,
      confidence: .5,
    );
    final r = gluePitchNotes([a, b], {a, b});
    final g = r.notes.single;
    bounds(g, 0, 3);
    expect(g.velocity, 80);
    expect(g.confidence, .5);
    expect(g.chance, .7);
    expect(g.velocityDeviation, 5);
    expect(r.selection, {g});
  });

  test('an unselected same-pitch note between them blocks glue', () {
    final a = at(60, 0, 1), c = at(60, 1, 1), b = at(60, 2, 1);
    final notes = [a, c, b];
    expect(gluePitchNotes(notes, {a, b}).notes, same(notes));
  });

  test('a locked note between them blocks glue and stays', () {
    final a = at(60, 0, 1), l = at(60, 1, 1, locked: true), b = at(60, 2, 1);
    final notes = [a, l, b];
    final r = gluePitchNotes(notes, {a, l, b});
    expect(r.notes, same(notes));
    expect(r.notes[1], same(l));
  });

  test('glue muted only when every glued note was muted', () {
    final a = at(60, 0, 1, muted: true), b = at(60, 1, 1);
    expect(gluePitchNotes([a, b], {a, b}).notes.single.muted, isFalse);
    final c = at(60, 0, 1, muted: true), d = at(60, 1, 1, muted: true);
    expect(gluePitchNotes([c, d], {c, d}).notes.single.muted, isTrue);
  });

  test('different pitches never glue', () {
    final a = at(60, 0, 1), b = at(62, 1, 1);
    final notes = [a, b];
    expect(gluePitchNotes(notes, {a, b}).notes, same(notes));
  });

  testWidgets('Ctrl+E splits at the playhead, Ctrl+J glues back', (
    tester,
  ) async {
    final key = await mountGrid(tester, [at(60, 0, 4)], playStep: 2);
    await tester.tapAt(gridPoint(tester, 1, 60));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(state.notes.map((n) => n.startSteps), [0, 2]);
    // both pieces stay selected, so glue joins them in one more commit
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(state.commits, 2);
    bounds(state.notes.single, 0, 4);
  });

  testWidgets('split sheet chops into equal parts', (tester) async {
    final key = await mountGrid(tester, [at(60, 0, 4)]);
    await tester.tapAt(gridPoint(tester, 1, 60));
    await tester.pump();
    await tapGridButton(tester, 'note-split');
    await tester.tap(find.byKey(const ValueKey('chop-parts-apply')));
    await tester.pumpAndSettle();
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(state.notes.map((n) => n.startSteps), [0, 2]);
  });
}
