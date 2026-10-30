// QA 2026-10-30 (codex-verification): a hum conversion into an empty track
// landed above the viewport (D5..A5 while the roll showed up to ~G4), so the
// grid looked empty. A GridReveal shows the new notes ONCE when none of them
// is on screen; visible results, the user's zoom, the data and later
// rebuilds are left alone, and a new grid (another track) ignores it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';

import '../support/offline_fonts.dart';

PitchNote _n(int midi, int step, {int dur = 2}) => PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

final _ladder = [
  for (var m = 0; m <= 127; m++)
    Rung(midi: m, name: '${kNoteNames[m % 12]}${m ~/ 12 - 1}', degree: m % 12, index: m, freq: midiToFreq(m)),
];

class _Host extends StatefulWidget {
  const _Host({super.key, required this.notes});
  final List<PitchNote> notes;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<PitchNote> notes = List.of(widget.notes);
  GridReveal? reveal;
  String gridKey = 'melody';
  final link = PitchGridViewLink();

  /// What the editor does after a hum conversion: add, then reveal once.
  void convert(List<PitchNote> added, int serial) => setState(() {
    notes = [...notes, ...added];
    reveal = GridReveal(serial, List.of(added));
  });

  /// A rebuild with nothing changed (playback / selection ticks).
  void rebuild() => setState(() {});

  /// Another track's grid (a new StepGrid) with the request still around.
  void switchTrack(String id) => setState(() => gridKey = id);

  @override
  Widget build(BuildContext context) => StepGrid(
    key: ValueKey(gridKey),
    ladder: _ladder,
    notes: notes,
    // the editor's empty-track focus: the pad window's low end
    focusMidi: 50,
    viewLink: link,
    reveal: reveal,
    onPlace: (_, _, _) {},
    onErase: (_, _) {},
    onEdit: (before, after) {
      setState(() => notes = after);
      return true;
    },
    playStep: 0,
    accent: Colors.lightGreen,
    steps: 16,
    bars: 1,
  );
}

void main() {
  late GlobalKey<_HostState> host;

  Future<void> mount(WidgetTester tester, List<PitchNote> notes) async {
    useOfflineTestFonts();
    host = GlobalKey<_HostState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SizedBox(width: 900, height: 420, child: _Host(key: host, notes: notes))),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ScrollController vertical(WidgetTester tester) =>
      tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('pitch-grid-viewport'))).controller!;

  /// Rows (MIDI) inside the viewport now.
  Set<int> visibleRows(WidgetTester tester) {
    final c = vertical(tester);
    final rowH = (c.position.maxScrollExtent + c.position.viewportDimension) / 128;
    final top = c.offset, bottom = top + c.position.viewportDimension;
    return {
      for (var i = 0; i < 128; i++)
        if ((i + 1) * rowH > top && i * rowH < bottom) 127 - i,
    };
  }

  final result = [_n(74, 0), _n(76, 4), _n(77, 8), _n(81, 12)]; // D5 E5 F5 A5

  testWidgets('an off-screen result (empty track) is shown once', (tester) async {
    await mount(tester, const []);
    expect(visibleRows(tester).intersection({74, 76, 77, 81}), isEmpty, reason: 'the reported starting state');
    host.currentState!.convert(result, 1);
    await tester.pumpAndSettle();
    expect(visibleRows(tester).containsAll({74, 76, 77, 81}), isTrue, reason: 'all four rows on screen');
    expect(host.currentState!.notes.map((n) => n.midi), [74, 76, 77, 81], reason: 'data untouched');
  });

  testWidgets('a result already on screen leaves the view where it is', (tester) async {
    await mount(tester, [_n(52, 0)]); // first focus near the existing note
    final rows = visibleRows(tester);
    final inView = [_n(52, 4), _n(53, 8)];
    expect(rows.containsAll({52, 53}), isTrue);
    final offset = vertical(tester).offset;
    host.currentState!.convert(inView, 1);
    await tester.pumpAndSettle();
    expect(vertical(tester).offset, offset);
  });

  testWidgets("the user's zoom stays; a pan only when the result is outside the zoomed time range", (tester) async {
    await mount(tester, const []);
    final view = host.currentState!.link.view!;
    view.setZoom(4); // 4 of 16 steps
    view.panTo(0);
    await tester.pump();
    host.currentState!.convert([_n(76, 12)], 1);
    await tester.pumpAndSettle();
    expect(view.zoom, 4, reason: 'zoom kept');
    expect(view.view.start <= 12 && view.view.end > 12, isTrue, reason: 'panned to the note');
    expect(visibleRows(tester).contains(76), isTrue);
  });

  testWidgets('rebuilds with the same request never move the view again; a new grid ignores it', (tester) async {
    await mount(tester, const []);
    host.currentState!.convert(result, 1);
    await tester.pumpAndSettle();
    // the user scrolls away; playback / selection rebuilds keep the request
    vertical(tester).jumpTo(0);
    await tester.pump();
    host.currentState!.rebuild();
    await tester.pumpAndSettle();
    expect(vertical(tester).offset, 0, reason: 'same serial: no second jump');
    // another track's grid (a new StepGrid) built with a stale request
    host.currentState!.switchTrack('bass');
    await tester.pumpAndSettle();
    final c = vertical(tester);
    final first = c.offset;
    host.currentState!.rebuild();
    await tester.pumpAndSettle();
    expect(c.offset, first, reason: 'a fresh grid does not replay the request');
  });
}
