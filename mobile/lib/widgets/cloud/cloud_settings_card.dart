// "내 클라우드" 설정 카드 — 사용량 + 자동 동기화 토글.
// 시안 ⑭ — cloud-sync-p3.html. AccountScreen 또는 SubscriptionScreen 에서 사용.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../state/project_store.dart';
import '../../theme/app_theme.dart';

class CloudSettingsCard extends StatelessWidget {
  const CloudSettingsCard({super.key});

  String _fmtGB(double bytes) {
    final gb = bytes / (1024 * 1024 * 1024);
    if (gb >= 1.0) return '${gb.toStringAsFixed(1)} GB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(0)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    final store = context.watch<ProjectStore>();
    if (!store.subscription.hasProAccess) return const SizedBox.shrink();
    final used = store.cloudUsageBytes;
    final quota = ProjectStore.cloudQuotaBytes;
    final p = (used / quota).clamp(0.0, 1.0);
    final percent = (p * 100).round();
    final free = quota - used;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            t.settingsCloudHeader,
            style: T.label.copyWith(
              fontSize: 11,
              letterSpacing: 0.6,
              color: AppColors.textTertiary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        RichText(
                          text: TextSpan(
                            style: T.body.copyWith(fontSize: 15),
                            children: [
                              TextSpan(
                                text: used == 0 ? '0 GB' : _fmtGB(used),
                                style: const TextStyle(
                                    color: AppColors.lime, fontWeight: FontWeight.w800),
                              ),
                              TextSpan(
                                text: ' / 5 GB',
                                style: T.body.copyWith(
                                    fontSize: 15, color: AppColors.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(t.cloudUsageCount(store.cloudProjects.length),
                            style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                      ],
                    ),
                  ),
                  // 사용량 상세 페이지는 v1.1 — 출시 P0 에서는 링크 비표시.
                  // 핵심 지표(사용량/% / 남은 용량)는 카드 본문에 이미 표시됨.
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: p,
                  minHeight: 6,
                  backgroundColor: AppColors.surface2,
                  valueColor: const AlwaysStoppedAnimation(AppColors.lime),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(t.settingsCloudPercentUsed(percent),
                      style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                  Text(t.settingsCloudFree(_fmtGB(free)),
                      style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(t.settingsAutoSync, style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 3),
                  Text(t.settingsAutoSyncDesc,
                      style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                ],
              ),
            ),
            Switch(
              value: store.autoSyncEnabled,
              activeTrackColor: AppColors.lime,
              thumbColor: const WidgetStatePropertyAll(Colors.white),
              inactiveTrackColor: AppColors.surface2,
              inactiveThumbColor: Colors.white,
              trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
              onChanged: (v) => store.setAutoSyncEnabled(v),
            ),
          ]),
        ),
      ],
    );
  }
}

