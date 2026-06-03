// 깜박이는 빨간 점 — 녹음 중 표시.
part of '../timeline_editor.dart';

class _BlinkDot extends StatefulWidget {
  @override
  State<_BlinkDot> createState() => _BlinkDotState();
}

class _BlinkDotState extends State<_BlinkDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
            color: const Color(0xFFFF4D4D).withValues(alpha: 0.35 + 0.65 * _ctrl.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
