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
            Disabled(
              label: l.exportCloudSaveLabel,
              child: _exportRow(Symbols.cloud_done, l.exportCloudSaveTitle, l.exportCloudSaveSub, AppColors.lime),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _exportFile(context, store, midi: true),
              child: _exportRow(Symbols.piano, l.exportMidiTitle, l.exportMidiSub, AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => _exportFile(context, store, midi: false),
              child: _exportRow(Symbols.graphic_eq, l.exportAudioTitle, l.exportAudioSub, AppColors.textPrimary),
            ),
            const SizedBox(height: 10),
            Disabled(
              label: l.exportShareLabel,
              child: _exportRow(Symbols.ios_share, l.exportShareLabel, l.exportShareSub, AppColors.textPrimary),
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
  try {
    // 재생 ▶ 와 동일한 결과: enabled 트랙 전부를 믹스/멀티트랙으로 export.
    final bytes = midi ? await store.exportMidiMix() : await store.exportMixWav();
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/humming_${DateTime.now().millisecondsSinceEpoch}.${midi ? 'mid' : 'wav'}');
    await f.writeAsBytes(bytes, flush: true);
    if (context.mounted) Navigator.pop(context);
    AnalyticsService.instance.songExported(format: midi ? 'midi' : 'wav');
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)], text: store.title));
  } catch (e) {
    if (context.mounted) comingSoon(context, L10n.of(context).exportFailed('$e'));
  }
}
