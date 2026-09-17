import '../models/loop_models.dart';
import 'theory.dart';

enum BackingStyle { calm, bounce, drive }

/// Deterministic, in-key bass + drums. All original sections/tracks stay intact;
/// only the returned copy's bass and drums are replaced.
Section withBeginnerBacking(
  Section source,
  String tonic,
  String scale,
  BackingStyle style,
) {
  final out = source.deepCopy();
  final bass = <PitchNote>[];
  final drums = <DrumNote>[];
  final allowed = (kScales[scale] ?? kScales['minor']!).steps;
  final root = rootMidi(tonic, 2);
  final melody = source.tracks['melody']?.pitchNotes ?? [];
  for (var bar = 0; bar < source.bars; bar++) {
    final start = bar * 16;
    final notes =
        melody.where((n) => n.step >= start && n.step < start + 16).toList()
          ..sort((a, b) => a.step.compareTo(b.step));
    final pc = notes.isEmpty ? root % 12 : notes.first.midi % 12;
    final degree = (pc - root % 12 + 12) % 12;
    final midi = root + (allowed.contains(degree) ? degree : 0);
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
  out.tracks['drums'] = TrackData(drums: drums);
  return out;
}
