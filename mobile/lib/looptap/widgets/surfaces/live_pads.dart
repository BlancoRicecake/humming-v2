// LoopTap — live note pads (Melody / Melody-fill / Bass). README §5.
// Tap = play; hold longer = longer note (printed on release while recording).
// The pads are a horizontal strip of the whole in-key ladder; only a few are
// visible and you SWIPE the strip (it glides like a train, then snaps to a pad)
// to reach higher/lower notes — all within the song's current scale.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../music/theory.dart';
import '../../theme/pad_scale.dart';
import '../../theme/tokens.dart';
import 'pad_fx.dart';

class _LivePad extends StatelessWidget {
  const _LivePad({
    required this.rung,
    required this.label,
    required this.sub,
    required this.lit,
    required this.accent,
    required this.onDown,
    required this.onUp,
    this.slidable = false,
    this.onSlideStart,
    this.onSlide,
    this.onSlideEnd,
  });

  final Rung rung;
  final String label;
  final String sub;
  final bool lit;
  final Color accent;
  final ValueChanged<Rung> onDown;
  final ValueChanged<Rung> onUp;
  final bool slidable;
  final ValueChanged<Rung>? onSlideStart;
  final ValueChanged<double>? onSlide;
  final VoidCallback? onSlideEnd;

  @override
  Widget build(BuildContext context) {
    return PadFx(
      accent: accent,
      borderRadius: 18,
      idle: LT.surface2,
      lit: lit,
      onDown: () => onDown(rung),
      onUp: () => onUp(rung),
      slidable: slidable,
      onSlideStart: onSlideStart == null ? null : () => onSlideStart!(rung),
      onSlide: onSlide,
      onSlideEnd: onSlideEnd,
      builder: (active) => LayoutBuilder(
        builder: (ctx, c) {
          // Size label/sub from the pad's own box so they scale with the pad on
          // every device + surface size (see PadScale).
          final sc = PadScale(math.min(c.maxWidth, c.maxHeight));
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: LTType.inter(size: sc.title, weight: FontWeight.w900, color: active ? LT.bg : LT.t1)),
                SizedBox(height: sc.gap),
                Text(sub,
                    style: LTType.mono(size: sc.sub, color: active ? LT.bg.withValues(alpha: 0.67) : LT.t3)),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Pitched live pads (melody / melody-fill / bass). [ladder] is the FULL in-key
/// ladder (~3 octaves); [visibleCount] pads fit on screen and a horizontal swipe
/// glides the strip and snaps to a pad. [offset] is the leftmost visible pad.
class NotePads extends StatefulWidget {
  const NotePads({
    super.key,
    required this.ladder,
    required this.visibleCount,
    required this.offset,
    required this.litMidis,
    required this.accent,
    required this.onDown,
    required this.onUp,
    required this.onSlideStart,
    required this.onOffsetChanged,
  });

  final List<Rung> ladder;
  final int visibleCount;
  final int offset;
  final Set<int> litMidis;
  final Color accent;
  final ValueChanged<Rung> onDown;
  final ValueChanged<Rung> onUp;

  /// Called when a swipe begins so the host can release the just-pressed note.
  final ValueChanged<Rung> onSlideStart;

  /// Called with the snapped leftmost-pad index after a swipe settles.
  final ValueChanged<int> onOffsetChanged;

  @override
  State<NotePads> createState() => _NotePadsState();
}

class _NotePadsState extends State<NotePads> with SingleTickerProviderStateMixin {
  late double _scroll = widget.offset.toDouble(); // current position, in pad units
  double _padW = 1;
  bool _dragging = false;

  late final AnimationController _snap =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  Animation<double>? _snapAnim;

  double get _maxScroll =>
      (widget.ladder.length - widget.visibleCount).toDouble().clamp(0, double.infinity);

  @override
  void didUpdateWidget(NotePads old) {
    super.didUpdateWidget(old);
    // Sync to an externally-driven offset change (octave stepper / key change),
    // but never yank the strip mid-gesture or mid-snap.
    if (!_dragging && !_snap.isAnimating && widget.offset != _scroll.round()) {
      _scroll = widget.offset.toDouble();
    }
    _scroll = _scroll.clamp(0, _maxScroll);
  }

  @override
  void dispose() {
    _snap.dispose();
    super.dispose();
  }

  void _slideStart(Rung r) {
    _dragging = true;
    _snap.stop();
    widget.onSlideStart(r);
  }

  void _slide(double dx) {
    // drag left (negative dx) reveals higher notes; +dx lowers.
    setState(() => _scroll = (_scroll - dx / _padW).clamp(0, _maxScroll));
  }

  void _slideEnd() {
    _dragging = false;
    final target = _scroll.round().clamp(0, _maxScroll.round()).toDouble();
    _snapAnim = Tween<double>(begin: _scroll, end: target)
        .animate(CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic))
      ..addListener(() => setState(() => _scroll = _snapAnim!.value));
    _snap.forward(from: 0).whenComplete(() => widget.onOffsetChanged(target.round()));
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.ladder.length;
    return LayoutBuilder(
      builder: (ctx, c) {
        _padW = c.maxWidth / widget.visibleCount;
        return ClipRect(
          child: Stack(
            children: [
              Positioned(
                left: -_scroll * _padW,
                top: 0,
                bottom: 0,
                width: _padW * n,
                child: Row(
                  children: [
                    for (var i = 0; i < n; i++)
                      SizedBox(
                        width: _padW,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: _LivePad(
                            rung: widget.ladder[i],
                            label: widget.ladder[i].name,
                            sub: 'deg ${widget.ladder[i].degree + 1}',
                            lit: widget.litMidis.contains(widget.ladder[i].midi),
                            accent: widget.accent,
                            onDown: widget.onDown,
                            onUp: widget.onUp,
                            slidable: true,
                            onSlideStart: _slideStart,
                            onSlide: _slide,
                            onSlideEnd: _slideEnd,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
