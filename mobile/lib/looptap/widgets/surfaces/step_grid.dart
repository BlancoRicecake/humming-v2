// LoopTap — Melody Grid (precise step sequencer). README §5.
// Tap places a note; drag lengthens it; notes merge only when their spans
// actually overlap. Tapping an existing note erases it. Rows = 8 in-key
// pitches (high -> low); cols = steps. Beat guides every 4 steps.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../../models/loop_models.dart';
import '../../music/theory.dart';
import '../../state/loop_prefs.dart';
import '../../theme/tokens.dart';

class _Draft {
  _Draft(this.row, this.rung, this.a, this.b);
  final int row;
  final Rung rung;
  final int a;
  int b;
}

class StepGrid extends StatefulWidget {
  const StepGrid({
    super.key,
    required this.ladder,
    required this.notes,
    required this.onPlace,
    required this.onErase,
    required this.playStep,
    required this.accent,
    required this.steps,
    required this.bars,
    this.windowOffset = 0,
    this.maxOffset = 0,
    this.onWindowChanged,
  });

  final List<Rung> ladder;
  final List<PitchNote> notes;
  final void Function(Rung rung, int a, int b) onPlace;
  final void Function(Rung rung, int step) onErase;
  final double playStep;
  final Color accent;
  final int steps;
  final int bars;

  /// Current pitch-window offset (shared with the pads) and its max, plus a
  /// callback to move it — dragging the row labels vertically scrolls the range.
  final int windowOffset;
  final int maxOffset;
  final ValueChanged<int>? onWindowChanged;

  @override
  State<StepGrid> createState() => _StepGridState();
}

class _StepGridState extends State<StepGrid> with SingleTickerProviderStateMixin {
  final GlobalKey _laneKey = GlobalKey();
  _Draft? _draft;
  String? _mode; // 'paint' | 'erase'

  // row-label vertical drag → pitch-window scroll accumulator.
  double _winAccum = 0;
  int _winOffset = 0;

  // gentle pulse for the active hold-drag preview ("release to place")
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  List<Rung> get _rows => widget.ladder.reversed.toList();

  int _stepFromX(double localX, double width) =>
      (localX / width * widget.steps).floor().clamp(0, widget.steps - 1);

  int _rowFromY(double localY, double height) =>
      (localY / height * _rows.length).floor().clamp(0, _rows.length - 1);

  PitchNote? _noteAt(int midi, int step) {
    for (final n in widget.notes) {
      if (n.midi == midi && step >= n.step && step < n.step + n.dur) return n;
    }
    return null;
  }

  ({int row, int step})? _hit(Offset global) {
    final box = _laneKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    final size = box.size;
    if (local.dx < 0 || local.dy < 0 || local.dx > size.width || local.dy > size.height) {
      // clamp instead of rejecting so drags that slip past the edge still track
    }
    return (
      row: _rowFromY(local.dy.clamp(0, size.height - 0.01), size.height),
      step: _stepFromX(local.dx.clamp(0, size.width - 0.01), size.width),
    );
  }

  void _down(PointerDownEvent e) {
    final h = _hit(e.position);
    if (h == null) return;
    final rung = _rows[h.row];
    final existing = _noteAt(rung.midi, h.step);
    if (LoopPrefs.instance.haptics.value) HapticFeedback.selectionClick();
    if (existing != null) {
      _mode = 'erase';
      widget.onErase(rung, h.step);
    } else {
      _mode = 'paint';
      setState(() => _draft = _Draft(h.row, rung, h.step, h.step));
    }
  }

  void _move(PointerMoveEvent e) {
    final h = _hit(e.position);
    if (h == null) return;
    if (_mode == 'erase') {
      final ex = _noteAt(_rows[h.row].midi, h.step);
      if (ex != null) widget.onErase(_rows[h.row], h.step);
      return;
    }
    if (_mode == 'paint' && _draft != null && h.row == _draft!.row) {
      setState(() => _draft!.b = h.step);
    }
  }

  void _up(PointerUpEvent e) {
    if (_mode == 'paint' && _draft != null) {
      widget.onPlace(_draft!.rung, _draft!.a, _draft!.b);
    }
    setState(() => _draft = null);
    _mode = null;
  }

  @override
  Widget build(BuildContext context) {
    final beats = widget.bars * kBeatsPerBar;
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              // note-name labels (root colored). Drag vertically to move the
              // pitch window — the grid then reaches the full slide range.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: widget.onWindowChanged == null
                    ? null
                    : (_) {
                        _winAccum = 0;
                        _winOffset = widget.windowOffset;
                      },
                onVerticalDragUpdate: widget.onWindowChanged == null
                    ? null
                    : (d) {
                        _winAccum += d.delta.dy;
                        const sens = 24.0; // px per pitch step
                        // drag down → reveal higher pitches (offset increases)
                        while (_winAccum.abs() >= sens) {
                          final dir = _winAccum > 0 ? 1 : -1;
                          _winAccum -= dir * sens;
                          _winOffset = (_winOffset + dir).clamp(0, widget.maxOffset);
                          widget.onWindowChanged!(_winOffset);
                        }
                      },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // scroll affordance rail: ▲ higher / grip / ▼ lower. The
                    // arrow lights up while there's more range in that direction.
                    if (widget.onWindowChanged != null)
                      SizedBox(
                        width: 13,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Icon(Icons.keyboard_arrow_up,
                                size: 13,
                                color: widget.windowOffset < widget.maxOffset
                                    ? widget.accent
                                    : LT.t3.withValues(alpha: 0.25)),
                            Icon(Icons.drag_indicator, size: 11, color: LT.t3.withValues(alpha: 0.4)),
                            Icon(Icons.keyboard_arrow_down,
                                size: 13,
                                color: widget.windowOffset > 0
                                    ? widget.accent
                                    : LT.t3.withValues(alpha: 0.25)),
                          ],
                        ),
                      ),
                    SizedBox(
                      width: 28,
                      child: Column(
                        children: [
                          for (final n in _rows)
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: Text(n.name,
                                      style: LTType.mono(
                                          size: 9, weight: FontWeight.w700, color: n.degree == 0 ? widget.accent : LT.t3)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Listener(
                  onPointerDown: _down,
                  onPointerMove: _move,
                  onPointerUp: _up,
                  behavior: HitTestBehavior.opaque,
                  child: AnimatedBuilder(
                    animation: _pulse,
                    builder: (_, __) => CustomPaint(
                      key: _laneKey,
                      size: Size.infinite,
                      painter: _GridPainter(
                        rows: _rows,
                        notes: widget.notes,
                        draft: _draft,
                        playStep: widget.playStep,
                        steps: widget.steps,
                        beats: beats,
                        accent: widget.accent,
                        pulse: _draft != null ? _pulse.value : 0,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        // beat numbers (aligned to the lane start: rail 13 + labels 28 + gap 4)
        Padding(
          padding: const EdgeInsets.only(left: 45, top: 5),
          child: Row(
            children: [
              for (var b = 0; b < beats; b++)
                Expanded(
                  child: Text('${b + 1}', style: LTType.mono(size: 9, color: LT.t3)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.rows,
    required this.notes,
    required this.draft,
    required this.playStep,
    required this.steps,
    required this.beats,
    required this.accent,
    required this.pulse,
  });

  final List<Rung> rows;
  final List<PitchNote> notes;
  final _Draft? draft;
  final double playStep;
  final int steps;
  final int beats;
  final Color accent;
  final double pulse; // 0..1 while a hold-drag is active

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final rowH = h / rows.length;
    final stepW = w / steps;
    const gap = 3.0;

    // row backgrounds + beat guides
    final bgPaint = Paint()..color = LT.surface;
    final guidePaint = Paint()..color = LT.bg;
    final altPaint = Paint()..color = Colors.white.withValues(alpha: 0.02);
    for (var r = 0; r < rows.length; r++) {
      final top = r * rowH;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, top + gap / 2, w, rowH - gap),
        const Radius.circular(5),
      );
      canvas.drawRRect(rect, bgPaint);
      // beat shading (alternate beats) + guide lines
      for (var b = 0; b < beats; b++) {
        final x = b * (w / beats);
        if (b.isEven) {
          canvas.drawRect(Rect.fromLTWH(x, top + gap / 2, w / beats, rowH - gap), altPaint);
        }
        if (b > 0) {
          canvas.drawRect(Rect.fromLTWH(x, top + gap / 2, 1, rowH - gap), guidePaint);
        }
      }
    }

    // playhead cell column
    final cur = playStep.floor() % steps;
    canvas.drawRect(
      Rect.fromLTWH(cur * stepW, 0, stepW, h),
      Paint()..color = LT.t1.withValues(alpha: 0.08),
    );

    // notes
    final notePaint = Paint()..color = accent;
    final glow = Paint()
      ..color = accent.withValues(alpha: 0.6)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    for (var r = 0; r < rows.length; r++) {
      final midi = rows[r].midi;
      for (final n in notes.where((n) => n.midi == midi)) {
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(n.step * stepW, r * rowH + gap, n.dur * stepW - 2, rowH - gap * 2),
          const Radius.circular(4),
        );
        canvas.drawRRect(rect, glow);
        canvas.drawRRect(rect, notePaint);
      }
    }

    // draft preview (active hold-drag) — make the "lengthening" obvious:
    // highlighted row, glowing growing bar, a bright grip at the moving edge,
    // and a length readout. Release places it.
    if (draft != null) {
      final d = draft!;
      final lo = d.a < d.b ? d.a : d.b;
      final hi = d.a < d.b ? d.b : d.a;
      final len = hi - lo + 1;
      final top = d.row * rowH + gap;
      final bh = rowH - gap * 2;
      final p = 0.5 + 0.5 * pulse; // 0.5..1 breathing

      // row highlight band
      canvas.drawRect(
        Rect.fromLTWH(0, d.row * rowH, w, rowH),
        Paint()..color = accent.withValues(alpha: 0.10),
      );

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(lo * stepW, top, len * stepW - 2, bh),
        const Radius.circular(4),
      );
      // glow + fill
      canvas.drawRRect(
        rect,
        Paint()
          ..color = accent.withValues(alpha: 0.5 * p)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );
      canvas.drawRRect(rect, Paint()..color = accent.withValues(alpha: 0.9));
      canvas.drawRRect(
        rect,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.4 + 0.5 * pulse)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );

      // grip at the moving edge (where the finger controls the length)
      final movingRight = d.b >= d.a;
      final gripX = movingRight ? (hi + 1) * stepW : lo * stepW;
      final cy = top + bh / 2;
      canvas.drawRect(
        Rect.fromLTWH(gripX - 1.5, top - 2, 3, bh + 4),
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(Offset(gripX, cy), 7 + 1.5 * pulse, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(gripX, cy), 3.5, Paint()..color = accent);

      // length readout near the grip
      final tp = TextPainter(
        text: TextSpan(
          text: '$len',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: LT.bg,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelX = (movingRight ? gripX + 6 : gripX - 6 - tp.width).clamp(0.0, w - tp.width);
      final labelY = (top - tp.height - 2).clamp(0.0, h - tp.height);
      // label chip
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(labelX - 3, labelY - 1, tp.width + 6, tp.height + 2),
          const Radius.circular(4),
        ),
        Paint()..color = accent,
      );
      tp.paint(canvas, Offset(labelX, labelY));
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.notes != notes ||
      old.draft != draft ||
      old.playStep != playStep ||
      old.steps != steps ||
      old.pulse != pulse;
}
