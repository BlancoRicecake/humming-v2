// 보컬 파형 페인터 — peaks 를 0..vocalDur 구간에 중앙 대칭으로 채워 그림.
part of '../timeline_editor.dart';

/// 보컬 파형 — peaks 를 0..vocalDur 구간에 중앙 대칭으로 채워 그림.
class _WavePainter extends CustomPainter {
  _WavePainter({required this.peaks, required this.vocalDur, required this.totalDur, required this.active});
  final List<double> peaks;
  final double vocalDur, totalDur;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || totalDur <= 0) return;
    final w = (vocalDur / totalDur) * size.width;
    final cy = size.height / 2;
    final paint = Paint()..color = active ? AppColors.lime : AppColors.textSecondary;
    final n = peaks.length;
    final step = w / n;
    for (int i = 0; i < n; i++) {
      final h = (peaks[i] * size.height * 0.9).clamp(1.0, size.height);
      final x = i * step;
      canvas.drawRect(Rect.fromLTWH(x, cy - h / 2, step.clamp(0.6, 3.0), h), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.peaks != peaks || old.vocalDur != vocalDur || old.totalDur != totalDur || old.active != active;
}
