// LoopTap — shared pad feedback: tap "pop" scale + white flash overlay + neon
// glow. Used by drum pads and live note/bass pads. (prototype shared.jsx fx.)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../theme/tokens.dart';

/// Wraps [child] with a press animation (pop scale + white flash) and an
/// active neon glow. [lit] forces the active look during loop playback.
class PadFx extends StatefulWidget {
  const PadFx({
    super.key,
    required this.accent,
    required this.borderRadius,
    required this.idle,
    required this.builder,
    this.lit = false,
    this.onDown,
    this.onUp,
  });

  final Color accent;
  final double borderRadius;
  final Color idle;
  /// builds the pad body given whether it's currently "active".
  final Widget Function(bool active) builder;
  final bool lit;
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  @override
  State<PadFx> createState() => _PadFxState();
}

class _PadFxState extends State<PadFx> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: LTMotion.pop);
  bool _pressed = false;

  bool get _active => widget.lit || _pressed || _c.isAnimating;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down() {
    setState(() => _pressed = true);
    _c.forward(from: 0);
    HapticFeedback.lightImpact();
    widget.onDown?.call();
  }

  void _up() {
    setState(() => _pressed = false);
    widget.onUp?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _down(),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          // pop: 1 -> 1.06 -> .97 -> 1 over the controller's life.
          final t = _c.value;
          double scale = 1;
          if (_c.isAnimating) {
            if (t < 0.3) {
              scale = 1 + (t / 0.3) * 0.06;
            } else if (t < 0.6) {
              scale = 1.06 - ((t - 0.3) / 0.3) * 0.09;
            } else {
              scale = 0.97 + ((t - 0.6) / 0.4) * 0.03;
            }
          }
          final active = _active;
          return Transform.scale(
            scale: scale,
            child: Stack(
              children: [
                AnimatedContainer(
                  duration: LTMotion.fast,
                  decoration: BoxDecoration(
                    color: active ? widget.accent : widget.idle,
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    border: Border.all(color: active ? widget.accent : LT.border, width: 2),
                    boxShadow: active
                        ? [BoxShadow(color: widget.accent.withValues(alpha: 0.8), blurRadius: 44, spreadRadius: 1)]
                        : [const BoxShadow(color: LT.bg, offset: Offset(0, -3))],
                  ),
                  child: widget.builder(active),
                ),
                // white flash on hit
                if (_c.isAnimating)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: (0.85 * (1 - t)).clamp(0, 0.85),
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(widget.borderRadius),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
