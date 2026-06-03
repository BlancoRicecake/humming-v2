// 녹음 진폭 미터 — 인라인 녹음 중 시각화.
part of '../timeline_editor.dart';

class _RecMeterPainter extends CustomPainter {
  _RecMeterPainter({required this.levels});
  final List<double> levels;
  static const Color _rec = Color(0xFFFF4D4D);

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final w = size.width, h = size.height;
    final mid = h / 2;
    final paint = Paint()
      ..color = _rec
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final n = levels.length;
    final stride = w / n;
    for (int i = 0; i < n; i++) {
      final x = (i + 0.5) * stride;
      final amp = levels[i].clamp(0.0, 1.0) * (h * 0.42);
      canvas.drawLine(Offset(x, mid - amp), Offset(x, mid + amp), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RecMeterPainter old) => old.levels != levels;
}
