// 녹음 결과 사용/삭제 시트. 어시스트 토글 + 미리듣기 포함(보컬 제외).
part of '../sheets.dart';

// ─── 녹음 결과 사용/삭제 시트 ──────────────────────────────────────────
// 녹음 종료 → 분석/정리 결과 미리보기 + 사용/삭제. 어시스트 토글 포함(보컬 제외).
// 기존 인라인 트랙 박스에서 모달 시트로 승격 — 좁은 공간에 다 안 들어가는 문제 해결.
void showPendingRecordingSheet(
  BuildContext context,
  ProjectStore store, {
  VoidCallback? onRetry,
}) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    isDismissible: false, // 사용/삭제 버튼으로만 닫힘 (실수 dismiss 방지)
    enableDrag: false,
    builder: (sheetCtx) {
      return AnimatedBuilder(
        animation: store,
        builder: (_, __) {
          final p = store.pendingRecording;
          if (p == null) {
            // commit/discard 후 자동 닫힘.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(sheetCtx)) Navigator.pop(sheetCtx);
            });
            return const SizedBox.shrink();
          }
          return _PendingSheetBody(store: store, p: p, onRetry: onRetry);
        },
      );
    },
  );
}

class _PendingSheetBody extends StatefulWidget {
  const _PendingSheetBody({required this.store, required this.p, this.onRetry});
  final ProjectStore store;
  final PendingRecording p;
  final VoidCallback? onRetry;

  @override
  State<_PendingSheetBody> createState() => _PendingSheetBodyState();
}

class _PendingSheetBodyState extends State<_PendingSheetBody> {
  final SynthPlayer _synth = SynthPlayer();
  final AudioPlayerService _audio = AudioPlayerService();
  bool _previewPlaying = false;
  StreamSubscription? _doneSub;

  @override
  void dispose() {
    _doneSub?.cancel();
    _synth.stop();
    _audio.stop();
    super.dispose();
  }

  Future<void> _togglePreview() async {
    final p = widget.p;
    if (_previewPlaying) {
      await _synth.stop();
      await _audio.stop();
      if (mounted) setState(() => _previewPlaying = false);
      return;
    }
    final isVocal = p.role == TrackRole.vocal;
    setState(() => _previewPlaying = true);
    _doneSub?.cancel();
    if (isVocal) {
      if (p.vocalWavPath == null) {
        setState(() => _previewPlaying = false);
        return;
      }
      await _audio.playFile(p.vocalWavPath!);
      // audioplayers 완료 시점 stream 이 따로 있지만 간단히 duration 후 reset.
      Future.delayed(Duration(milliseconds: (p.vocalDuration * 1000).toInt() + 200), () {
        if (mounted) setState(() => _previewPlaying = false);
      });
    } else {
      final tr = widget.store.trackById(p.trackId);
      final program = tr?.program ?? 0;
      final isDrum = tr?.role == TrackRole.drum;
      _doneSub = _synth.onComplete.listen((_) {
        if (mounted) setState(() => _previewPlaying = false);
      });
      // 커밋 후 렌더와 동일하게 변환된 노트로 미리듣기(베이스 저음역 배치 등).
      final notes = widget.store.pendingRenderNotes(p);
      await _synth.play([SynthTrack(notes: notes, program: program, isDrum: isDrum)]);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final p = widget.p;
    final store = widget.store;
    final mq = MediaQuery.of(context);
    final isVocal = p.role == TrackRole.vocal;
    final analyzing = store.busy && p.analysis == null && p.vocalWavPath == null;
    final notesCount = p.notes.length;
    final dur = p.analysis?.durationSec ?? p.vocalDuration;
    final canPreview = !analyzing && (isVocal ? p.vocalWavPath != null : p.notes.isNotEmpty);
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: Text(l.pendingRecTitle, style: T.h2.copyWith(fontSize: 18))),
              if (widget.onRetry != null)
                _RetryIconBtn(
                  onTap: analyzing
                      ? null
                      : () async {
                          await _synth.stop();
                          await _audio.stop();
                          store.discardPendingRecording();
                          widget.onRetry!();
                        },
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            analyzing
                ? l.pendingAnalyzing
                : (isVocal
                    ? l.pendingVocalUseQ(dur.toStringAsFixed(1))
                    : l.pendingNotesUseQ(dur.toStringAsFixed(1), notesCount)),
            style: T.body.copyWith(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          Container(
            height: 110,
            decoration: BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: analyzing
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.lime),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.all(8),
                    child: CustomPaint(
                      painter: isVocal
                          ? _PendingWavePainter(peaks: p.vocalPeaks)
                          : _PendingNotesPainter(notes: widget.store.pendingRenderNotes(p)),
                      size: Size.infinite,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          _previewButton(canPreview),
          const SizedBox(height: 12),
          _saveToLibraryRow(),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: _pendingSheetBtn(
                l.delete,
                outlined: true,
                onTap: () async {
                  await _synth.stop();
                  await _audio.stop();
                  store.discardPendingRecording();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _pendingSheetBtn(
                l.use,
                outlined: false,
                onTap: analyzing
                    ? null
                    : () async {
                        await _synth.stop();
                        await _audio.stop();
                        store.commitPendingRecording();
                      },
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _saveToLibraryRow() {
    final l = L10n.of(context);
    final p = widget.p;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        const Icon(Symbols.bookmark, size: 18, color: AppColors.lime),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l.recordLibrarySaveToggle,
                  style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(l.recordLibrarySaveToggleSub,
                  style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
            ],
          ),
        ),
        Transform.scale(
          scale: 0.85,
          child: Switch(
            value: p.saveToLibraryOnUse,
            activeTrackColor: AppColors.lime,
            thumbColor: const WidgetStatePropertyAll(Colors.white),
            inactiveTrackColor: AppColors.surface,
            inactiveThumbColor: Colors.white,
            trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
            onChanged: (v) => widget.store.setPendingSaveToLibrary(v),
          ),
        ),
      ]),
    );
  }

  Widget _previewButton(bool enabled) {
    final color = enabled
        ? (_previewPlaying ? AppColors.lime : AppColors.textPrimary)
        : AppColors.textTertiary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? _togglePreview : null,
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _previewPlaying ? AppColors.lime : AppColors.border),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_previewPlaying ? Symbols.stop : Symbols.play_arrow, size: 18, color: color),
            const SizedBox(width: 6),
            Text(_previewPlaying ? L10n.of(context).pendingStop : L10n.of(context).pendingPreview,
                style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
          ],
        ),
      ),
    );
  }
}

Widget _pendingSheetBtn(String label, {required bool outlined, VoidCallback? onTap}) {
  final disabled = onTap == null;
  return GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      height: 48,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: outlined ? Colors.transparent : (disabled ? AppColors.border : AppColors.lime),
        border: outlined ? Border.all(color: AppColors.border) : null,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: T.body.copyWith(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: outlined ? AppColors.textPrimary : AppColors.bg)),
    ),
  );
}

class _PendingWavePainter extends CustomPainter {
  _PendingWavePainter({required this.peaks});
  final List<double> peaks;
  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final w = size.width, h = size.height;
    final pad = 8.0;
    final innerH = h - pad * 2;
    final mid = h / 2;
    final paint = Paint()..color = AppColors.lime..strokeWidth = 1.4..strokeCap = StrokeCap.round;
    final n = peaks.length;
    for (int i = 0; i < n; i++) {
      final x = (i / (n - 1)) * w;
      final a = peaks[i].clamp(0.0, 1.0) * innerH / 2;
      canvas.drawLine(Offset(x, mid - a), Offset(x, mid + a), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PendingWavePainter old) => old.peaks != peaks;
}

class _PendingNotesPainter extends CustomPainter {
  _PendingNotesPainter({required this.notes});
  final List<Note> notes;
  @override
  void paint(Canvas canvas, Size size) {
    if (notes.isEmpty) return;
    final w = size.width, h = size.height;
    final minT = notes.map((n) => n.start).reduce(math.min);
    final maxT = notes.map((n) => n.end).reduce(math.max);
    final span = math.max(maxT - minT, 0.05);
    final pitched = notes.where((n) => n.kind == 'pitched').toList();
    int minP = 60, maxP = 72;
    if (pitched.isNotEmpty) {
      minP = pitched.map((n) => n.pitch).reduce((a, b) => a < b ? a : b) - 1;
      maxP = pitched.map((n) => n.pitch).reduce((a, b) => a > b ? a : b) + 1;
    }
    final range = (maxP - minP).clamp(1, 127);
    final paint = Paint()..color = AppColors.lime;
    final bh = (h / range).clamp(4.0, 10.0);
    for (final n in notes) {
      final x = ((n.start - minT) / span) * w;
      final bw = math.max(((n.end - n.start) / span) * w, 3.0);
      if (n.kind == 'percussive') {
        canvas.drawRect(Rect.fromLTWH(x, h / 2 - 2, bw.clamp(3.0, 12.0), 4), paint);
        continue;
      }
      final tt = 1 - (n.pitch - minP) / range;
      final y = (tt * (h - bh)).clamp(0.0, h - bh);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, y, bw, bh), const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _PendingNotesPainter old) => old.notes != notes;
}

/// 녹음 완료 시트 우상단 — 결과가 맘에 안 들 때 즉시 재녹음.
class _RetryIconBtn extends StatelessWidget {
  const _RetryIconBtn({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.lime.withValues(alpha: 0.14)
              : AppColors.surface,
          shape: BoxShape.circle,
          border: Border.all(
            color: enabled ? AppColors.lime.withValues(alpha: 0.5) : AppColors.border,
          ),
        ),
        child: Icon(
          Symbols.refresh,
          size: 20,
          color: enabled ? AppColors.lime : AppColors.textTertiary,
        ),
      ),
    );
  }
}
