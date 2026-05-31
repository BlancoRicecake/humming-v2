// 공통 음량 바 미터 — 중앙 기준 대칭 막대.
// recording_screen 의 풀사이즈 미터와 edit_screen 인라인 녹음 박스 미터가 공유.
// always-on 패턴(옵션 B): [active]=false 이면 lime alpha 0.18 정적 막대로
// 자리/크기는 유지한 채 시각적 점프 없이 녹음 시작 시 자연스럽게 lime 1.0 으로 흐름.
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class MeterPainter extends CustomPainter {
  MeterPainter(
    this.levels, {
    this.active = true,
    this.barWidthRatio = 0.5,
    this.barWidthMin,
    this.barWidthMax,
    this.minBarHeight = 3.0,
    this.inactiveAlpha = 0.18,
  });

  final List<double> levels;
  final bool active;
  final double barWidthRatio;
  final double? barWidthMin;
  final double? barWidthMax;
  final double minBarHeight;
  final double inactiveAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final n = levels.length;
    if (n == 0) return;
    final slot = size.width / n;
    double barW = slot * barWidthRatio;
    if (barWidthMin != null || barWidthMax != null) {
      barW = barW.clamp(barWidthMin ?? 0.0, barWidthMax ?? double.infinity);
    }
    final cy = size.height / 2;
    final paint = Paint()
      ..color = active ? AppColors.lime : AppColors.lime.withValues(alpha: inactiveAlpha);
    for (int i = 0; i < n; i++) {
      final h = (levels[i] * size.height).clamp(minBarHeight, size.height);
      final x = i * slot + (slot - barW) / 2;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x, cy - h / 2, barW, h), const Radius.circular(2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MeterPainter old) => true;
}
