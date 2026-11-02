// Phone piano roll without modes (2026-11-02, user feedback: too many
// buttons, modes, overlapping velocity bars, awkward 편집 확대).
// - tap empty = add a note (no tool row, only a ⋯ button);
// - tap a note = select → a selection bar (delete, duplicate, octave,
//   length, ⋯) and the velocity lane appear; tap empty = clear (no note);
// - long-press + drag on empty space = area select (a chord column);
//   long-press a note = add it to the selection;
// - chord bars in the lane sit side by side and each one can be dragged;
// - the ⋯ sheet holds the rest (select all, scale snap, chord stamp…).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/surfaces/velocity_lane.dart';

import '../support/offline_fonts.dart';

PitchNote _n(int midi, int step, {int dur = 2, int? velocity}) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur, velocity: velocity);

final _ladder = [
  for (var m = 48; m <= 84; m++)
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
  final placed = <(int, int, int)>[];

  @override
  Widget build(BuildContext context) => StepGrid(
    ladder: _ladder,
    notes: notes,
    focusMidi: 60,
    onPlace: (rung, a, b) => setState(() {
      placed.add((rung.midi, a, b));
      notes = [...notes, _n(rung.midi, a, dur: b - a + 1)];
    }),
    onErase: (_, _) {},
    onEdit: (before, after) {
      setState(() => notes = after);
      return true;
    },
    playStep: 0,
    accent: Colors.lightGreen,
    steps: 16,
    bars: 1,
    phoneSimple: true,
  );
}

void main() {
  late GlobalKey<_HostState> host;

  Future<void> mount(WidgetTester tester, List<PitchNote> notes) async {
    useOfflineTestFonts();
    host = GlobalKey<_HostState>();
    await tester.binding.setSurfaceSize(const Size(390, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _Host(key: host, notes: notes))),
    );
    await tester.pumpAndSettle();
  }

  /// Screen point of [step] on [midi]'s row.
  Future<Offset> at(WidgetTester tester, double step, int midi) async {
    final rows = _ladder.reversed.toList();
    final row = rows.indexWhere((r) => r.midi == midi);
    final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('pitch-grid-viewport'))).controller!;
    var lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final vp = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
    final rowH = lane.height / rows.length;
    scroll.jumpTo(((row + .5) * rowH - vp.height / 2).clamp(0.0, scroll.position.maxScrollExtent).toDouble());
    await tester.pump();
    lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final v = tester.widget<PitchGridSurface>(find.byType(PitchGridSurface)).view!.view;
    return Offset(lane.left + (step - v.start) / v.length * lane.width, lane.top + (row + .5) * rowH);
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  testWidgets('nothing selected: no tool row, one ⋯ button, no lane; tap empty adds a note', (tester) async {
    await mount(tester, const []);
    expect(key('note-draw'), findsNothing);
    expect(key('note-select'), findsNothing);
    expect(key('grid-focus'), findsNothing);
    expect(key('phone-more-idle'), findsOneWidget);
    expect(find.byType(VelocityLane), findsNothing);
    await tester.tapAt(await at(tester, 4.5, 60));
    await tester.pumpAndSettle();
    expect(host.currentState!.placed, hasLength(1));
    expect(host.currentState!.placed.single.$1, 60);
  });

  testWidgets('tap a note selects it; the bar and the note panel appear; tap empty clears without adding', (tester) async {
    await mount(tester, [_n(60, 4)]);
    await tester.tapAt(await at(tester, 4.5, 60));
    await tester.pumpAndSettle();
    expect(key('phone-selection-count'), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    expect(key('phone-note-panel'), findsOneWidget);
    expect(find.byType(VelocityLane), findsNothing, reason: 'no lane on the phone');
    expect(key('phone-more-idle'), findsNothing);
    await tester.tapAt(await at(tester, 8.5, 67)); // empty, clear of the floating panel
    await tester.pumpAndSettle();
    expect(key('phone-selection-count'), findsNothing);
    expect(host.currentState!.placed, isEmpty, reason: 'clearing never adds a note');
    expect(host.currentState!.notes, hasLength(1));
  });

  testWidgets('selection bar: octave up and delete', (tester) async {
    await mount(tester, [_n(60, 4), _n(64, 8)]);
    await tester.tapAt(await at(tester, 4.5, 60));
    await tester.pumpAndSettle();
    await tester.ensureVisible(key('phone-octave-up'));
    await tester.pumpAndSettle();
    await tester.tap(key('phone-octave-up'));
    await tester.pumpAndSettle();
    expect(host.currentState!.notes.map((n) => n.midi).toSet(), {72, 64});
    await tester.ensureVisible(key('phone-delete'));
    await tester.pumpAndSettle();
    await tester.tap(key('phone-delete'));
    await tester.pumpAndSettle();
    expect(host.currentState!.notes.map((n) => n.midi), [64]);
  });

  testWidgets('drag a note moves it (no mode switch)', (tester) async {
    await mount(tester, [_n(60, 4)]);
    final from = await at(tester, 4.5, 60);
    final to = await at(tester, 8.5, 60);
    await tester.dragFrom(from, to - from);
    await tester.pumpAndSettle();
    expect(host.currentState!.notes.single.step, 8);
  });

  testWidgets('long-press + drag on empty space selects a whole chord column', (tester) async {
    await mount(tester, [_n(60, 4), _n(64, 4), _n(67, 4), _n(72, 12)]);
    final a = await at(tester, 3.2, 70);
    final g = await tester.startGesture(a);
    await tester.pump(const Duration(milliseconds: 1100)); // held still 1 s
    final b = await at(tester, 6.8, 58);
    await g.moveTo(b);
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(host.currentState!.placed, isEmpty, reason: 'the long press did not draw');
  });

  testWidgets('long-press a note adds it to the selection', (tester) async {
    await mount(tester, [_n(60, 4), _n(64, 8)]);
    await tester.tapAt(await at(tester, 4.5, 60));
    await tester.pumpAndSettle();
    final g = await tester.startGesture(await at(tester, 8.5, 64));
    await tester.pump(const Duration(milliseconds: 500));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  // 2026-11-02: the selected notes' sound is set in a panel on the right
  testWidgets('note panel: one velocity for every selected note, pitch, mute; no more', (tester) async {
    await mount(tester, [_n(60, 4, velocity: 100), _n(64, 4, velocity: 60), _n(72, 12, velocity: 90)]);
    final g = await tester.startGesture(await at(tester, 3.2, 70));
    await tester.pump(const Duration(milliseconds: 1100)); // hold, then select
    await g.moveTo(await at(tester, 6.8, 58));
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    expect(find.text('Mixed'), findsOneWidget, reason: 'two different velocities');
    expect(key('phone-more'), findsNothing, reason: 'no more for now (2026-11-02)');
    // the vertical slider: drag to the top = 127 for both
    final slider = tester.getRect(key('phone-velocity'));
    await tester.dragFrom(slider.center, Offset(0, -slider.height));
    await tester.pumpAndSettle();
    final byMidi = {for (final n in host.currentState!.notes) n.midi: n};
    expect(byMidi[60]!.velocity, 127);
    expect(byMidi[64]!.velocity, 127);
    expect(byMidi[72]!.velocity, 90, reason: 'not selected');
    expect(find.text('127'), findsOneWidget);
    await tester.tap(key('phone-pitch-up'));
    await tester.pumpAndSettle();
    expect(host.currentState!.notes.map((n) => n.midi).toSet(), {61, 65, 72});
    await tester.tap(key('phone-mute'));
    await tester.pumpAndSettle();
    expect(host.currentState!.notes.where((n) => n.muted).map((n) => n.midi).toSet(), {61, 65});
    expect(key('phone-palm'), findsNothing, reason: 'guitar only');
  });

  testWidgets('note panel fits a tall and a short (landscape) roll', (tester) async {
    for (final size in const [Size(390, 700), Size(800, 190)]) {
      await mount(tester, [_n(60, 4)]);
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      await tester.tapAt(await at(tester, 4.5, 60));
      await tester.pumpAndSettle();
      expect(key('phone-note-panel'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$size');
      expect(key('phone-velocity').hitTestable(), findsOneWidget, reason: '$size');
    }
  });

  testWidgets('⋯ sheet: select all from there; the sheet follows the grid', (tester) async {
    await mount(tester, [_n(60, 4), _n(64, 8)]);
    await tester.tap(key('phone-more-idle'));
    await tester.pumpAndSettle();
    expect(key('phone-more-sheet'), findsOneWidget);
    await tester.tap(key('note-select-all'));
    await tester.pumpAndSettle();
    expect(find.text('Selected notes'), findsOneWidget, reason: 'the sheet rebuilt with the selection tools');
    Navigator.of(tester.element(key('phone-more-sheet'))).pop();
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('no play chance anywhere on the phone (2026-11-02)', (tester) async {
    await mount(tester, [_n(60, 4), _n(64, 8)]);
    await tester.tap(key('phone-more-idle'));
    await tester.pumpAndSettle();
    expect(key('phone-lane-mode'), findsNothing);
    await tester.tap(key('note-select-all'));
    await tester.pumpAndSettle();
    expect(key('note-chance'), findsNothing);
    expect(key('note-velocity'), findsOneWidget, reason: 'velocity stays');
    expect(find.textContaining('Chance'), findsNothing);
    expect(find.textContaining('chance'), findsNothing);
  });

  // 2026-11-02 (later): a plain drag on empty space MOVES the roll; held
  // 1 s first, the drag selects an area (adding to the selection)
  testWidgets('drag on empty space moves the roll; held 1 s it selects', (tester) async {
    await mount(tester, [_n(60, 4), _n(64, 4), _n(67, 4), _n(72, 12)]);
    final surface = tester.widget<PitchGridSurface>(find.byType(PitchGridSurface));
    final view = surface.view!;
    view.setZoom(2); // room to move sideways
    await tester.pumpAndSettle();
    final start0 = view.view.start;
    final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('pitch-grid-viewport'))).controller!;
    final y0 = scroll.offset;
    final from = await at(tester, view.view.start + view.view.length * .6, 70);
    await tester.dragFrom(from, const Offset(-120, 60));
    await tester.pumpAndSettle();
    expect(view.view.start, greaterThan(start0), reason: 'dragged left: later steps come in');
    expect(scroll.offset, lessThan(y0), reason: 'dragged down: higher rows come in');
    expect(find.text('Selected notes'), findsNothing);
    expect(key('phone-selection-count'), findsNothing, reason: 'a move selects nothing');
    expect(host.currentState!.placed, isEmpty, reason: 'nor draws');
    view.fit();
    await tester.pumpAndSettle();
    // held 1 s, then a drag selects
    final g = await tester.startGesture(await at(tester, 3.2, 70));
    await tester.pump(const Duration(milliseconds: 1100));
    await g.moveTo(await at(tester, 6.8, 58));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(host.currentState!.placed, isEmpty);
    // held and let go without moving: nothing changes
    final h = await tester.startGesture(await at(tester, 9.5, 66));
    await tester.pump(const Duration(milliseconds: 1100));
    await h.up();
    await tester.pumpAndSettle();
    expect(find.text('3 selected'), findsOneWidget);
    expect(host.currentState!.notes, hasLength(4));
  });

  testWidgets('a hum (locked) note: unlock right on the bar, then edit', (tester) async {
    await mount(tester, [_n(60, 4).copyWith(locked: true)]);
    await tester.tapAt(await at(tester, 4.5, 60));
    await tester.pumpAndSettle();
    expect(find.text('Locked notes'), findsOneWidget);
    expect(tester.widget<TextButton>(key('phone-delete')).onPressed, isNull, reason: 'locked: not editable yet');
    await tester.tap(key('phone-unlock'));
    await tester.pumpAndSettle();
    expect(host.currentState!.notes.single.locked, isFalse);
    expect(key('phone-unlock'), findsNothing);
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('short roll (phone landscape): no velocity lane, the roll keeps the room', (tester) async {
    await mount(tester, [_n(60, 4)]);
    await tester.binding.setSurfaceSize(const Size(800, 150));
    await tester.pumpAndSettle();
    await tester.tapAt(await at(tester, 4.5, 60));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byType(VelocityLane), findsNothing);
  });

  testWidgets('tapping a note never moves it, nor the roll (bar and panel float)', (tester) async {
    await mount(tester, [_n(60, 4), _n(64, 8)]);
    final lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final at4 = await at(tester, 4.5, 60);
    final before = List.of(host.currentState!.notes);
    await tester.tapAt(at4);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(tester.getRect(find.byKey(const ValueKey('pitch-grid-lane'))).size, lane.size);
    expect(host.currentState!.notes, before, reason: 'the tap changed no note');
    // a tap with a little finger jitter still changes nothing
    final g = await tester.startGesture(at4);
    await g.moveBy(const Offset(3, 2));
    await g.up();
    await tester.pumpAndSettle();
    expect(host.currentState!.notes.map((n) => (n.midi, n.startSteps, n.soundingSteps)),
        before.map((n) => (n.midi, n.startSteps, n.soundingSteps)));
  });

  testWidgets('a picked note under the floating panel slides out to its left edge', (tester) async {
    await mount(tester, [_n(60, 14)]); // the loop's last steps: under the panel
    await tester.tapAt(await at(tester, 14.5, 60));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    final view = tester.widget<PitchGridSurface>(find.byType(PitchGridSurface)).view!;
    expect(view.view.start, greaterThan(0), reason: 'panned past the end, by the panel');
    final lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final panel = tester.getRect(find.byKey(const ValueKey('phone-note-panel')));
    final endX = lane.left + (16 - view.view.start) / view.view.length * lane.width;
    expect(endX, lessThanOrEqualTo(panel.left + 1), reason: 'the note ends at the panel');
    expect(endX, greaterThan(panel.left - 40), reason: 'right beside it');
    // closing the selection puts the view back
    await tester.tapAt(await at(tester, view.view.start + 1.5, 67));
    await tester.pumpAndSettle();
    expect(view.view.start, 0);
  });

  testWidgets('a flick keeps the roll gliding; the side rail scrolls the rows fast', (tester) async {
    await mount(tester, [_n(60, 4)]);
    final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('pitch-grid-viewport'))).controller!;
    scroll.jumpTo(scroll.position.maxScrollExtent / 2);
    await tester.pump();
    final y0 = scroll.offset;
    final lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
    // a quick upward flick on empty space
    await tester.flingFrom(Offset(lane.center.dx - 60, lane.center.dy + 40), const Offset(0, -60), 1500);
    await tester.pump();
    final afterLift = scroll.offset;
    await tester.pump(const Duration(milliseconds: 300));
    expect(scroll.offset, greaterThan(afterLift), reason: 'still gliding after the finger left');
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(y0 + 60));
    // the rail: dragging its thumb across the track spans the whole range
    final rail = tester.getRect(find.byKey(const ValueKey('pitch-grid-scroll-rail')));
    scroll.jumpTo(0);
    await tester.pump();
    await tester.dragFrom(Offset(rail.center.dx, rail.top + 60), Offset(0, rail.height));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(scroll.position.maxScrollExtent, 1));
    expect(host.currentState!.placed, isEmpty, reason: 'scrolling adds no note');
  });
}
