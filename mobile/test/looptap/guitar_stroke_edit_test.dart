// gt-001 decision after implementation (lead, 2026-10-22): pitch-only edits
// keep a guitar stroke tag; timing and velocity edits drop it. A note that
// lost its tag keeps its explicit velocity and durationSteps, so the legacy
// auto strum never re-applies.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/pitch_clipboard.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

import '../support/midi_events.dart';
import '../support/step_grid_harness.dart';

PitchNote at(int midi, int step, {int dur = 2}) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

List<PitchNote> converted([int step = 0]) => applyGuitarStroke(
  [for (final m in [60, 62, 64]) at(m, step)],
  {},
  const StrokeSpec.down(),
  bpm: 120,
).notes;

/// Every note dropped its tag, keeps an explicit velocity and length, and
/// the legacy strum does not run (live predicate and MIDI export).
void expectDroppedSafely(List<PitchNote> notes) {
  expect(notes.every((x) => x.stroke == null), isTrue, reason: 'tag dropped');
  expect(
    notes.every((x) => x.velocity != null && x.durationSteps != null),
    isTrue,
    reason: 'explicit velocity + durationSteps kept',
  );
  for (final step in {for (final x in notes) x.step}) {
    expect(
      liveLegacyStrum(
        notes.where((x) => x.step == step).toList(),
        guitar: true,
      ),
      isNull,
    );
  }
  final s = Section(id: 's', name: 's', bars: 1)
    ..tracks['melody'] = TrackData(notes: notes);
  final read = readNoteOns(
    buildMidi(flattenSong([s]), 120, melodyProgram: 25),
  );
  final tps = read.tpq / kStepsPerBeat;
  expect(
    {for (final e in read.ons) (e.pitch, e.tick, e.velocity)},
    {for (final x in notes) (x.midi, (x.startSteps * tps).round(), x.velocity)},
    reason: 'export plays the note data, no legacy strum on top',
  );
}

void main() {
  late List<PitchNote> src;
  late Set<PitchNote> all;
  setUp(() {
    src = converted();
    all = src.toSet();
    expect(src.every((x) => x.stroke != null), isTrue);
  });

  group('timing and velocity edits drop the tag', () {
    test('a time-axis move (whole step) drops it', () {
      expectDroppedSafely(
        movePitchNotes(src, all, deltaSteps: 2, semitones: 0, steps: 16),
      );
    });

    test('a fractional nudge drops it', () {
      expectDroppedSafely(
        movePitchNotes(src, all, deltaSteps: .1, semitones: 0, steps: 16),
      );
    });

    test('a combined time + pitch move drops it', () {
      expectDroppedSafely(
        movePitchNotes(src, all, deltaSteps: 1, semitones: 2, steps: 16),
      );
    });

    test('resize drops it', () {
      expectDroppedSafely(
        resizePitchNotes(src, all, deltaSteps: 1, steps: 16),
      );
      expectDroppedSafely(
        resizePitchNotes(src, all, deltaSteps: -.5, steps: 16),
      );
    });

    test('velocity lane drag (relative) drops it', () {
      expectDroppedSafely(shiftPitchVelocities(src, all, -10));
    });

    test('velocity set (slider / ±) drops it', () {
      expectDroppedSafely(setPitchVelocity(src, all, 64));
    });

    test('humanize (timing only) drops it', () {
      // chord away from the loop start so no move is clamped to a no-op
      final mid = converted(4);
      expectDroppedSafely(
        humanizePitchNotes(
          mid,
          mid.toSet(),
          timingSteps: .3,
          velocityRange: 0,
          seed: 11,
          steps: 16,
        ),
      );
    });

    test('only the edited notes drop; unselected keep their tag', () {
      final first = src.first;
      final out = shiftPitchVelocities(src, {first}, 5);
      expect(out.first.stroke, isNull);
      expect(out.skip(1).every((x) => x.stroke != null), isTrue);
      final moved = movePitchNotes(
        src,
        {first},
        deltaSteps: 1,
        semitones: 0,
        steps: 16,
      );
      expect(moved.first.stroke, isNull);
      expect(identical(moved[1], src[1]), isTrue);
    });

    test('a no-op velocity edit keeps the note (and its tag)', () {
      final same = setPitchVelocity(src, {src.first}, src.first.velocity!);
      expect(identical(same, src), isTrue);
    });
  });

  group('pitch-only edits keep the tag', () {
    test('transpose, octave, scale snap, fit to scale, mute', () {
      for (final out in [
        movePitchNotes(src, all, deltaSteps: 0, semitones: 1, steps: 16),
        movePitchNotes(src, all, deltaSteps: 0, semitones: -12, steps: 16),
        movePitchNotesInScale(src, all, root: 'C', scale: 'major', dir: 1),
        fitPitchNotesToScale(src, all, 'C', 'pentatonic'),
        setPitchNotesMuted(src, all, true),
      ]) {
        expect(out, isNot(same(src)));
        expect(
          [for (final x in out) x.stroke],
          [for (final x in src) x.stroke],
        );
      }
    });

    test('duplicate and copy/paste keep it (relative base stays valid)', () {
      final dup = duplicatePitchNotes(src, all, 16);
      expect(dup.skip(3).map((x) => x.stroke), src.map((x) => x.stroke));
      final pasted = (PitchClipboard()..copy(src)).paste(atStep: 8, steps: 16);
      expect(pasted.map((x) => x.stroke), src.map((x) => x.stroke));
    });
  });

  group('editor gestures', () {
    Future<void> selectAll(WidgetTester tester) async {
      await tester.tapAt(gridPoint(tester, .5, 60));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    testWidgets('→ nudge drops, ♯ keeps', (tester) async {
      final key = await mountGrid(tester, converted(), guitar: true);
      await selectAll(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // semitone
      await tester.pump();
      final state = key.currentState!;
      expect(state.commits, 1);
      expect(state.notes.every((x) => x.stroke != null), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // time nudge
      await tester.pump();
      expect(state.commits, 2);
      expectDroppedSafely(state.notes);
    });

    testWidgets('length ± button drops', (tester) async {
      final key = await mountGrid(tester, converted(), guitar: true);
      await selectAll(tester);
      await tapGridButton(tester, 'note-length-up');
      expectDroppedSafely(key.currentState!.notes);
    });

    testWidgets('velocity slider drops', (tester) async {
      final key = await mountGrid(tester, converted(), guitar: true);
      await selectAll(tester);
      final slider = find.byKey(const ValueKey('note-velocity'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      await tester.drag(slider, const Offset(-30, 0));
      await tester.pumpAndSettle();
      expect(key.currentState!.commits, 1);
      expectDroppedSafely(key.currentState!.notes);
    });
  });
}
