// My Songs — 저장된 프로젝트 카드 리스트(시안 ②) + 빈 상태 + 우상단 person chip.
// FAB ＋ → 새 프로젝트, 카드 탭 → load 후 Edit push, ⋯ / 길게누름 → 옵션 시트.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../state/local_storage.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/account_sheets.dart';
import '../widgets/common.dart';
import 'account_screen.dart';
import 'edit_screen.dart';

class SongsScreen extends StatefulWidget {
  const SongsScreen({super.key});
  @override
  State<SongsScreen> createState() => _SongsScreenState();
}

class _SongsScreenState extends State<SongsScreen> {
  List<ProjectMeta> _projects = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
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

  Future<void> _newProject() async {
    final store = context.read<ProjectStore>();
    store.newProject();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditScreen()));
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.lime, strokeWidth: 2.4))
                  : (_projects.isEmpty ? _emptyState() : _projectList()),
            ),
            _bottomNav(context),
          ],
        ),
      ),
      floatingActionButton: _projects.isEmpty ? null : _fab(),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('My Songs', style: T.h1),
          GestureDetector(
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AccountScreen())),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              child: const Icon(Symbols.person, size: 20, color: AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _brandMark(),
          const SizedBox(height: 28),
          Text('새 곡 작업을 시작하세요', style: T.h2),
          const SizedBox(height: 10),
          Text(
            '흥얼거리면 악기로 변환되고, 녹음부터 편집까지 한 번에',
            style: T.sub,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: 240,
            child: LimeButton(
              label: '작업 시작',
              icon: Symbols.arrow_forward,
              onTap: _newProject,
            ),
          ),
        ],
      ),
    );
  }

  Widget _projectList() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: _projects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) => _projectCard(_projects[i]),
    );
  }

  Widget _projectCard(ProjectMeta meta) {
    final store = context.read<ProjectStore>();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _openProject(meta),
      onLongPress: () => showProjectOptionsSheet(
        context,
        store,
        meta,
        onChanged: _refresh,
        onOpen: () => _openProject(meta),
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
                Text(fmtProjectAgo(meta.updatedAt), style: T.sub.copyWith(fontSize: 11)),
                const SizedBox(height: 6),
                Row(children: [
                  _miniChip(Symbols.queue_music, '${meta.trackCount}트랙'),
                  const SizedBox(width: 6),
                  _miniChip(Symbols.schedule, fmtProjectDuration(meta.durationSec)),
                ]),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Symbols.more_horiz, color: AppColors.textSecondary, size: 22),
            onPressed: () => showProjectOptionsSheet(
              context, store, meta, onChanged: _refresh, onOpen: () => _openProject(meta),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 72),
      child: FloatingActionButton(
        backgroundColor: AppColors.lime,
        onPressed: _newProject,
        child: const Icon(Symbols.add, color: AppColors.bg, size: 28),
      ),
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
          tab(Symbols.auto_awesome, 'STUDIO', false, disabled: true),
          tab(Symbols.library_music, 'SONGS', true),
          tab(Symbols.tune, 'MIXER', false, disabled: true),
        ]),
      ),
    );
  }
}
