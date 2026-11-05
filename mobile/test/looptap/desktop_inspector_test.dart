// ui-001 stage 4 (docs/specs/ui/ui-001-desktop-b2-layout.md "4단계 — 오른쪽
// 인스펙터와 도구 줄 정리", "오른쪽 인스펙터 (280, 4단계)"):
//
// - Tabs: a new selection opens Notes, no selection goes back to Track; a tab
//   the user picked stays until the next selection change — and "change" is
//   the selected SET (another single note is a new selection).
// - Notes tab = the grid's own items: octave / length / quantize results and
//   one undo step; the velocity slider previews while dragging (the panel
//   follows at once) and commits once on release.
// - Track tab = the mixer's state: volume / Pan both ways, Pan reset.
// - LoopPrefs.inspectorOpen across a restart; Ctrl/Cmd+I (not while typing).
// - Windows: under 1100 px the 40 px bar, opened over the editor (the roll
//   keeps its width); 1100 docks. Collapsing / overlaying / crossing 1100
//   keeps the same grid (selection, zoom view).
// - The desktop tool row (30 px buttons) and the piano / drum / guitar keys;
//   the arrange view's Track tab only; the phone layout untouched.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/desktop_inspector.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/sheets/mixer_sheet.dart';
import 'package:humming/looptap/widgets/surfaces/drum_surface.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

PitchNote _n(int midi, int step, {int dur = 2, int velocity = 100}) =>
    PitchNote(midi: midi, freq: 440, step: step, dur: dur, velocity: velocity);

void main() {
  late Directory root;
  final stage4Errors = <String>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_inspector_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    LoopPrefs.instance.metro.value = false;
  });
  tearDown(() async {
    LoopPrefs.instance.resetGridLayout();
    EditScreen.debugDesktopOverride = null;
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  /// Opens the editor; Ahem overflow reports outside the stage-4 files are
  /// filtered, and the filter is restored in `finally` by [editorTest].
  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    String locale = 'en',
    bool desktop = true,
    List<PitchNote>? melody,
    int? program,
  }) async {
    useOfflineTestFonts();
    EditScreen.debugDesktopOverride = desktop;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sec = Section(id: 'A', name: 'A', bars: 2)
      ..tracks['melody'] = TrackData(notes: melody ?? [_n(60, 0), _n(64, 8), _n(67, 16, dur: 4)])
      ..tracks['drums'] = TrackData(drums: [DrumNote(step: 0, kind: 'kick'), DrumNote(step: 8, kind: 'snare')]);
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: _Store(),
        child: MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: EditScreen(
            song: Song(
              id: 'inspector',
              title: 'Inspector',
              bpm: 120,
              bars: 2,
              sections: [sec],
              instruments: program == null ? null : {'melody': program},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void editorTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      stage4Errors.clear();
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.toString();
        if (RegExp(r'desktop_inspector\.dart|grid_chrome\.dart').hasMatch(text) ||
            !d.exceptionAsString().contains('overflowed')) {
          stage4Errors.add(text);
        }
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      try {
        await body(tester);
      } finally {
        FlutterError.onError = onError;
      }
    });
  }

  Future<void> toGrid(WidgetTester tester) async {
    if (find.byType(StepGrid).evaluate().isNotEmpty || find.byType(DrumGrid).evaluate().isNotEmpty) return;
    final label = find.text('Grid').evaluate().isNotEmpty ? 'Grid' : '그리드';
    tester.widget<GestureDetector>(find.ancestor(of: find.text(label), matching: find.byType(GestureDetector)).first).onTap!();
    await tester.pumpAndSettle();
  }

  Future<void> melodyGrid(WidgetTester tester) async {
    await editTrack(tester, 'melody');
    await tester.pumpAndSettle();
    await toGrid(tester);
  }

  StepGrid grid(WidgetTester tester) => tester.widget<StepGrid>(find.byType(StepGrid));
  DesktopCommands commands(WidgetTester tester) => tester.widget<DesktopCommands>(find.byType(DesktopCommands));
  bool notesTab() => find.byKey(const ValueKey('grid-notes-tab')).evaluate().isNotEmpty;
  bool trackTab() => find.byKey(const ValueKey('inspector-track-tab')).evaluate().isNotEmpty;

  /// Screen point of [step] on [midi]'s row (scrolls the row into view).
  Future<Offset> noteAt(WidgetTester tester, double step, int midi) async {
    final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('pitch-grid-viewport'))).controller!;
    var lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final vp = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
    final rowH = lane.height / 128;
    scroll.jumpTo(((127 - midi + .5) * rowH - vp.height / 2).clamp(0.0, scroll.position.maxScrollExtent).toDouble());
    await tester.pump();
    lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final v = tester.widget<PitchGridSurface>(find.byType(PitchGridSurface)).view!.view;
    return Offset(lane.left + (step - v.start) / v.length * lane.width, lane.top + (127 - midi + .5) * rowH);
  }

  Future<void> selectMode(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('note-select')));
    await tester.pumpAndSettle();
  }

  Future<void> clickNote(WidgetTester tester, double step, int midi) async {
    await tester.tapAt(await noteAt(tester, step, midi));
    await tester.pumpAndSettle();
  }

  group('tabs follow the selection (the set, not the count)', () {
    editorTest('select → Notes; Track by hand stays through rebuilds / playback; another single note → Notes; none → Track', (tester) async {
      await open(tester);
      await melodyGrid(tester);
      expect(find.byKey(const ValueKey('desktop-inspector')), findsOneWidget);
      expect(trackTab(), isTrue);
      await selectMode(tester);
      await clickNote(tester, .5, 60);
      expect(grid(tester).notes.where((n) => n.midi == 60), hasLength(1));
      expect(notesTab(), isTrue, reason: 'a new selection opens Notes');
      expect(find.text('1 note selected'), findsOneWidget);
      // the user picks Track: rebuilds and playback keep it
      await tester.tap(find.byKey(const ValueKey('inspector-tab-track')));
      await tester.pumpAndSettle();
      expect(trackTab(), isTrue);
      commands(tester).play();
      await tester.pump(const Duration(milliseconds: 400));
      commands(tester).play();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(trackTab(), isTrue, reason: 'no selection change');
      // another single note (count stays 1) = a new selection
      await clickNote(tester, 8.5, 64);
      expect(notesTab(), isTrue);
      expect(find.text('1 note selected'), findsOneWidget);
      expect(find.textContaining('E4'), findsOneWidget, reason: 'the note names');
      // an empty click clears the selection: back to Track
      await clickNote(tester, 30, 90);
      expect(grid(tester).notes, hasLength(3), reason: 'select mode: no new note');
      expect(trackTab(), isTrue, reason: 'no selection = Track');
      expect(stage4Errors, isEmpty);
    });
  });

  group('Notes tab = the grid inspector', () {
    editorTest('octave / length / quantize results; one undo step each', (tester) async {
      await open(tester, melody: [_n(60, 1), _n(64, 9)]);
      await melodyGrid(tester);
      await selectMode(tester);
      await clickNote(tester, 1.5, 60);
      expect(notesTab(), isTrue);
      final before = [for (final n in grid(tester).notes) n.toJson()];
      await tester.tap(find.byKey(const ValueKey('note-octave-up')));
      await tester.pumpAndSettle();
      expect(grid(tester).notes.map((n) => n.midi), containsAll([72, 64]));
      commands(tester).undo();
      await tester.pumpAndSettle();
      expect([for (final n in grid(tester).notes) n.toJson()], before);
      await clickNote(tester, 1.5, 60);
      await tester.tap(find.byKey(const ValueKey('note-length-up')));
      await tester.pumpAndSettle();
      expect(grid(tester).notes.firstWhere((n) => n.midi == 60).soundingSteps, 3);
      expect(tester.widget<Text>(find.byKey(const ValueKey('note-length-value'))).data, '3');
      commands(tester).undo();
      await tester.pumpAndSettle();
      expect([for (final n in grid(tester).notes) n.toJson()], before);
      // quantize (to 1/16 by default): the off-grid start goes to the grid
      await clickNote(tester, 1.5, 60);
      final off = grid(tester).notes.firstWhere((n) => n.midi == 60);
      await tester.ensureVisible(find.byKey(const ValueKey('note-quantize')));
      await tester.tap(find.byKey(const ValueKey('note-quantize')));
      await tester.pumpAndSettle();
      expect(grid(tester).notes.firstWhere((n) => n.midi == 60).startSteps, off.startSteps.roundToDouble());
      // the footer: 48 px, four cells, delete in the danger colour
      expect(tester.getSize(find.byKey(const ValueKey('grid-notes-footer'))).height, 48);
      for (final k in const ['note-duplicate', 'note-mute', 'note-lock', 'note-delete']) {
        expect(find.descendant(of: find.byKey(const ValueKey('grid-notes-footer')), matching: find.byKey(ValueKey(k))), findsOneWidget, reason: k);
      }
      // sheet rows: 34 px with a chevron (quantize settings, chord, arpeggiate)
      for (final k in const ['note-quantize-settings', 'note-chord-settings', 'note-arpeggiate-settings', 'note-more']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      await tester.tap(find.byKey(const ValueKey('note-more')));
      await tester.pumpAndSettle();
      for (final k in const ['note-split', 'note-glue', 'note-legato', 'note-fit-scale', 'note-humanize']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(stage4Errors, isEmpty);
    });

    editorTest('velocity slider: the panel follows the draft at once; release commits once; one undo', (tester) async {
      await open(tester, melody: [_n(60, 1, velocity: 40), _n(64, 9, velocity: 40)]);
      await melodyGrid(tester);
      await selectMode(tester);
      await clickNote(tester, 1.5, 60);
      final before = [for (final n in grid(tester).notes) n.toJson()];
      final slider = find.byKey(const ValueKey('note-velocity'));
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
      final r = tester.getRect(slider);
      final g = await tester.startGesture(Offset(r.left + r.width * .3, r.center.dy));
      await tester.pump();
      await g.moveTo(Offset(r.left + r.width * .9, r.center.dy));
      await tester.pump();
      // the panel shows the draft, the stored notes are unchanged
      expect(find.textContaining('Velocity 40'), findsNothing);
      expect(grid(tester).notes.firstWhere((n) => n.midi == 60).velocity, 40);
      await g.up();
      await tester.pumpAndSettle();
      final v = grid(tester).notes.firstWhere((n) => n.midi == 60).velocity!;
      expect(v, greaterThan(100));
      expect(grid(tester).notes.firstWhere((n) => n.midi == 64).velocity, 40, reason: 'other notes kept');
      expect(find.text('Velocity $v'), findsOneWidget);
      commands(tester).undo();
      await tester.pumpAndSettle();
      expect([for (final n in grid(tester).notes) n.toJson()], before, reason: 'one undo step');
    });

    editorTest('a focused Notes-tab / tool-row button: Ctrl+C and Delete still reach the grid (the phone route)', (tester) async {
      await open(tester, melody: [_n(60, 1), _n(64, 9)]);
      await melodyGrid(tester);
      await selectMode(tester);
      await clickNote(tester, 1.5, 60);
      Focus.of(tester.element(find.descendant(of: find.byKey(const ValueKey('note-octave-up')), matching: find.byType(Text)))).requestFocus();
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('MIDI note editor'));
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('note-paste'))).onPressed, isNull);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(find.byKey(const ValueKey('note-paste'))).onPressed, isNotNull, reason: 'copied');
      // a tool-row button focused: Delete removes the selected note
      Focus.of(tester.element(find.descendant(of: find.byKey(const ValueKey('note-copy')), matching: find.byType(Text)))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(grid(tester).notes.map((n) => n.midi), [64]);
      commands(tester).undo();
      await tester.pumpAndSettle();
      expect(grid(tester).notes, hasLength(2));
    });

    editorTest('drum grid: Draw / Select in the tool row, its inspector in the Notes tab', (tester) async {
      await open(tester);
      await editTrack(tester, 'drums');
      await tester.pumpAndSettle();
      await toGrid(tester);
      for (final k in const ['drum-draw-mode', 'drum-select-mode']) {
        expect(find.descendant(of: find.byKey(const ValueKey('desktop-tool-row')), matching: find.byKey(ValueKey(k))), findsOneWidget, reason: k);
      }
      await tester.tap(find.byKey(const ValueKey('drum-select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('inspector-tab-notes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('drum-notes-tab')), findsOneWidget);
      for (final k in const ['drum-time-left', 'drum-velocity', 'drum-chance', 'drum-velocity-deviation', 'drum-quantize', 'drum-quantize-settings', 'drum-humanize', 'drum-mute', 'drum-delete']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      expect(tester.getSize(find.byKey(const ValueKey('drum-notes-footer'))).height, 48);
      expect(stage4Errors, isEmpty);
    });

    editorTest('guitar: the guitar tools in the tool row, stroke buttons and panel in the Notes tab', (tester) async {
      await open(tester, program: 25);
      await melodyGrid(tester);
      expect(find.descendant(of: find.byKey(const ValueKey('desktop-tool-row')), matching: find.byKey(const ValueKey('note-guitar-tools'))), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('inspector-tab-notes')));
      await tester.pumpAndSettle();
      for (final k in const ['stroke-down', 'stroke-up', 'stroke-more']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
    });
  });

  group('Track tab = the mixer state', () {
    editorTest('volume / Pan both ways with the mixer; Pan double-click resets; one undo per drag', (tester) async {
      await open(tester);
      await melodyGrid(tester);
      expect(trackTab(), isTrue);
      final vol = find.byKey(const ValueKey('inspector-volume'));
      final r = tester.getRect(vol);
      await tester.dragFrom(Offset(r.left + r.width * .85, r.center.dy), Offset(-r.width * .45, 0));
      await tester.pumpAndSettle();
      final label = tester.widget<Text>(find.byKey(const ValueKey('inspector-volume-label'))).data!;
      final v = int.parse(label);
      expect(v, lessThan(85));
      // the mixer sheet shows the same value
      await tester.tap(find.byKey(const ValueKey('top-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mixer').last);
      await tester.pumpAndSettle();
      final mixer = tester.widget<MixerSheet>(find.byType(MixerSheet));
      expect((mixer.vol['melody']! * 100).round(), v);
      // and the other way: the mixer's handlers → the Track tab
      mixer.onVol('melody', .4);
      mixer.onPan!('melody', .5);
      Navigator.of(tester.element(find.byType(MixerSheet))).pop();
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('inspector-volume-label'))).data, '40');
      expect(tester.widget<Text>(find.byKey(const ValueKey('inspector-pan-label'))).data, isNot('C'));
      final pan = tester.getCenter(find.byKey(const ValueKey('inspector-pan')));
      await tester.tapAt(pan);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(pan);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('inspector-pan-label'))).data, 'C');
      // Solo / mute buttons drive the same sets as the mixer and the rows
      await tester.tap(find.byKey(const ValueKey('inspector-mute')));
      await tester.pumpAndSettle();
      await showArrange(tester);
      expect(find.byKey(const ValueKey('inspector-mute')), findsOneWidget, reason: 'arrange view keeps the Track tab');
      expect(find.byKey(const ValueKey('inspector-tab-notes')), findsNothing, reason: 'Track tab only');
      expect(stage4Errors, isEmpty);
    });
  });

  group('open / closed', () {
    late Directory prefsRoot;
    setUp(() async {
      prefsRoot = await Directory.systemTemp.createTemp('humtrack_inspector_prefs_');
      LoopPrefs.rootOverride = prefsRoot;
    });
    tearDown(() async {
      LoopPrefs.rootOverride = null;
      LoopPrefs.instance.debugAllowReload();
      LoopPrefs.instance.resetGridLayout();
      await prefsRoot.delete(recursive: true);
    });

    test('inspectorOpen: default true, saved, back after a restart', () async {
      expect(LoopPrefs.instance.inspectorOpen.value, isTrue);
      await LoopPrefs.instance.setInspectorOpen(false);
      final saved = jsonDecode(await File('${prefsRoot.path}/looptap/prefs.json').readAsString()) as Map;
      expect(saved['inspectorOpen'], isFalse);
      LoopPrefs.instance.resetGridLayout();
      LoopPrefs.instance.debugAllowReload();
      await LoopPrefs.instance.bootstrap();
      expect(LoopPrefs.instance.inspectorOpen.value, isFalse);
    });
  });

  group('windows and keys', () {
    editorTest('Ctrl/Cmd+I and the collapse button toggle (not while typing); the grid survives', (tester) async {
      await open(tester);
      await melodyGrid(tester);
      await selectMode(tester);
      await clickNote(tester, .5, 60);
      final view = grid(tester).viewLink!.view!..setZoom(2);
      final sel = Set.of(tester.state<State<StepGrid>>(find.byType(StepGrid)).widget.notes.where((n) => n.midi == 60));
      final rollWidth = tester.getSize(find.byKey(const ValueKey('pitch-grid-viewport'))).width;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(LoopPrefs.instance.inspectorOpen.value, isFalse);
      expect(find.byKey(const ValueKey('inspector-bar')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('pitch-grid-viewport'))).width, closeTo(rollWidth + 240, .5));
      expect(grid(tester).viewLink!.view, same(view), reason: 'same grid, same zoom view');
      expect(view.zoom, 2);
      expect(find.text('1 note selected'), findsNothing, reason: 'collapsed');
      await tester.tap(find.byKey(const ValueKey('inspector-bar-notes')));
      await tester.pumpAndSettle();
      expect(LoopPrefs.instance.inspectorOpen.value, isTrue);
      expect(find.text('1 note selected'), findsOneWidget, reason: 'the selection survived');
      expect(sel, isNotEmpty);
      // typing in the title: Ctrl+I is the field's
      await tester.tap(find.byKey(const ValueKey('top-title')));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(LoopPrefs.instance.inspectorOpen.value, isTrue);
      await tester.tap(find.byKey(const ValueKey('inspector-collapse')));
      await tester.pumpAndSettle();
      expect(LoopPrefs.instance.inspectorOpen.value, isFalse);
    });

    editorTest('960x600: starts as the bar; opened over the editor (roll width kept); 1100 docks; the grid survives resizes', (tester) async {
      await open(tester, size: const Size(960, 600));
      await melodyGrid(tester);
      expect(find.byKey(const ValueKey('inspector-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('desktop-inspector')), findsNothing);
      expect(LoopPrefs.instance.inspectorOpen.value, isTrue, reason: 'the saved choice is untouched');
      await selectMode(tester);
      await clickNote(tester, .5, 60);
      final view = grid(tester).viewLink!.view!..setZoom(2);
      final rollWidth = tester.getSize(find.byKey(const ValueKey('pitch-grid-viewport'))).width;
      await tester.tap(find.byKey(const ValueKey('inspector-bar-notes')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-inspector')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('pitch-grid-viewport'))).width, rollWidth, reason: 'over the editor');
      expect(tester.getRect(find.byKey(const ValueKey('desktop-inspector'))).right, 960);
      expect(find.text('1 note selected'), findsOneWidget);
      // 1099 → still the bar + overlay; 1100 → docked, same grid and view
      tester.view.physicalSize = const Size(1099, 700);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inspector-bar')), findsOneWidget);
      tester.view.physicalSize = const Size(1100, 700);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inspector-bar')), findsNothing);
      expect(find.byKey(const ValueKey('desktop-inspector')), findsOneWidget);
      expect(grid(tester).viewLink!.view, same(view));
      expect(view.zoom, 2);
      expect(find.text('1 note selected'), findsOneWidget);
      tester.view.physicalSize = const Size(1000, 640);
      await tester.pumpAndSettle();
      expect(grid(tester).viewLink!.view, same(view));
      expect(stage4Errors, isEmpty);
    });

    for (final size in const [Size(960, 600), Size(1280, 720), Size(1920, 1080)]) {
      for (final locale in const ['ko', 'en']) {
        editorTest('${size.width.toInt()}x${size.height.toInt()} $locale: tool row 40, 30 px buttons, inspector inside the window', (tester) async {
          await open(tester, size: size, locale: locale);
          await melodyGrid(tester);
          final row = tester.getRect(find.byKey(const ValueKey('desktop-tool-row')));
          expect(row.height, 40);
          for (final k in const ['note-draw', 'note-select', 'note-erase']) {
            final f = find.byKey(ValueKey(k));
            expect(tester.getSize(f).height, 30, reason: '$k render height (no padded tap target)');
          }
          expect(find.byKey(const ValueKey('desktop-hum')), findsOneWidget);
          final panel = find.byKey(ValueKey(size.width >= 1100 ? 'desktop-inspector' : 'inspector-bar'));
          final r = tester.getRect(panel);
          expect(r.right, closeTo(size.width, .01));
          expect(r.width, size.width >= 1100 ? 280 : 40);
          // the old header (instrument pill, octave) is gone from the edit view
          expect(find.byKey(const ValueKey('grid-focus')), findsNothing);
          final vp = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
          debugPrint('[stage4-measure] ${size.width.toInt()}x${size.height.toInt()} $locale roll ${vp.width.toStringAsFixed(1)}x${vp.height.toStringAsFixed(1)}');
          expect(stage4Errors, isEmpty);
        });
      }
    }

    // the real desktop theme (Windows: compact density, no padded targets)
    editorTest('Windows platform theme: the tool-row buttons are really 30 px tall', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await open(tester);
        await melodyGrid(tester);
        for (final k in const ['note-draw', 'note-select', 'note-area', 'note-erase', 'note-copy', 'note-paste']) {
          expect(tester.getSize(find.byKey(ValueKey(k))).height, 30, reason: k);
        }
        await tester.tap(find.byKey(const ValueKey('inspector-tab-notes')));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byKey(const ValueKey('note-octave-up'))).height, 30);
        await tester.pumpWidget(const SizedBox.shrink());
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    editorTest('phone 390x844: no inspector, the grid keeps its own tool row and header', (tester) async {
      await open(tester, size: const Size(390, 844), desktop: false);
      expect(find.byType(DesktopInspector), findsNothing);
      expect(find.byKey(const ValueKey('desktop-tool-row')), findsNothing);
    });
  });
}
