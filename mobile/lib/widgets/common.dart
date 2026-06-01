// 공통 위젯/헬퍼.
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 미연결 기능 안내 (디자인의 40% dim 버튼 탭 시).
void comingSoon(BuildContext context, [String label = '기능']) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text('$label — 준비중입니다', style: T.body),
      backgroundColor: AppColors.surface,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
}

/// 라임 가득 버튼.
class LimeButton extends StatelessWidget {
  const LimeButton({super.key, required this.label, this.icon, this.onTap, this.height = 56});
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        decoration: BoxDecoration(color: AppColors.lime, borderRadius: BorderRadius.circular(height / 2)),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, color: AppColors.bg, size: 20), const SizedBox(width: 8)],
            Text(label, style: T.title.copyWith(color: AppColors.bg, fontWeight: FontWeight.w700)),
          ],
        ),
      ),
    );
  }
}

/// 미연결 래퍼 — 탭 시 준비중 안내. 라벨 가독성 위해 opacity 0.55 사용
/// (0.4 는 텍스트가 surface(#16161E) 위에서 2:1 이하로 떨어져 안 읽힘).
class Disabled extends StatelessWidget {
  const Disabled({super.key, required this.child, required this.label});
  final Widget child;
  final String label;
  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.55,
      child: GestureDetector(
        onTap: () => comingSoon(context, label),
        child: AbsorbPointer(child: child),
      ),
    );
  }
}
