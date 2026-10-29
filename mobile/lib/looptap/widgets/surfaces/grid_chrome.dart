// ui-001 stage 4 (docs/specs/ui/ui-001-desktop-b2-layout.md "4단계 — 오른쪽
// 인스펙터와 도구 줄 정리"): the desktop editor draws a grid's tools and its
// selection inspector OUTSIDE the grid — the tool row above the editing
// surface and the inspector's Notes tab.
//
// The grid (StepGrid / DrumGrid) keeps everything: its selection, its edit
// callbacks and the widgets' ValueKeys. It only hands the editor two builders
// that call its own item lists, so a button in the inspector is the very same
// button the phone shows in the grid's rows (no copied state, same meaning).
//
// Lifetime: the grid that is mounted attaches its content and detaches it
// before disposing; only the attached content can detach, so a new grid
// (track / section / mode switch) that attached first is never cleared by the
// old one's later dispose. The grid calls [changed] after every setState so
// the tool row and the inspector repaint in the same frame; changes made
// while the tree builds are announced at the end of that frame.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class GridChromeContent {
  const GridChromeContent({
    required this.tools,
    required this.notes,
    required this.selection,
    this.onKey,
  });

  /// The grid's own key handler. On the phone the inspector buttons sit
  /// inside the grid's focus, so a key a focused button does not use (Ctrl+C,
  /// Delete, arrows ...) reaches the grid; [GridChromeKeys] keeps that route
  /// for the tool row and the Notes tab drawn outside.
  final KeyEventResult Function(KeyEvent event)? onKey;

  /// The desktop tool-row items (draw / select / area / eraser / copy /
  /// paste ...), built by the grid.
  final List<Widget> Function() tools;

  /// The Notes tab body (selection header, the inspector items, the fixed
  /// footer), built by the grid.
  final Widget Function() notes;

  /// The notes / hits selected now (the grid's own selection objects). The
  /// editor compares the SET, not the count: picking another single note is
  /// a new selection even though the count stays 1.
  final Iterable<Object> Function() selection;
}

/// Wraps the grid's tools / Notes tab drawn outside the grid: keys their
/// focused buttons leave unhandled go to the grid's handler (never takes the
/// focus itself, never a traversal stop).
class GridChromeKeys extends StatelessWidget {
  const GridChromeKeys({super.key, required this.content, required this.child});
  final GridChromeContent? content;
  final Widget child;

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: (_, event) => content?.onKey?.call(event) ?? KeyEventResult.ignored,
    child: child,
  );
}

class GridChrome extends ChangeNotifier {
  GridChromeContent? _content;
  bool _disposed = false, _pending = false;

  /// The mounted grid's content (null: no editing grid on screen).
  GridChromeContent? get content => _content;

  /// The selected notes / hits now (empty: none, or no grid).
  Set<Object> get selection => _content?.selection().toSet() ?? const {};

  void attach(GridChromeContent content) {
    if (identical(_content, content)) return;
    _content = content;
    changed();
  }

  void detach(GridChromeContent content) {
    if (!identical(_content, content)) return;
    _content = null;
    changed();
  }

  /// The grid's state changed: rebuild the tool row and the inspector.
  void changed() {
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
    _content = null;
    super.dispose();
  }
}
