// LoopTap — Songs (home). README §1: landscape full-screen, 3-col grid of song
// cards + a dashed "start a new loop" card. Header logo + Settings + My Page + New.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../models/loop_models.dart';
import '../music/theory.dart';
import '../state/loop_store.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';
import '../widgets/sheets/account_sheet.dart';
import '../widgets/sheets/paywall_sheet.dart';
import '../widgets/sheets/settings_sheet.dart';
import 'edit_screen.dart';

/// 비-Pro 사용자가 만들 수 있는 작업물 최대 개수.
const int kFreeSongQuota = 4;

class SongsScreen extends StatelessWidget {
  const SongsScreen({super.key});

  void _open(BuildContext context, Song song) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => EditScreen(song: song)));
  }

  /// 새 작업물 생성. 비-Pro 가 quota (4개) 에 도달하면 paywall 우선 표시.
  Future<void> _new(BuildContext context) async {
    final store = context.read<LoopStore>();
    if (!store.proActive && store.songs.length >= kFreeSongQuota) {
      await showPaywallSheet(context, trigger: PaywallTrigger.songQuota);
      if (!context.mounted) return;
      // paywall 닫혔는데도 여전히 비-Pro 라면 그대로 종료.
      if (!context.read<LoopStore>().proActive) return;
    }
    if (!context.mounted) return;
    _open(context, store.createNew());
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LoopStore>();
    return Scaffold(
      backgroundColor: LT.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 20, 28, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onNew: () => _new(context)),
              const SizedBox(height: 18),
              Expanded(
                child: !store.loaded
                    ? const Center(child: CircularProgressIndicator(color: LT.lime))
                    : _Grid(
                        songs: store.songs,
                        onOpen: (s) => _open(context, s),
                        onNew: () => _new(context),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onNew});
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // logo — HumTrack app icon (lime hummingbird), rounded to match the badge
        ClipRRect(
          borderRadius: BorderRadius.circular(9),
          child: Image.asset(
            'assets/icon/app_icon.png',
            width: 34,
            height: 34,
            fit: BoxFit.cover,
            cacheWidth: 96,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text.rich(
              TextSpan(
                style: LTType.inter(size: 20, weight: FontWeight.w800, color: LT.t1, letterSpacing: -0.4),
                children: [
                  const TextSpan(text: 'Hum'),
                  TextSpan(text: 'Track', style: const TextStyle(color: LT.lime)),
                ],
              ),
            ),
            const LtLabel('Tap-to-make beats', color: LT.t3),
          ],
        ),
        const Spacer(),
        if (context.watch<LoopStore>().proActive) ...[
          _ProBadge(onTap: () => showAccountSheet(context)),
          const SizedBox(width: 10),
        ],
        IconBtn(icon: LtIcons.settings, size: 40, tooltip: 'Settings', onTap: () => showSettingsSheet(context)),
        const SizedBox(width: 10),
        _MyPageButton(),
        const SizedBox(width: 10),
        Pill(label: 'New song', icon: LtIcons.add, tone: PillTone.lime, height: 40, fontSize: 14, horizontalPadding: 18, onTap: onNew),
      ],
    );
  }
}

/// Pro 활성 시 헤더에 노출되는 lime pill — 시각적 active 피드백.
/// 탭하면 account sheet 로 이동 (구독 관리 진입점).
class _ProBadge extends StatelessWidget {
  const _ProBadge({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: LT.lime,
          borderRadius: BorderRadius.circular(LTRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Ms(LtIcons.workspacePremium, size: 18, color: LT.bg),
            const SizedBox(width: 6),
            Text('PRO',
                style: LTType.inter(
                  size: 13,
                  weight: FontWeight.w900,
                  color: LT.bg,
                  letterSpacing: 1,
                )),
          ],
        ),
      ),
    );
  }
}

class _MyPageButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final user = context.watch<LoopStore>().user;
    final initial = user == null ? null : ((user['name'] ?? 'U').isNotEmpty ? user['name']![0].toUpperCase() : 'U');
    return GestureDetector(
      onTap: () => showAccountSheet(context),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: user != null ? LT.lime : LT.surface2,
          shape: BoxShape.circle,
          border: Border.all(color: user != null ? Colors.transparent : LT.border),
        ),
        child: Center(
          child: user != null
              ? Text(initial!, style: LTType.inter(size: 16, weight: FontWeight.w900, color: LT.bg))
              : const Ms(LtIcons.person, size: 20, color: LT.t1),
        ),
      ),
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.songs, required this.onOpen, required this.onNew});
  final List<Song> songs;
  final void Function(Song) onOpen;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        mainAxisExtent: 150,
      ),
      itemCount: songs.length + 1,
      itemBuilder: (context, i) {
        if (i == songs.length) return _NewCard(onTap: onNew);
        return _SongCard(
          song: songs[i],
          onTap: () => onOpen(songs[i]),
          onRename: () => _renameSong(context, songs[i]),
          onDuplicate: () => _duplicateSong(context, songs[i]),
          onDelete: () => _deleteSong(context, songs[i]),
        );
      },
    );
  }

  Future<void> _renameSong(BuildContext context, Song song) async {
    final store = context.read<LoopStore>();
    final l = L10n.of(context);
    final controller = TextEditingController(text: song.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: LT.surface,
        title: Text(l.projectOptionRename, style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: LTType.inter(size: 14, weight: FontWeight.w600, color: LT.t1),
          cursorColor: LT.lime,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(dctx).pop(v),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: LT.surface2,
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(LTRadius.control),
              borderSide: const BorderSide(color: LT.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(LTRadius.control),
              borderSide: const BorderSide(color: LT.lime),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(l.cancel, style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.t3)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(controller.text),
            child: Text(l.save, style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.lime)),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.trim().isNotEmpty && newTitle != song.title) {
      await store.rename(song.id, newTitle);
    }
  }

  Future<void> _duplicateSong(BuildContext context, Song song) {
    return context.read<LoopStore>().duplicate(song);
  }

  Future<void> _deleteSong(BuildContext context, Song song) async {
    final store = context.read<LoopStore>();
    final l = L10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: LT.surface,
        title: Text(
          l.projectDeleteTitle(song.title),
          style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.danger),
        ),
        content: Text(l.projectDeleteBody, style: LTType.inter(size: 13, color: LT.t1)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(l.cancel, style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.t3)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(l.delete, style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.danger)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await store.delete(song.id);
    }
  }
}

class _SongCard extends StatelessWidget {
  const _SongCard({
    required this.song,
    required this.onTap,
    required this.onRename,
    required this.onDuplicate,
    required this.onDelete,
  });
  final Song song;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scaleLabel = kScales[song.scale]?.label ?? song.scale;
    return Stack(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: LT.surface,
              borderRadius: BorderRadius.circular(LTRadius.card),
              border: Border.all(color: LT.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            // waveform thumbnail (30 bars; every 5th lime)
            Container(
              height: 64,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: LT.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: LT.border),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  for (var i = 0; i < song.wave.length; i++)
                    Expanded(
                      child: Container(
                        height: (song.wave[i] * 44).clamp(2, 44),
                        margin: const EdgeInsets.symmetric(horizontal: 1),
                        decoration: BoxDecoration(
                          color: i % 5 == 0 ? LT.lime : LT.surface3,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(song.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.t1)),
                const SizedBox(height: 6),
                Text('${song.key} $scaleLabel · ${song.bpm} BPM · ${song.bars} bars',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LTType.mono(size: 10, color: LT.t3)),
              ],
            ),
          ),
        ),
        // 3-dot 메뉴 — 카드 우하단 overlay. PopupMenuButton 으로 rename/duplicate/delete.
        Positioned(
          bottom: 6,
          right: 6,
          child: _CardMenu(
            onRename: onRename,
            onDuplicate: onDuplicate,
            onDelete: onDelete,
          ),
        ),
      ],
    );
  }
}

class _CardMenu extends StatelessWidget {
  const _CardMenu({
    required this.onRename,
    required this.onDuplicate,
    required this.onDelete,
  });
  final VoidCallback onRename;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return PopupMenuButton<String>(
      tooltip: l.ltCardMore,
      color: LT.surface2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LTRadius.control),
        side: const BorderSide(color: LT.border),
      ),
      padding: EdgeInsets.zero,
      icon: Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: LT.surface2.withValues(alpha: 0.85),
          shape: BoxShape.circle,
        ),
        child: const Ms(LtIcons.moreHoriz, size: 16, color: LT.t2),
      ),
      onSelected: (v) {
        switch (v) {
          case 'rename': onRename(); break;
          case 'duplicate': onDuplicate(); break;
          case 'delete': onDelete(); break;
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(
          value: 'rename',
          child: Row(children: [
            const Ms(LtIcons.edit, size: 16, color: LT.t1),
            const SizedBox(width: 10),
            Text(l.projectOptionRename, style: LTType.inter(size: 13, weight: FontWeight.w600, color: LT.t1)),
          ]),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: Row(children: [
            const Ms(LtIcons.layers, size: 16, color: LT.t1),
            const SizedBox(width: 10),
            Text(l.projectOptionDuplicate, style: LTType.inter(size: 13, weight: FontWeight.w600, color: LT.t1)),
          ]),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Row(children: [
            const Ms(LtIcons.delete, size: 16, color: LT.danger),
            const SizedBox(width: 10),
            Text(l.projectOptionDelete, style: LTType.inter(size: 13, weight: FontWeight.w600, color: LT.danger)),
          ]),
        ),
      ],
    );
  }
}

class _NewCard extends StatelessWidget {
  const _NewCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: DottedBorderBox(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Ms(LtIcons.add, size: 28, color: LT.t2),
            const SizedBox(height: 8),
            Text('Start a new loop',
                style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t2)),
          ],
        ),
      ),
    );
  }
}

/// A 1.5px dashed rounded rectangle (the "new loop" card border).
class DottedBorderBox extends StatelessWidget {
  const DottedBorderBox({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRectPainter(),
      child: Center(child: child),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = LT.border
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(LTRadius.card),
    );
    final path = Path()..addRRect(rrect);
    const dash = 6.0, gap = 5.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + dash), paint);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
