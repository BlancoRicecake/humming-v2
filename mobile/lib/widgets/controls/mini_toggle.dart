// 작은 라임 토글 — active_track_cards 의 카드 우상단 on/off 스위치.
part of '../active_track_cards.dart';

class _MiniToggle extends StatelessWidget {
  const _MiniToggle({required this.on, required this.onTap});
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 20,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: on ? AppColors.lime : AppColors.border,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Align(
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: const BoxDecoration(color: AppColors.bg, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }
}
