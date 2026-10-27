import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tokens.dart';
import '../music/audition.dart';
import '../music/timeline_view.dart';

class DesktopCommands extends StatelessWidget {
  const DesktopCommands({
    super.key,
    required this.enabled,
    required this.play,
    required this.record,
    required this.save,
    required this.undo,
    required this.redo,
    required this.child,
    this.groove,
    this.duplicateLinked,
  });
  final bool enabled;
  final VoidCallback play, record, save, undo, redo;

  /// Ctrl/Cmd+G: the active track's groove sheet (groove-001).
  final VoidCallback? groove;

  /// Ctrl/Cmd+Shift+D: linked duplicate of the active section (AR-001).
  final VoidCallback? duplicateLinked;
  final Widget child;

  /// Whether [event] is the shortcut [letter] (a-z). A Latin layout decides
  /// by the typed letter (AZERTY's Ctrl+Z stays on its Z key); a non-Latin
  /// layout or IME (Korean 2-beolsik reports 'ㅋ' for physical Z) falls back
  /// to the letter's US key position, so Ctrl/Cmd+Z still undoes.
  static bool _letter(KeyEvent event, LogicalKeyboardKey letter) {
    if (event.logicalKey == letter) return true;
    final a = LogicalKeyboardKey.keyA.keyId;
    final typed = event.logicalKey.keyId - a;
    if (typed >= 0 && typed < 26) return false; // another Latin letter
    // USB HID usages of the letter keys are contiguous, like a-z.
    return event.physicalKey.usbHidUsage ==
        PhysicalKeyboardKey.keyA.usbHidUsage + (letter.keyId - a);
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (ModalRoute.of(context)?.isCurrent == false) {
          return KeyEventResult.ignored;
        }
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
          return KeyEventResult.ignored;
        }
        final keyboard = HardwareKeyboard.instance;
        final command = keyboard.isControlPressed || keyboard.isMetaPressed;
        VoidCallback? action;
        if (!command &&
            !keyboard.isAltPressed &&
            !keyboard.isShiftPressed &&
            event.logicalKey == LogicalKeyboardKey.space) {
          action = play;
        }
        if (command && !keyboard.isAltPressed) {
          if (_letter(event, LogicalKeyboardKey.keyS) &&
              !keyboard.isShiftPressed) {
            action = save;
          }
          if (_letter(event, LogicalKeyboardKey.keyR) &&
              keyboard.isShiftPressed) {
            action = record;
          }
          if (_letter(event, LogicalKeyboardKey.keyZ)) {
            action = keyboard.isShiftPressed ? redo : undo;
          }
          if (_letter(event, LogicalKeyboardKey.keyG) &&
              !keyboard.isShiftPressed) {
            action = groove;
          }
          if (_letter(event, LogicalKeyboardKey.keyD) &&
              keyboard.isShiftPressed) {
            action = duplicateLinked;
          }
        }
        if (action == null) return KeyEventResult.ignored;
        if (event is KeyDownEvent) action();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }
}

/// The scrollbar controls a shared time projection. Track labels stay fixed
/// while the ruler, notes, clips and playhead pan together.
class DesktopTimeline extends StatefulWidget {
  const DesktopTimeline({
    super.key,
    this.child,
    this.builder,
    this.steps = 64,
    this.loopRange,
    this.labelWidth = 220,
    this.onCollapse,
  }) : assert(child != null || builder != null);
  final Widget? child;
  final Widget Function(TimelineView view)? builder;
  final int steps;
  final PlaybackRange? loopRange;
  final double labelWidth;

  /// Folds the timeline to one row (the editor shows a ▾ to bring it back).
  final VoidCallback? onCollapse;
  @override
  State<DesktopTimeline> createState() => _DesktopTimelineState();
}

class _DesktopTimelineState extends State<DesktopTimeline> {
  final _scroll = ScrollController();
  double _zoom = 1, _laneWidth = 1;
  bool _fittingLoop = false;
  double get _maxZoom => (widget.steps / 16).clamp(4.0, 64.0);
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DesktopTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.steps != widget.steps ||
        (_fittingLoop &&
            (oldWidget.loopRange?.start != widget.loopRange?.start ||
                oldWidget.loopRange?.end != widget.loopRange?.end))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_fittingLoop && widget.loopRange != null) {
          _fitLoop();
        } else {
          _fitAll();
        }
      });
    }
  }

  void _show(double zoom, double start, {bool fitLoop = false}) {
    setState(() {
      _zoom = zoom.clamp(1.0, _maxZoom);
      _fittingLoop = fitLoop;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(
        (start / widget.steps * _laneWidth * _zoom).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
      setState(() {});
    });
  }

  void _setZoom(double zoom) {
    final start =
        _scroll.hasClients
            ? _scroll.offset / (_laneWidth * _zoom) * widget.steps
            : 0.0;
    _show(zoom, start);
  }

  void _fitAll() => _show(1, 0);
  void _fitLoop() {
    final range = widget.loopRange;
    if (range != null) {
      _show(widget.steps / range.length, range.start.toDouble(), fitLoop: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    final mod = mac ? '⌘' : 'Ctrl';
    return Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              Text(
                ko ? '타임라인' : 'Timeline',
                style: const TextStyle(color: LT.t2, fontSize: 12),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Space ▶/Ⅱ   $mod+Shift+R ●   $mod+S ↓   $mod+Z ↶',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: LT.t3, fontSize: 11),
                ),
              ),
              IconButton(
                key: const ValueKey('timeline-zoom-out'),
                visualDensity: VisualDensity.compact,
                tooltip: ko ? '축소' : 'Zoom out',
                onPressed: _zoom > 1 ? () => _setZoom(_zoom - .5) : null,
                icon: const Icon(Icons.remove, size: 16),
              ),
              Text(
                '${(_zoom * 100).round()}%',
                style: const TextStyle(fontSize: 11),
              ),
              IconButton(
                key: const ValueKey('timeline-zoom-in'),
                visualDensity: VisualDensity.compact,
                tooltip: ko ? '확대' : 'Zoom in',
                onPressed: _zoom < _maxZoom ? () => _setZoom(_zoom + .5) : null,
                icon: const Icon(Icons.add, size: 16),
              ),
              TextButton(
                key: const ValueKey('timeline-fit-loop'),
                onPressed: widget.loopRange == null ? null : _fitLoop,
                child: Text(
                  ko ? '반복 구간 확대' : 'Fit loop',
                  style: TextStyle(
                    fontSize: 11,
                    color: _fittingLoop ? LT.lime : null,
                  ),
                ),
              ),
              TextButton(
                key: const ValueKey('timeline-fit-all'),
                onPressed: _fitAll,
                child: Text(
                  ko ? '전체 보기' : 'Fit',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              if (widget.onCollapse != null)
                IconButton(
                  key: const ValueKey('timeline-collapse'),
                  visualDensity: VisualDensity.compact,
                  tooltip: ko ? '타임라인 접기' : 'Hide timeline',
                  onPressed: widget.onCollapse,
                  icon: const Icon(Icons.expand_less, size: 18),
                ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (widget.builder == null) {
                _laneWidth = constraints.maxWidth;
                return Scrollbar(
                  controller: _scroll,
                  thumbVisibility: true,
                  trackVisibility: true,
                  scrollbarOrientation: ScrollbarOrientation.bottom,
                  notificationPredicate:
                      (n) => n.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: constraints.maxWidth * _zoom,
                      height: constraints.maxHeight - 12,
                      child: widget.child,
                    ),
                  ),
                );
              }
              final width = (constraints.maxWidth - widget.labelWidth - 8)
                  .clamp(1.0, double.infinity);
              if (width != _laneWidth &&
                  _scroll.hasClients &&
                  _scroll.offset > 0) {
                final start =
                    _scroll.offset / (_laneWidth * _zoom) * widget.steps;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_fittingLoop && widget.loopRange != null) {
                    _fitLoop();
                  } else {
                    _show(_zoom, start);
                  }
                });
              }
              _laneWidth = width;
              return Column(
                children: [
                  Expanded(
                    child: AnimatedBuilder(
                      animation: _scroll,
                      builder: (context, _) {
                        final start =
                            _scroll.hasClients
                                ? _scroll.offset.clamp(
                                      0.0,
                                      _laneWidth * (_zoom - 1),
                                    ) /
                                    (_laneWidth * _zoom) *
                                    widget.steps
                                : 0.0;
                        return widget.builder!(
                          TimelineView(start, start + widget.steps / _zoom),
                        );
                      },
                    ),
                  ),
                  // A thin scroll extent drives the projection above; labels never
                  // become part of the horizontally scrolled content.
                  SizedBox(
                    height: 14,
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      trackVisibility: true,
                      scrollbarOrientation: ScrollbarOrientation.bottom,
                      notificationPredicate:
                          (n) => n.metrics.axis == Axis.horizontal,
                      child: SingleChildScrollView(
                        key: const ValueKey('timeline-scroll'),
                        controller: _scroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: widget.labelWidth + 8 + _laneWidth * _zoom,
                          height: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class DesktopSplitHandle extends StatelessWidget {
  const DesktopSplitHandle({
    super.key,
    required this.onDelta,
    required this.onReset,
  });
  final ValueChanged<double> onDelta;
  final VoidCallback onReset;
  @override
  Widget build(BuildContext context) {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    return Semantics(
      label: ko ? '작업 영역 크기 조절' : 'Resize workspace',
      child: Tooltip(
        message:
            ko
                ? '위아래로 끌어 크기 조절 · 두 번 클릭해 초기화'
                : 'Drag to resize · Double-click to reset',
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeUpDown,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) => onDelta(details.delta.dy),
            onDoubleTap: onReset,
            child: const SizedBox(
              height: 14,
              width: double.infinity,
              child: Center(
                child: SizedBox(
                  width: 48,
                  child: Divider(
                    height: 2,
                    thickness: 2,
                    color: LT.borderStrong,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
