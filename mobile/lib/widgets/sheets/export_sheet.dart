// 내보내기 / 공유 시트 — WAV / MIDI / 클라우드 / Share.
part of '../sheets.dart';

// ─── 내보내기 / 공유 ───────────────────────────────────────────────────
void showExportShare(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) {
      final l = L10n.of(sheetCtx);
      return Container(
        decoration: _sheetDeco(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Text(l.exportTitle(store.title), style: T.h2.copyWith(fontSize: 18)),
            const SizedBox(height: 14),
            // 클라우드 저장 / 직접 공유는 v1.1 에 동작. 출시 P0 에서는 메뉴 비표시.
            // (Play 심사 "반응하지 않는 UI" 회피 — 미구현 placeholder 노출 금지.)
            GestureDetector(
              onTap: () => _exportFile(context, store, midi: true),
              child: _exportRow(Symbols.piano, l.exportMidiTitle, l.exportMidiSub, AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _exportFile(context, store, midi: false),
              child: _exportRow(Symbols.graphic_eq, l.exportAudioTitle, l.exportAudioSub, AppColors.textPrimary),
            ),
          ],
        ),
      );
    },
  );
}

Widget _exportRow(IconData ic, String title, String sub, Color iconColor) {
  return Container(
    height: 64,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: AppColors.bg,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.border),
    ),
    child: Row(children: [
      Icon(ic, size: 24, color: iconColor),
      const SizedBox(width: 14),
      Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: T.body.copyWith(fontSize: 15, fontWeight: FontWeight.w600)),
          Text(sub, style: T.sub.copyWith(fontSize: 11)),
        ],
      ),
      const Spacer(),
      const Icon(Symbols.chevron_right, size: 22, color: AppColors.textTertiary),
    ]),
  );
}

Future<void> _exportFile(BuildContext context, ProjectStore store, {required bool midi}) async {
  final box = context.findRenderObject() as RenderBox?;
  final size = MediaQuery.of(context).size;
  final origin = box != null
      ? box.localToGlobal(Offset.zero) & box.size
      : Rect.fromCenter(center: Offset(size.width / 2, size.height / 2), width: 1, height: 1);

  // 로딩 인디케이터 표시
  if (context.mounted) {
    final l = L10n.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(l.exportExporting, style: const TextStyle(fontSize: 14)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  try {
    final bytes = midi ? await store.exportMidiMix() : await store.exportMixWav();
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/humming_${DateTime.now().millisecondsSinceEpoch}.${midi ? 'mid' : 'wav'}');
    await f.writeAsBytes(bytes, flush: true);
    if (context.mounted) {
      Navigator.pop(context); // 로딩 다이얼로그 닫기
      Navigator.pop(context); // export 시트 닫기
    }
    AnalyticsService.instance.songExported(format: midi ? 'midi' : 'wav');
    await SharePlus.instance.share(ShareParams(
      files: [XFile(f.path)],
      text: store.title,
      sharePositionOrigin: origin,
    ));
  } catch (e) {
    if (context.mounted) {
      Navigator.pop(context); // 로딩 다이얼로그 닫기
      errorToast(context, L10n.of(context).exportFailed('$e'));
    }
  }
}
