// 박자 보정 시트 — BPM + 그리드 chips + 강도 슬라이더.
part of '../sheets.dart';

// ─── 박자 보정 시트 ─────────────────────────────────────────────────────
// BPM stepper + 메트로놈 자동 클릭(시청각 보조) + 그리드 chips + 강도 슬라이더.
// 시트 열려있는 동안 메트로놈 켜져 BPM 빠르기를 귀로 확인 가능.
void showQuantizeSheet(BuildContext context, ProjectStore store) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _QuantizeSheetBody(store: store),
  );
}

class _QuantizeSheetBody extends StatefulWidget {
  const _QuantizeSheetBody({required this.store});
  final ProjectStore store;
  @override
  State<_QuantizeSheetBody> createState() => _QuantizeSheetBodyState();
}

class _QuantizeSheetBodyState extends State<_QuantizeSheetBody> {
  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final mq = MediaQuery.of(context);
    return AnimatedBuilder(
      animation: widget.store,
      builder: (_, __) {
        final store = widget.store;
        final t = store.active;
        return Container(
          decoration: _sheetDeco(),
          padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _grabber(),
              Row(children: [
                Text(l.quantizeTitle, style: T.h2.copyWith(fontSize: 18)),
                const Spacer(),
                Text('BPM ${store.bpm}',
                    style: T.label.copyWith(fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(width: 12),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Text(l.done,
                        style: T.body.copyWith(color: AppColors.lime, fontWeight: FontWeight.w700)),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              Text(
                l.quantizeBpmHint,
                style: T.body.copyWith(fontSize: 11, color: AppColors.textTertiary),
              ),
              const Divider(height: 28, color: Color(0xFF222229)),
              // 박자 단위 (그리드)
              Text(l.quantizeGridLabel,
                  style: T.label.copyWith(
                      fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              Row(children: [
                for (final g in [4, 8, 16, 32]) ...[
                  _gridChip(g, t.quantizeGrid, () => store.setTrackQuantize(t.id, grid: g)),
                  if (g != 32) const SizedBox(width: 8),
                ],
              ]),
              const SizedBox(height: 6),
              Text(l.quantizeGridDetail(t.quantizeGrid ~/ 4),
                  style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
              const SizedBox(height: 18),
              // 강도
              Row(children: [
                Text(l.quantizeStrength,
                    style: T.label.copyWith(
                        fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.textSecondary)),
                const Spacer(),
                Text('${(t.quantizeStrength * 100).round()}%',
                    style: T.body.copyWith(fontWeight: FontWeight.w700)),
              ]),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: AppColors.lime,
                  inactiveTrackColor: AppColors.border,
                  thumbColor: AppColors.lime,
                  overlayColor: AppColors.lime.withValues(alpha: 0.2),
                ),
                child: Slider(
                  value: t.quantizeStrength,
                  min: 0,
                  max: 1,
                  divisions: 20,
                  onChanged: (v) => store.setTrackQuantize(t.id, strength: v),
                ),
              ),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text(l.quantizeStrengthMin,
                    style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
                Text(l.quantizeStrengthMax,
                    style: T.label.copyWith(fontSize: 10, color: AppColors.textTertiary)),
              ]),
              const SizedBox(height: 14),
              Text(
                l.quantizeFooter,
                style: T.body.copyWith(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
              ),
            ],
          ),
        );
      },
    );
  }


  Widget _gridChip(int grid, int current, VoidCallback onTap) {
    final active = grid == current;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.lime : Colors.transparent,
          border: Border.all(color: active ? AppColors.lime : AppColors.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text('1/$grid',
            style: T.body.copyWith(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: active ? AppColors.bg : AppColors.textPrimary,
            )),
      ),
    );
  }
}
