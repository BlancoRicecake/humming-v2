// My Songs — 저장된 프로젝트 카드 리스트 + 클라우드 세그먼트 탭.
// 시안 ① ② ③ ④ ⑤ ⑬ — docs/mockups/cloud-sync-p3.html.
//
// 상단: 제목 + person chip. 검색 바 자리(아직 미구현). 그 아래 세그먼트 컨트롤.
// [내 작업물] [클라우드] — IndexedStack 으로 전환(빈 상태와 리스트 상태가 함께 살아있도록).
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../l10n/generated/app_localizations.dart';
import '../state/local_storage.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/account_sheets.dart';
import '../widgets/sheets.dart';
import '../widgets/cloud/cloud_tab_view.dart';
import '../widgets/common.dart';
import '../widgets/controls/segmented_control.dart';
import 'account_screen.dart';
import 'edit_screen.dart';
import 'pro_welcome_screen.dart';

class SongsScreen extends StatefulWidget {
  const SongsScreen({super.key});
  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  List<ProjectMeta> _projects = const [];
  bool _loading = true;
  int _tabIndex = 0; // 0 = 내 작업물, 1 = 클라우드

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = context.read<ProjectStore>();
    // 세션 만료로 인한 강제 로그아웃 알림.
    if (store.sessionExpiredNotification) {
      store.sessionExpiredNotification = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(L10n.of(context).authSessionExpired),
          backgroundColor: AppColors.danger,
          duration: const Duration(seconds: 4),
        ));
      });
    }
    // Pro 결제 직후 환영 화면 — store.pendingProWelcome 가 true 면 1회 push.
    if (store.pendingProWelcome) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        store.markProWelcomeSeen();
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const ProWelcomeScreen()),
        );
        if (mounted) setState(() => _tabIndex = 1);
      });
    }
  }

  Future<void> _refresh() async {
    final list = await LocalStorage.instance.listProjects();
    if (!mounted) return;
    setState(() {
      _projects = list;
      _loading = false;
    });
  }

  Future<void> _openProject(ProjectMeta meta) async {
    final store = context.read<ProjectStore>();
    final ok = await LocalStorage.instance.loadProject(meta.id, store);
    if (!ok || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditScreen()));
    _refresh();
  }

  Future<void> _exportProject(ProjectMeta meta) async {
    final store = context.read<ProjectStore>();
    final ok = await LocalStorage.instance.loadProject(meta.id, store);
    if (!ok || !mounted) return;
    showExportShare(context, store);
  }

  Future<void> _newProject() async {
    final store = context.read<ProjectStore>();
    store.newProject();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditScreen()));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProjectStore>();
    final t = L10n.of(context);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(context, store),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: SegmentedControl(
                tabs: [
                  (icon: Symbols.smartphone, label: t.tabSongs),
                  (icon: Symbols.cloud, label: t.tabCloud),
                ],
                selectedIndex: _tabIndex,
                onChanged: (i) => setState(() => _tabIndex = i),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tabIndex,
                children: [
                  _loading
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: AppColors.lime, strokeWidth: 2.4))
                      : (_projects.isEmpty ? _emptyState() : _projectList()),
                  CloudTabView(onGoToLocalTab: () => setState(() => _tabIndex = 0)),
                ],
              ),
            ),
            // 하단 탭바 — 출시 P0 에서는 Songs 만 구현 상태라 탭바 자체 비표시.
            // STUDIO / MIXER 가 동작 가능한 v1.1 에서 _bottomNav(context) 재활성.
          ],
        ),
      ),
      floatingActionButton: (_tabIndex == 0 && _projects.isNotEmpty) ? _fab() : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _topBar(BuildContext context, ProjectStore store) {
    final pro = store.subscription.hasProAccess;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(L10n.of(context).songsTitle, style: T.h1),
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: pro ? AppColors.lime : AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: pro ? AppColors.lime : AppColors.border),
              ),
              child: Icon(
                Symbols.person,
                size: 20,
                color: pro ? AppColors.bg : AppColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    final t = L10n.of(context);
    return TabletConstrain(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _brandMark(),
            const SizedBox(height: 28),
            Text(t.songsEmptyTitle, style: T.h2),
            const SizedBox(height: 10),
            Text(
              t.songsEmptySub,
              style: T.sub,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: 240,
              child: LimeButton(
                label: t.songsEmptyCta,
                icon: Symbols.arrow_forward,
                onTap: _newProject,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _projectList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _projectCard(_projects[i]),
    );
  }

  Widget _projectCard(ProjectMeta meta) {
    final store = context.read<ProjectStore>();
    // 클라우드 보유 여부 — 같은 id 가 클라우드에 있으면 작은 단서 표시.
    final inCloud = store.cloudProjects.any((c) => c.id == meta.id);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openProject(meta),
      onLongPress: () => showProjectOptionsSheet(
        context,
        store,
        meta,
        onChanged: _refresh,
        onOpen: () => _openProject(meta),
        onExport: () => _exportProject(meta),
      ),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          ProjectThumb(index: meta.thumbIndex, size: 64),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(meta.title,
                    style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 4),
                Row(children: [
                  Text(fmtProjectAgo(context, meta.updatedAt), style: T.sub.copyWith(fontSize: 11)),
                  if (inCloud) ...[
                    const SizedBox(width: 6),
                    const _Dot(),
                    const SizedBox(width: 6),
                    Icon(Symbols.cloud_done, size: 12, color: AppColors.lime),
                    const SizedBox(width: 3),
                    Text(L10n.of(context).songsCardInCloud,
                        style: T.sub.copyWith(fontSize: 11, color: AppColors.lime)),
                  ],
                ]),
                const SizedBox(height: 6),
                Row(children: [
                  _miniChip(Symbols.queue_music, L10n.of(context).songsTrackCountChip(meta.trackCount)),
                  const SizedBox(width: 6),
                  _miniChip(Symbols.schedule, fmtProjectDuration(context, meta.durationSec)),
                  if (meta.sizeBytes > 0) ...[
                    const SizedBox(width: 6),
                    _miniChip(Symbols.sd_storage, meta.sizeLabel),
                  ],
                ]),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.more_horiz, color: AppColors.textSecondary, size: 22),
            onPressed: () => showProjectOptionsSheet(
              context, store, meta, onChanged: _refresh, onOpen: () => _openProject(meta),
              onExport: () => _exportProject(meta),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _miniChip(IconData ic, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(ic, size: 11, color: AppColors.textSecondary),
        const SizedBox(width: 4),
        Text(label, style: T.label.copyWith(fontSize: 10, color: AppColors.textSecondary)),
      ]),
    );
  }

  Widget _fab() {
    // 하단 탭바 제거(P0) — FAB 의 추가 bottom 여백 불필요. SafeArea 가 끝까지 보장.
    return FloatingActionButton(
      backgroundColor: AppColors.lime,
      onPressed: _newProject,
      child: const Icon(Symbols.add, color: AppColors.bg, size: 28),
    );
  }

  Widget _brandMark() {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(34)),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/icon/hummingbird.png',
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Symbols.flutter_dash, size: 72, color: AppColors.lime),
      ),
    );
  }

  // ignore: unused_element
  Widget _bottomNav(BuildContext context) {
    Widget tab(IconData ic, String label, bool active, {bool disabled = false}) {
      final w = Expanded(
        child: Container(
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: active ? AppColors.lime : Colors.transparent,
            borderRadius: BorderRadius.circular(26),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ic, size: 16, color: active ? AppColors.bg : AppColors.textSecondary),
              const SizedBox(height: 4),
              Text(label,
                  style: T.label.copyWith(
                      fontSize: 10, color: active ? AppColors.bg : AppColors.textSecondary)),
            ],
          ),
        ),
      );
      if (disabled) return Expanded(child: Disabled(label: 'Mixer', child: w.child));
      return w;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(21, 12, 21, 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(36),
          border: Border.all(color: AppColors.border),
        ),
        padding: const EdgeInsets.all(4),
        child: Row(children: [
          tab(Symbols.auto_awesome, L10n.of(context).navStudio, false, disabled: true),
          tab(Symbols.library_music, L10n.of(context).navSongs, true),
          tab(Symbols.tune, L10n.of(context).navMixer, false, disabled: true),
        ]),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();
  @override
  Widget build(BuildContext context) => Container(
        width: 3,
        height: 3,
        decoration: const BoxDecoration(
          color: AppColors.textTertiary,
          shape: BoxShape.circle,
        ),
      );
}
