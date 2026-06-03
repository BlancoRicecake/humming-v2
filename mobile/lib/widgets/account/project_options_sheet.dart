// ⑳ 프로젝트 옵션 시트 — 열기 / 이름변경 / 복제 / 내보내기 / 삭제 / 클라우드.
part of '../account_sheets.dart';

// ─── ⑳ ㉑ ㉒ 프로젝트 옵션 ───────────────────────────────────────────
// cloud-sync-p3 ⑥ — 내 작업물 탭 옵션 시트에 "클라우드에 올리기 / 클라우드 최신화" 추가.
enum _ProjectAction {
  open,
  rename,
  duplicate,
  export,
  delete,
  uploadToCloud,
  refreshCloud,
}

/// `onChanged` 는 옵션 시트 결과로 리스트를 갱신해야 할 때 호출 — songs screen 에서 setState.
Future<void> showProjectOptionsSheet(
  BuildContext context,
  ProjectStore store,
  ProjectMeta meta, {
  required VoidCallback onChanged,
  required Future<void> Function() onOpen,
}) async {
  final action = await showModalBottomSheet<_ProjectAction>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _ProjectOptionsBody(meta: meta, store: store),
  );
  if (action == null) return;
  switch (action) {
    case _ProjectAction.open:
      await onOpen();
      break;
    case _ProjectAction.rename:
      // ignore: use_build_context_synchronously
      final newName = await _promptRename(context, meta.title);
      if (newName != null && newName.trim().isNotEmpty) {
        await LocalStorage.instance.renameProject(meta.id, newName.trim());
        onChanged();
      }
      break;
    case _ProjectAction.duplicate:
      await LocalStorage.instance.duplicateProject(meta);
      onChanged();
      break;
    case _ProjectAction.export:
      if (!store.subscription.hasProAccess) {
        // ignore: use_build_context_synchronously
        await showPaywallSheet(context, store, trigger: 'export');
        break;
      }
      // Pro — 해당 프로젝트를 열어 EditScreen 진입. 사용자는 거기서 우상단 공유 아이콘
      // 으로 MIDI/WAV 내보내기 가능. (별도 export 시트를 여기서 직접 띄우려면 onOpen
      // 의 navigation 종료를 기다린 뒤 EditScreen context 를 받아야 해 흐름이 복잡.)
      await onOpen();
      break;
    case _ProjectAction.delete:
      // ignore: use_build_context_synchronously
      final ok = await _promptDelete(context, meta.title);
      if (ok == true) {
        await LocalStorage.instance.deleteProject(meta.id);
        onChanged();
      }
      break;
    case _ProjectAction.uploadToCloud:
    case _ProjectAction.refreshCloud:
      // Pro 가 아니면 paywall (lock 아이콘 탭).
      if (!store.subscription.hasProAccess) {
        // ignore: use_build_context_synchronously
        await showPaywallSheet(context, store, trigger: 'sync');
        break;
      }
      // 시안 ⑧ — 업로드 진행 모달 → mock 업로드.
      final sizeBytes = (meta.durationSec * 200 * 1024).toInt().clamp(1024 * 1024, 50 * 1024 * 1024);
      if (!context.mounted) break;
      final done = await showSyncProgressSheet(
        context,
        direction: SyncDirection.upload,
        projectTitle: meta.title,
        totalBytes: sizeBytes,
        onRun: () => store.mockUploadToCloud(meta.id, meta.title, sizeBytes: sizeBytes),
      );
      if (done && context.mounted) {
        // 시안 ② — "{title} — 클라우드에 올렸어요" 토스트.
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Row(children: [
              const Icon(Symbols.check_circle, color: AppColors.lime, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(L10n.of(context).projectUploadedToast(meta.title),
                    style: T.body.copyWith(fontSize: 13)),
              ),
            ]),
            backgroundColor: AppColors.surface3,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ));
        onChanged();
      }
      break;
  }
}

class _ProjectOptionsBody extends StatelessWidget {
  const _ProjectOptionsBody({required this.meta, required this.store});
  final ProjectMeta meta;
  final ProjectStore store;

  Widget _row(BuildContext context, IconData ic, String title, String? sub, _ProjectAction action, {bool danger = false, bool pro = false, bool lime = false, bool muted = false}) {
    final color = danger
        ? AppColors.danger
        : (lime ? AppColors.lime : (muted ? AppColors.textSecondary : AppColors.textPrimary));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context, action),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: danger ? AppColors.dangerBorder : AppColors.border),
        ),
        child: Row(children: [
          Icon(ic, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(title, style: T.body.copyWith(fontWeight: FontWeight.w600, color: color)),
                  if (pro) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.lime.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('PRO', style: T.label.copyWith(color: AppColors.lime, fontSize: 9)),
                    ),
                  ],
                ]),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(sub, style: T.sub.copyWith(fontSize: 11)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 같은 id 가 클라우드에 있으면 "최신화" 톤. 없으면 "올리기" lime 강조.
    final cloudExisting = store.cloudProjects.firstWhere(
      (c) => c.id == meta.id,
      orElse: () => CloudProjectMeta(
        id: '',
        title: '',
        uploadedAt: DateTime.now(),
        lastModifiedAt: DateTime.now(),
        sizeBytes: 0,
        onThisDevice: true,
      ),
    );
    final hasCloud = cloudExisting.id.isNotEmpty;
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          _projectHeader(context, meta),
          const SizedBox(height: 16),
          // 클라우드 액션 — 시안 ⑥. Pro 면 lime, 비-Pro 면 lock + paywall.
          if (!hasCloud)
            _row(
              context,
              Symbols.cloud_upload,
              L10n.of(context).projectActionUploadToCloud,
              store.subscription.hasProAccess ? null : L10n.of(context).projectOptionUploadProBadge,
              _ProjectAction.uploadToCloud,
              lime: store.subscription.hasProAccess,
              pro: !store.subscription.hasProAccess,
            )
          else
            _row(
              context,
              Symbols.cloud_sync,
              L10n.of(context).projectActionRefreshCloud,
              L10n.of(context).projectOptionRefreshSyncedAt(_fmtAgo(context, cloudExisting.lastModifiedAt)),
              _ProjectAction.refreshCloud,
              muted: true,
            ),
          _row(context, Symbols.folder_open, L10n.of(context).projectOptionOpen, null, _ProjectAction.open),
          _row(context, Symbols.edit, L10n.of(context).projectOptionRename, null, _ProjectAction.rename),
          _row(context, Symbols.content_copy, L10n.of(context).projectOptionDuplicate, null, _ProjectAction.duplicate),
          _row(context, Symbols.ios_share, L10n.of(context).projectOptionExport, L10n.of(context).projectOptionExportSub, _ProjectAction.export, pro: !store.subscription.hasProAccess),
          _row(context, Symbols.delete, L10n.of(context).projectOptionDelete, L10n.of(context).projectOptionDeleteSub, _ProjectAction.delete, danger: true),
        ],
      ),
    );
  }
}

Widget _projectHeader(BuildContext context, ProjectMeta meta) {
  return Row(children: [
    _ProjectThumb(index: meta.thumbIndex, size: 56),
    const SizedBox(width: 12),
    Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meta.title, style: T.h2.copyWith(fontSize: 17),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(
            L10n.of(context).projectHeaderMeta(
              meta.trackCount,
              _fmtDur(context, meta.durationSec),
              _fmtAgo(context, meta.updatedAt),
            ),
            style: T.sub,
          ),
        ],
      ),
    ),
  ]);
}

class _ProjectThumb extends StatelessWidget {
  const _ProjectThumb({required this.index, this.size = 56});
  final int index;
  final double size;

  // 4 종 그라데이션 — 시안 ② 카드 썸네일과 유사.
  static const _palettes = <List<Color>>[
    [Color(0xFFA3E635), Color(0xFF65A30D)], // lime
    [Color(0xFF7C3AED), Color(0xFF4C1D95)], // violet
    [Color(0xFFF59E0B), Color(0xFFB45309)], // amber
    [Color(0xFF06B6D4), Color(0xFF0E7490)], // cyan
  ];

  @override
  Widget build(BuildContext context) {
    final pal = _palettes[index.clamp(0, _palettes.length - 1)];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: pal,
        ),
      ),
      child: const Icon(Symbols.graphic_eq, color: Colors.white, size: 24),
    );
  }
}

/// 외부에서 공개 — 카드 위젯에서도 같은 썸네일 색을 쓰기 위해.
class ProjectThumb extends StatelessWidget {
  const ProjectThumb({super.key, required this.index, this.size = 56});
  final int index;
  final double size;
  @override
  Widget build(BuildContext context) => _ProjectThumb(index: index, size: size);
}
