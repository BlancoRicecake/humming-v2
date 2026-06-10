// LoopTap — shared pad feedback: tap "pop" scale + white flash overlay + neon
// glow. Used by drum pads and live note/bass pads. (prototype shared.jsx fx.)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../state/loop_prefs.dart';
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
    this.slidable = false,
    this.onSlideStart,
    this.onSlide,
    this.onSlideEnd,
  });

  final Color accent;
  final double borderRadius;
  final Color idle;
  /// builds the pad body given whether it's currently "active".
  final Widget Function(bool active) builder;
  final bool lit;
  final VoidCallback? onDown;
  final VoidCallback? onUp;

  /// When true, a horizontal drag turns into a "slide" instead of a held note:
  /// the just-pressed note is cancelled ([onSlideStart]) and subsequent
  /// horizontal motion is reported as deltas ([onSlide], +dx = drag right).
  final bool slidable;
  final VoidCallback? onSlideStart;
  final ValueChanged<double>? onSlide;
  final VoidCallback? onSlideEnd;

  @override
  State<PadFx> createState() => _PadFxState();
}

class _PadFxState extends State<PadFx> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: LTMotion.pop);
  bool _pressed = false;

  // slide-gesture tracking
  static const double _slideThreshold = 10;
  Offset? _downPos;
  double _lastX = 0;
  bool _sliding = false;

  bool get _active => widget.lit || _pressed || _c.isAnimating;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down(Offset pos) {
    _downPos = pos;
    _lastX = pos.dx;
    _sliding = false;
    // Fire the sound FIRST so audio isn't queued behind the rebuild/animation.
    widget.onDown?.call();
    if (LoopPrefs.instance.haptics.value) HapticFeedback.lightImpact();
    setState(() => _pressed = true);
    _c.forward(from: 0);
  }

  void _move(Offset pos) {
    if (!widget.slidable || _downPos == null) return;
    if (!_sliding) {
      final dx = pos.dx - _downPos!.dx;
      final dy = pos.dy - _downPos!.dy;
      // become a slide only on a clearly-horizontal drag
      if (dx.abs() > _slideThreshold && dx.abs() > dy.abs()) {
        _sliding = true;
        _lastX = pos.dx;
        setState(() => _pressed = false);
        widget.onSlideStart?.call(); // host releases the just-pressed note
      }
      return;
    }
    final d = pos.dx - _lastX;
    _lastX = pos.dx;
    if (d != 0) widget.onSlide?.call(d);
  }

  void _up() {
    final wasSliding = _sliding;
    _sliding = false;
    _downPos = null;
    setState(() => _pressed = false);
    if (wasSliding) {
      widget.onSlideEnd?.call(); // settle/snap the strip
    } else {
      widget.onUp?.call(); // a slide doesn't commit a note
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) => _down(e.localPosition),
      onPointerMove: (e) => _move(e.localPosition),
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
                // Instant (non-animated) decoration — the lit state must snap on,
                // not ease in, or taps read as laggy.
                Container(
                  clipBehavior: Clip.antiAlias,
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
