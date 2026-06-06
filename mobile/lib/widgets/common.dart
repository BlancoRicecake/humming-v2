// 공통 위젯/헬퍼.
import 'package:flutter/material.dart';
import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';

/// 태블릿 / 큰 화면에서 컨텐츠 가로 폭을 모바일 폭(<= [maxWidth])으로 제한하고
/// 가운데 정렬한다. iPhone 등 좁은 화면(< [maxWidth])에서는 child 가 그대로
/// 풀폭으로 표시되어 regression 없다.
///
/// 사용처: SongsScreen 같은 풀-스크린 컬럼, 빈 상태, 하단 탭바 등.
class TabletConstrain extends StatelessWidget {
  const TabletConstrain({super.key, required this.child, this.maxWidth = 640});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// 화면 폭 >= 600 이면 태블릿으로 간주.
bool isTabletWidth(BuildContext context) =>
    MediaQuery.of(context).size.shortestSide >= 600;

/// 미연결 기능 안내 (디자인의 40% dim 버튼 탭 시).
///
/// 의미상 *진짜 v1 출시 후 추가될 placeholder* 에만 사용한다.
/// 조건부 비활성(노트 없음 / 권한 거부 / 분석 미완료) 또는 에러는
/// [errorToast] / [infoToast] 를 사용하라.
void comingSoon(BuildContext context, [String? label]) {
  final t = L10n.of(context);
  final lbl = label ?? t.comingSoonFeature;
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(t.comingSoonToast(lbl), style: T.body),
      backgroundColor: AppColors.surface,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
}

/// 에러/실패 안내 — "준비중" 라벨 없이 메시지 그대로 표시.
/// (분석 실패, 재생 실패, export 실패, 권한 거부 등.)
void errorToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message, style: T.body),
      backgroundColor: AppColors.surface,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 3),
    ));
}

/// 안내성 토스트 — 조건부 비활성 사유 등 단순 정보.
void infoToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(message, style: T.body),
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
