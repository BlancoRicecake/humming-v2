// 카운트다운 링 — 인라인 녹음 진입 시 3-2-1 sweep arc.
part of '../timeline_editor.dart';

class _CountdownRingPainter extends CustomPainter {
  _CountdownRingPainter({required this.progress});
  final double progress;
  static const Color _rec = Color(0xFFFF4D4D);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    final bg = Paint()
      ..color = _rec.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, radius, bg);
    final fg = Paint()
      ..color = _rec
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final sweep = (progress.clamp(0.0, 1.0)) * 2 * math.pi;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: radius),
      -math.pi / 2, // 12시 방향에서 시작
      sweep,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _CountdownRingPainter old) => old.progress != progress;
}
