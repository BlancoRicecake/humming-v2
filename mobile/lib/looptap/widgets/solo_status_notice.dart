import 'package:flutter/material.dart';
import '../music/solo_status.dart';
import '../theme/tokens.dart';

class SoloStatusNotice extends StatelessWidget {
  const SoloStatusNotice({
    super.key,
    required this.issues,
    this.onOpenVelocity,
  });
  final List<SoloStatus> issues;
  final ValueChanged<String>? onOpenVelocity;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) return const SizedBox.shrink();
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    String reason(SoloStatus s) => switch (s.issue) {
      SoloIssue.muted => ko ? '음소거가 켜져 있어요' : 'Mute is on',
      SoloIssue.zeroVolume => ko ? '트랙 음량이 0이에요' : 'Track volume is zero',
      SoloIssue.noNotes =>
        ko ? '이 구간에 재생할 노트·오디오가 없어요' : 'No notes or audio in this range',
      SoloIssue.veryQuiet =>
        ko
            ? '노트 세기 ${s.minVelocity}–${s.maxVelocity}/127 · 매우 작게 들릴 수 있어요'
            : 'Velocity ${s.minVelocity}–${s.maxVelocity}/127 · may be very quiet',
    };
    final message = issues.map((s) => '${s.label}: ${reason(s)}').join('\n');
    final quiet =
        issues.where((s) => s.issue == SoloIssue.veryQuiet).firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Tooltip(
        message: message,
        child: Container(
          key: const ValueKey('solo-status-notice'),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: LT.surface2,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(Icons.info_outline, size: 16, color: LT.t2),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: LT.t2),
                ),
              ),
              if (quiet != null && onOpenVelocity != null)
                TextButton(
                  key: const ValueKey('solo-open-velocity'),
                  onPressed: () => onOpenVelocity!(quiet.id),
                  child: Text(
                    ko ? '강약 보기' : 'View velocity',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
