// 클라우드 탭 뷰 — Free / Pro-empty / Pro-list / Expired-grace 4 가지 상태 분기.
// 시안 ③ ④ ⑤ ⑬ — docs/mockups/cloud-sync-p3.html.
//
// Free 도 자유 진입 가능 — 잠금 ❌, "Pro 로 업그레이드" 권유 톤.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/iap_pricing.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/account_sheets.dart';
import '../widgets/common.dart';
import '../widgets/sync_progress_sheet.dart';

class CloudTabView extends StatefulWidget {
  const CloudTabView({super.key, required this.onGoToLocalTab});

  /// "내 작업물 탭으로 가기" CTA — 세그먼트 인덱스 0 으로 전환.
  final VoidCallback onGoToLocalTab;

  @override
  State<CloudTabView> createState() => _CloudTabViewState();
}

class _CloudTabViewState extends State<CloudTabView> {
  @override
  void initState() {
    super.initState();
    // 진입 시 1회 — 인증 안 됐으면 store 가 self-skip.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final store = context.read<ProjectStore>();
      if (store.subscription.hasProAccess ||
          store.subscription == SubscriptionStatus.expired) {
        store.refreshCloudData();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProjectStore>();
    final hasPro = store.subscription.hasProAccess;
    final expired = store.subscription == SubscriptionStatus.expired;
    Widget child;
    if (!hasPro && !expired) {
      child = _FreePaywallView(store: store);
    } else if (expired) {
      child = _ExpiredGraceView(store: store, onGoToLocalTab: widget.onGoToLocalTab);
    } else if (store.cloudProjects.isEmpty) {
      child = _ProEmptyView(store: store, onGoToLocalTab: widget.onGoToLocalTab);
    } else {
      child = _ProListView(store: store);
    }
    if (!hasPro && !expired) return child; // free 는 새로고침 의미 없음
    return RefreshIndicator(
      color: AppColors.lime,
      backgroundColor: AppColors.surface,
      onRefresh: () => store.refreshCloudData(),
      child: child,
    );
  }
}

// ─── ③ Free 자유 진입 — 가치 카드 + Pro 업그레이드 CTA ─────────────────
class _FreePaywallView extends StatelessWidget {
  const _FreePaywallView({required this.store});
  final ProjectStore store;

  Widget _valueMini(IconData ic, String title, String sub) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.activeLane,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(ic, color: AppColors.lime, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title, style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 1),
              Text(sub, style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
            ],
          ),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        const SizedBox(height: 12),
        Center(
          child: Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1F2A0F), AppColors.surface],
              ),
              border: Border.all(color: const Color(0xFF2E3D18)),
            ),
            alignment: Alignment.center,
            child: const Icon(Symbols.cloud, color: AppColors.lime, size: 46),
          ),
        ),
        const SizedBox(height: 14),
        Center(child: Text(t.cloudFreeImageHeadline, style: T.h2.copyWith(fontSize: 18))),
        const SizedBox(height: 8),
        Center(
          child: Text(
            t.cloudFreeImageSub,
            style: T.sub.copyWith(height: 1.5),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        _valueMini(Symbols.shield, t.cloudValueBackupTitle, t.cloudValueBackupSub),
        const SizedBox(height: 8),
        _valueMini(Symbols.sync, t.cloudValueAutoSyncTitle, t.cloudValueAutoSyncSub),
        const SizedBox(height: 8),
        _valueMini(Symbols.download, t.cloudValueExportTitle, t.cloudValueExportSub),
        const SizedBox(height: 18),
        GestureDetector(
          onTap: () => showPaywallSheet(context, store, trigger: 'sync'),
          child: Container(
            height: 60,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: AppColors.lime,
              borderRadius: BorderRadius.circular(999),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(t.actionUpgradeToPro,
                    style: T.body.copyWith(
                        fontWeight: FontWeight.w800, color: AppColors.bg, fontSize: 14)),
                const SizedBox(height: 2),
                Text(t.cloudUpgradeFootnote(IapPricing.trialDays, IapPricing.monthlyLabel()),
                    style: T.sub.copyWith(
                        color: AppColors.bg.withValues(alpha: 0.7), fontSize: 10)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── ⑤ Pro 인데 클라우드 비어있음 ─────────────────────────────────────
class _ProEmptyView extends StatelessWidget {
  const _ProEmptyView({required this.store, required this.onGoToLocalTab});
  final ProjectStore store;
  final VoidCallback onGoToLocalTab;

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        const UsageCard(),
        const SizedBox(height: 16),
        Center(
          child: Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1F2A0F), AppColors.surface],
              ),
              border: Border.all(color: const Color(0xFF2E3D18)),
            ),
            alignment: Alignment.center,
            child: const Icon(Symbols.cloud, color: AppColors.lime, size: 46),
          ),
        ),
        const SizedBox(height: 14),
        Center(child: Text(t.cloudProEmptyTitle, style: T.h2.copyWith(fontSize: 18))),
        const SizedBox(height: 8),
        Center(
          child: Text(
            t.cloudProEmptySub,
            style: T.sub.copyWith(height: 1.5),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 18),
        GestureDetector(
          onTap: onGoToLocalTab,
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: AppColors.border),
            ),
            alignment: Alignment.center,
            child: Text(t.cloudGoToLocalTab,
                style: T.body.copyWith(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ),
      ],
    );
  }
}

// ─── ④ Pro + 클라우드 작업물 있음 ─────────────────────────────────────
class _ProListView extends StatelessWidget {
  const _ProListView({required this.store});
  final ProjectStore store;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      itemCount: store.cloudProjects.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        if (i == 0) return const UsageCard();
        return CloudProjectCard(meta: store.cloudProjects[i - 1]);
      },
    );
  }
}

// ─── ⑬ 만료 grace ──────────────────────────────────────────────────────
class _ExpiredGraceView extends StatelessWidget {
  const _ExpiredGraceView({required this.store, required this.onGoToLocalTab});
  final ProjectStore store;
  final VoidCallback onGoToLocalTab;

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
      children: [
        _graceBanner(context),
        const SizedBox(height: 12),
        const UsageCard(muted: true),
        const SizedBox(height: 10),
        if (store.cloudProjects.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(t.cloudGraceEmpty,
                  style: T.sub, textAlign: TextAlign.center),
            ),
          )
        else
          for (final c in store.cloudProjects) ...[
            CloudProjectCard(meta: c, forceDownloadCta: true),
            const SizedBox(height: 10),
          ],
      ],
    );
  }

  Widget _graceBanner(BuildContext context) {
    final t = L10n.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: AppColors.amberBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.amberBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.cloudGraceTitle,
                    style: T.body.copyWith(
                        fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.amber)),
                const SizedBox(height: 3),
                Text(t.cloudGraceBody,
                    style: T.sub.copyWith(fontSize: 11, height: 1.4)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.amber,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('D-27',
                style: T.label.copyWith(
                    fontSize: 11, color: AppColors.bg, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

// ─── 사용량 카드 ──────────────────────────────────────────────────────
class UsageCard extends StatelessWidget {
  const UsageCard({super.key, this.muted = false});
  final bool muted;

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
    final used = store.cloudUsageBytes;
    final quota = ProjectStore.cloudQuotaBytes;
    final p = (used / quota).clamp(0.0, 1.0);
    final num = used == 0 ? '0 GB' : _fmtGB(used);
    final count = store.cloudProjects.length;
    return Container(
      margin: const EdgeInsets.only(top: 4, bottom: 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: T.body.copyWith(fontSize: 15, fontWeight: FontWeight.w700),
                    children: [
                      TextSpan(
                        text: num,
                        style: TextStyle(color: muted ? AppColors.textSecondary : AppColors.lime),
                      ),
                      TextSpan(
                        text: ' / 5 GB ${muted ? t.cloudUsageStored : t.cloudUsageInUse}',
                        style: T.body.copyWith(
                            fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary),
                      ),
                    ],
                  ),
                ),
              ),
              Text(
                muted ? t.cloudUsageReadOnly : (count > 0 ? t.cloudUsageCount(count) : t.cloudUsageCountStored(count)),
                style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: p,
              minHeight: 6,
              backgroundColor: AppColors.surface2,
              valueColor: AlwaysStoppedAnimation(
                  muted ? AppColors.textTertiary : AppColors.lime),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── 클라우드 카드 아이템 ─────────────────────────────────────────────
class CloudProjectCard extends StatelessWidget {
  const CloudProjectCard({
    super.key,
    required this.meta,
    this.forceDownloadCta = false,
  });
  final CloudProjectMeta meta;

  /// 만료 grace 상태 — 모든 카드를 "받기" 강조로.
  final bool forceDownloadCta;

  String _fmtAgo(BuildContext context, DateTime dt) {
    final t = L10n.of(context);
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return t.agoJustUploaded;
    if (d.inHours < 1) return t.agoMinutes(d.inMinutes);
    if (d.inDays < 1) return t.agoHours(d.inHours);
    if (d.inDays < 7) return t.agoDays(d.inDays);
    return t.agoMonthDay(dt.month, dt.day);
  }

  String _fmtMB(int bytes) {
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<ProjectStore>();
    final showHere = meta.onThisDevice && !forceDownloadCta;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showCloudProjectOptionsSheet(context, store, meta),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          ProjectThumb(index: meta.thumbIndex, size: 52),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  meta.title,
                  style: T.body.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  '${_fmtMB(meta.sizeBytes)} · ${_fmtAgo(context, meta.lastModifiedAt)}',
                  style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary),
                ),
              ],
            ),
          ),
          _deviceMark(context, showHere),
        ]),
      ),
    );
  }

  Widget _deviceMark(BuildContext context, bool here) {
    final t = L10n.of(context);
    final bg = here ? AppColors.activeLane : AppColors.surface2;
    final color = here ? AppColors.lime : AppColors.textSecondary;
    final label = here ? t.cloudCardThisDevice : t.cloudCardDownload;
    final icon = here ? Symbols.smartphone : Symbols.download;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label, style: T.label.copyWith(fontSize: 10, color: color, letterSpacing: 0.3)),
        ],
      ),
    );
  }
}

// ─── ⑦ 클라우드 옵션 시트 ──────────────────────────────────────────────
enum _CloudProjectAction { downloadFromCloud, rename, deleteFromCloud }

Future<void> showCloudProjectOptionsSheet(
    BuildContext context, ProjectStore store, CloudProjectMeta meta) async {
  final action = await showModalBottomSheet<_CloudProjectAction>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _CloudOptionsBody(meta: meta),
  );
  if (action == null) return;
  switch (action) {
    case _CloudProjectAction.downloadFromCloud:
      if (!context.mounted) return;
      await showSyncProgressSheet(
        context,
        direction: SyncDirection.download,
        projectTitle: meta.title,
        totalBytes: meta.sizeBytes,
        onRun: () => store.mockDownloadFromCloud(meta.id),
      );
      break;
    case _CloudProjectAction.rename:
      if (!context.mounted) return;
      comingSoon(context, L10n.of(context).cloudRenameLabel);
      break;
    case _CloudProjectAction.deleteFromCloud:
      store.mockDeleteFromCloud(meta.id);
      break;
  }
}

class _CloudOptionsBody extends StatelessWidget {
  const _CloudOptionsBody({required this.meta});
  final CloudProjectMeta meta;

  String _fmtMB(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  String _fmtDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final t = L10n.of(context);
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
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: const Color(0xFF3F3F46),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(meta.title,
                          style: T.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text(
                        t.cloudOptionsSubtitle(_fmtDate(meta.uploadedAt), _fmtMB(meta.sizeBytes)),
                        style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary),
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
          ),
          const Divider(color: AppColors.border, height: 1),
          _row(
            context,
            icon: Symbols.download,
            label: meta.onThisDevice ? t.cloudOptionsDownloadAgain : t.cloudOptionsDownload,
            trailing: _fmtMB(meta.sizeBytes),
            lime: true,
            action: _CloudProjectAction.downloadFromCloud,
          ),
          _row(
            context,
            icon: Symbols.edit,
            label: t.rename,
            action: _CloudProjectAction.rename,
          ),
          _row(
            context,
            icon: Symbols.delete,
            label: t.projectActionDeleteFromCloud,
            sub: t.projectActionDeleteFromCloudSub,
            danger: true,
            action: _CloudProjectAction.deleteFromCloud,
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required String label,
    String? sub,
    String? trailing,
    bool lime = false,
    bool danger = false,
    required _CloudProjectAction action,
  }) {
    final color = danger ? AppColors.danger : (lime ? AppColors.lime : AppColors.textPrimary);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context, action),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        child: Row(
          crossAxisAlignment: sub != null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            SizedBox(width: 24, child: Icon(icon, color: color, size: 18)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: T.body.copyWith(
                      fontSize: 15,
                      fontWeight: lime ? FontWeight.w600 : FontWeight.w500,
                      color: color,
                    ),
                  ),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub, style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              Text(trailing,
                  style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
          ],
        ),
      ),
    );
  }
}
