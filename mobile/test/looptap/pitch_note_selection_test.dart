import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/pitch_clipboard.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import '../support/offline_fonts.dart';
import 'package:humming/looptap/theme/tokens.dart';

const _previewPath = String.fromEnvironment('NOTE_EDITOR_PREVIEW');

PitchNote note(
  int step, {
  int midi = 60,
  double offset = .25,
  double duration = 1.5,
  int velocity = 47,
  bool locked = false,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: duration.ceil(),
  offsetSteps: offset,
  durationSteps: duration,
  velocity: velocity,
  sourceMidi: midi - 1,
  confidence: .72,
  assisted: true,
  locked: locked,
);

void main() {
  test(
    'group move clamps together and preserves micro-offsets, gates and metadata',
    () {
      final a = note(1),
          b = note(4, midi: 67, offset: .6),
          locked = note(2, locked: true);
      final notes = [a, b, locked];
      final moved = movePitchNotes(
        notes,
        notes.toSet(),
        deltaSteps: 1,
        semitones: 12,
        steps: 8,
      );
      expect(moved[0].offsetSteps, a.offsetSteps);
      expect(moved[1].offsetSteps, b.offsetSteps);
      expect(moved[0].durationSteps, a.durationSteps);
      expect(moved[0].velocity, 47);
      expect(moved[0].sourceMidi, 59);
      expect(moved[0].confidence, .72);
      expect(moved[0].assisted, isTrue);
      expect(moved[0].midi, 72);
      expect(moved[0].freq, closeTo(midiToFreq(72), 1e-10));
      expect(moved[2], same(locked));
      final bounded = movePitchNotes(
        notes,
        {a, b},
        deltaSteps: -100,
        semitones: 100,
        steps: 8,
      );
      expect(bounded[0].startSteps, 0);
      expect(
        bounded[1].startSteps - bounded[0].startSteps,
        closeTo(b.startSteps - a.startSteps, 1e-10),
      );
      expect(bounded[1].midi, 127);
      expect(bounded[1].midi - bounded[0].midi, 7);
      final free = movePitchNotes(
        notes,
        {a},
        deltaSteps: .125,
        semitones: 0,
        steps: 8,
      );
      expect(free[0].startSteps, 1.375);
      expect(free[0].durationSteps, a.durationSteps);
      expect(free[1], same(b));
    },
  );

  test(
    'resize keeps starts, clamps gates/loop end and leaves collisions separate',
    () {
      final a = note(1), b = note(4), locked = note(0, locked: true);
      final notes = [a, b, locked];
      final longer = resizePitchNotes(
        notes,
        notes.toSet(),
        deltaSteps: 100,
        steps: 8,
      );
      expect(longer[1].endSteps, 8);
      expect(longer[0].startSteps, a.startSteps);
      expect(longer[1].offsetSteps, b.offsetSteps);
      expect(longer[0].velocity, 47);
      expect(longer[2], same(locked));
      final shorter = resizePitchNotes(
        notes,
        {a, b},
        deltaSteps: -100,
        steps: 8,
      );
      expect(shorter[0].soundingSteps, closeTo(1 / 16, 1e-10));
      expect(shorter[1].soundingSteps, closeTo(1 / 16, 1e-10));
      final overlap = movePitchNotes(
        notes,
        {a},
        deltaSteps: 3,
        semitones: 0,
        steps: 8,
      );
      expect(overlap, hasLength(3));
      expect(overlap[1], same(b));
      expect(overlap[0].startSteps, b.startSteps);
    },
  );

  test(
    'velocity, duplicate and delete preserve locked and unrelated notes',
    () {
      final a = note(0, duration: .5), locked = note(1, locked: true);
      final notes = [a, locked];
      final loud = setPitchVelocity(notes, notes.toSet(), 500);
      expect(loud[0].velocity, 127);
      expect(loud[0].offsetSteps, .25);
      expect(loud[0].durationSteps, .5);
      expect(loud[1], same(locked));
      final copied = duplicatePitchNotes(notes, notes.toSet(), 8);
      expect(copied, hasLength(3));
      expect(copied.last.startSteps, 1.25);
      expect(copied.last.durationSteps, .5);
      expect(copied.last.velocity, 47);
      expect(copied.last.sourceMidi, 59);
      expect(copied[0], same(a));
      expect(deletePitchNotes(notes, notes.toSet()), [locked]);
      final edge = [note(7, duration: .5)];
      expect(duplicatePitchNotes(edge, edge.toSet(), 8), same(edge));
      expect(
        movePitchNotes(notes, {locked}, deltaSteps: 1, semitones: 1, steps: 8),
        same(notes),
      );
    },
  );

  Future<GlobalKey<_HarnessState>> mount(
    WidgetTester tester,
    List<PitchNote> notes, {
    double width = 720,
    double height = 340,
    bool enabled = true,
    PitchClipboard? clipboard,
  }) async {
    useOfflineTestFonts();
    if (_previewPath.isNotEmpty &&
        File('C:/Windows/Fonts/segoeui.ttf').existsSync()) {
      final bytes = File('C:/Windows/Fonts/segoeui.ttf').readAsBytesSync();
      final families = {
        'NotePreview',
        LTType.mono().fontFamily!,
        LTType.mono(weight: FontWeight.w700).fontFamily!,
      };
      await tester.runAsync(() async {
        for (final family in families) {
          await (FontLoader(family)
            ..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      });
    }
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          brightness: Brightness.dark,
          fontFamily: _previewPath.isEmpty ? null : 'NotePreview',
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: const ValueKey('note-editor-preview'),
            child: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: _Harness(
                  key: key,
                  notes: notes,
                  enabled: enabled,
                  clipboard: clipboard,
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

  Offset point(WidgetTester tester, double time, int midi) {
    final rect = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    return Offset(
      rect.left + rect.width * time / 8,
      rect.top + rect.height * (64 - midi + .5) / 5,
    );
  }

  testWidgets('body drag and end handle preview first, then each commit once', (
    tester,
  ) async {
    final original = note(1);
    final key = await mount(tester, [original]);
    final gesture = await tester.startGesture(point(tester, 1.7, 60));
    await tester.pump();
    await gesture.moveTo(point(tester, 3.7, 60));
    await tester.pump();
    expect(key.currentState!.commits, 0);
    expect(key.currentState!.notes.single, same(original));
    expect(
      tester
          .widget<PitchGridSurface>(find.byType(PitchGridSurface))
          .notes
          .single
          .startSteps,
      3.25,
    );
    await gesture.up();
    await tester.pump();
    expect(key.currentState!.commits, 1);
    expect(key.currentState!.notes.single.startSteps, 3.25);
    expect(key.currentState!.notes.single.velocity, 47);
    expect(key.currentState!.notes.single.durationSteps, 1.5);
    final resize = await tester.startGesture(point(tester, 4.72, 60));
    await tester.pump();
    await resize.moveTo(point(tester, 5.72, 60));
    await tester.pump();
    expect(key.currentState!.commits, 1);
    await resize.up();
    await tester.pump();
    expect(key.currentState!.commits, 2);
    expect(key.currentState!.notes.single.startSteps, 3.25);
    expect(key.currentState!.notes.single.endSteps, 5.75);
    expect(key.currentState!.erases, 0);
    expect(key.currentState!.places, 0);
  });

  testWidgets('cancelled and externally invalidated drags never commit', (
    tester,
  ) async {
    final original = note(1);
    final key = await mount(tester, [original]);
    var gesture = await tester.startGesture(point(tester, 1.7, 60));
    await tester.pump();
    await gesture.moveTo(point(tester, 3.7, 60));
    await tester.pump();
    await gesture.cancel();
    await tester.pump();
    expect(key.currentState!.commits, 0);
    expect(key.currentState!.notes.single, same(original));
    gesture = await tester.startGesture(point(tester, 1.7, 60));
    await tester.pump();
    await gesture.moveTo(point(tester, 3.7, 60));
    await tester.pump();
    final restored = note(2, velocity: 101);
    key.currentState!.replace([restored]);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(key.currentState!.commits, 0);
    expect(key.currentState!.notes.single, same(restored));
  });

  testWidgets(
    'multi selection supports keyboard duplicate/delete without drawing',
    (tester) async {
      final a = note(1, duration: .5), b = note(3, midi: 64, duration: .5);
      final key = await mount(tester, [a, b]);
      await tester.tap(find.byKey(const ValueKey('note-multiple')));
      await tester.pump();
      await tester.tapAt(point(tester, 1.4, 60));
      await tester.pump();
      await tester.tapAt(point(tester, 3.4, 64));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(key.currentState!.notes, hasLength(4));
      expect(key.currentState!.notes[2].startSteps, 4.25);
      expect(key.currentState!.notes[3].startSteps, 6.25);
      if (_previewPath.isNotEmpty) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('note-editor-preview')),
        );
        await tester.runAsync(() async {
          final rendered = await boundary.toImage(pixelRatio: 1);
          final bytes = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(_previewPath);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          rendered.dispose();
        });
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(key.currentState!.notes, [a, b]);
      expect(key.currentState!.commits, 2);
      expect(key.currentState!.erases, 0);
      expect(key.currentState!.places, 0);
    },
  );

  Future<void> command(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets(
    'area tool starts on notes, copies and pastes at a clicked cell',
    (tester) async {
      final key = await mount(tester, [
        note(1, midi: 64, duration: .5),
        note(3, duration: .5),
      ]);
      await tester.tap(find.byKey(const ValueKey('note-area')));
      await tester.pump();
      final area = await tester.startGesture(point(tester, 1.3, 64));
      await area.moveTo(point(tester, 4.2, 60));
      await tester.pump();
      await area.up();
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      expect(key.currentState!.commits, 0);
      await command(tester, LogicalKeyboardKey.keyC);
      await tester.tapAt(point(tester, 5.1, 64));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyV);
      expect(key.currentState!.notes, hasLength(4));
      expect(key.currentState!.notes.skip(2).map((n) => n.startSteps), [
        5.25,
        7.25,
      ]);
      expect(key.currentState!.notes.skip(2).map((n) => n.velocity), [47, 47]);
      expect(key.currentState!.notes.last.sourceMidi, 59);
      expect(key.currentState!.commits, 1);
      expect(key.currentState!.erases, 0);
      expect(key.currentState!.places, 0);
    },
  );

  testWidgets(
    'clipboard crosses tracks, rejects overflow and respects read only',
    (tester) async {
      final clipboard = PitchClipboard();
      addTearDown(clipboard.dispose);
      var key = await mount(tester, [note(1)], clipboard: clipboard);
      await tester.tapAt(point(tester, 1.7, 60));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyC);
      key = await mount(tester, [], clipboard: clipboard);
      await tester.tapAt(point(tester, 7.1, 60));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyV);
      expect(key.currentState!.notes, isEmpty);
      expect(key.currentState!.commits, 0);
      await tester.tapAt(point(tester, 2.1, 60));
      await tester.pump();
      await command(tester, LogicalKeyboardKey.keyV);
      expect(key.currentState!.notes.single.startSteps, 2.25);
      expect(key.currentState!.notes.single.durationSteps, 1.5);
      expect(key.currentState!.commits, 1);
      key = await mount(tester, [], clipboard: clipboard, enabled: false);
      await command(tester, LogicalKeyboardKey.keyV);
      expect(key.currentState!.commits, 0);
    },
  );

  testWidgets('drawing on an existing note auditions instead of erasing', (
    tester,
  ) async {
    final key = await mount(tester, [note(1)]);
    await tester.tap(find.byKey(const ValueKey('note-draw')));
    await tester.pump();
    await tester.tapAt(point(tester, 1.7, 60));
    await tester.pump();
    expect(key.currentState!.previews, 1);
    expect(key.currentState!.erases, 0);
    expect(key.currentState!.places, 0);
    await tester.tapAt(point(tester, 4.2, 60));
    await tester.pump();
    expect(key.currentState!.places, 1);
  });

  testWidgets('velocity slider commits once and keeps timing metadata', (
    tester,
  ) async {
    final key = await mount(tester, [note(1)]);
    await tester.tapAt(point(tester, 1.7, 60));
    await tester.pump();
    final slider = find.byKey(const ValueKey('note-velocity'));
    await tester.ensureVisible(slider);
    await tester.pumpAndSettle();
    final rect = tester.getRect(slider);
    final drag = await tester.startGesture(rect.center);
    await tester.pump();
    await drag.moveTo(Offset(rect.right - 20, rect.center.dy));
    await tester.pump();
    expect(key.currentState!.commits, 0);
    await drag.up();
    await tester.pump();
    expect(key.currentState!.commits, 1);
    final edited = key.currentState!.notes.single;
    expect(edited.velocity, greaterThan(47));
    expect(edited.offsetSteps, .25);
    expect(edited.durationSteps, 1.5);
    expect(edited.sourceMidi, 59);
    expect(edited.assisted, isTrue);
  });

  testWidgets('free movement and draw mode remain separate on small layouts', (
    tester,
  ) async {
    final key = await mount(tester, [note(1)], width: 340, height: 220);
    // The velocity lane shares the compact workspace. Scroll the pitch rows
    // to the low note before grabbing it, as a user would on this small view.
    final pitchScroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(PitchGridSurface),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    pitchScroll.controller!.jumpTo(
      pitchScroll.controller!.position.maxScrollExtent,
    );
    await tester.pump();

    await tester.ensureVisible(find.byKey(const ValueKey('note-snap')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note-snap')));
    await tester.pump();
    final drag = await tester.startGesture(point(tester, 1.7, 60));
    await tester.pump();
    await drag.moveTo(point(tester, 2.075, 60));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(key.currentState!.notes.single.startSteps, closeTo(1.625, 1e-8));
    await tester.ensureVisible(find.byKey(const ValueKey('note-erase')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('note-erase')));
    await tester.pump();
    await tester.tapAt(point(tester, 2, 60));
    await tester.pumpAndSettle();
    expect(key.currentState!.erases, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'marquee selects a chord and octave shortcuts retain its intervals',
    (tester) async {
      final key = await mount(tester, [
        note(1, duration: .5),
        note(2, midi: 64, duration: .5),
      ]);
      final box = await tester.startGesture(point(tester, .4, 64));
      await tester.pump();
      await box.moveTo(point(tester, 3, 60));
      await tester.pump();
      await box.up();
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      expect(key.currentState!.commits, 0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(key.currentState!.notes.map((n) => n.midi), [72, 76]);
      expect(key.currentState!.notes.map((n) => n.velocity), [47, 47]);
      expect(key.currentState!.notes.map((n) => n.offsetSteps), [.25, .25]);
      expect(key.currentState!.commits, 1);
    },
  );

  testWidgets(
    'dense pitch ranges keep usable rows and scroll without editing',
    (tester) async {
      useOfflineTestFonts();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 210,
              child: StepGrid(
                ladder: [
                  for (var m = 30; m <= 90; m++)
                    Rung(
                      midi: m,
                      name: '$m',
                      freq: midiToFreq(m),
                      degree: 0,
                      index: m - 30,
                    ),
                ],
                notes: [note(1)],
                onPlace: (_, _, _) {},
                onErase: (_, _) {},
                onEdit: (_, _) => true,
                initialEditMode: true,
                playStep: 0,
                accent: Colors.green,
                steps: 8,
                bars: 1,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final lane = tester.getRect(
        find.byKey(const ValueKey('pitch-grid-lane')),
      );
      expect(lane.height / 61, greaterThanOrEqualTo(24));
      final vertical = tester.widget<SingleChildScrollView>(
        find.descendant(
          of: find.byType(PitchGridSurface),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      expect(vertical.controller!.position.maxScrollExtent, greaterThan(1000));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read-only view and locked notes cannot be changed', (
    tester,
  ) async {
    final locked = note(1, locked: true);
    final key = await mount(tester, [locked]);
    await tester.tapAt(point(tester, 1.7, 60));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(key.currentState!.notes.single, same(locked));
    expect(key.currentState!.commits, 0);
    final unlock = find.byKey(const ValueKey('note-lock'));
    await tester.ensureVisible(unlock);
    await tester.pumpAndSettle();
    await tester.tap(unlock);
    await tester.pump();
    expect(key.currentState!.notes.single.locked, isFalse);
    expect(key.currentState!.notes.single.velocity, 47);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(key.currentState!.notes.single.startSteps, 2.25);
    await mount(tester, [note(1)], enabled: false);
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('note-draw')),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
  Offset velocityPoint(WidgetTester tester, PitchNote n) {
    final rect = tester.getRect(find.byKey(const ValueKey('velocity-lane')));
    return Offset(
      rect.left + n.startSteps / 8 * rect.width,
      rect.bottom - 4 - (n.velocity ?? 100) / 127 * (rect.height - 8),
    );
  }

  testWidgets(
    'velocity bars preview then commit one edit without changing timing or metadata',
    (tester) async {
      final original = note(1);
      final key = await mount(tester, [original]);
      final gesture = await tester.startGesture(
        velocityPoint(tester, original),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
      expect(key.currentState!.commits, 0);
      expect(key.currentState!.notes.single, same(original));
      await gesture.up();
      await tester.pump();
      expect(key.currentState!.commits, 1);
      final edited = key.currentState!.notes.single;
      final fields = edited.toJson()..remove('velocity');
      final before = original.toJson()..remove('velocity');
      expect(fields, before);
      expect(edited.velocity, greaterThan(47));
    },
  );

  testWidgets(
    'velocity bar tap, cancellation and external undo never normalize source notes',
    (tester) async {
      final original = note(1);
      final key = await mount(tester, [original]);
      await tester.tapAt(velocityPoint(tester, original));
      await tester.pump();
      expect(key.currentState!.commits, 0);
      var gesture = await tester.startGesture(velocityPoint(tester, original));
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
      await gesture.cancel();
      await tester.pump();
      expect(key.currentState!.notes.single, same(original));
      gesture = await tester.startGesture(velocityPoint(tester, original));
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
      final restored = note(2, velocity: 91);
      key.currentState!.replace([restored]);
      await tester.pump();
      await gesture.moveBy(const Offset(0, -12));
      await gesture.up();
      await tester.pump();
      expect(key.currentState!.commits, 0);
      expect(key.currentState!.notes.single, same(restored));
    },
  );

  testWidgets(
    'group velocity drag keeps differences and respects locked notes',
    (tester) async {
      final a = note(1, velocity: 30),
          b = note(1, midi: 64, velocity: 65),
          locked = note(5, locked: true);
      final key = await mount(tester, [a, b, locked]);
      await tester.ensureVisible(find.byKey(const ValueKey('note-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('note-select-all')));
      await tester.pump();
      final gesture = await tester.startGesture(velocityPoint(tester, b));
      await gesture.moveBy(const Offset(0, -8));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(key.currentState!.commits, 1);
      expect(
        key.currentState!.notes[1].velocity! -
            key.currentState!.notes[0].velocity!,
        35,
      );
      expect(key.currentState!.notes.last, same(locked));
      expect(key.currentState!.notes.first.offsetSteps, .25);
      expect(key.currentState!.notes.first.durationSteps, 1.5);
    },
  );

  testWidgets('locked and read-only velocity bars cannot change values', (
    tester,
  ) async {
    final original = note(1, locked: true);
    var key = await mount(tester, [original]);
    await tester.dragFrom(
      velocityPoint(tester, original),
      const Offset(0, -20),
    );
    await tester.pump();
    expect(key.currentState!.commits, 0);
    key = await mount(tester, [note(1)], enabled: false);
    await tester.dragFrom(
      velocityPoint(tester, key.currentState!.notes.single),
      const Offset(0, -20),
    );
    await tester.pump();
    expect(key.currentState!.commits, 0);
  });
}

class _Harness extends StatefulWidget {
  const _Harness({
    super.key,
    required this.notes,
    this.enabled = true,
    this.clipboard,
  });
  final PitchClipboard? clipboard;
  final List<PitchNote> notes;
  final bool enabled;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late List<PitchNote> notes = List.of(widget.notes);
  int commits = 0, erases = 0, places = 0, previews = 0;
  void replace(List<PitchNote> value) => setState(() => notes = value);
  @override
  Widget build(BuildContext context) => StepGrid(
    ladder: [
      for (var midi = 60; midi <= 64; midi++)
        Rung(
          midi: midi,
          name: '$midi',
          degree: midi - 60,
          index: midi - 60,
          freq: midiToFreq(midi),
        ),
    ],
    notes: notes,
    clipboard: widget.clipboard,
    onPreview: (_) => previews++,
    initialEditMode: true,
    enabled: widget.enabled,
    onPlace: (_, _, _) => places++,
    onErase: (_, _) => erases++,
    onEdit: (before, after) {
      commits++;
      setState(() => notes = after);
      return true;
    },
    playStep: 0,
    accent: Colors.lightGreen,
    steps: 8,
    bars: 1,
  );
}
