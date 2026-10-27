import 'package:flutter/material.dart';
import '../music/audition.dart';
import '../music/timeline_view.dart';
import '../theme/tokens.dart';

class TimelineRuler extends StatelessWidget {
  const TimelineRuler({
    super.key,
    required this.view,
    required this.steps,
    this.loopRange,
    this.onSeek,
  });
  final TimelineView view;
  final int steps;
  final PlaybackRange? loopRange;
  final ValueChanged<double>? onSeek;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final width = c.maxWidth;
      final stride = (36 /
              (width.clamp(1.0, double.infinity) * 16 / view.length))
          .ceil()
          .clamp(1, 10000);
      final a =
          loopRange == null
              ? 0.0
              : view.fraction(loopRange!.start).clamp(0.0, 1.0);
      final b =
          loopRange == null
              ? 0.0
              : view.fraction(loopRange!.end).clamp(0.0, 1.0);
      return GestureDetector(
        key: const ValueKey('timeline-ruler'),
        behavior: HitTestBehavior.opaque,
        onTapDown:
            onSeek == null
                ? null
                : (d) => onSeek!(view.stepAt(d.localPosition.dx / width)),
        child: ClipRect(
          child: Stack(
            children: [
              if (b > a)
                Positioned(
                  left: a * width,
                  width: (b - a) * width,
                  top: 0,
                  bottom: 0,
                  child: ColoredBox(color: LT.lime.withValues(alpha: .10)),
                ),
              for (
                var bar = (view.start / 16).floor();
                bar * 16 < view.end && bar * 16 < steps;
                bar++
              )
                Positioned(
                  left: view.fraction(bar * 16) * width,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.only(left: 5, top: 3),
                    decoration: const BoxDecoration(
                      border: Border(left: BorderSide(color: LT.borderStrong)),
                    ),
                    child: Text(
                      bar % stride == 0 ? '${bar + 1}' : '',
                      key: ValueKey('timeline-bar-${bar + 1}'),
                      style: const TextStyle(fontSize: 11, color: LT.t2),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
