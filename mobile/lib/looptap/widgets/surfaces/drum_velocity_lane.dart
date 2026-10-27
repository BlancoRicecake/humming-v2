// drums-001: velocity / chance lane under the drum grid. Same gesture model as
// VelocityLane (one drag = one relative edit of the selection), showing the
// hits of one focused drum row.
import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';

import '../../models/loop_models.dart';
import '../../theme/tokens.dart';

class DrumVelocityLane extends StatefulWidget {
  const DrumVelocityLane({
    super.key,
    required this.notes,
    required this.selected,
    required this.steps,
    required this.accent,
    required this.leftInset,
    required this.rowLabel,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
    required this.onCancel,
    this.enabled = true,
    this.height = 76,
    this.chanceMode = false,
    this.onModeChanged,
  });

  /// The focused row's hits.
  final List<DrumNote> notes;
  final Set<DrumNote> selected;
  final int steps;
  final Color accent;
  final double leftInset, height;
  final String rowLabel;
  final bool enabled;
  final bool Function(DrumNote) onStart;
  final ValueChanged<int> onDelta;
  final VoidCallback onEnd, onCancel;
  final bool chanceMode;
  final ValueChanged<bool>? onModeChanged;
  @override
  State<DrumVelocityLane> createState() => _DrumVelocityLaneState();
}

double _laneValue(DrumNote n, bool chance) =>
    chance ? n.chance : (n.velocity ?? 100) / 127;

class _DrumVelocityLaneState extends State<DrumVelocityLane> {
  int? _pointer;
  double _startY = 0, _dragHeight = 1;
  int _delta = 0;
  Size _size = Size.zero;

  double _x(DrumNote n) =>
      (n.startSteps + .5) / widget.steps * _size.width;

  DrumNote? _hit(Offset p) {
    final candidates = [
      for (final n in widget.notes)
        if (n.startSteps >= 0 &&
            n.startSteps < widget.steps &&
            (_x(n) - p.dx).abs() <= 10)
          n,
    ];
    if (candidates.isEmpty) return null;
    final selected = candidates.where(widget.selected.contains).toList();
    final pool = selected.isEmpty ? candidates : selected;
    double distance(DrumNote n) {
      final y =
          _size.height -
          4 -
          _laneValue(n, widget.chanceMode) * (_size.height - 8);
      return (_x(n) - p.dx).abs() * 4 + (y - p.dy).abs();
    }

    pool.sort((a, b) => distance(a).compareTo(distance(b)));
    return pool.first;
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null || e.buttons != kPrimaryButton) {
      return;
    }
    final hit = _hit(e.localPosition);
    if (hit == null || !widget.onStart(hit)) return;
    _pointer = e.pointer;
    _startY = e.position.dy;
    _dragHeight = (_size.height - 8).clamp(1.0, double.infinity);
    _delta = 0;
  }

  void _move(PointerMoveEvent e) {
    if (_pointer != e.pointer || _size.height <= 8) return;
    final dy = e.position.dy - _startY;
    if (dy.abs() < 3 && _delta == 0) return;
    final delta = (-dy / _dragHeight * 127).round().clamp(-126, 126);
    if (delta == _delta) return;
    _delta = delta;
    widget.onDelta(delta);
  }

  void _up(PointerUpEvent e) {
    if (_pointer != e.pointer) return;
    _pointer = null;
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    Widget mode(String key, String label, bool chance) => InkWell(
      key: ValueKey(key),
      onTap:
          widget.onModeChanged == null || widget.chanceMode == chance
              ? null
              : () => widget.onModeChanged!(chance),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: widget.chanceMode == chance ? widget.accent : LT.t3,
          fontWeight:
              widget.chanceMode == chance ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
    );
    return SizedBox(
      height: widget.height,
      child: Column(
        children: [
          SizedBox(
            height: 18,
            child: Row(
              children: [
                mode('drum-lane-velocity', ko ? '강약' : 'Velocity', false),
                const Text(
                  ' | ',
                  style: TextStyle(fontSize: 10, color: LT.t3),
                ),
                mode('drum-lane-chance', ko ? '확률' : 'Chance', true),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.rowLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, color: LT.t3),
                  ),
                ),
                Text(
                  widget.chanceMode ? '0–100%' : '1–127',
                  style: const TextStyle(fontSize: 10, color: LT.t3),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(left: widget.leftInset),
              child: LayoutBuilder(
                builder: (context, c) {
                  _size = c.biggest;
                  return MouseRegion(
                    cursor:
                        widget.enabled
                            ? SystemMouseCursors.resizeUpDown
                            : SystemMouseCursors.basic,
                    child: Listener(
                      key: const ValueKey('drum-velocity-lane'),
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _down,
                      onPointerMove: _move,
                      onPointerUp: _up,
                      onPointerCancel: (e) {
                        if (_pointer != e.pointer) return;
                        _pointer = null;
                        widget.onCancel();
                      },
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _DrumLanePainter(
                          List.of(widget.notes),
                          Set.of(widget.selected),
                          widget.steps,
                          widget.accent,
                          widget.enabled,
                          widget.chanceMode,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DrumLanePainter extends CustomPainter {
  _DrumLanePainter(
    this.notes,
    this.selected,
    this.steps,
    this.accent,
    this.enabled,
    this.chance,
  );
  final List<DrumNote> notes;
  final Set<DrumNote> selected;
  final int steps;
  final Color accent;
  final bool enabled, chance;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    for (var step = 0; step < steps; step += 4) {
      final x = step / steps * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()..color = LT.border,
      );
    }
    final ordered = [
      ...notes.where((n) => !selected.contains(n)),
      ...notes.where(selected.contains),
    ];
    for (final n in ordered) {
      final x = (n.startSteps + .5) / steps * size.width;
      final y = size.height - 4 - _laneValue(n, chance) * (size.height - 8);
      final base =
          !enabled
              ? LT.t3
              : selected.contains(n)
              ? accent
              : accent.withValues(alpha: .5);
      final color = n.muted ? base.withValues(alpha: base.a * .4) : base;
      final paint =
          Paint()
            ..color = color
            ..strokeWidth = selected.contains(n) ? 3 : 2;
      if (!chance && n.velocityDeviation != 0) {
        final other = ((n.velocity ?? 100) + n.velocityDeviation).clamp(1, 127);
        final y2 = size.height - 4 - other / 127 * (size.height - 8);
        canvas.drawRect(
          Rect.fromLTRB(x - 3, y < y2 ? y : y2, x + 3, y < y2 ? y2 : y),
          Paint()..color = color.withValues(alpha: color.a * .35),
        );
      }
      canvas.drawLine(Offset(x, size.height - 3), Offset(x, y), paint);
      if (chance ? n.chance >= 1 : n.velocity == null) {
        paint.style = PaintingStyle.stroke;
      }
      canvas.drawCircle(Offset(x, y), selected.contains(n) ? 3.5 : 2.5, paint);
    }
  }

  @override
  bool shouldRepaint(_DrumLanePainter old) =>
      !listEquals(old.notes, notes) ||
      !setEquals(old.selected, selected) ||
      old.steps != steps ||
      old.enabled != enabled ||
      old.chance != chance ||
      old.accent != accent;
}
