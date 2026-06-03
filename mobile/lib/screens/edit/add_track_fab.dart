// 트랙 추가 FAB — 40×40 흰색 원형. 우측 하단 위치는 EditScreen 이 결정.
part of '../edit_screen.dart';

// 트랙 추가 FAB — 40×40 흰색 원형 + 다크 + 아이콘. 시안 docs/mockups/track-expansion.html.
class _AddTrackFab extends StatelessWidget {
  final VoidCallback onTap;
  const _AddTrackFab({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.textPrimary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(Symbols.add, color: AppColors.bg, size: 22, weight: 700),
      ),
    );
  }
}
