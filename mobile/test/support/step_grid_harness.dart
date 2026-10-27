// Shared StepGrid harness for the piano-roll command tests: records each
// onEdit commit and applies it, like the editor's _gridEditNotes does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';

import 'offline_fonts.dart';

class GridHarness extends StatefulWidget {
  const GridHarness({
    super.key,
    required this.notes,
    this.low = 60,
    this.high = 64,
    this.steps = 8,
    this.playStep = 0,
    this.scaleRoot,
    this.scaleName,
    this.guitar = false,
    this.bpm = 120,
    this.grooved = false,
  });
  final List<PitchNote> notes;
  final int low, high, steps;
  final double playStep;
  final String? scaleRoot, scaleName;
  final bool guitar, grooved;
  final int bpm;
  @override
  State<GridHarness> createState() => GridHarnessState();
}

class GridHarnessState extends State<GridHarness> {
  late List<PitchNote> notes = List.of(widget.notes);
  int commits = 0;
  final List<(int, int, int)> placed = [];

  @override
  Widget build(BuildContext context) => StepGrid(
    ladder: [
      for (var midi = widget.low; midi <= widget.high; midi++)
        Rung(
          midi: midi,
          name: '$midi',
          degree: midi % 12,
          index: midi - widget.low,
          freq: midiToFreq(midi),
        ),
    ],
    notes: notes,
    initialEditMode: true,
    scaleRoot: widget.scaleRoot,
    scaleName: widget.scaleName,
    guitar: widget.guitar,
    bpm: widget.bpm,
    grooved: widget.grooved,
    onPlace: (rung, a, b) => placed.add((rung.midi, a, b)),
    onErase: (_, _) {},
    onEdit: (before, after) {
      commits++;
      setState(() => notes = after);
      return true;
    },
    playStep: widget.playStep,
    accent: Colors.lightGreen,
    steps: widget.steps,
    bars: (widget.steps / 16).ceil(),
  );
}

Future<GlobalKey<GridHarnessState>> mountGrid(
  WidgetTester tester,
  List<PitchNote> notes, {
  int low = 60,
  int high = 64,
  int steps = 8,
  double playStep = 0,
  String? scaleRoot,
  String? scaleName,
  bool guitar = false,
  int bpm = 120,
  bool grooved = false,
  Widget Function(Widget grid)? wrap,
}) async {
  useOfflineTestFonts();
  final key = GlobalKey<GridHarnessState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 720,
            height: 340,
            child: (wrap ?? (g) => g)(
              GridHarness(
                key: key,
                notes: notes,
                low: low,
                high: high,
                steps: steps,
                playStep: playStep,
                scaleRoot: scaleRoot,
                scaleName: scaleName,
                guitar: guitar,
                bpm: bpm,
                grooved: grooved,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

/// Center of [time] on [midi]'s row in the harness grid.
Offset gridPoint(
  WidgetTester tester,
  double time,
  int midi, {
  int low = 60,
  int high = 64,
  int steps = 8,
}) {
  final rect = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
  final rows = high - low + 1;
  return Offset(
    rect.left + rect.width * time / steps,
    rect.top + rect.height * (high - midi + .5) / rows,
  );
}

/// Tap a scrollable toolbar/inspector button by key.
Future<void> tapGridButton(WidgetTester tester, String key) async {
  final finder = find.byKey(ValueKey(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}
