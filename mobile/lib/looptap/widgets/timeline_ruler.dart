import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import '../music/audition.dart';
import '../music/timeline_view.dart';
import '../theme/tokens.dart';

class TimelineRuler extends StatefulWidget {
  const TimelineRuler({
    super.key,
    required this.view,
    required this.steps,
    this.loopRange,
    this.onSeek,
    this.onRange,
    this.rangeEnabled = true,
  });
  final TimelineView view;
  final int steps;
  final PlaybackRange? loopRange;
  final ValueChanged<double>? onSeek;

  /// ui-001 stage 2 (desktop): drag across the ruler to set the loop range in
  /// whole bars (from the bar under the pointer-down to the bar under the
  /// pointer, both included: bars 2–3 = steps 16–48); drag either end of the
  /// shown range to move just that end to the nearest bar line (the range
  /// keeps at least one bar); click to seek. The range is committed once, on
  /// release. Null = the phone ruler (tap to seek).
  final ValueChanged<PlaybackRange>? onRange;

  /// False while recording / counting in / previewing the song: the ruler
  /// keeps its look, range drags do nothing (an ongoing drag is dropped).
  final bool rangeEnabled;

  @override
  State<TimelineRuler> createState() => _TimelineRulerState();
}

enum _Drag { create, start, end }

class _TimelineRulerState extends State<TimelineRuler> {
  _Drag? _mode;

  /// create: the bar under the pointer-down (0-based).
  int _anchor = 0;
  PlaybackRange? _preview;

  static const double _handleSlop = 8;

  int get _bars => (widget.steps / 16).ceil().clamp(1, 1 << 20);
  double _stepAt(double dx, double width) => widget.view.stepAt(dx / width);

  /// The bar containing [dx] (a bar line belongs to the bar on its right).
  int _barAt(double dx, double width) => (_stepAt(dx, width) / 16).floor().clamp(0, _bars - 1);

  /// The bar line nearest to [dx], as a bar index 0.._bars.
  int _lineAt(double dx, double width) => (_stepAt(dx, width) / 16).round().clamp(0, _bars);

  PlaybackRange _span(int a, int b) =>
      PlaybackRange((a < b ? a : b) * 16, ((a < b ? b : a) + 1) * 16).bounded(widget.steps);

  PlaybackRange? _rangeAt(double dx, double width) {
    if (_mode == _Drag.create) return _span(_anchor, _barAt(dx, width));
    final shown = widget.loopRange; // a handle drag needs the shown range
    if (shown == null) return null;
    final line = _lineAt(dx, width);
    return _mode == _Drag.end
        ? PlaybackRange(shown.start, (line * 16).clamp(shown.start + 16, _bars * 16))
        : PlaybackRange((line * 16).clamp(0, shown.end - 16), shown.end);
  }

  bool get _canDrag => widget.onRange != null && widget.rangeEnabled;

  /// A range end is a handle only while its bar line is inside the view
  /// (the same rule decides drawing and hit testing).
  static bool _inView(double fraction) => fraction >= 0 && fraction <= 1;

  @override
  void didUpdateWidget(TimelineRuler old) {
    super.didUpdateWidget(old);
    // Disabled mid-drag, or the loop turned off (e.g. Ctrl+L) while an end
    // handle was held: drop the preview and commit nothing.
    final handleLost = (_mode == _Drag.start || _mode == _Drag.end) && widget.loopRange == null;
    if ((!_canDrag || handleLost) && (_mode != null || _preview != null)) {
      _mode = null;
      _preview = null;
    }
  }

  void _start(double dx, double width) {
    if (!_canDrag) return;
    // [dx] is the pointer-down position (DragStartBehavior.down).
    final shown = widget.loopRange;
    _mode = _Drag.create;
    if (shown != null) {
      final fs = widget.view.fraction(shown.start), fe = widget.view.fraction(shown.end);
      final sd = _inView(fs) ? (dx - fs * width).abs() : double.infinity;
      final ed = _inView(fe) ? (dx - fe * width).abs() : double.infinity;
      if (ed <= _handleSlop && ed <= sd) {
        _mode = _Drag.end;
      } else if (sd <= _handleSlop) {
        _mode = _Drag.start;
      }
    }
    _anchor = _barAt(dx, width);
    setState(() => _preview = _mode == _Drag.create ? _span(_anchor, _anchor) : shown);
  }

  void _update(double dx, double width) {
    if (_mode == null || !_canDrag) return;
    final r = _rangeAt(dx, width);
    setState(() {
      if (r == null) _mode = null; // the handle's range is gone: cancel
      _preview = r;
    });
  }

  void _end() {
    final r = _mode == null ? null : _preview;
    setState(() {
      _mode = null;
      _preview = null;
    });
    if (r != null && _canDrag) widget.onRange!(r);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final view = widget.view;
      final width = c.maxWidth;
      final stride = (36 / (width.clamp(1.0, double.infinity) * 16 / view.length)).ceil().clamp(1, 10000);
      final shown = _preview ?? widget.loopRange;
      final fs = shown == null ? 0.0 : view.fraction(shown.start);
      final fe = shown == null ? 0.0 : view.fraction(shown.end);
      final a = fs.clamp(0.0, 1.0), b = fe.clamp(0.0, 1.0);
      final ranged = widget.onRange != null;
      final ruler = ClipRect(
        child: Stack(
          children: [
            if (b > a)
              Positioned(
                key: ranged ? const ValueKey('timeline-ruler-range') : null,
                left: a * width,
                width: (b - a) * width,
                top: 0,
                bottom: 0,
                child: ColoredBox(color: LT.lime.withValues(alpha: ranged ? .12 : .10)),
              ),
            for (var bar = (view.start / 16).floor(); bar * 16 < view.end && bar * 16 < widget.steps; bar++)
              Positioned(
                left: view.fraction(bar * 16) * width,
                top: 0,
                bottom: 0,
                child: Container(
                  padding: EdgeInsets.only(left: 5, top: ranged ? 1 : 3),
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: LT.borderStrong)),
                  ),
                  child: Text(
                    bar % stride == 0 ? '${bar + 1}' : '',
                    key: ValueKey('timeline-bar-${bar + 1}'),
                    style: TextStyle(fontSize: ranged ? 10 : 11, color: LT.t2, height: ranged ? 1.2 : null),
                  ),
                ),
              ),
            if (ranged && b > a) ...[
              // off-view ends get no handle (they could not be grabbed)
              for (final (key, x) in [if (_inView(fs)) ('loop-handle-start', a), if (_inView(fe)) ('loop-handle-end', b)])
                Positioned(
                  key: ValueKey(key),
                  left: (x * width - 1.5).clamp(0.0, width - 3),
                  width: 3,
                  top: 0,
                  bottom: 0,
                  child: const ColoredBox(color: LT.lime),
                ),
            ],
          ],
        ),
      );
      if (!ranged) {
        return GestureDetector(
          key: const ValueKey('timeline-ruler'),
          behavior: HitTestBehavior.opaque,
          onTapDown: widget.onSeek == null ? null : (d) => widget.onSeek!(view.stepAt(d.localPosition.dx / width)),
          child: ruler,
        );
      }
      return Tooltip(
        message: L10n.of(context).rulerTooltip,
        waitDuration: const Duration(milliseconds: 800),
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            key: const ValueKey('timeline-ruler'),
            behavior: HitTestBehavior.opaque,
            onTapUp: widget.onSeek == null ? null : (d) => widget.onSeek!(view.stepAt(d.localPosition.dx / width)),
            // anchor at the pointer-down, not after the touch slop
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (d) => _start(d.localPosition.dx, width),
            onHorizontalDragUpdate: (d) => _update(d.localPosition.dx, width),
            onHorizontalDragEnd: (_) => _end(),
            onHorizontalDragCancel: () => setState(() {
              _mode = null;
              _preview = null;
            }),
            child: ruler,
          ),
        ),
      );
    },
  );
}
