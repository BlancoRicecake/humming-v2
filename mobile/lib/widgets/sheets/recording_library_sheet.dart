// 녹음 라이브러리 시트 — 영구 보관된 녹음 목록 + 재사용.
//
// 항목 탭 → 현재 active 트랙의 악기로 /analyze 재실행해서 같은 흥얼거림을 다른 악기에
// 적용한다. 미리듣기/삭제 보조.
//
// part of '../sheets.dart' — 같은 라이브러리 묶음에 속한다.
part of '../sheets.dart';

void showRecordingLibrarySheet(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (_) => _RecordingLibrarySheetBody(store: store),
  );
}

class _RecordingLibrarySheetBody extends StatefulWidget {
  const _RecordingLibrarySheetBody({required this.store});
  final ProjectStore store;

  @override
  State<_RecordingLibrarySheetBody> createState() => _RecordingLibrarySheetBodyState();
}

class _RecordingLibrarySheetBodyState extends State<_RecordingLibrarySheetBody> {
  final AudioPlayerService _audio = AudioPlayerService();
  String? _playingId;

  @override
  void dispose() {
    _audio.stop();
    super.dispose();
  }

  Future<void> _togglePreview(RecordingEntry e) async {
    if (_playingId == e.id) {
      await _audio.stop();
      if (mounted) setState(() => _playingId = null);
      return;
    }
    try {
      await _audio.stop();
      await _audio.playFile(e.path);
      if (mounted) setState(() => _playingId = e.id);
      Future.delayed(Duration(milliseconds: (e.duration * 1000).toInt() + 200), () {
        if (mounted && _playingId == e.id) setState(() => _playingId = null);
      });
    } catch (err) {
      debugPrint('[reclib-sheet] preview FAILED: $err');
      if (mounted) setState(() => _playingId = null);
    }
  }

  Future<void> _applyEntry(RecordingEntry e) async {
    final store = widget.store;
    final nav = Navigator.of(context);
    await _audio.stop();
    if (mounted) setState(() => _playingId = null);
    nav.pop(); // 라이브러리 시트 닫기
    await store.applyLibraryEntry(e);
  }

  Future<void> _deleteEntry(RecordingEntry e) async {
    await RecordingLibrary.instance.deleteFromLibrary(e.id);
    if (mounted) setState(() {});
  }

  Future<void> _renameEntry(RecordingEntry e) async {
    final l = L10n.of(context);
    final controller = TextEditingController(text: e.label ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text(l.recordLibraryRenameTitle, style: T.h2.copyWith(fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: T.body.copyWith(fontSize: 14, color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: l.recordLibraryRenameHint,
            hintStyle: T.body.copyWith(fontSize: 14, color: AppColors.textTertiary),
            enabledBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.border),
            ),
            focusedBorder: const UnderlineInputBorder(
              borderSide: BorderSide(color: AppColors.lime),
            ),
          ),
          onSubmitted: (v) => Navigator.pop(dctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(l.cancel, style: T.body.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, controller.text),
            child: Text(l.ok, style: T.body.copyWith(color: AppColors.lime, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (result == null) return;
    await RecordingLibrary.instance.rename(e.id, result);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final mq = MediaQuery.of(context);
    final entries = RecordingLibrary.instance.savedEntries;
    final maxH = mq.size.height * 0.78;
    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Row(children: [
            const Icon(Symbols.library_music, size: 20, color: AppColors.lime),
            const SizedBox(width: 8),
            Expanded(child: Text(l.recordLibraryTitle, style: T.h2.copyWith(fontSize: 17))),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Symbols.close, size: 20, color: AppColors.textSecondary),
              ),
            ),
          ]),
          const SizedBox(height: 14),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 30),
              child: Column(children: [
                Container(
                  width: 64, height: 64, alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.bg,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: const Icon(Symbols.mic, size: 28, color: AppColors.textTertiary),
                ),
                const SizedBox(height: 14),
                Text(l.recordLibraryEmpty,
                    style: T.body.copyWith(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 6),
                Text(l.recordLibraryEmptySub,
                    textAlign: TextAlign.center,
                    style: T.sub.copyWith(color: AppColors.textTertiary, height: 1.4)),
              ]),
            )
          else
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: entries.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _entryCard(entries[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _entryCard(RecordingEntry e) {
    final l = L10n.of(context);
    final playing = _playingId == e.id;
    final hasLabel = e.label != null && e.label!.isNotEmpty;
    final dateStr = _fmtRecordedAt(e.recordedAt);
    final lastProg = e.lastProgram;
    final subParts = <String>[
      '${e.duration.toStringAsFixed(1)}s',
      if (lastProg != null) _programLabel(lastProg),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // 좌측 첫 자식 — 미리듣기 재생 버튼(가장 눈에 띄게 lime border).
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _togglePreview(e),
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: playing ? AppColors.lime : AppColors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: playing ? AppColors.lime : AppColors.lime.withValues(alpha: 0.55),
                      width: 1.4,
                    ),
                  ),
                  child: Icon(
                    playing ? Symbols.stop : Symbols.play_arrow,
                    size: 22,
                    color: playing ? AppColors.bg : AppColors.lime,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _applyEntry(e),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasLabel) ...[
                        Text(
                          e.label!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: T.body.copyWith(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          dateStr,
                          style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary),
                        ),
                      ] else
                        Text(
                          dateStr,
                          style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        subParts.join(' · '),
                        style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _applyEntry(e),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.lime,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    l.recordLibraryUseAs,
                    style: T.label.copyWith(
                      fontSize: 10,
                      color: AppColors.bg,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 파형 — 명확한 lime stroke 로 표시. 비어있을 때는 안내 텍스트.
          SizedBox(
            height: 28,
            width: double.infinity,
            child: e.peaks.isEmpty
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '— — —',
                      style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary),
                    ),
                  )
                : CustomPaint(
                    painter: _LibraryWavePainter(peaks: e.peaks),
                    size: Size.infinite,
                  ),
          ),
          const SizedBox(height: 8),
          // 보조 액션 — rename / delete.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _miniIconButton(
                icon: Symbols.edit,
                tooltip: l.recordLibraryRename,
                onTap: () => _renameEntry(e),
              ),
              const SizedBox(width: 8),
              _miniIconButton(
                icon: Symbols.delete,
                tooltip: l.recordLibraryDelete,
                onTap: () => _deleteEntry(e),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Semantics(
      label: tooltip,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 36,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.border),
          ),
          child: Icon(icon, size: 16, color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

String _fmtRecordedAt(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}.${two(dt.month)}.${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
}

/// GM program → 짧은 라벨. instrument_icons 에 GM 이름 매핑이 없는 폴백 — "Program N".
String _programLabel(int program) {
  // 자주 쓰는 program 만 가벼운 매핑(전체 GM 128 표는 instrument_icons.dart 가 담당).
  switch (program) {
    case 0: return 'Piano';
    case 24: return 'Guitar';
    case 25: return 'Steel Guitar';
    case 32: return 'Bass';
    case 33: return 'Electric Bass';
    case 40: return 'Violin';
    case 48: return 'Strings';
    case 56: return 'Trumpet';
    case 73: return 'Flute';
    default: return 'Program $program';
  }
}


// 라이브러리 카드용 굵은 막대 파형 — 가로 폭에 맞춰 균등 다운샘플링 후 lime 막대.
class _LibraryWavePainter extends CustomPainter {
  _LibraryWavePainter({required this.peaks});
  final List<double> peaks;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || size.width <= 0) return;
    final w = size.width, h = size.height;
    final mid = h / 2;
    const barW = 3.0;
    const gap = 1.5;
    final stride = barW + gap;
    final nBars = (w / stride).floor();
    if (nBars <= 0) return;
    final paint = Paint()
      ..color = AppColors.lime
      ..strokeWidth = barW
      ..strokeCap = StrokeCap.round;
    final bgPaint = Paint()
      ..color = AppColors.lime.withValues(alpha: 0.25)
      ..strokeWidth = barW
      ..strokeCap = StrokeCap.round;
    final bucket = peaks.length / nBars;
    for (int i = 0; i < nBars; i++) {
      final from = (i * bucket).floor();
      final to = ((i + 1) * bucket).ceil().clamp(from + 1, peaks.length);
      double mx = 0;
      for (int k = from; k < to; k++) {
        final v = peaks[k].abs();
        if (v > mx) mx = v;
      }
      final amp = mx.clamp(0.0, 1.0) * (h * 0.45);
      final x = i * stride + barW / 2;
      canvas.drawLine(Offset(x, mid - 1), Offset(x, mid + 1), bgPaint);
      if (amp > 0.5) {
        canvas.drawLine(Offset(x, mid - amp), Offset(x, mid + amp), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LibraryWavePainter old) => old.peaks != peaks;
}
