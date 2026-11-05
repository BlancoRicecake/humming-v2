// piano-roll-006: humanize. docs/specs/piano-roll/pr-006-humanize.md
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/note_random.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/state/loop_prefs.dart';

import '../support/step_grid_harness.dart';

PitchNote at(int midi, int step, {int? velocity, bool locked = false}) =>
    PitchNote(
      midi: midi,
      freq: midiToFreq(midi),
      step: step,
      dur: 1,
      velocity: velocity,
      sourceMidi: midi - 2,
      confidence: .8,
      assisted: true,
      locked: locked,
    );

List<PitchNote> eight() => [
  for (var i = 0; i < 8; i++) at(60 + i % 3, i * 2, velocity: 64 + i),
];

List<PitchNote> hum(
  List<PitchNote> notes, {
  double timing = .1,
  int velocity = 10,
  int seed = 42,
  int steps = 16,
  Set<PitchNote>? selected,
}) => humanizePitchNotes(
  notes,
  selected ?? notes.toSet(),
  timingSteps: timing,
  velocityRange: velocity,
  seed: seed,
  steps: steps,
);

List<(int, double, int?)> sig(List<PitchNote> notes) => [
  for (final n in notes) (n.step, n.offsetSteps, n.velocity),
];

void main() {
  test('HumRng: xorshift32 reference value and seed-0 substitution', () {
    expect(HumRng(1).nextUint32(), 270369);
    final a = HumRng(0), b = HumRng(0x9E3779B9);
    for (var i = 0; i < 20; i++) {
      expect(a.nextUint32(), b.nextUint32());
    }
    final r = HumRng(7);
    for (var i = 0; i < 1000; i++) {
      final u = r.nextDouble();
      expect(u, inInclusiveRange(0, 1));
      expect(u, lessThan(1));
    }
  });

  test('same input and seed give the same result', () {
    final notes = eight();
    expect(sig(hum(notes)), sig(hum(notes)));
  });

  test('a different seed changes at least one note', () {
    final notes = eight();
    expect(sig(hum(notes, seed: 1)), isNot(sig(hum(notes, seed: 2))));
  });

  test('changes stay within the ranges', () {
    final notes = eight();
    for (var seed = 0; seed < 50; seed++) {
      final out = hum(notes, timing: .1, velocity: 10, seed: seed);
      for (var i = 0; i < notes.length; i++) {
        expect(
          (out[i].startSteps - notes[i].startSteps).abs(),
          lessThanOrEqualTo(.1 + 1e-9),
        );
        expect(
          (out[i].velocity! - notes[i].velocity!).abs(),
          lessThanOrEqualTo(10),
        );
      }
    }
  });

  test('timing 0 keeps starts; velocities do not depend on timing', () {
    final notes = eight();
    final velOnly = hum(notes, timing: 0, velocity: 10, seed: 9);
    for (var i = 0; i < notes.length; i++) {
      expect(velOnly[i].startSteps, notes[i].startSteps);
    }
    expect(velOnly.map((n) => n.velocity), isNot(notes.map((n) => n.velocity)));
    final both = hum(notes, timing: .1, velocity: 10, seed: 9);
    expect(both.map((n) => n.velocity), velOnly.map((n) => n.velocity));
  });

  test('velocity 0 keeps default (null) velocity', () {
    final notes = [at(60, 2), at(62, 6)];
    final out = hum(notes, timing: .3, velocity: 0);
    expect(out.map((n) => n.velocity), [null, null]);
  });

  test('a note at the loop end is clamped inside', () {
    // find a seed whose first timing draw is positive
    var seed = 1;
    while (HumRng(seed).nextDouble() <= .5) {
      seed++;
    }
    final out = hum([at(60, 15)], timing: .5, velocity: 0, seed: seed);
    expect(out.single.startSteps, 15.0);
    expect(out.single.endSteps, 16.0);
  });

  test('locked notes are skipped and do not consume randomness', () {
    final notes = eight();
    final locked = at(64, 5, velocity: 90, locked: true);
    final withLocked = hum([...notes, locked], seed: 5);
    expect(withLocked.last, same(locked));
    expect(sig(withLocked.take(8).toList()), sig(hum(notes, seed: 5)));
  });

  test('pitch, length and metadata are unchanged', () {
    final notes = [for (final n in eight()) n.copyWith(muted: true)];
    final out = hum(notes, timing: .5, velocity: 40, seed: 3);
    for (var i = 0; i < notes.length; i++) {
      expect(out[i].midi, notes[i].midi);
      expect(out[i].soundingSteps, closeTo(notes[i].soundingSteps, 1e-9));
      expect(out[i].sourceMidi, notes[i].sourceMidi);
      expect(out[i].confidence, notes[i].confidence);
      expect(out[i].assisted, notes[i].assisted);
      expect(out[i].muted, isTrue);
    }
  });

  test('both ranges 0 returns the input list', () {
    final notes = eight();
    expect(hum(notes, timing: 0, velocity: 0), same(notes));
  });

  testWidgets('H humanizes the track with one commit', (tester) async {
    LoopPrefs.instance.humanizeTiming.value = .5;
    LoopPrefs.instance.humanizeVelocity.value = 40;
    final notes = [at(60, 1, velocity: 60), at(62, 3, velocity: 60)];
    final key = await mountGrid(tester, notes);
    await tester.tapAt(gridPoint(tester, 7.5, 64));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(sig(state.notes), isNot(sig(notes)));
    LoopPrefs.instance.humanizeTiming.value = .1;
    LoopPrefs.instance.humanizeVelocity.value = 10;
  });
}
