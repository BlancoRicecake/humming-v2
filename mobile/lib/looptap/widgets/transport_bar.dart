// LoopTap — transport bar (README §4.6, prototype/timeline.jsx TransportBar).
// left: metronome · count-in · loop(always on) · BPM stepper
// center: stop · play(lime) · record(red ring)
// right: SWING slider · 2|4 bars · clear track
import 'package:flutter/material.dart';

import '../theme/atoms.dart';
import '../theme/tokens.dart';

class TransportBar extends StatelessWidget {
  const TransportBar({
    super.key,
    required this.playing,
    required this.recording,
    required this.onPlay,
    required this.onStop,
    required this.onRec,
    required this.bpm,
    required this.onBpm,
    required this.metro,
    required this.onMetro,
    required this.countIn,
    required this.onCountIn,
    required this.onClear,
    required this.swing,
    required this.onSwing,
    required this.bars,
    required this.onBars,
    this.showRecord = true,
  });

  final bool playing;
  final bool recording;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onRec;
  final int bpm;
  final ValueChanged<int> onBpm;
  final bool metro;
  final ValueChanged<bool> onMetro;
  final bool countIn;
  final ValueChanged<bool> onCountIn;
  final VoidCallback onClear;
  final double swing; // 0..0.6
  final ValueChanged<double> onSwing;
  final int bars; // 2 | 4
  final ValueChanged<int> onBars;
  final bool showRecord; // hidden on the vocal track (it has its own record ring)

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        // ── left: options ──
        // 작은 폰(iPhone SE 등) 에선 BPM stepper + 아이콘 3개 합이 부모 너비를
        // 넘으므로 FittedBox scaleDown 으로 비율 유지하며 축소. clipBehavior 로
        // overflow 데코(노란 빗금)도 안 뜨게.
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconBtn(icon: LtIcons.straighten, active: metro, tooltip: 'Metronome', onTap: () => onMetro(!metro)),
                const SizedBox(width: 8),
                IconBtn(icon: LtIcons.timer, active: countIn, tooltip: 'Count-in', onTap: () => onCountIn(!countIn)),
                const SizedBox(width: 8),
                const IconBtn(icon: LtIcons.repeat, active: true, tooltip: 'Loop (always on)'),
                const SizedBox(width: 12),
                _BpmStepper(bpm: bpm, onBpm: onBpm),
              ],
            ),
          ),
        ),
        // ── center: transport ──
        // 사이즈 위계: Play(52) > Record(44) > Stop(38). 줄어든 만큼 bar 전체
        // 높이도 줄어듦 (Row 높이 = 가장 큰 자식 = Play).
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconBtn(icon: LtIcons.stop, size: 38, tooltip: 'Stop', onTap: onStop),
            const SizedBox(width: 14),
            // play
            GestureDetector(
              onTap: onPlay,
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: LT.lime,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: LT.lime.withValues(alpha: 0.4), blurRadius: 24)],
                ),
                child: Center(child: Ms(playing ? LtIcons.pause : LtIcons.playArrow, size: 26, color: LT.bg, fill: 1)),
              ),
            ),
            if (showRecord) ...[
              const SizedBox(width: 14),
              // record
              GestureDetector(
                onTap: onRec,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: recording ? LT.danger : LT.surface2,
                    shape: BoxShape.circle,
                    border: Border.all(color: LT.danger, width: 2),
                    boxShadow: recording ? [BoxShadow(color: LT.danger.withValues(alpha: 0.53), blurRadius: 24)] : null,
                  ),
                  child: Center(
                    child: Container(
                      width: 15,
                      height: 15,
                      decoration: const BoxDecoration(color: LT.danger, shape: BoxShape.circle),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        // 좌측 BPM stepper 뒤의 SizedBox(width: 12) 와 대칭 맞추기 — Record 와
        // "Swing" 라벨이 딱 붙어 보이던 문제.
        const SizedBox(width: 12),
        // ── right: swing + bars + clear ──
        // 좌측과 동일한 이유로 FittedBox scaleDown. alignment 는 centerRight 라
        // 큰 폰에선 기존처럼 오른쪽 정렬, 좁아지면 비율 유지하며 자연 축소.
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LtLabel('Swing', color: swing > 0 ? LT.lime : LT.t3),
                SizedBox(
                  width: 84,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: LT.lime,
                      inactiveTrackColor: LT.surface3,
                      thumbColor: LT.lime,
                      overlayShape: SliderComponentShape.noOverlay,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      min: 0,
                      max: 60,
                      value: (swing * 100).clamp(0, 60),
                      onChanged: (v) => onSwing(v / 100),
                    ),
                  ),
                ),
                SizedBox(
                  width: 30,
                  child: Text('${(swing * 100).round()}%', style: LTType.mono(size: 11, color: LT.t2)),
                ),
                const SizedBox(width: 10),
                _BarsToggle(bars: bars, onBars: onBars),
                const SizedBox(width: 10),
                IconBtn(icon: LtIcons.backspace, tooltip: 'Clear track', onTap: onClear),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BpmStepper extends StatelessWidget {
  const _BpmStepper({required this.bpm, required this.onBpm});
  final int bpm;
  final ValueChanged<int> onBpm;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(LTRadius.pill),
        border: Border.all(color: LT.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepBtn('−', () => onBpm((bpm - 1).clamp(40, 220))),
          SizedBox(
            width: 58,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text('$bpm', style: LTType.mono(size: 15, weight: FontWeight.w700, color: LT.t1)),
                const SizedBox(width: 3),
                Text('BPM', style: LTType.inter(size: 9, color: LT.t3)),
              ],
            ),
          ),
          _StepBtn('+', () => onBpm((bpm + 1).clamp(40, 220))),
        ],
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  const _StepBtn(this.glyph, this.onTap);
  final String glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 26,
        height: 26,
        child: Center(
          child: Text(glyph, style: LTType.inter(size: 18, weight: FontWeight.w700, color: LT.t1)),
        ),
      ),
    );
  }
}

class _BarsToggle extends StatelessWidget {
  const _BarsToggle({required this.bars, required this.onBars});
  final int bars;
  final ValueChanged<int> onBars;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(LTRadius.pill),
        border: Border.all(color: LT.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final b in const [2, 4])
            GestureDetector(
              onTap: () => onBars(b),
              child: Container(
                width: 28,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: bars == b ? LT.lime : Colors.transparent,
                  borderRadius: BorderRadius.circular(LTRadius.pill),
                ),
                child: Text('$b',
                    style: LTType.inter(size: 12, weight: FontWeight.w800, color: bars == b ? LT.bg : LT.t2)),
              ),
            ),
        ],
      ),
    );
  }
}
