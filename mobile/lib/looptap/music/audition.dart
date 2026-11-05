import '../models/loop_models.dart';

/// Temporary listening controls. Neither Solo nor the playback range changes
/// song content, saved mutes, or the export mix.
bool trackIsAudible(
  String id,
  Map<String, bool> mutes,
  Set<String> solos, {
  bool bypassSolo = false,
}) =>
    !(mutes[id] ?? false) &&
    (bypassSolo || solos.isEmpty || solos.contains(id));

/// Half-open step interval; the end belongs to the next pass, never this one.
class PlaybackRange {
  const PlaybackRange(this.start, this.end)
    : assert(start >= 0),
      assert(end > start);

  final int start, end;
  int get length => end - start;
  double position(num absolute) =>
      (start + (absolute - start) % length).toDouble();
  bool contains(num step) => step >= start && step < end;

  PlaybackRange bounded(int steps) {
    final a = start.clamp(0, steps - 1);
    return PlaybackRange(a, end.clamp(a + 1, steps));
  }

  /// Do not let a delayed attack or sustained gate leak into the next pass.
  double gateSeconds(double atStep, double duration, double secondsPerStep) =>
      contains(atStep) ? duration.clamp(0, (end - atStep) * secondsPerStep) : 0;
}

/// Notes already held at a seek/loop start, with their remaining gates clipped
/// to the audition boundary. [before] excludes attacks triggered normally by
/// the first step, even when the frame arrives a little late.
Iterable<({PitchNote note, double steps})> chasedPitchGates(
  Iterable<PitchNote> notes,
  PlaybackRange range,
  double position, {
  double? before,
}) sync* {
  if (!range.contains(position)) return;
  for (final n in notes) {
    if (n.startSteps >= (before ?? position) || n.endSteps <= position) {
      continue;
    }
    final end = n.endSteps < range.end ? n.endSteps : range.end.toDouble();
    yield (note: n, steps: end - position);
  }
}
