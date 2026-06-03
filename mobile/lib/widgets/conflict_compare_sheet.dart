// 충돌 비교 시트 — 로컬 vs 클라우드 (mock).
// 시안 ⑩ — cloud-sync-p3.html. 실 동작은 후속.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';

enum ConflictResolution { keepBoth, overwriteCloud, pullFromCloud }

Future<ConflictResolution?> showConflictCompareSheet(
  BuildContext context, {
  required String projectTitle,
  required DateTime localModifiedAt,
  required int localBytes,
  required int localTrackCount,
  required DateTime cloudModifiedAt,
  required int cloudBytes,
  required int cloudTrackCount,
}) {
  return showModalBottomSheet<ConflictResolution>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _ConflictBody(
      projectTitle: projectTitle,
      localModifiedAt: localModifiedAt,
      localBytes: localBytes,
      localTrackCount: localTrackCount,
      cloudModifiedAt: cloudModifiedAt,
      cloudBytes: cloudBytes,
      cloudTrackCount: cloudTrackCount,
    ),
  );
}

class _ConflictBody extends StatelessWidget {
  const _ConflictBody({
    required this.projectTitle,
    required this.localModifiedAt,
    required this.localBytes,
    required this.localTrackCount,
    required this.cloudModifiedAt,
    required this.cloudBytes,
    required this.cloudTrackCount,
  });
  final String projectTitle;
  final DateTime localModifiedAt;
  final int localBytes;
  final int localTrackCount;
  final DateTime cloudModifiedAt;
  final int cloudBytes;
  final int cloudTrackCount;

  String _fmtAgo(L10n l, DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return l.agoJustEdited;
    if (d.inHours < 1) return l.agoMinutes(d.inMinutes);
    if (d.inDays < 1) return l.agoHours(d.inHours);
    if (d.inDays < 7) return l.agoDays(d.inDays);
    return l.agoMonthDay(dt.month, dt.day);
  }

  String _fmtMB(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final l = L10n.of(context);
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: const Color(0xFF3F3F46),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.conflictTitle, style: T.title),
                    const SizedBox(height: 4),
                    Text(
                      l.conflictSub(projectTitle),
                      style: T.sub.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Icon(Symbols.close, color: AppColors.textSecondary, size: 14),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 14),
            child: Divider(color: AppColors.border, height: 1),
          ),
          Row(children: [
            Expanded(child: _versionCard(
              header: l.conflictLocalHeader,
              headerColor: AppColors.textPrimary,
              date: _fmtAgo(l, localModifiedAt),
              info: l.conflictTrackInfo(localTrackCount, _fmtMB(localBytes)),
            )),
            const SizedBox(width: 10),
            Expanded(child: _versionCard(
              header: l.conflictCloudHeader,
              headerColor: AppColors.lime,
              date: _fmtAgo(l, cloudModifiedAt),
              info: l.conflictTrackInfo(cloudTrackCount, _fmtMB(cloudBytes)),
            )),
          ]),
          const SizedBox(height: 14),
          _resolveRow(context, l.conflictKeepBoth, ConflictResolution.keepBoth,
              primary: true, badge: l.conflictBadgeRecommended),
          const SizedBox(height: 8),
          _resolveRow(context, l.conflictOverwriteCloud,
              ConflictResolution.overwriteCloud, trailingIcon: Symbols.arrow_forward),
          const SizedBox(height: 8),
          _resolveRow(context, l.conflictPullFromCloud,
              ConflictResolution.pullFromCloud, trailingIcon: Symbols.arrow_back),
        ],
      ),
    );
  }

  Widget _versionCard({
    required String header,
    required Color headerColor,
    required String date,
    required String info,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            header,
            style: T.label.copyWith(fontSize: 10, color: headerColor, letterSpacing: 0.6),
          ),
          const SizedBox(height: 8),
          Text(date, style: T.body.copyWith(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          Text(info, style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
        ],
      ),
    );
  }

  Widget _resolveRow(
    BuildContext context,
    String label,
    ConflictResolution res, {
    bool primary = false,
    String? badge,
    IconData? trailingIcon,
  }) {
    return GestureDetector(
      onTap: () => Navigator.pop(context, res),
      child: Container(
        height: 46,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: primary ? AppColors.lime : AppColors.surface2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              label,
              style: T.body.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 13,
                color: primary ? AppColors.bg : AppColors.textPrimary,
              ),
            ),
          ),
          if (badge != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(badge,
                  style: T.label.copyWith(fontSize: 9, color: AppColors.lime, letterSpacing: 0.5)),
            )
          else if (trailingIcon != null)
            Icon(trailingIcon, size: 14, color: AppColors.textTertiary),
        ]),
      ),
    );
  }
}
