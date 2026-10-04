import '../models/loop_models.dart';
import 'theory.dart';

const double kLowMelodyConfidence = 0.62;

List<int> uncertainNoteIndices(
  List<PitchNote> notes, {
  double threshold = kLowMelodyConfidence,
}) => [
  for (var i = 0; i < notes.length; i++)
    if (notes[i].confidence < threshold) i,
];

List<PitchNote> shiftNoteOctave(List<PitchNote> notes, int index, int octaves) {
  if (index < 0 || index >= notes.length || octaves == 0) return [...notes];
  final out = [...notes];
  final note = out[index];
  final midi = (note.midi + octaves * 12).clamp(0, 127);
  out[index] = note.copyWith(
    midi: midi,
    freq: midiToFreq(midi),
    assisted: true,
  );
  return out;
}

List<PitchNote> splitNoteAtMidpoint(List<PitchNote> notes, int index) {
  if (index < 0 || index >= notes.length) return [...notes];
  final note = notes[index];
  if (note.dur < 2) return [...notes];
  final left = note.dur ~/ 2;
  final out = [...notes]..removeAt(index);
  out.insertAll(index, [
    note.copyWith(dur: left),
    note.copyWith(step: note.step + left, dur: note.dur - left),
  ]);
  return out;
}

List<PitchNote> mergeWithNext(List<PitchNote> notes, int index) {
  if (index < 0 || index + 1 >= notes.length) return [...notes];
  final sorted = [...notes]..sort((a, b) => a.step.compareTo(b.step));
  final target = notes[index];
  final sortedIndex = sorted.indexOf(target);
  if (sortedIndex < 0 || sortedIndex + 1 >= sorted.length) return [...notes];
  final next = sorted[sortedIndex + 1];
  final gap = next.step - (target.step + target.dur);
  if (gap > 1 || (target.midi - next.midi).abs() > 1) return [...notes];
  final targetEnd = target.step + target.dur;
  final nextEnd = next.step + next.dur;
  final end = targetEnd > nextEnd ? targetEnd : nextEnd;
  final merged = target.copyWith(dur: end - target.step, assisted: true);
  return [
    for (final note in notes)
      if (identical(note, target)) merged else if (!identical(note, next)) note,
  ];
}
