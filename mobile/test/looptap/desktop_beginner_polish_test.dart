// ui-001 stage 5 (docs/specs/ui/ui-001-desktop-b2-layout.md "5단계 — 초보자를
// 위한 다듬기"), desktop piano roll:
//
// - The key on the lane (PitchKeyHighlight; the phone has none).
// - "키 안의 음만" (LoopPrefs.gridInKeyOnly, default on, saved): D dorian
//   shows D E F G A B C; a pitch that already holds a note stays (and is
//   counted "키 밖 음 N개"); drawn notes land in the key (the Scale snap
//   rule); no note data changes; the selection and the viewport's centre
//   pitch survive the toggle.
// - The primary "허밍으로 넣기" and Ctrl/Cmd+Shift+H (active track; not
//   while typing, in a dialog, recording or on a vocal track; a focused grid
//   with notes keeps it for humanize).
// - The velocity lane: folded by default on the desktop (24 px row), a saved
//   choice kept, the quiet-Solo "강약 보기" unfolds it; 1280x720 folded
//   pitch-grid-viewport >= 500; the phone unchanged.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/shortcut_help.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart' show tapGridButton;

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

PitchNote _n(int midi, int step, {int dur = 2, int velocity = 100}) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur, velocity: velocity);

Finder _humModal() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_HumModal');

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_beginner_');
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

  /// Opens the editor in D dorian; Ahem overflow reports are filtered and the
  /// filter is restored in `finally` by [editorTest].
  Future<Song> open(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    bool desktop = true,
    List<PitchNote>? melody,
    String key = 'D',
    String scale = 'dorian',
  }) async {
    useOfflineTestFonts();
    EditScreen.debugDesktopOverride = desktop;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sec = Section(id: 'A', name: 'A', bars: 2)
      ..tracks['melody'] = TrackData(notes: melody ?? [_n(62, 0), _n(66, 8), _n(69, 16, dur: 4)]);
    final song = Song(id: 'polish', title: 'Polish', bpm: 120, bars: 2, key: key, scale: scale, sections: [sec]);
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: _Store(),
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: EditScreen(song: song),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return song;
  }

  void editorTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
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
    if (find.byType(StepGrid).evaluate().isNotEmpty) return;
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
  Set<int> rows(WidgetTester tester) => {for (final r in grid(tester).ladder) r.midi};

  /// Screen point of [step] on [midi]'s row (through the grid's own rows).
  Future<Offset> at(WidgetTester tester, double step, int midi) async {
    final ladder = grid(tester).ladder.reversed.toList();
    final row = ladder.indexWhere((r) => r.midi == midi);
    expect(row, isNonNegative, reason: 'row $midi shown');
    final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('pitch-grid-viewport'))).controller!;
    var lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final vp = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
    final rowH = lane.height / ladder.length;
    scroll.jumpTo(((row + .5) * rowH - vp.height / 2).clamp(0.0, scroll.position.maxScrollExtent).toDouble());
    await tester.pump();
    lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final v = tester.widget<PitchGridSurface>(find.byType(PitchGridSurface)).view!.view;
    return Offset(lane.left + (step - v.start) / v.length * lane.width, lane.top + (row + .5) * rowH);
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool ctrl = false, bool shift = false}) async {
    if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  Future<void> closeHum(WidgetTester tester) async {
    Navigator.of(tester.element(_humModal())).pop();
    await tester.pumpAndSettle();
  }

  group('the key in the piano roll', () {
    editorTest('D dorian: rows D E F G A B C, the F# note row kept and counted; the key on the lane', (tester) async {
      await open(tester);
      await melodyGrid(tester);
      expect(LoopPrefs.instance.gridInKeyOnly.value, isTrue, reason: 'default on');
      final shown = rows(tester);
      const dorian = {2, 4, 5, 7, 9, 11, 0};
      expect(shown.where((m) => !dorian.contains(m % 12)), [66], reason: 'only the row with the F# note');
      expect(shown.where((m) => dorian.contains(m % 12)).length, 75, reason: 'every in-key pitch 0..127');
      expect(find.text('1 note out of key'), findsOneWidget);
      final key = grid(tester).keyHighlight!;
      expect(key.root, 2);
      expect(key.pitchClasses, dorian);
      expect(tester.widget<PitchGridSurface>(find.byType(PitchGridSurface)).keyHighlight, key);
      // off: every row; the notes are the same objects / data
      final before = [for (final n in grid(tester).notes) n.toJson()];
      await tester.tap(find.byKey(const ValueKey('grid-in-key-only')));
      await tester.pumpAndSettle();
      expect(rows(tester), hasLength(128));
      expect(find.byKey(const ValueKey('grid-out-of-key-count')), findsNothing);
      expect([for (final n in grid(tester).notes) n.toJson()], before);
    });

    editorTest('drawing: an out-of-key row snaps into the key; an in-key row keeps its pitch; nothing else changes', (tester) async {
      await open(tester);
      await melodyGrid(tester);
      final before = [for (final n in grid(tester).notes) n.toJson()];
      await tester.tapAt(await at(tester, 24.5, 66)); // the kept F# row, empty step
      await tester.pumpAndSettle();
      final added = grid(tester).notes.where((n) => n.startSteps == 24).toList();
      expect(added, hasLength(1));
      expect(added.single.midi, 65, reason: 'F# -> F (ties go down, the Scale snap rule)');
      await tester.tapAt(await at(tester, 28.5, 71)); // B, in the key
      await tester.pumpAndSettle();
      expect(grid(tester).notes.where((n) => n.startSteps == 28).single.midi, 71);
      final kept = [for (final n in grid(tester).notes) if (n.startSteps < 24) n.toJson()];
      expect(kept, before, reason: 'existing notes untouched (the F# stays F#)');
    });

    editorTest('the toggle keeps the selection and the pitch at the viewport centre', (tester) async {
      await open(tester, melody: [_n(62, 0), _n(66, 8), _n(74, 16)]);
      await melodyGrid(tester);
      await tapGridButton(tester, 'note-select');
      await tester.tapAt(await at(tester, 16.5, 74));
      await tester.pumpAndSettle();
      expect(find.text('1 note selected'), findsOneWidget);
      double centreMidi() {
        final ladder = grid(tester).ladder.reversed.toList();
        final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('pitch-grid-viewport'))).controller!;
        final rowH = (scroll.position.maxScrollExtent + scroll.position.viewportDimension) / ladder.length;
        final row = ((scroll.offset + scroll.position.viewportDimension / 2) / rowH).floor().clamp(0, ladder.length - 1);
        return ladder[row].midi.toDouble();
      }

      final centre = centreMidi();
      await tester.tap(find.byKey(const ValueKey('grid-in-key-only')));
      await tester.pumpAndSettle();
      expect(centreMidi(), closeTo(centre, 2), reason: 'the same pitch stays in the middle');
      expect(find.text('1 note selected'), findsOneWidget, reason: 'selection kept');
      await tester.tap(find.byKey(const ValueKey('grid-in-key-only')));
      await tester.pumpAndSettle();
      expect(centreMidi(), closeTo(centre, 2));
      expect(find.text('1 note selected'), findsOneWidget);
    });

    editorTest('a key change re-filters the rows; a chromatic song shows them all', (tester) async {
      await open(tester, key: 'C', scale: 'major', melody: [_n(60, 0)]);
      await melodyGrid(tester);
      expect(rows(tester).every((m) => const {0, 2, 4, 5, 7, 9, 11}.contains(m % 12)), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await open(tester, scale: 'chromatic', melody: [_n(60, 0)]);
      await melodyGrid(tester);
      expect(rows(tester), hasLength(128));
      expect(grid(tester).keyHighlight, isNull);
      expect(find.byKey(const ValueKey('grid-in-key-only')), findsNothing);
    });

    editorTest('phone: no key colours, no filter, the old toggle row', (tester) async {
      await open(tester, size: const Size(390, 844), desktop: false);
      tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
      await tester.pumpAndSettle();
      await toGrid(tester);
      expect(grid(tester).keyHighlight, isNull);
      expect(rows(tester), hasLength(128));
      expect(grid(tester).velocityLaneFold, isFalse);
      expect(find.byKey(const ValueKey('velocity-lane-fold')), findsNothing);
      expect(find.byKey(const ValueKey('velocity-lane')), findsOneWidget, reason: 'phone default: lane on');
    });
  });

  group('preferences', () {
    late Directory prefsRoot;
    setUp(() async {
      prefsRoot = await Directory.systemTemp.createTemp('humtrack_beginner_prefs_');
      LoopPrefs.rootOverride = prefsRoot;
    });
    tearDown(() async {
      LoopPrefs.rootOverride = null;
      LoopPrefs.instance.debugAllowReload();
      LoopPrefs.instance.resetGridLayout();
      await prefsRoot.delete(recursive: true);
    });

    File file() => File('${prefsRoot.path}/looptap/prefs.json');
    Future<Map> saved() async => jsonDecode(await file().readAsString()) as Map;
    Future<void> restart(Map<String, Object?>? json) async {
      if (json != null) {
        await file().parent.create(recursive: true);
        await file().writeAsString(jsonEncode(json));
      }
      LoopPrefs.instance.resetGridLayout();
      LoopPrefs.instance.debugAllowReload();
      await LoopPrefs.instance.bootstrap();
    }

    test('gridInKeyOnly: default on, saved, back after a restart', () async {
      await LoopPrefs.instance.setGridInKeyOnly(false);
      expect((await saved())['gridInKeyOnly'], isFalse);
      await restart(null);
      expect(LoopPrefs.instance.gridInKeyOnly.value, isFalse);
    });

    test('velocity lane: an untouched install stays unchosen; a saved value (old file or a toggle) is kept', () async {
      await LoopPrefs.instance.setMetro(false); // some other setting saved
      expect((await saved()).containsKey('gridVelocityLane'), isFalse);
      await restart(null);
      expect(LoopPrefs.instance.gridVelocityLaneChosen.value, isFalse, reason: 'desktop starts folded');
      // an older prefs file that already holds the lane value: the user's
      await restart({'gridVelocityLane': true});
      expect(LoopPrefs.instance.gridVelocityLaneChosen.value, isTrue);
      expect(LoopPrefs.instance.gridVelocityLane.value, isTrue);
      await restart({'gridVelocityLane': false});
      expect(LoopPrefs.instance.gridVelocityLane.value, isFalse);
      // a toggle is a choice and is saved
      await LoopPrefs.instance.setGridLayout(velocityLane: true);
      expect((await saved())['gridVelocityLane'], isTrue);
    });
  });

  group('velocity lane (desktop folded by default)', () {
    editorTest('folded 24 px row; unfold / fold; 1280x720 folded roll >= 500; no undo step', (tester) async {
      await open(tester);
      await melodyGrid(tester);
      expect(find.byKey(const ValueKey('velocity-lane')), findsNothing);
      final fold = tester.getRect(find.byKey(const ValueKey('velocity-lane-fold')));
      expect(fold.height, 24);
      expect(find.text('Velocity · chance'), findsOneWidget);
      final vp = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
      debugPrint('[stage5-measure] 1280x720 folded pitch-grid-viewport height=${vp.height}');
      expect(vp.height, greaterThanOrEqualTo(500));
      final canUndo = tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).canUndo;
      await tester.tap(find.byKey(const ValueKey('velocity-lane-fold')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('velocity-lane')), findsOneWidget);
      expect(LoopPrefs.instance.gridVelocityLaneChosen.value, isTrue);
      expect(LoopPrefs.instance.gridVelocityLane.value, isTrue);
      await tester.tap(find.byKey(const ValueKey('velocity-lane-fold')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('velocity-lane')), findsNothing);
      expect(LoopPrefs.instance.gridVelocityLane.value, isFalse);
      expect(tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).canUndo, canUndo, reason: 'a view setting, not an edit');
      // the old tool-row toggle moved into this row
      expect(find.byKey(const ValueKey('note-velocity-toggle')), findsNothing);
    });

    editorTest('a saved "open" choice opens it on the desktop', (tester) async {
      LoopPrefs.instance.gridVelocityLaneChosen.value = true;
      LoopPrefs.instance.gridVelocityLane.value = true;
      await open(tester);
      await melodyGrid(tester);
      expect(find.byKey(const ValueKey('velocity-lane')), findsOneWidget);
    });

    editorTest('quiet Solo "강약 보기" opens the track and unfolds the lane', (tester) async {
      await open(tester, melody: [_n(62, 0, velocity: 3)]);
      await showArrange(tester);
      tester.widget<Arrangement>(find.byType(Arrangement)).onToggleSolo!('melody');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('solo-status-notice')));
      await tester.pumpAndSettle();
      expect(find.byType(StepGrid), findsOneWidget);
      expect(find.byKey(const ValueKey('velocity-lane')), findsOneWidget);
    });
  });

  group('humming: the primary button and Ctrl/Cmd+Shift+H', () {
    editorTest('button and shortcut open humming for the active track; never while typing, in a dialog, recording or on a vocal track', (tester) async {
      await open(tester);
      await melodyGrid(tester);
      final hum = tester.getRect(find.byKey(const ValueKey('desktop-hum')));
      expect(hum.height, 30);
      expect(find.descendant(of: find.byKey(const ValueKey('desktop-hum')), matching: find.text('Add by humming')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('desktop-hum')));
      await tester.pumpAndSettle();
      expect(_humModal(), findsOneWidget);
      expect((tester.widget(_humModal()) as dynamic).trackLabel, 'Melody');
      await closeHum(tester);
      // the shortcut from the editor commands
      FocusManager.instance.primaryFocus?.unfocus();
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).focusNode!.requestFocus();
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyH, ctrl: true, shift: true);
      expect(_humModal(), findsOneWidget);
      // inside the modal: no second one
      await press(tester, LogicalKeyboardKey.keyH, ctrl: true, shift: true);
      expect(_humModal(), findsOneWidget);
      await closeHum(tester);
      // typing in the title
      await tester.tap(find.byKey(const ValueKey('top-title')));
      await tester.pump();
      await press(tester, LogicalKeyboardKey.keyH, ctrl: true, shift: true);
      expect(_humModal(), findsNothing);
      FocusManager.instance.primaryFocus?.unfocus();
      // recording
      if (tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).countIn) {
        await tester.tap(find.byKey(const ValueKey('top-count-in')));
        await tester.pumpAndSettle();
      }
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).focusNode!.requestFocus();
      await tester.tap(find.byKey(const ValueKey('top-record')));
      await tester.pump();
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).hum!();
      await tester.pump();
      expect(_humModal(), findsNothing);
      await tester.tap(find.byKey(const ValueKey('top-stop')));
      await tester.pump(const Duration(milliseconds: 300));
      // a vocal track
      await editTrack(tester, 'vocal');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-hum')), findsNothing);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).hum!();
      await tester.pumpAndSettle();
      expect(_humModal(), findsNothing);
    });

    editorTest('a focused grid with notes keeps Ctrl/Cmd+Shift+H for humanize', (tester) async {
      await open(tester, melody: [_n(62, 1), _n(65, 9)]);
      await melodyGrid(tester);
      await tapGridButton(tester, 'note-select');
      await tester.tapAt(await at(tester, 1.5, 62));
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'MIDI note editor');
      await press(tester, LogicalKeyboardKey.keyH, ctrl: true, shift: true);
      expect(_humModal(), findsNothing, reason: 'the grid humanized instead');
    });

    test('the catalogue: Ctrl+Shift+H registered (help / tooltips read it)', () {
      final s = kDesktopShortcutsFor(DesktopShortcutId.hum);
      expect(s.single.keysLabel(mac: false), 'Ctrl+Shift+H');
    });
  });
}

/// The registered shortcuts of [id].
List<DesktopShortcut> kDesktopShortcutsFor(DesktopShortcutId id) => [
  for (final s in kDesktopShortcuts)
    if (s.id == id) s,
];
