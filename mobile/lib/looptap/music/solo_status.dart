import '../models/loop_models.dart';
import 'audition.dart';
import 'theory.dart';

enum SoloIssue { muted, zeroVolume, noNotes, veryQuiet }

class SoloStatus {
  const SoloStatus(
    this.id,
    this.label,
    this.issue, {
    this.minVelocity,
    this.maxVelocity,
  });
  final String id, label;
  final SoloIssue issue;
  final int? minVelocity, maxVelocity;
}

/// Content-based listening hints, not a claim that the sound device is silent.
/// Sustained notes crossing the range start count; its end is exclusive.
/// Unspecified legacy velocity uses the normal default and is never "quiet".
List<SoloStatus> soloIssues({
  required Map<String, TrackData> tracks,
  required Iterable<TrackMeta> metas,
  required Set<String> solos,
  required Map<String, bool> mutes,
  required Map<String, double> volumes,
  required PlaybackRange range,
  required int steps,
  bool bypass = false,
}) {
  if (bypass || solos.isEmpty) return [];
  final issues = <SoloStatus>[];
  for (final meta in metas.where((m) => solos.contains(m.id))) {
    final data = tracks[meta.id];
    final label = data?.label ?? meta.label;
    if (mutes[meta.id] ?? false) {
      issues.add(SoloStatus(meta.id, label, SoloIssue.muted));
      continue;
    }
    if ((volumes[meta.id] ?? .85) <= 0) {
      issues.add(SoloStatus(meta.id, label, SoloIssue.zeroVolume));
      continue;
    }
    final strengths = <int>[];
    var hasAudio = false;
    if (data != null) {
      if (meta.kind == TrackKind.vocal) {
        hasAudio = data.effectiveClips.any(
          (c) =>
              c.startStep < range.end &&
              c.startStep +
                      (c.durSteps > 0 ? c.durSteps : steps - c.startStep) >
                  range.start,
        );
      } else if (meta.kind == TrackKind.drums) {
        strengths.addAll(
          data.drumNotes
              .where((n) => range.contains(n.step + n.offsetSteps))
              .map((n) => n.velocity ?? 100),
        );
      } else {
        strengths.addAll(
          data.pitchNotes
              .where(
                (n) => n.startSteps < range.end && n.endSteps > range.start,
              )
              .map((n) => n.velocity ?? 100),
        );
      }
    }
    if (strengths.isEmpty && !hasAudio) {
      issues.add(SoloStatus(meta.id, label, SoloIssue.noNotes));
    } else if (strengths.isNotEmpty && strengths.every((v) => v <= 8)) {
      strengths.sort();
      issues.add(
        SoloStatus(
          meta.id,
          label,
          SoloIssue.veryQuiet,
          minVelocity: strengths.first,
          maxVelocity: strengths.last,
        ),
      );
    }
  }
  return issues;
}
