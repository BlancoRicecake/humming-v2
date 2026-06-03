// 저장 상태 인디케이터 — 곡 제목 아래의 작은 행.
part of '../edit_screen.dart';

// 저장 상태 인디케이터 — 곡 제목 아래의 작은 행. 시각이 자주 변하지만 전체
// 화면을 rebuild 하지 않도록, ProjectStore 의 변경은 Selector 로, 시간 텍스트
// 갱신은 _saveTick(ValueNotifier<int>) 로 격리.
class _SaveIndicator extends StatelessWidget {
  final ValueNotifier<int> tick;
  const _SaveIndicator({required this.tick});

  String _fmtAgo(L10n l, DateTime saved) {
    final diff = DateTime.now().difference(saved);
    if (diff.inSeconds < 5) return l.editSaveJust;
    if (diff.inSeconds < 60) return l.agoSecondsAgo(diff.inSeconds);
    if (diff.inMinutes < 60) return l.agoMinutes(diff.inMinutes);
    final hh = saved.hour.toString().padLeft(2, '0');
    final mm = saved.minute.toString().padLeft(2, '0');
    return l.editSaveAt('$hh:$mm');
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    // saving / lastSavedAt 만 구독 — 다른 store 변경은 rebuild 안 함.
    return Selector<ProjectStore, ({bool saving, DateTime? savedAt, bool dirty})>(
      selector: (_, s) => (saving: s.isSaving, savedAt: s.lastSavedAt, dirty: s.hasUnsavedChanges),
      builder: (_, v, __) {
        if (v.saving) {
          return Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(
              width: 10,
              height: 10,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.lime),
            ),
            const SizedBox(width: 6),
            Text(l.editSaveSaving,
                style: T.label.copyWith(
                    fontSize: 10, color: AppColors.lime, fontWeight: FontWeight.w600)),
          ]);
        }
        if (v.savedAt == null) {
          // 첫 저장 전 — 표시 없음(공간만 유지).
          return const SizedBox(height: 14);
        }
        // ValueListenableBuilder 로 1초 tick 만 받아 텍스트 재계산.
        return SizedBox(
          height: 14,
          child: ValueListenableBuilder<int>(
            valueListenable: tick,
            builder: (_, __, ___) => Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Symbols.check_circle,
                  size: 11,
                  color: v.dirty
                      ? AppColors.textTertiary.withValues(alpha: 0.5)
                      : AppColors.textTertiary),
              const SizedBox(width: 4),
              Text(_fmtAgo(l, v.savedAt!),
                  style: T.label.copyWith(
                      fontSize: 10, color: AppColors.textTertiary, fontWeight: FontWeight.w500)),
            ]),
          ),
        );
      },
    );
  }
}
