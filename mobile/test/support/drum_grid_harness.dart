// Shared DrumGrid harness (drums-001): records each onEdit commit and its
// "before" snapshot (the editor's undo step), and each draw-mode toggle.
// Optionally mounts a DesktopInstrument around the grid, as the desktop
// editor does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/widgets/desktop_instrument.dart';
import 'package:humming/looptap/widgets/surfaces/drum_surface.dart';

import 'offline_fonts.dart';

class DrumHarness extends StatefulWidget {
  const DrumHarness({
    super.key,
    required this.notes,
    this.steps = 16,
    this.selectMode = true,
  });
  final List<DrumNote> notes;
  final int steps;
  final bool selectMode;
  @override
  State<DrumHarness> createState() => DrumHarnessState();
}

class DrumHarnessState extends State<DrumHarness> {
  late List<DrumNote> notes = List.of(widget.notes);
  final List<List<DrumNote>> undo = [];
  final List<(String, int)> toggled = [];
  int get commits => undo.length;

  /// Restore the last snapshot, like the editor's Undo.
  void undoLast() => setState(() => notes = undo.removeLast());

  @override
  Widget build(BuildContext context) => DrumGrid(
    notes: notes,
    initialSelectMode: widget.selectMode,
    onToggle: (kind, step) => toggled.add((kind, step)),
    onEdit: (before, after) {
      setState(() {
        undo.add(before);
        notes = after;
      });
      return true;
    },
    playStep: 0,
    steps: widget.steps,
    bars: (widget.steps / 16).ceil(),
  );
}

Future<GlobalKey<DrumHarnessState>> mountDrums(
  WidgetTester tester,
  List<DrumNote> notes, {
  int steps = 16,
  bool selectMode = true,
  bool instrument = false,
  List<int>? instrumentHits,
}) async {
  useOfflineTestFonts();
  LoopPrefs.instance.keyboardBindings.value = {};
  final key = GlobalKey<DrumHarnessState>();
  Widget grid = DrumHarness(
    key: key,
    notes: notes,
    steps: steps,
    selectMode: selectMode,
  );
  if (instrument) {
    grid = DesktopInstrument(
      group: 'drums',
      identity: 'drums',
      capturePointerFocus: false,
      labels: const ['KK', 'SN', 'HH', 'A', 'B', 'C'],
      onDown: (i) {
        instrumentHits?.add(i);
        return () {};
      },
      child: grid,
    );
  }
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: Center(child: SizedBox(width: 720, height: 420, child: grid)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

/// Center of time [t] (in steps) on drum row [row] (0 = top = hihat).
Offset drumPoint(
  WidgetTester tester,
  double t,
  int row, {
  int steps = 16,
  int rows = 3,
}) {
  final rect = tester.getRect(find.byKey(const ValueKey('drum-grid-lanes')));
  return Offset(
    rect.left + rect.width * t / steps,
    rect.top + rect.height * (row + .5) / rows,
  );
}
