import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/tokens.dart';

class DesktopCommands extends StatelessWidget {
  const DesktopCommands({super.key, required this.enabled, required this.play,
    required this.record, required this.save, required this.undo, required this.redo,
    required this.child});
  final bool enabled;
  final VoidCallback play, record, save, undo, redo;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Focus(autofocus: true, onKeyEvent: (_, event) {
      if (ModalRoute.of(context)?.isCurrent == false) return KeyEventResult.ignored;
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
        return KeyEventResult.ignored;
      }
      final keyboard = HardwareKeyboard.instance;
      final command = keyboard.isControlPressed || keyboard.isMetaPressed;
      VoidCallback? action;
      if (!command && !keyboard.isAltPressed && !keyboard.isShiftPressed && event.logicalKey == LogicalKeyboardKey.space) action = play;
      if (command && !keyboard.isAltPressed) {
        if (event.logicalKey == LogicalKeyboardKey.keyS && !keyboard.isShiftPressed) action = save;
        if (event.logicalKey == LogicalKeyboardKey.keyR && keyboard.isShiftPressed) action = record;
        if (event.logicalKey == LogicalKeyboardKey.keyZ) action = keyboard.isShiftPressed ? redo : undo;
      }
      if (action == null) return KeyEventResult.ignored;
      if (event is KeyDownEvent) action();
      return KeyEventResult.handled;
    }, child: child);
  }
}

/// A dedicated horizontal scrollbar leaves lane dragging available for seeking.
class DesktopTimeline extends StatefulWidget {
  const DesktopTimeline({super.key, required this.child});
  final Widget child;
  @override
  State<DesktopTimeline> createState() => _DesktopTimelineState();
}
class _DesktopTimelineState extends State<DesktopTimeline> {
  final _scroll = ScrollController();
  double _zoom = 1;
  @override
  void dispose() { _scroll.dispose(); super.dispose(); }
  void _setZoom(double value) {
    final oldZoom = _zoom;
    final oldOffset = _scroll.hasClients ? _scroll.offset : 0.0;
    setState(() => _zoom = value.clamp(1.0, 4.0));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo((oldOffset * _zoom / oldZoom).clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }
  @override
  Widget build(BuildContext context) {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    final mac = Theme.of(context).platform == TargetPlatform.macOS;
    final mod = mac ? '⌘' : 'Ctrl';
    return Column(children: [
      SizedBox(height: 32, child: Row(children: [
        Text(ko ? '타임라인' : 'Timeline', style: const TextStyle(color: LT.t2, fontSize: 12)),
        const SizedBox(width: 12),
        Expanded(child: Text('Space ▶/Ⅱ   $mod+Shift+R ●   $mod+S ↓   $mod+Z ↶',
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: LT.t3, fontSize: 11))),
        IconButton(key: const ValueKey('timeline-zoom-out'), visualDensity: VisualDensity.compact,
          tooltip: ko ? '축소' : 'Zoom out', onPressed: _zoom > 1 ? () => _setZoom(_zoom - .5) : null,
          icon: const Icon(Icons.remove, size: 16)),
        Text('${(_zoom * 100).round()}%', style: const TextStyle(fontSize: 11)),
        IconButton(key: const ValueKey('timeline-zoom-in'), visualDensity: VisualDensity.compact,
          tooltip: ko ? '확대' : 'Zoom in', onPressed: _zoom < 4 ? () => _setZoom(_zoom + .5) : null,
          icon: const Icon(Icons.add, size: 16)),
        TextButton(onPressed: () => _setZoom(1), child: Text(ko ? '전체 보기' : 'Fit', style: const TextStyle(fontSize: 11))),
      ])),
      Expanded(child: LayoutBuilder(builder: (context, constraints) => Scrollbar(
        controller: _scroll, thumbVisibility: true, trackVisibility: true,
        scrollbarOrientation: ScrollbarOrientation.bottom,
        notificationPredicate: (notification) => notification.metrics.axis == Axis.horizontal,
        child: SingleChildScrollView(controller: _scroll, scrollDirection: Axis.horizontal,
          child: SizedBox(width: constraints.maxWidth * _zoom, height: constraints.maxHeight - 12,
            child: widget.child)),
      ))),
    ]);
  }
}

class DesktopSplitHandle extends StatelessWidget {
  const DesktopSplitHandle({super.key, required this.onDelta, required this.onReset});
  final ValueChanged<double> onDelta;
  final VoidCallback onReset;
  @override
  Widget build(BuildContext context) {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    return Semantics(label: ko ? '작업 영역 크기 조절' : 'Resize workspace',
      child: Tooltip(message: ko ? '위아래로 끌어 크기 조절 · 두 번 클릭해 초기화' : 'Drag to resize · Double-click to reset',
        child: MouseRegion(cursor: SystemMouseCursors.resizeUpDown,
          child: GestureDetector(behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (details) => onDelta(details.delta.dy), onDoubleTap: onReset,
            child: const SizedBox(height: 14, width: double.infinity,
              child: Center(child: SizedBox(width: 48, child: Divider(height: 2, thickness: 2, color: LT.borderStrong)))),
          ),
        ),
      ),
    );
  }
}
