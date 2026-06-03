// BPM 펄스 dot — 박자 보정 카드에서 메트로놈 박과 동기.
part of '../active_track_cards.dart';

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.bpm});
  final int bpm;
  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: _period())..repeat();
    _pulse = _buildPulse();
  }

  Duration _period() => Duration(milliseconds: (60000 / widget.bpm).round().clamp(150, 2000));

  /// 비트 시작 시 즉시 피크, 이후 감쇠 — 메트로놈 클릭과 위상 일치.
  Animation<double> _buildPulse() => Tween<double>(begin: 1, end: 0)
      .chain(CurveTween(curve: Curves.easeIn))
      .animate(_ctrl);

  @override
  void didUpdateWidget(covariant _PulseDot old) {
    super.didUpdateWidget(old);
    if (old.bpm != widget.bpm) {
      _ctrl.duration = _period();
      _ctrl.stop();
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (_, __) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: AppColors.lime.withValues(alpha: 0.2 + 0.8 * _pulse.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
