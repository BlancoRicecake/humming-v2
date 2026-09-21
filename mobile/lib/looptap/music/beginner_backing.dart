import '../models/loop_models.dart';
import 'theory.dart';

enum BackingStyle { calm, bounce, drive }

/// Three intentionally small harmonic choices. They are deterministic so a
/// beginner can compare them and undo them; the user's melody is never changed.
List<List<int>> backingChordCandidates(BackingStyle style) => switch (style) {
  BackingStyle.calm => const [
    [0, 5, 3, 4], // I–vi–IV–V
    [0, 3, 5, 4], // I–IV–vi–V
    [0, 4, 5, 3], // I–V–vi–IV
  ],
  BackingStyle.bounce => const [
    [0, 4, 5, 3],
    [0, 3, 0, 4],
    [5, 3, 0, 4],
  ],
  BackingStyle.drive => const [
    [0, 5, 3, 4],
    [0, 4, 3, 5],
    [5, 3, 0, 4],
  ],
};

/// Deterministic, in-key bass + drums. All original sections/tracks stay intact;
/// only the returned copy's bass and drums are replaced.
Section withBeginnerBacking(
  Section source,
  String tonic,
  String scale,
  BackingStyle style, {
  int chordVariant = 0,
  bool melodyLocked = true,
}) {
  final out = source.deepCopy();
  final bass = <PitchNote>[];
  final chords = <PitchNote>[];
  final drums = <DrumNote>[];
  final allowed = (kScales[scale] ?? kScales['minor']!).steps;
  final root = rootMidi(tonic, 2);
  final chordRoot = rootMidi(tonic, 4);
  final progression = backingChordCandidates(style)[chordVariant.clamp(0, 2)];
  final melody = source.tracks['melody']?.pitchNotes ?? [];
  for (var bar = 0; bar < source.bars; bar++) {
    final start = bar * 16;
    final notes =
        melody.where((n) => n.step >= start && n.step < start + 16).toList()
          ..sort((a, b) => a.step.compareTo(b.step));
    final progressionDegree = progression[bar % progression.length];
    final progressionStep = allowed[progressionDegree % allowed.length];
    final pc = notes.isEmpty ? progressionStep : (notes.first.midi - root) % 12;
    final degree = allowed.contains(pc) ? pc : progressionStep;
    final midi = root + degree;
    for (final offset
        in (style == BackingStyle.calm ? [0, 8] : [0, 6, 8, 14])) {
      bass.add(
        PitchNote(
          midi: midi,
          freq: midiToFreq(midi),
          step: start + offset,
          dur: style == BackingStyle.calm ? 6 : 2,
        ),
      );
    }
    final degreeIndex = allowed.indexOf(progressionStep);
    final safeIndex = degreeIndex < 0 ? 0 : degreeIndex;
    for (final offset in const [0, 2, 4]) {
      final scaleStep = allowed[(safeIndex + offset) % allowed.length];
      final octave = (safeIndex + offset) ~/ allowed.length;
      final chordMidi = chordRoot + scaleStep + octave * 12;
      chords.add(
        PitchNote(
          midi: chordMidi,
          freq: midiToFreq(chordMidi),
          step: start,
          dur: 16,
          locked: false,
        ),
      );
    }
    for (final offset
        in (style == BackingStyle.drive ? [0, 4, 8, 12] : [0, 8])) {
      drums.add(DrumNote(kind: 'kick', step: start + offset));
    }
    for (final offset in [4, 12]) {
      drums.add(DrumNote(kind: 'snare', step: start + offset));
    }
    for (
      var offset = 0;
      offset < 16;
      offset += style == BackingStyle.calm ? 4 : 2
    ) {
      drums.add(DrumNote(kind: 'hihat', step: start + offset));
    }
  }
  out.tracks['bass'] = TrackData(notes: bass);
  out.tracks['melodyDec'] = TrackData(notes: chords);
  out.tracks['drums'] = TrackData(drums: drums);
  // Defensive invariant: even a future backing implementation must not mutate
  // or replace the user's melody when it is locked.
  if (melodyLocked) {
    out.tracks['melody'] = source.tracks['melody']!.deepCopy();
  }
  return out;
}
