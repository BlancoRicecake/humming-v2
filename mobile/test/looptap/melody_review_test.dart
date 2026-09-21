import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/melody_review.dart';
import 'package:humming/looptap/music/theory.dart';

PitchNote note(int midi, int step, int dur, {double confidence = 1}) =>
    PitchNote(
      midi: midi,
      freq: midiToFreq(midi),
      step: step,
      dur: dur,
      confidence: confidence,
    );

void main() {
  test('finds only uncertain notes and shifts a single octave reversibly', () {
    final notes = [note(60, 0, 2), note(61, 2, 2, confidence: .4)];
    expect(uncertainNoteIndices(notes), [1]);
    final shifted = shiftNoteOctave(notes, 1, 1);
    expect(shifted.map((n) => n.midi), [60, 73]);
    expect(notes[1].midi, 61);
  });

  test('split preserves duration and merge rejoins adjacent near pitches', () {
    final notes = [note(60, 0, 4), note(61, 4, 2)];
    final split = splitNoteAtMidpoint(notes, 0);
    expect(split.map((n) => (n.step, n.dur)), [(0, 2), (2, 2), (4, 2)]);
    final merged = mergeWithNext(notes, 0);
    expect(merged, hasLength(1));
    expect((merged.single.step, merged.single.dur), (0, 6));
  });
}
