import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import '../../models/loop_models.dart';
import '../../music/theory.dart' show kBeatsPerBar, kStepsPerBeat;
import '../../music/timeline_view.dart';
import '../../theme/tokens.dart';
import 'pitch_grid_surface.dart' show PitchGridAxis;

/// Shares the piano-roll time axis. Chord notes keep the same time position;
/// selecting a note in the roll gives its velocity handle hit-test priority.
class VelocityLane extends StatefulWidget {
  const VelocityLane({
    super.key,
    required this.notes,
    required this.selected,
    required this.steps,
    required this.accent,
    required this.leftInset,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
    required this.onCancel,
    this.enabled = true,
    this.height = 76,
    this.chanceMode = false,
    this.onModeChanged,
    this.view,
    this.spreadStacked = false,
    this.simple = false,
  });
  final List<PitchNote> notes;
  final Set<PitchNote> selected;
  final int steps;
  final Color accent;
  final double leftInset, height;
  final bool enabled;
  final bool Function(PitchNote) onStart;
  final ValueChanged<int> onDelta;
  final VoidCallback onEnd, onCancel;

  /// Chance mode: bars show (and dragging edits) each note's play
  /// probability instead of its velocity. Drag deltas stay in 1/127 units.
  final bool chanceMode;
  final ValueChanged<bool>? onModeChanged;

  /// The piano roll's visible time range (zoom/pan); null = whole section.
  /// With [leftInset] = the roll's gutter width, x matches the grid exactly.
  final TimelineView? view;
  TimelineView get timeView => view ?? TimelineView(0, steps.toDouble());

  /// Phone (2026-11-02): notes that start together (a chord) get their bars
  /// side by side, low to high, so each one can be grabbed — instead of all
  /// on one x where only the top one could be reached.
  final bool spreadStacked;

  /// Phone: one plain heading ("세기" / "재생 확률") instead of the
  /// velocity | chance switch (chance moves to the grid's ⋯ sheet).
  final bool simple;
  @override
  State<VelocityLane> createState() => _VelocityLaneState();
}

/// Horizontal offsets (px) for bars of notes sharing a start: spread side by
/// side, ordered by pitch, at most 10 px apart and within ~90% of a step.
List<double> stackOffsets(List<PitchNote> notes, double stepPx) {
  final out = List<double>.filled(notes.length, 0);
  final groups = <int, List<int>>{};
  for (var i = 0; i < notes.length; i++) {
    groups.putIfAbsent((notes[i].startSteps * 100).round(), () => []).add(i);
  }
  for (final g in groups.values) {
    if (g.length < 2) continue;
    g.sort((a, b) => notes[a].midi.compareTo(notes[b].midi));
    final spacing = (stepPx * .9 / g.length).clamp(4.0, 10.0);
    for (var j = 0; j < g.length; j++) {
      out[g[j]] = (j - (g.length - 1) / 2) * spacing;
    }
  }
  return out;
}

/// The bar height (0..1) a note shows in the lane's current mode.
double _laneValue(PitchNote n, bool chance) =>
    chance ? n.chance : (n.velocity ?? 100) / 127;

class _VelocityLaneState extends State<VelocityLane> {
  int? _pointer, _active, _hover;
  double _startY = 0, _dragHeight = 1;
  int _delta = 0;
  Size _size = Size.zero;

  double _x(num step) => widget.timeView.fraction(step) * _size.width;

  List<double> get _offsets =>
      widget.spreadStacked
          ? stackOffsets(widget.notes, (_x(1) - _x(0)).abs())
          : List<double>.filled(widget.notes.length, 0);

  int? _hit(Offset p) {
    final offsets = _offsets;
    final candidates = <int>[];
    for (var i = 0; i < widget.notes.length; i++) {
      final n = widget.notes[i];
      if (n.startSteps < 0 || n.startSteps >= widget.steps) continue;
      if ((_x(n.startSteps) + offsets[i] - p.dx).abs() <= 8) {
        candidates.add(i);
      }
    }
    if (candidates.isEmpty) return null;
    final selected =
        candidates
            .where((i) => widget.selected.contains(widget.notes[i]))
            .toList();
    final pool = selected.isEmpty ? candidates : selected;
    double distance(int i) {
      final n = widget.notes[i];
      final x = _x(n.startSteps) + offsets[i];
      final y =
          _size.height -
          4 -
          _laneValue(n, widget.chanceMode) * (_size.height - 8);
      return (x - p.dx).abs() * 4 + (y - p.dy).abs();
    }

    pool.sort((a, b) => distance(a).compareTo(distance(b)));
    return pool.first;
  }

  void _down(PointerDownEvent e) {
    if (!widget.enabled || _pointer != null || e.buttons != kPrimaryButton) {
      return;
    }
    final index = _hit(e.localPosition);
    if (index == null) return;
    if (!widget.onStart(widget.notes[index])) return;
    setState(() {
      _pointer = e.pointer;
      _active = index;
      _startY = e.position.dy;
      _dragHeight = (_size.height - 8).clamp(1.0, double.infinity);
      _delta = 0;
    });
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
    setState(() {
      _pointer = null;
      _active = null;
    });
    widget.onEnd();
  }

  @override
  Widget build(BuildContext context) {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    final index = _active ?? _hover;
    final note =
        index != null && index < widget.notes.length
            ? widget.notes[index]
            : null;
    final name =
        note == null
            ? ''
            : '${const ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'][note.midi % 12]}${note.midi ~/ 12 - 1}';
    final detail =
        note == null
            ? (widget.simple
                ? (ko ? '막대를 위아래로 끌어 조절' : 'Drag a bar up or down')
                : ko
                ? '노트 선택 후 막대를 위아래로 끌기'
                : 'Select notes, then drag a bar up/down')
            : widget.chanceMode
            ? '$name · ${(note.chance * 100).round()}%${note.locked ? (ko ? ' · 잠김' : ' · Locked') : ''}'
            : '$name · ${note.velocity ?? (ko ? '기본' : 'Default')}${note.velocityDeviation == 0 ? '' : ' (${note.velocityDeviation > 0 ? '+' : ''}${note.velocityDeviation})'}${note.locked ? (ko ? ' · 잠김' : ' · Locked') : ''}';
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
                if (widget.simple) ...[
                  Text(
                    widget.chanceMode
                        ? (ko ? '재생 확률' : 'Play chance')
                        : (ko ? '세기' : 'Velocity'),
                    style: TextStyle(
                      fontSize: 10,
                      color: widget.accent,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                ] else ...[
                mode('velocity-lane-velocity', ko ? '강약' : 'Velocity', false),
                const Text(
                  ' | ',
                  style: TextStyle(fontSize: 10, color: LT.t3),
                ),
                mode('velocity-lane-chance', ko ? '확률' : 'Chance', true),
                const SizedBox(width: 8),
                ],
                Expanded(
                  child: Text(
                    detail,
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
              // right: the roll's scroll rail column (same x axis)
              padding: EdgeInsets.only(
                left: widget.leftInset,
                right: PitchGridAxis.scrollRailWidth,
              ),
              child: LayoutBuilder(
                builder: (context, c) {
                  _size = c.biggest;
                  return MouseRegion(
                    cursor:
                        widget.enabled
                            ? SystemMouseCursors.resizeUpDown
                            : SystemMouseCursors.basic,
                    onHover: (e) {
                      final hit = _hit(e.localPosition);
                      if (hit != _hover) setState(() => _hover = hit);
                    },
                    onExit: (_) => setState(() => _hover = null),
                    child: Tooltip(
                      message:
                          ko
                              ? '빈 원은 기본 세기입니다. 같은 시각의 화음은 위 그리드에서 노트를 먼저 선택하세요. 여러 노트는 강약 차이를 유지하며 함께 조절합니다.'
                              : 'Hollow heads use default velocity. For chords, select notes in the roll first. Group edits keep relative velocities.',
                      child: Listener(
                        key: const ValueKey('velocity-lane'),
                        behavior: HitTestBehavior.opaque,
                        onPointerDown: _down,
                        onPointerMove: _move,
                        onPointerUp: _up,
                        onPointerCancel: (e) {
                          if (_pointer != e.pointer) return;
                          setState(() {
                            _pointer = null;
                            _active = null;
                          });
                          widget.onCancel();
                        },
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _VelocityPainter(
                            List.of(widget.notes),
                            widget.selected,
                            widget.steps,
                            widget.accent,
                            widget.enabled,
                            widget.chanceMode,
                            widget.timeView,
                            _offsets,
                          ),
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

class _VelocityPainter extends CustomPainter {
  _VelocityPainter(
    this.notes,
    Set<PitchNote> selected,
    this.steps,
    this.accent,
    this.enabled,
    this.chance,
    this.view,
    this.offsets,
  ) : selected = Set.of(selected);
  final TimelineView view;
  final List<double> offsets;
  final List<PitchNote> notes;
  final Set<PitchNote> selected;
  final int steps;
  final Color accent;
  final bool enabled, chance;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    double xOf(num step) => view.fraction(step) * size.width;
    // same bar / beat hierarchy as the roll above
    for (var step = 0; step <= steps; step += kStepsPerBeat) {
      final x = xOf(step);
      if (x < -1 || x > size.width + 1) continue;
      final bar = step % (kBeatsPerBar * kStepsPerBeat) == 0;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = bar ? LT.t3 : LT.border
          ..strokeWidth = bar ? 1.5 : 1,
      );
    }
    // Selected stems are on top so coincident chord attacks remain editable.
    final order = [
      for (var i = 0; i < notes.length; i++)
        if (!selected.contains(notes[i])) i,
      for (var i = 0; i < notes.length; i++)
        if (selected.contains(notes[i])) i,
    ];
    for (final i in order) {
      final n = notes[i];
      final x = xOf(n.startSteps) + (i < offsets.length ? offsets[i] : 0);
      if (x < -4 || x > size.width + 4) continue;
      final y = size.height - 4 - _laneValue(n, chance) * (size.height - 8);
      final base =
          n.locked || !enabled
              ? LT.t3
              : selected.contains(n)
              ? accent
              : accent.withValues(alpha: .5);
      // deactivated notes keep their bar but read as inactive
      final color = n.muted ? base.withValues(alpha: base.a * .4) : base;
      final paint =
          Paint()
            ..color = color
            ..strokeWidth = selected.contains(n) ? 3 : 2;
      if (!chance && n.velocityDeviation != 0) {
        // shaded range the per-pass velocity can land in
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
  bool shouldRepaint(_VelocityPainter old) =>
      !listEquals(old.notes, notes) ||
      !setEquals(old.selected, selected) ||
      old.steps != steps ||
      old.enabled != enabled ||
      old.chance != chance ||
      old.view.start != view.start ||
      old.view.end != view.end ||
      !listEquals(old.offsets, offsets) ||
      old.accent != accent;
}
