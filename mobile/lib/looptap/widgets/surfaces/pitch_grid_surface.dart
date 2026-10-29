// LoopTap — Melody Grid (precise step sequencer). README §5.
// Tap places a note; drag lengthens it; notes merge only when their spans
// actually overlap. Existing notes audition in Draw mode; Eraser removes cells.
// Rows = fixed chromatic pitches (high -> low); cols = steps.
//
// Layout (docs/specs/grid-usability.md): a sticky time ruler above the notes,
// a piano-key gutter left of them (same vertical scroll as the rows), and an
// optional horizontal zoom. Every x(step) / y(row) goes through
// [PitchGridAxis] — the painter, ruler, playhead, hit tests, StepGrid's
// selection math and the velocity lane share it.
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HapticFeedback, HardwareKeyboard;
import 'package:flutter/gestures.dart'
    show PointerScrollEvent, PointerSignalEvent, kPrimaryButton;

import '../../models/loop_models.dart';
import '../../music/guitar_articulation.dart' show articulationMark;
import '../../music/guitar_stroke.dart' show strokeMark;
import '../../music/theory.dart';
import '../../music/timeline_view.dart';
import '../../state/loop_prefs.dart';
import '../../theme/tokens.dart';

const int _kStepsPerBar = kBeatsPerBar * kStepsPerBeat;

/// The one coordinate system of the piano roll. [size] is the note lane's
/// content size (the full scrollable height, the visible width); [view] is the
/// visible time range (zoom/pan). Song steps never change with the view.
class PitchGridAxis {
  PitchGridAxis({
    required this.steps,
    required this.rows,
    required this.size,
    TimelineView? view,
  }) : view = view ?? TimelineView(0, math.max(1, steps).toDouble());
  final int steps, rows;
  final Size size;
  final TimelineView view;

  /// Rail (▲/▼ pitch-window affordance) + piano keys + gap before the lane.
  static const double railWidth = 13, keysWidth = 40, gap = 4;
  static double gutterWidth({required bool rail}) =>
      (rail ? railWidth : 0) + keysWidth + gap;

  /// Sticky time ruler height above the lane.
  static const double rulerHeight = 22;

  double get pxPerStep => size.width / view.length;
  double get rowHeight => rows <= 0 ? 0 : size.height / rows;
  double x(num step) => (step - view.start) * pxPerStep;
  double stepAt(double x) => view.start + x / pxPerStep;
  int cellAt(double x) =>
      stepAt(x).floor().clamp(0, math.max(0, steps - 1)).toInt();
  double y(int row) => row * rowHeight;
  int rowAt(double y) =>
      (y / rowHeight).floor().clamp(0, math.max(0, rows - 1)).toInt();
}

/// Horizontal zoom / pan of the grid (UI state, not song data). Shared by
/// the grid, its ruler and the velocity lane.
class PitchGridView extends ChangeNotifier {
  PitchGridView(this._steps);
  int _steps;
  double _zoom = 1, _start = 0;
  int get steps => _steps;
  double get zoom => _zoom;
  double get maxZoom => math.max(1.0, _steps / 4);
  double get length => _steps / _zoom;
  TimelineView get view => TimelineView(_start, _start + length);

  set steps(int value) {
    if (value == _steps || value <= 0) return;
    _steps = value;
    _zoom = 1;
    _start = 0;
    notifyListeners();
  }

  /// Zoom keeping [anchor] (a step) under the same screen fraction.
  void setZoom(double zoom, {double? anchor}) {
    final z = zoom.clamp(1.0, maxZoom).toDouble();
    if (z == _zoom) return;
    final a = anchor ?? (_start + length / 2);
    final f = length == 0 ? 0.5 : (a - _start) / length;
    _zoom = z;
    _start = (a - f * length).clamp(0.0, _steps - length).toDouble();
    notifyListeners();
  }

  void panTo(double start) {
    final s = start.clamp(0.0, _steps - length).toDouble();
    if (s == _start) return;
    _start = s;
    notifyListeners();
  }

  void panBy(double steps) => panTo(_start + steps);

  void fit() {
    if (_zoom == 1 && _start == 0) return;
    _zoom = 1;
    _start = 0;
    notifyListeners();
  }
}

/// ui-001 stage 3: lets the desktop minimap follow (and pan) the piano
/// roll's [PitchGridView] without owning it. The [StepGrid] that creates a
/// view owns and disposes it; it attaches the view after mounting and
/// detaches it before disposing. Only the attached view can detach, so a new
/// grid (track / section switch) that attached first is never cleared by the
/// old grid's later dispose, and no disposed view is ever handed out.
class PitchGridViewLink extends ChangeNotifier {
  PitchGridView? _view;
  bool _disposed = false, _pending = false;

  /// The roll's live view (null: no piano roll on screen).
  PitchGridView? get view => _view;

  void attach(PitchGridView view) {
    if (identical(_view, view)) return;
    _view?.removeListener(_changed);
    _view = view..addListener(_changed);
    _changed();
  }

  void detach(PitchGridView view) {
    if (!identical(_view, view)) return;
    view.removeListener(_changed);
    _view = null;
    _changed();
  }

  // Attach / detach (and a steps change in didUpdateWidget) run while the
  // tree builds or finalizes, where listeners must not rebuild: their
  // notification waits for the end of that frame.
  void _changed() {
    if (_disposed) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase != SchedulerPhase.persistentCallbacks &&
        phase != SchedulerPhase.midFrameMicrotasks) {
      notifyListeners();
      return;
    }
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _view?.removeListener(_changed);
    _view = null;
    super.dispose();
  }
}

/// ui-001 stage 5 (desktop piano roll): the song's key on the lane. Rows
/// outside it get [LT.laneOutOfKey], the root row a 6 % lime tint, and rows
/// in the key their note name at the left edge. Null = the phone look.
class PitchKeyHighlight {
  const PitchKeyHighlight({required this.pitchClasses, required this.root});

  /// Pitch classes (0 = C) in the key.
  final Set<int> pitchClasses;

  /// The key's root pitch class.
  final int root;

  @override
  bool operator ==(Object other) =>
      other is PitchKeyHighlight &&
      other.root == root &&
      setEquals(other.pitchClasses, pitchClasses);

  @override
  int get hashCode => Object.hash(root, Object.hashAllUnordered(pitchClasses));
}

class _Draft {
  _Draft(this.row, this.rung, this.a, this.b);
  final int row;
  final Rung rung;
  final int a;
  final int b; // immutable: a drag replaces the draft so shouldRepaint sees it
}

class GridPointer {
  const GridPointer(
    this.rung,
    this.row,
    this.position,
    this.local,
    this.size, [
    this.axis,
  ]);
  final Rung rung;
  final int row;

  /// Absolute (fractional) song step under the pointer.
  final double position;

  /// Lane-content coordinates ([axis] maps them).
  final Offset local;
  final Size size;
  final PitchGridAxis? axis;

  /// Pixels per step on screen.
  double unitFor(int steps) => axis?.pxPerStep ?? size.width / steps;
}

class PitchGridSurface extends StatefulWidget {
  const PitchGridSurface({
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
    this.onGestureStart,
    this.onGestureMove,
    this.onGestureEnd,
    this.onGestureCancel,
    this.selected = const {},
    this.marquee,
    this.focusMidi,
    this.eraseMode = false,
    this.onPreview,
    this.strokeMarks = false,
    this.stringMarks = false,
    this.warnNotes = const {},
    this.view,
    this.keyHighlight,
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
  /// callback to move it — dragging the piano keys vertically scrolls the range.
  final int windowOffset;
  final int maxOffset;
  final ValueChanged<int>? onWindowChanged;
  final ValueChanged<GridPointer>? onGestureStart, onGestureMove;
  final VoidCallback? onGestureEnd, onGestureCancel;
  final Set<PitchNote> selected;
  final Rect? marquee;
  final int? focusMidi;
  final bool eraseMode;

  /// Audition only (piano-key clicks and existing notes): never places notes.
  final ValueChanged<Rung>? onPreview;

  /// gt-001: draw ↓/↑ on the first string of converted guitar stroke hits
  /// (guitar tracks only; other tracks keep the data but hide the mark).
  final bool strokeMarks;

  /// gt-002: draw each assigned note's string number (expanded guitar view).
  final bool stringMarks;

  /// gt-002: notes flagged without a string (amber outline + "!").
  final Set<PitchNote> warnNotes;

  /// Shared horizontal zoom/pan (StepGrid passes the one the velocity lane
  /// uses). Null = the surface keeps its own.
  final PitchGridView? view;

  /// ui-001 stage 5 (desktop): the key highlight on the lane (null = phone).
  final PitchKeyHighlight? keyHighlight;

  @override
  State<PitchGridSurface> createState() => _PitchGridSurfaceState();
}

class _PitchGridSurfaceState extends State<PitchGridSurface>
    with SingleTickerProviderStateMixin {
  final GlobalKey _laneKey = GlobalKey();
  final ScrollController _vertical = ScrollController();
  PitchGridView? _ownView;
  PitchGridView get _view =>
      widget.view ?? (_ownView ??= PitchGridView(widget.steps));
  _Draft? _draft;
  String? _mode; // 'paint' | 'erase'
  int? _pointer;

  bool _needsFocus = true, _firstFocus = true;

  /// ui-001 stage 5: the pitch at the viewport's centre when the rows change
  /// (in-key-only toggle, key change), kept at the centre afterwards.
  int? _keepMidi;

  @override
  void didUpdateWidget(PitchGridSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ownView?.steps = widget.steps;
    if (oldWidget.focusMidi != widget.focusMidi) _needsFocus = true;
    if (!listEquals(
      oldWidget.ladder.map((r) => r.midi).toList(),
      widget.ladder.map((r) => r.midi).toList(),
    )) {
      _pointer = null;
      _draft = null;
      _mode = null;
      _pulse.stop();
      final old = oldWidget.ladder.reversed.toList();
      if (_vertical.hasClients && old.isNotEmpty) {
        final pos = _vertical.position;
        final rowH = (pos.maxScrollExtent + pos.viewportDimension) / old.length;
        if (rowH > 0) {
          final row = ((pos.pixels + pos.viewportDimension / 2) / rowH)
              .floor()
              .clamp(0, old.length - 1);
          _keepMidi = old[row].midi;
        }
      }
    }
  }

  void _scheduleKeep(double height) {
    final keep = _keepMidi;
    if (keep == null) return;
    _keepMidi = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients || _rows.isEmpty) return;
      var row = _rows.indexWhere((r) => r.midi <= keep);
      if (row < 0) row = _rows.length - 1;
      final rowH = height / _rows.length;
      final pos = _vertical.position;
      _vertical.jumpTo(
        (row * rowH + rowH / 2 - pos.viewportDimension / 2).clamp(
          0.0,
          pos.maxScrollExtent,
        ),
      );
    });
  }

  // piano-key vertical drag → pitch-window scroll accumulator.
  double _winAccum = 0;
  int _winOffset = 0;

  // gentle pulse for the active hold-drag preview ("release to place")
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void dispose() {
    _vertical.dispose();
    _pulse.dispose();
    _ownView?.dispose();
    super.dispose();
  }

  List<Rung> get _rows => widget.ladder.reversed.toList();

  PitchGridAxis _axis(Size size) => PitchGridAxis(
    steps: widget.steps,
    rows: _rows.length,
    size: size,
    view: _view.view,
  );

  PitchNote? _noteAt(int midi, int step) {
    for (final n in widget.notes) {
      if (n.midi == midi && n.overlapsCell(step)) return n;
    }
    return null;
  }

  ({int row, int step})? _hit(Offset global) {
    final box = _laneKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _rows.isEmpty || box.size.isEmpty) return null;
    final local = box.globalToLocal(global);
    final size = box.size;
    final axis = _axis(size);
    // clamp instead of rejecting so drags that slip past the edge still track
    return (
      row: axis.rowAt(local.dy.clamp(0, size.height - 0.01)),
      step: axis.cellAt(local.dx.clamp(0, size.width - 0.01)),
    );
  }

  void _down(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    if (_pointer != null) return;
    _pointer = e.pointer;
    if (widget.onGestureStart != null) {
      final point = _point(e.position);
      if (point != null) widget.onGestureStart!(point);
      return;
    }
    final h = _hit(e.position);
    if (h == null) return;
    final rung = _rows[h.row];
    final existing = _noteAt(rung.midi, h.step);
    if (LoopPrefs.instance.haptics.value) HapticFeedback.selectionClick();
    if (widget.eraseMode) {
      _mode = 'erase';
      if (existing != null) widget.onErase(rung, h.step);
    } else if (existing != null) {
      _mode = 'preview';
      widget.onPreview?.call(rung);
    } else {
      _mode = 'paint';
      _pulse.repeat(reverse: true);
      setState(() => _draft = _Draft(h.row, rung, h.step, h.step));
    }
  }

  void _move(PointerMoveEvent e) {
    if (e.pointer != _pointer) return;
    if (widget.onGestureMove != null) {
      final point = _point(e.position);
      if (point != null) widget.onGestureMove!(point);
      return;
    }
    final h = _hit(e.position);
    if (h == null) return;
    if (_mode == 'erase') {
      final ex = _noteAt(_rows[h.row].midi, h.step);
      if (ex != null) widget.onErase(_rows[h.row], h.step);
      return;
    }
    if (_mode == 'paint' && _draft != null && h.row == _draft!.row) {
      final d = _draft!;
      setState(() => _draft = _Draft(d.row, d.rung, d.a, h.step));
    }
  }

  void _up(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _pointer = null;
    if (widget.onGestureEnd != null) {
      widget.onGestureEnd!();
      return;
    }
    if (_mode == 'paint' && _draft != null) {
      widget.onPlace(_draft!.rung, _draft!.a, _draft!.b);
    }
    _pulse.stop();
    setState(() => _draft = null);
    _mode = null;
  }

  GridPointer? _point(Offset global) {
    final box = _laneKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || _rows.isEmpty || box.size.isEmpty) return null;
    final raw = box.globalToLocal(global);
    final local = Offset(
      raw.dx.clamp(0, box.size.width),
      raw.dy.clamp(0, box.size.height - .001),
    );
    final axis = _axis(box.size);
    final row = axis.rowAt(local.dy);
    return GridPointer(
      _rows[row],
      row,
      axis.stepAt(local.dx),
      local,
      box.size,
      axis,
    );
  }

  void _cancelGesture() {
    if (_pointer == null) return;
    _pointer = null;
    _pulse.stop();
    setState(() {
      _draft = null;
      _mode = null;
    });
    widget.onGestureCancel?.call();
  }

  void _signal(PointerSignalEvent event, double laneLeft, double laneWidth) {
    if (event is! PointerScrollEvent) return;
    final keys = HardwareKeyboard.instance;
    final zoom = keys.isControlPressed || keys.isMetaPressed;
    final pan = !zoom && (keys.isShiftPressed || event.scrollDelta.dx != 0);
    if (zoom || pan) {
      _cancelGesture();
      final view = _view;
      if (zoom) {
        // Ctrl/Cmd+wheel zooms around the pointer's step
        final f = ((event.localPosition.dx - laneLeft) / laneWidth).clamp(
          0.0,
          1.0,
        );
        final anchor = view.view.stepAt(f);
        final dy = event.scrollDelta.dy;
        if (dy != 0) view.setZoom(view.zoom * (dy < 0 ? 1.25 : 0.8), anchor: anchor);
      } else {
        final d =
            event.scrollDelta.dx != 0
                ? event.scrollDelta.dx
                : event.scrollDelta.dy;
        view.panBy(d / laneWidth * view.length);
      }
      return;
    }
    if (!_vertical.hasClients) return;
    _cancelGesture();
    _vertical.jumpTo(
      (_vertical.offset + event.scrollDelta.dy).clamp(
        0,
        _vertical.position.maxScrollExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rail = widget.onWindowChanged != null;
        final gutter = PitchGridAxis.gutterWidth(rail: rail);
        final laneWidth = math.max(1.0, constraints.maxWidth - gutter);
        return AnimatedBuilder(
          animation: _view,
          builder: (context, _) {
            final zoomed = _view.zoom > 1;
            final viewport = math.max(
              0.0,
              constraints.maxHeight -
                  PitchGridAxis.rulerHeight -
                  (zoomed ? _kHBarHeight : 0),
            );
            // rows stay >= 24 px (usable touch/click targets)
            final height = math.max(viewport, widget.ladder.length * 24.0);
            _scheduleFocus(height);
            _scheduleKeep(height);
            return Column(
              children: [
                SizedBox(
                  height: PitchGridAxis.rulerHeight,
                  child: Row(
                    children: [
                      SizedBox(width: gutter, child: _corner()),
                      Expanded(
                        child: _GridRuler(
                          key: const ValueKey('pitch-grid-ruler'),
                          steps: widget.steps,
                          view: _view.view,
                          playStep: widget.playStep,
                          accent: widget.accent,
                          onFit: _view.fit,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Listener(
                    onPointerSignal: (e) => _signal(e, gutter, laneWidth),
                    child: Scrollbar(
                      controller: _vertical,
                      interactive: true,
                      thumbVisibility: height > viewport,
                      child: SingleChildScrollView(
                        key: const ValueKey('pitch-grid-viewport'),
                        controller: _vertical,
                        physics: const NeverScrollableScrollPhysics(),
                        child: SizedBox(
                          height: height,
                          child: _content(rail),
                        ),
                      ),
                    ),
                  ),
                ),
                if (zoomed)
                  SizedBox(
                    height: _kHBarHeight,
                    child: Row(
                      children: [
                        SizedBox(width: gutter),
                        Expanded(child: _HBar(view: _view)),
                      ],
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }

  void _scheduleFocus(double height) {
    if (!_needsFocus || widget.focusMidi == null) return;
    _needsFocus = false;
    final target =
        _firstFocus && widget.notes.isNotEmpty
            ? (widget.notes.map((n) => n.midi).reduce(math.max) + 2).clamp(
              0,
              127,
            )
            : widget.focusMidi!;
    _firstFocus = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_vertical.hasClients || _rows.isEmpty) return;
      final row = _rows.indexWhere((r) => r.midi <= target);
      if (row >= 0) {
        _vertical.jumpTo(
          (row * height / _rows.length).clamp(
            0,
            _vertical.position.maxScrollExtent,
          ),
        );
      }
    });
  }

  Widget _corner() {
    final ko = Localizations.maybeLocaleOf(context)?.languageCode == 'ko';
    Widget btn(String key, IconData icon, String tip, VoidCallback? onTap) =>
        Tooltip(
          message: tip,
          child: InkWell(
            key: ValueKey(key),
            onTap: onTap,
            child: SizedBox(
              width: 18,
              height: PitchGridAxis.rulerHeight,
              child: Icon(
                icon,
                size: 14,
                color: onTap == null ? LT.t3.withValues(alpha: .35) : LT.t2,
              ),
            ),
          ),
        );
    final v = _view;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        btn(
          'grid-zoom-out',
          Icons.remove,
          ko ? '가로 축소 (Ctrl+휠)' : 'Zoom out (Ctrl+wheel)',
          v.zoom > 1 ? () => v.setZoom(v.zoom / 2) : null,
        ),
        btn(
          'grid-zoom-in',
          Icons.add,
          ko ? '가로 확대 (Ctrl+휠)' : 'Zoom in (Ctrl+wheel)',
          v.zoom < v.maxZoom ? () => v.setZoom(v.zoom * 2) : null,
        ),
        const SizedBox(width: PitchGridAxis.gap),
      ],
    );
  }

  /// Painted labels use the app font, like the widgets around them.
  String? get _fontFamily => Theme.of(context).textTheme.bodyMedium?.fontFamily;

  Widget _content(bool rail) {
    final rows = _rows;
    return Row(
      children: [
        // Piano keys (same scroll as the rows). Tap = audition only; vertical
        // drag moves the pitch window (the pads' range) as before.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp:
              widget.onPreview == null || rows.isEmpty
                  ? null
                  : (d) {
                    final keys =
                        _keysKey.currentContext?.findRenderObject()
                            as RenderBox?;
                    if (keys == null) return;
                    final axis = PitchGridAxis(
                      steps: widget.steps,
                      rows: rows.length,
                      size: keys.size,
                    );
                    final y = keys.globalToLocal(d.globalPosition).dy;
                    widget.onPreview!(rows[axis.rowAt(y)]);
                  },
          onVerticalDragStart:
              widget.onWindowChanged == null
                  ? null
                  : (_) {
                    _winAccum = 0;
                    _winOffset = widget.windowOffset;
                  },
          onVerticalDragUpdate:
              widget.onWindowChanged == null
                  ? null
                  : (d) {
                    _winAccum += d.delta.dy;
                    const sens = 24.0; // px per pitch step
                    // drag down → reveal higher pitches (offset increases)
                    while (_winAccum.abs() >= sens) {
                      final dir = _winAccum > 0 ? 1 : -1;
                      _winAccum -= dir * sens;
                      _winOffset = (_winOffset + dir).clamp(
                        0,
                        widget.maxOffset,
                      );
                      widget.onWindowChanged!(_winOffset);
                    }
                  },
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // scroll affordance rail: ▲ higher / grip / ▼ lower. The
              // arrow lights up while there's more range in that direction.
              if (rail)
                SizedBox(
                  width: PitchGridAxis.railWidth,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Icon(
                        Icons.keyboard_arrow_up,
                        size: 13,
                        color:
                            widget.windowOffset < widget.maxOffset
                                ? widget.accent
                                : LT.t3.withValues(alpha: 0.25),
                      ),
                      Icon(
                        Icons.drag_indicator,
                        size: 11,
                        color: LT.t3.withValues(alpha: 0.4),
                      ),
                      Icon(
                        Icons.keyboard_arrow_down,
                        size: 13,
                        color:
                            widget.windowOffset > 0
                                ? widget.accent
                                : LT.t3.withValues(alpha: 0.25),
                      ),
                    ],
                  ),
                ),
              SizedBox(
                key: const ValueKey('pitch-grid-keys'),
                width: PitchGridAxis.keysWidth,
                child: CustomPaint(
                  key: _keysKey,
                  size: Size.infinite,
                  painter: _KeysPainter(
                    rows: rows,
                    accent: widget.accent,
                    fontFamily: _fontFamily,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: PitchGridAxis.gap),
        Expanded(
          child: Listener(
            key: const ValueKey('pitch-grid-lane'),
            onPointerDown: _down,
            onPointerMove: _move,
            onPointerUp: _up,
            onPointerCancel: (event) {
              if (event.pointer != _pointer) return;
              _pointer = null;
              widget.onGestureCancel?.call();
              _pulse.stop();
              setState(() => _draft = null);
              _mode = null;
            },
            behavior: HitTestBehavior.opaque,
            child: AnimatedBuilder(
              animation: _pulse,
              builder:
                  (_, __) => CustomPaint(
                    key: _laneKey,
                    size: Size.infinite,
                    painter: _GridPainter(
                      rows: rows,
                      // snapshots: the host mutates both in place
                      // (pitchNotes.addAll, _selected.add), so the
                      // painter must not alias them for shouldRepaint
                      notes: List.of(widget.notes),
                      selected: Set.of(widget.selected),
                      marquee: widget.marquee,
                      strokeMarks: widget.strokeMarks,
                      stringMarks: widget.stringMarks,
                      warnNotes: Set.of(widget.warnNotes),
                      draft: _draft,
                      playStep: widget.playStep,
                      steps: widget.steps,
                      view: _view.view,
                      accent: widget.accent,
                      pulse: _draft != null ? _pulse.value : 0,
                      fontFamily: _fontFamily,
                      keyHighlight: widget.keyHighlight,
                    ),
                  ),
            ),
          ),
        ),
      ],
    );
  }

  final GlobalKey _keysKey = GlobalKey(debugLabel: 'pitch-grid-keys');
}

const double _kHBarHeight = 10;

/// Horizontal scroll strip under a zoomed grid: drag the thumb (or click the
/// track) to pan.
class _HBar extends StatelessWidget {
  const _HBar({required this.view});
  final PitchGridView view;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final w = c.maxWidth;
      final v = view.view;
      final steps = view.steps;
      final thumbW = math.max(24.0, v.length / steps * w);
      final track = math.max(1.0, w - thumbW);
      final maxStart = math.max(1e-9, steps - v.length);
      final left = v.start / maxStart * track;
      return GestureDetector(
        key: const ValueKey('grid-hscroll'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate:
            (d) => view.panBy(d.delta.dx / track * maxStart),
        onTapUp: (d) {
          final x = d.localPosition.dx;
          if (x < left) view.panBy(-v.length);
          if (x > left + thumbW) view.panBy(v.length);
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _HBarPainter(left, thumbW),
        ),
      );
    },
  );
}

class _HBarPainter extends CustomPainter {
  _HBarPainter(this.left, this.width);
  final double left, width;
  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 2, size.width, h - 4),
        const Radius.circular(3),
      ),
      Paint()..color = LT.surface2,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(left, 2, width, h - 4),
        const Radius.circular(3),
      ),
      Paint()..color = LT.t3,
    );
  }

  @override
  bool shouldRepaint(_HBarPainter old) =>
      old.left != left || old.width != width;
}

/// Bar numbers + beat ticks over the lane (sticky above the vertical scroll).
/// Labels are thinned by measured width so they never overlap.
class _GridRuler extends StatelessWidget {
  const _GridRuler({
    super.key,
    required this.steps,
    required this.view,
    required this.playStep,
    required this.accent,
    required this.onFit,
  });
  final int steps;
  final TimelineView view;
  final double playStep;
  final Color accent;
  final VoidCallback onFit;

  static const _barStyle = TextStyle(
    fontSize: 10,
    fontWeight: FontWeight.w700,
    color: LT.t1,
  );
  static const _beatStyle = TextStyle(fontSize: 9, color: LT.t3);

  static double _textWidth(String s, TextStyle style) =>
      (TextPainter(text: TextSpan(text: s, style: style),
              textDirection: TextDirection.ltr)
            ..layout())
          .width;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      // measure with exactly the style the labels render with
      final base = DefaultTextStyle.of(context).style;
      final barStyle = base.merge(_barStyle);
      final beatStyle = base.merge(_beatStyle);
      final axis = PitchGridAxis(
        steps: steps,
        rows: 0,
        size: Size(c.maxWidth, 0),
        view: view,
      );
      final bars = (steps / _kStepsPerBar).ceil();
      final barW = _kStepsPerBar * axis.pxPerStep;
      final beatW = kStepsPerBeat * axis.pxPerStep;
      final labelW = _textWidth('$bars', barStyle) + 8;
      var stride = 1;
      while (stride * barW < labelW && stride < bars) {
        stride *= 2;
      }
      final beatLabelW = _textWidth('$bars.4', beatStyle) + 8;
      final beatLabels = stride == 1 && beatW >= math.max(labelW, beatLabelW);
      final labels = <Widget>[];
      final first = math.max(0, (view.start / _kStepsPerBar).floor());
      for (var bar = first; bar < bars && bar * _kStepsPerBar < view.end; bar++) {
        final x = axis.x(bar * _kStepsPerBar);
        if (bar % stride == 0 && x >= -.5) {
          final text = '${bar + 1}';
          if (x + 3 + _textWidth(text, barStyle) <= c.maxWidth) {
            labels.add(
              Positioned(
                left: x + 3,
                top: 2,
                child: Text(
                  text,
                  key: ValueKey('grid-ruler-bar-${bar + 1}'),
                  style: barStyle,
                  textScaler: TextScaler.noScaling,
                ),
              ),
            );
          }
        }
        if (beatLabels) {
          for (var b = 1; b < kBeatsPerBar; b++) {
            final bx = axis.x(bar * _kStepsPerBar + b * kStepsPerBeat);
            final text = '${bar + 1}.${b + 1}';
            if (bx < 0 || bx + 3 + _textWidth(text, beatStyle) > c.maxWidth) {
              continue;
            }
            labels.add(
              Positioned(
                left: bx + 3,
                top: 3,
                child: Text(
                  text,
                  key: ValueKey('grid-ruler-beat-${bar + 1}-${b + 1}'),
                  style: beatStyle,
                  textScaler: TextScaler.noScaling,
                ),
              ),
            );
          }
        }
      }
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: onFit,
        child: ClipRect(
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _RulerPainter(
                    steps: steps,
                    view: view,
                    playStep: playStep,
                    accent: accent,
                  ),
                ),
              ),
              ...labels,
            ],
          ),
        ),
      );
    },
  );
}

class _RulerPainter extends CustomPainter {
  _RulerPainter({
    required this.steps,
    required this.view,
    required this.playStep,
    required this.accent,
  });
  final int steps;
  final TimelineView view;
  final double playStep;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    final axis = PitchGridAxis(
      steps: steps,
      rows: 0,
      size: Size(size.width, 0),
      view: view,
    );
    final h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = LT.surface2);
    canvas.drawLine(
      Offset(0, h - .5),
      Offset(size.width, h - .5),
      Paint()..color = LT.borderStrong,
    );
    final bar = Paint()
      ..color = LT.t2
      ..strokeWidth = 1.5;
    final beat = Paint()
      ..color = LT.t3
      ..strokeWidth = 1;
    final sub = Paint()
      ..color = LT.t3.withValues(alpha: .5)
      ..strokeWidth = 1;
    final showSub = axis.pxPerStep >= 5;
    for (var s = math.max(0, view.start.floor()); s <= math.min(steps, view.end.ceil()); s++) {
      final x = axis.x(s);
      if (s % _kStepsPerBar == 0) {
        canvas.drawLine(Offset(x, 0), Offset(x, h), bar);
      } else if (s % kStepsPerBeat == 0) {
        canvas.drawLine(Offset(x, h * .55), Offset(x, h), beat);
      } else if (showSub) {
        canvas.drawLine(Offset(x, h * .8), Offset(x, h), sub);
      }
    }
    // playhead marker (same projection as the lane's playhead column)
    final px = axis.x(playStep % math.max(1, steps));
    if (px >= -6 && px <= size.width + 6) {
      final path = Path()
        ..moveTo(px - 5, h - 7)
        ..lineTo(px + 5, h - 7)
        ..lineTo(px, h)
        ..close();
      canvas.drawPath(path, Paint()..color = LT.t1);
    }
  }

  @override
  bool shouldRepaint(_RulerPainter old) =>
      old.steps != steps ||
      old.view.start != view.start ||
      old.view.end != view.end ||
      old.playStep != playStep ||
      old.accent != accent;
}

bool _isBlack(int midi) => const {1, 3, 6, 8, 10}.contains(midi % 12);

/// Piano keys: one per grid row (same height), white/black shapes, C names
/// with the octave on every C (all white keys when rows are tall enough).
class _KeysPainter extends CustomPainter {
  _KeysPainter({required this.rows, required this.accent, this.fontFamily});
  final List<Rung> rows;
  final String? fontFamily;
  final Color accent;
  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty) return;
    final axis = PitchGridAxis(steps: 1, rows: rows.length, size: size);
    final rowH = axis.rowHeight;
    final white = Paint()..color = const Color(0xFFD4D4D8);
    final cWhite = Paint()..color = const Color(0xFFF4F4F5);
    final black = Paint()..color = const Color(0xFF18181B);
    final seam = Paint()
      ..color = const Color(0xFF71717A)
      ..strokeWidth = 1;
    // white key bed
    canvas.drawRect(Offset.zero & size, white);
    for (var r = 0; r < rows.length; r++) {
      final midi = rows[r].midi;
      final top = axis.y(r);
      if (!_isBlack(midi) && midi % 12 == 0) {
        canvas.drawRect(Rect.fromLTWH(0, top, size.width, rowH), cWhite);
      }
      // seams between adjacent white keys (B|C and E|F) and octave line
      if (midi % 12 == 0 || midi % 12 == 5) {
        canvas.drawLine(
          Offset(0, top + rowH),
          Offset(size.width, top + rowH),
          seam,
        );
      }
    }
    for (var r = 0; r < rows.length; r++) {
      final midi = rows[r].midi;
      if (!_isBlack(midi)) continue;
      final top = axis.y(r);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTWH(0, top + .5, size.width * .62, rowH - 1),
          topRight: const Radius.circular(2),
          bottomRight: const Radius.circular(2),
        ),
        black,
      );
      // white-key seam continuing behind the black key
      canvas.drawLine(
        Offset(size.width * .62, top + rowH / 2),
        Offset(size.width, top + rowH / 2),
        seam,
      );
    }
    final allWhite = rowH >= 16;
    final fontSize = rowH >= 14 ? 9.0 : math.max(6.0, rowH * .65);
    for (var r = 0; r < rows.length; r++) {
      final n = rows[r];
      final isC = n.midi % 12 == 0;
      if (_isBlack(n.midi) || (!isC && !allWhite)) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: n.name,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: fontSize,
            fontWeight: isC ? FontWeight.w800 : FontWeight.w500,
            color: isC ? LT.bg : const Color(0xFF52525B),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width - 3);
      tp.paint(
        canvas,
        Offset(
          size.width - 3 - tp.width,
          axis.y(r) + (rowH - tp.height) / 2,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(_KeysPainter old) =>
      !listEquals(old.rows, rows) ||
      old.accent != accent ||
      old.fontFamily != fontFamily;
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.rows,
    required this.notes,
    required this.draft,
    required this.playStep,
    required this.steps,
    required this.view,
    required this.accent,
    required this.pulse,
    required this.selected,
    this.marquee,
    this.strokeMarks = false,
    this.stringMarks = false,
    this.warnNotes = const {},
    this.fontFamily,
    this.keyHighlight,
  });

  final String? fontFamily;
  final PitchKeyHighlight? keyHighlight;
  final List<Rung> rows;
  final List<PitchNote> notes;
  final _Draft? draft;
  final double playStep;
  final int steps;
  final TimelineView view;
  final Color accent;
  final double pulse; // 0..1 while a hold-drag is active
  final Set<PitchNote> selected;
  final Rect? marquee;
  final bool strokeMarks;
  final bool stringMarks;
  final Set<PitchNote> warnNotes;

  void _label(Canvas canvas, String text, Offset at, Color color, {
    bool right = false,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(right ? at.dx - tp.width : at.dx, at.dy - tp.height / 2),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty || size.isEmpty) return;
    canvas.clipRect(Offset.zero & size);
    final axis = PitchGridAxis(
      steps: steps,
      rows: rows.length,
      size: size,
      view: view,
    );
    final w = size.width, h = size.height;
    final rowH = axis.rowHeight;
    final stepW = axis.pxPerStep;
    final gap = rowH >= 16 ? 2.5 : 1.5;

    // rows: black-key rows darker, octave (C) boundary line
    final whiteRow = Paint()..color = LT.surface2;
    final blackRow = Paint()..color = LT.surface;
    final rowSep = Paint()..color = LT.bg;
    final octave = Paint()..color = LT.borderStrong;
    // ui-001 stage 5 (desktop): rows by the song's key instead of the
    // piano's black / white keys
    final key = keyHighlight;
    final outOfKey = Paint()..color = LT.laneOutOfKey;
    final rootRow =
        Paint()..color = Color.alphaBlend(LT.lime.withValues(alpha: .06), LT.surface2);
    for (var r = 0; r < rows.length; r++) {
      final top = axis.y(r);
      final pc = rows[r].midi % 12;
      canvas.drawRect(
        Rect.fromLTWH(0, top, w, rowH),
        key == null
            ? (_isBlack(rows[r].midi) ? blackRow : whiteRow)
            : pc == key.root
            ? rootRow
            : key.pitchClasses.contains(pc)
            ? whiteRow
            : outOfKey,
      );
      canvas.drawRect(Rect.fromLTWH(0, top + rowH - 1, w, 1), rowSep);
      if (rows[r].midi % 12 == 0) {
        canvas.drawRect(Rect.fromLTWH(0, top + rowH - 1, w, 1), octave);
      }
    }
    // the note name at the left of every in-key row (root in lime)
    if (key != null && rowH >= 10) {
      for (var r = 0; r < rows.length; r++) {
        final pc = rows[r].midi % 12;
        if (!key.pitchClasses.contains(pc)) continue;
        final tp = _rowName(rows[r].name, pc == key.root);
        tp.paint(canvas, Offset(4, axis.y(r) + (rowH - tp.height) / 2));
      }
    }
    // alternate-bar tint, then sub / beat / bar lines (weak → strong)
    final altBar = Paint()..color = Colors.white.withValues(alpha: .025);
    for (var b = 0; b * _kStepsPerBar < steps; b++) {
      if (b.isOdd) {
        final x0 = axis.x(b * _kStepsPerBar);
        final x1 = axis.x(math.min(steps, (b + 1) * _kStepsPerBar));
        if (x1 >= 0 && x0 <= w) {
          canvas.drawRect(Rect.fromLTRB(x0, 0, x1, h), altBar);
        }
      }
    }
    final subLine = Paint()..color = Colors.white.withValues(alpha: .045);
    final beatLine = Paint()..color = Colors.white.withValues(alpha: .14);
    final barLine = Paint()..color = Colors.white.withValues(alpha: .38);
    final showSub = stepW >= 6;
    for (
      var s = math.max(0, view.start.floor());
      s <= math.min(steps, view.end.ceil());
      s++
    ) {
      final x = axis.x(s);
      if (s % _kStepsPerBar == 0) {
        canvas.drawRect(Rect.fromLTWH(x - .75, 0, 1.5, h), barLine);
      } else if (s % kStepsPerBeat == 0) {
        canvas.drawRect(Rect.fromLTWH(x - .5, 0, 1, h), beatLine);
      } else if (showSub) {
        canvas.drawRect(Rect.fromLTWH(x - .5, 0, 1, h), subLine);
      }
    }

    // playhead cell column
    final cur = playStep.floor() % steps;
    canvas.drawRect(
      Rect.fromLTWH(axis.x(cur), 0, stepW, h),
      Paint()..color = LT.t1.withValues(alpha: 0.08),
    );

    // notes: unselected first, selected on top (their halo stays visible)
    final rowOf = {for (var r = 0; r < rows.length; r++) rows[r].midi: r};
    final ordered = [
      ...notes.where((n) => !selected.contains(n)),
      ...notes.where(selected.contains),
    ];
    for (final n in ordered) {
      final r = rowOf[n.midi];
      if (r == null) continue;
      final start = n.step + n.offsetSteps;
      final left = axis.x(start);
      final width = math.max(1.0, n.soundingSteps * stepW - 2);
      if (left > w || left + width < 0) continue;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(left, axis.y(r) + gap, width, rowH - gap * 2),
        const Radius.circular(4),
      );
      _note(canvas, n, rect, selected.contains(n));
    }

    if (marquee != null) {
      canvas.drawRect(
        marquee!,
        Paint()..color = Colors.white.withValues(alpha: .08),
      );
      _dashedRect(canvas, marquee!, LT.t1, 1.5, 5, 3);
    }

    // draft preview (active hold-drag) — make the "lengthening" obvious:
    // highlighted row, glowing growing bar, a bright grip at the moving edge,
    // and a length readout. Release places it.
    if (draft != null) {
      final d = draft!;
      final lo = d.a < d.b ? d.a : d.b;
      final hi = d.a < d.b ? d.b : d.a;
      final len = hi - lo + 1;
      final top = axis.y(d.row) + gap;
      final bh = rowH - gap * 2;
      final p = 0.5 + 0.5 * pulse; // 0.5..1 breathing

      // row highlight band
      canvas.drawRect(
        Rect.fromLTWH(0, axis.y(d.row), w, rowH),
        Paint()..color = accent.withValues(alpha: 0.10),
      );

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(axis.x(lo), top, len * stepW - 2, bh),
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
      final gripX = movingRight ? axis.x(hi + 1) : axis.x(lo);
      final cy = top + bh / 2;
      canvas.drawRect(
        Rect.fromLTWH(gripX - 1.5, top - 2, 3, bh + 4),
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        Offset(gripX, cy),
        7 + 1.5 * pulse,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(Offset(gripX, cy), 3.5, Paint()..color = accent);

      // length readout near the grip
      final tp = TextPainter(
        text: TextSpan(
          text: '$len',
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            color: LT.bg,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelX = (movingRight ? gripX + 6 : gripX - 6 - tp.width).clamp(
        0.0,
        math.max(0.0, w - tp.width),
      ).toDouble();
      final labelY = (top - tp.height - 2).clamp(
        0.0,
        math.max(0.0, h - tp.height),
      ).toDouble();
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

  /// One note. Selected = white fill (hollow when muted) + halo + edge
  /// handles (+ ▼ over tiny notes): never color alone.
  void _note(Canvas canvas, PitchNote n, RRect rect, bool isSelected) {
    if (isSelected) {
      // dark separation ring, then the bright halo
      canvas.drawRRect(
        rect.inflate(3),
        Paint()
          ..color = LT.bg
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      canvas.drawRRect(
        rect.inflate(1.5),
        Paint()
          ..color = LT.t1
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      if (n.muted) {
        canvas.drawRRect(
          rect,
          Paint()..color = LT.t1.withValues(alpha: .16),
        );
      } else {
        canvas.drawRRect(
          rect,
          Paint()
            ..color = LT.t1.withValues(alpha: n.chance < 1 ? math.max(.55, n.chance) : 1),
        );
        // thin accent stripe keeps the track identity
        canvas.drawRect(
          Rect.fromLTWH(rect.left, rect.bottom - 2.5, rect.width, 2.5),
          Paint()..color = accent,
        );
      }
      final handle = Paint()..color = n.muted ? LT.t1 : LT.bg;
      if (rect.width >= 10) {
        final hh = math.max(4.0, rect.height - 6);
        final ht = rect.center.dy - hh / 2;
        // the right end is the resize grip (StepGrid resizes from the end
        // only); the left end is marked by the outline alone
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(rect.right - 4, ht, 2.5, hh),
            const Radius.circular(1),
          ),
          handle,
        );
      } else {
        // tiny note: a ▼ above it so the selection is findable
        final cx = rect.center.dx;
        final t = rect.top - 4;
        canvas.drawPath(
          Path()
            ..moveTo(cx - 4, t - 5)
            ..lineTo(cx + 4, t - 5)
            ..lineTo(cx, t)
            ..close(),
          Paint()..color = LT.t1,
        );
      }
    } else if (n.muted) {
      // deactivated: hollow outline, no glow — still selectable/editable
      canvas.drawRRect(
        rect,
        Paint()
          ..color = accent.withValues(alpha: .45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
    } else if (n.chance < 1) {
      // fades with its play probability
      canvas.drawRRect(
        rect,
        Paint()..color = accent.withValues(alpha: math.max(.25, n.chance)),
      );
    } else {
      canvas.drawRRect(
        rect,
        Paint()
          ..color = accent.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
      canvas.drawRRect(rect, Paint()..color = accent);
    }
    if (!isSelected && !n.muted) {
      // hairline so touching notes stay separate
      canvas.drawRRect(
        rect,
        Paint()
          ..color = LT.bg.withValues(alpha: .7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
    final ink = isSelected && !n.muted ? LT.bg : Colors.white;
    // wide chance notes show the percent
    if (n.chance < 1 && rect.width >= 30 && rect.height >= 10) {
      final tp = TextPainter(
        text: TextSpan(
          text: '${(n.chance * 100).round()}%',
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 4);
      tp.paint(canvas, Offset(rect.left + 6, rect.center.dy - tp.height / 2));
    }
    if (n.locked) {
      canvas.drawCircle(
        Offset(rect.left + 3, rect.top + 3),
        2,
        Paint()..color = LT.amber,
      );
    }
    final mark = strokeMarks ? strokeMark(n) : null;
    if (mark != null && rect.height >= 8) {
      final tp = TextPainter(
        text: TextSpan(
          text: mark,
          style: TextStyle(
            fontFamily: fontFamily,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: ink,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(rect.left + 2, rect.center.dy - tp.height / 2),
      );
    }
    // gt-003: technique markers on guitar tracks — "s" (짧게), "PM" with
    // a dotted outline (팜뮤트 근사), "◇" (하모닉스 근사)
    final art = strokeMarks ? articulationMark(n) : null;
    if (art != null) {
      if (art == 'PM') _dotted(canvas, rect.outerRect, ink);
      if (rect.height >= 8) {
        _label(
          canvas,
          art,
          Offset(rect.left + (mark == null ? 2 : 12), rect.top + 5),
          ink,
        );
      }
    }
    if (stringMarks && n.guitarString != null && rect.height >= 8) {
      _label(
        canvas,
        '${n.guitarString}',
        Offset(rect.right - (isSelected ? 6 : 3), rect.center.dy),
        ink,
        right: true,
      );
    }
    if (warnNotes.contains(n)) {
      canvas.drawRRect(
        rect,
        Paint()
          ..color = LT.amber
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
      _label(
        canvas,
        '!',
        Offset(rect.right - 3, rect.center.dy),
        LT.amber,
        right: true,
      );
    }
  }

  void _dashedRect(
    Canvas canvas,
    Rect r,
    Color color,
    double width,
    double dash,
    double gap,
  ) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = width;
    for (var x = r.left; x < r.right; x += dash + gap) {
      final e = math.min(x + dash, r.right);
      canvas.drawLine(Offset(x, r.top), Offset(e, r.top), paint);
      canvas.drawLine(Offset(x, r.bottom), Offset(e, r.bottom), paint);
    }
    for (var y = r.top; y < r.bottom; y += dash + gap) {
      final e = math.min(y + dash, r.bottom);
      canvas.drawLine(Offset(r.left, y), Offset(r.left, e), paint);
      canvas.drawLine(Offset(r.right, y), Offset(r.right, e), paint);
    }
  }

  /// A dotted outline (gt-003 palm-tone marker).
  void _dotted(Canvas canvas, Rect r, Color color) =>
      _dashedRect(canvas, r, color, 1.2, 2, 2);

  // laid-out row names (the lane repaints with the playhead: no relayout)
  static final Map<(String, bool), TextPainter> _names = {};
  static TextPainter _rowName(String name, bool root) =>
      _names[(name, root)] ??= TextPainter(
        text: TextSpan(
          text: name,
          style: LTType.mono(
            size: 9,
            color: root ? LT.lime.withValues(alpha: .6) : LT.t2.withValues(alpha: .35),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.keyHighlight != keyHighlight ||
      !listEquals(old.notes, notes) ||
      !setEquals(old.selected, selected) ||
      !listEquals(old.rows, rows) ||
      old.view.start != view.start ||
      old.view.end != view.end ||
      old.accent != accent ||
      old.marquee != marquee ||
      old.strokeMarks != strokeMarks ||
      old.stringMarks != stringMarks ||
      !setEquals(old.warnNotes, warnNotes) ||
      old.draft != draft ||
      old.playStep != playStep ||
      old.steps != steps ||
      old.fontFamily != fontFamily ||
      old.pulse != pulse;
}
