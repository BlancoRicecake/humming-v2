// ui-001 stage 3 (docs/specs/ui/ui-001-desktop-b2-layout.md "3단계 — 편곡 보기
// ↔ 편집 보기"): the desktop arrange / edit views.
//
// - LoopPrefs.desktopView: default, persistence across a restart, the one-time
//   migration (old timelineCollapsed users) and invalid-value recovery.
// - Switching: the top-bar segment, Tab, Enter and a real double-click in the
//   arrange view, the minimap's track button; all locked while recording.
// - Keyboard focus: Tab from a focused piano roll, never while typing or with
//   a dialog open; Enter only when nothing more specific holds the focus.
// - The arrange view (64 px rows, add track, 40 px hint, kept zoom / scroll)
//   and the edit view (44 px minimap, no split / 편집 확대 / fold).
// - The minimap: song (global) steps vs the active section's local roll view,
//   seek into other sections and repeats, rectangle drag = roll pan (clamped
//   to the section), thin rows for many tracks.
// - PitchGridViewLink: the StepGrid owns the view; track / section / view
//   switches never leave a stale (disposed) view behind.
// - Acceptance heights, measured like grid_usability_test (real window size,
//   pitch-grid-viewport): 1280x720 >= 480, 960x600 >= 330, 1920x1080 >= 840,
//   and the phone layout unchanged.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/timeline_minimap.dart';
import 'package:provider/provider.dart';

import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

PitchNote _n(int midi, int step, {int dur = 2}) =>
    PitchNote(midi: midi, freq: 440, step: step, dur: dur);

/// A (2 bars x2) = 64, B (4 bars) = 64, C (1 bar x3) = 48: 176 song steps.
List<Section> _abc() => [
  Section(id: 'A', name: 'Verse', bars: 2, repeats: 2)
    ..tracks['melody'] = TrackData(notes: [_n(60, 0), _n(62, 16)]),
  Section(id: 'B', name: 'Chorus', bars: 4)
    ..tracks['melody'] = TrackData(notes: [_n(64, 0), _n(65, 32, dur: 8)]),
  Section(id: 'C', name: 'Bridge', bars: 1, repeats: 3)
    ..tracks['melody'] = TrackData(notes: [_n(67, 4)]),
];

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_view_modes_');
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

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    String locale = 'en',
    List<Section>? sections,
    bool desktop = true,
  }) async {
    useOfflineTestFonts();
    EditScreen.debugDesktopOverride = desktop;
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      // Ahem glyphs overflow unrelated fixed-width labels
      if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final secs = sections ?? [Section(id: 'A', name: 'A', bars: 2)..tracks['melody'] = TrackData(notes: [_n(60, 0)])];
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: _Store(),
        child: MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: EditScreen(song: Song(id: 'views', title: 'Views', bpm: 120, bars: secs.first.bars, sections: secs)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> toGrid(WidgetTester tester) async {
    if (find.byType(StepGrid).evaluate().isNotEmpty) return;
    final label = find.text('Grid').evaluate().isNotEmpty ? 'Grid' : '그리드';
    tester.widget<GestureDetector>(find.ancestor(of: find.text(label), matching: find.byType(GestureDetector)).first).onTap!();
    await tester.pumpAndSettle();
  }

  /// A mouse click with real event times (tester.tap sends time 0, which
  /// every double-click check would see as instant).
  var pointerId = 100;
  Future<void> click(WidgetTester tester, Offset at, int ms) async {
    final p = TestPointer(pointerId++, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(p.down(at, timeStamp: Duration(milliseconds: ms)));
    await tester.sendEventToBinding(p.up(timeStamp: Duration(milliseconds: ms + 40)));
  }

  bool arrangeShown() => find.byType(Arrangement).evaluate().isNotEmpty;
  String view() => LoopPrefs.instance.desktopView.value;
  TimelineMinimap minimap(WidgetTester tester) => tester.widget<TimelineMinimap>(find.byType(TimelineMinimap));
  PitchGridViewLink link(WidgetTester tester) => tester.widget<StepGrid>(find.byType(StepGrid)).viewLink!;
  String? focusLabel() => FocusManager.instance.primaryFocus?.debugLabel;

  group('desktopView preference', () {
    late Directory prefsRoot;
    setUp(() async {
      prefsRoot = await Directory.systemTemp.createTemp('humtrack_view_prefs_');
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

    test('default edit; a switch is saved and comes back after a restart', () async {
      expect(view(), LoopPrefs.kDesktopViewEdit);
      await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewArrange);
      expect((await saved())['desktopView'], 'arrange');
      await restart(null);
      expect(view(), 'arrange');
      await LoopPrefs.instance.setDesktopView('bogus'); // ignored
      expect(view(), 'arrange');
      await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
      await restart(null);
      expect(view(), 'edit');
    });

    test('older prefs without desktopView: once to edit (also a collapsed timeline), saved', () async {
      await restart({'timelineCollapsed': true, 'haptics': false});
      expect(view(), 'edit');
      final m = await saved();
      expect(m['desktopView'], 'edit', reason: 'migration written once');
      expect(m['timelineCollapsed'], isTrue, reason: 'the old value is left alone');
      expect(m['haptics'], isFalse, reason: 'other settings kept');
      // the user's next choice wins over the old collapsed flag afterwards
      await LoopPrefs.instance.setDesktopView('arrange');
      await restart(null);
      expect(view(), 'arrange');
    });

    test('a saved desktopView wins over timelineCollapsed; an invalid one is repaired', () async {
      await restart({'timelineCollapsed': true, 'desktopView': 'arrange'});
      expect(view(), 'arrange');
      await restart({'desktopView': 'sideways'});
      expect(view(), 'edit');
      expect((await saved())['desktopView'], 'edit');
      await restart({'desktopView': 7});
      expect(view(), 'edit');
      expect((await saved())['desktopView'], 'edit');
    });
  });

  group('switching views', () {
    testWidgets('segment, Tab, minimap button, Enter and a real double-click', (tester) async {
      await open(tester);
      expect(arrangeShown(), isFalse);
      expect(find.byKey(const ValueKey('timeline-minimap')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('view-arrange')));
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue);
      expect(view(), 'arrange');
      await tester.tap(find.byKey(const ValueKey('view-edit')));
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse);
      // Tab both ways
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse);
      // the minimap's track button opens the arrange view
      await tester.tap(find.byKey(const ValueKey('minimap-arrange')));
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue);
      // a click selects a row (still arrange); Enter edits it
      await tester.tap(find.byKey(const ValueKey('track-row-bass')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(arrangeShown(), isTrue);
      expect(tester.widget<Arrangement>(find.byType(Arrangement)).activeId, 'bass');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse);
      expect(tester.widget<Text>(find.byKey(const ValueKey('minimap-label'))).data, contains('Bass'));
      // a real double-click on another row = that track in the edit view
      await showArrange(tester);
      await tester.pumpAndSettle();
      final row = tester.getRect(find.byKey(const ValueKey('track-row-melody')));
      final spot = Offset(row.right - 40, row.center.dy);
      await click(tester, spot, 1000);
      await tester.pump(const Duration(milliseconds: 80));
      await click(tester, spot, 1080);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse);
      expect(tester.widget<Text>(find.byKey(const ValueKey('minimap-label'))).data, contains('Melody'));
      // slow clicks are two selections, not a double-click
      await showArrange(tester);
      await tester.pumpAndSettle();
      await click(tester, spot, 5000);
      await tester.pump(const Duration(milliseconds: 600));
      await click(tester, spot, 5600);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue);
    });

    testWidgets('recording / count-in lock every switch (segment, Tab, Enter, double-click, minimap)', (tester) async {
      await open(tester);
      if (tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).countIn) {
        await tester.tap(find.byKey(const ValueKey('top-count-in')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('top-record')));
      await tester.pump();
      expect(tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).onView, isNull);
      expect(minimap(tester).onArrange, isNull);
      await tester.tap(find.byKey(const ValueKey('view-arrange')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('minimap-arrange')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(arrangeShown(), isFalse);
      expect(view(), 'edit');
      await tester.tap(find.byKey(const ValueKey('top-stop')));
      await tester.pump(const Duration(milliseconds: 300));
      // arrange view: Enter / double-click while recording stay put
      await showArrange(tester);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('top-record')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      tester.widget<Arrangement>(find.byType(Arrangement)).onOpenTrack!('melody');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(arrangeShown(), isTrue);
      expect(view(), 'arrange');
      await tester.tap(find.byKey(const ValueKey('top-stop')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse, reason: 'unlocked after stop');
    });
  });

  group('keyboard focus', () {
    testWidgets('Tab from a focused piano roll: arrange view, focus back on the commands; Tab returns', (tester) async {
      await open(tester);
      await editTrack(tester, 'melody');
      await tester.pumpAndSettle();
      await toGrid(tester);
      tester
          .widget<Focus>(find.byWidgetPredicate((w) => w is Focus && w.focusNode?.debugLabel == 'MIDI note editor'))
          .focusNode!
          .requestFocus();
      await tester.pump();
      expect(focusLabel(), 'MIDI note editor');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue);
      expect(focusLabel(), 'editor commands', reason: 'no hidden grid keeps the keyboard');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse, reason: 'Enter edits the selected track');
    });

    testWidgets('typing in the title or a dialog: Tab / Enter do not switch', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const ValueKey('top-title')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse);
      FocusManager.instance.primaryFocus?.unfocus();
      await showArrange(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('top-title')));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue, reason: 'Enter in the title field');
      // the shortcut help dialog over the editor
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).help!();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const ValueKey('shortcut-help-help')))).pop();
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue, reason: 'Tab with a dialog open');
    });

    testWidgets('Enter on a focused button activates the button, not the editor', (tester) async {
      await open(tester);
      await showArrange(tester);
      await tester.pumpAndSettle();
      final zoomIn = find.byKey(const ValueKey('timeline-zoom-in'));
      Focus.of(tester.element(find.descendant(of: zoomIn, matching: find.byType(Icon)))).requestFocus();
      await tester.pump();
      expect(focusLabel(), isNot('editor commands'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue);
      expect(find.text('150%'), findsOneWidget, reason: 'the button ran');
      // a track click hands the keyboard back: Enter edits it
      await tester.tap(find.byKey(const ValueKey('track-row-melody')));
      await tester.pump(const Duration(milliseconds: 500));
      expect(focusLabel(), 'editor commands');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(arrangeShown(), isFalse);
    });
  });

  group('layouts', () {
    testWidgets('arrange view: 64 px rows, add track, 40 px hint, no surface; edit view: 44 px minimap', (tester) async {
      await open(tester);
      expect(tester.getSize(find.byKey(const ValueKey('timeline-minimap'))).height, 44);
      for (final key in const ['grid-focus', 'timeline-expand', 'timeline-collapse']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.byType(DesktopSplitHandle), findsNothing);
      await showArrange(tester);
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const ValueKey('track-label-melody'))).height, 64);
      final hint = tester.getRect(find.byKey(const ValueKey('arrange-hint')));
      expect(hint.height, 40);
      expect(hint.bottom, closeTo(720, .01));
      expect(find.text('Double-click a track or press Enter to edit it'), findsOneWidget);
      final arr = tester.widget<Arrangement>(find.byType(Arrangement));
      expect(arr.onAddTrack, isNotNull);
      // kept: reorder, Solo / mute, vocal clip moves, MIDI drop, seek
      expect(arr.onReorder, isNotNull);
      expect(arr.onToggleSolo, isNotNull);
      expect(arr.onMoveClip, isNotNull);
      expect(arr.onConvertClip, isNotNull);
      expect(arr.onSeek, isNotNull);
      expect(find.byType(StepGrid), findsNothing);
      expect(find.byKey(const ValueKey('timeline-minimap')), findsNothing);
      // Solo / mute buttons in a row work and never open the editor
      await tester.tap(find.byKey(const ValueKey('solo-melody')));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(find.byKey(const ValueKey('solo-melody')));
      await tester.pumpAndSettle();
      expect(arrangeShown(), isTrue);
      expect(tester.widget<Arrangement>(find.byType(Arrangement)).solos, isEmpty);
    });

    testWidgets('timeline zoom / scroll come back after the edit view', (tester) async {
      await open(tester, sections: [Section(id: 'A', name: 'A', bars: 8)]);
      await showArrange(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timeline-zoom-in')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timeline-zoom-in')));
      await tester.pumpAndSettle();
      final scroll = tester.widget<SingleChildScrollView>(find.byKey(const ValueKey('timeline-scroll'))).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent / 2);
      await tester.pumpAndSettle();
      final before = tester.widget<Arrangement>(find.byType(Arrangement)).visible;
      expect(find.text('200%'), findsOneWidget);
      await showEdit(tester);
      await tester.pumpAndSettle();
      await showArrange(tester);
      await tester.pumpAndSettle();
      expect(find.text('200%'), findsOneWidget);
      final after = tester.widget<Arrangement>(find.byType(Arrangement)).visible;
      expect(after.start, closeTo(before.start, .01));
      expect(after.end, closeTo(before.end, .01));
    });
  });

  group('minimap', () {
    test('song steps of every section instance (A 2x2, B 4, C 1x3 = 176)', () {
      final map = SongMap([(steps: 32, repeats: 2), (steps: 64, repeats: 1), (steps: 16, repeats: 3)]);
      expect(map.total, 176);
      expect([map.instanceStart(0, 1), map.instanceStart(1, 0), map.instanceStart(2, 2)], [32, 64, 160]);
      // B's local 16..48 is song 80..112
      expect(map.instanceStart(1, 0) + 16, 80);
      expect(map.instanceStart(1, 0) + 48, 112);
      final hit = map.locate(150);
      expect((hit.section, hit.repeat, hit.local), (2, 1, 6.0));
      expect(map.locate(-5).section, 0);
      expect(map.locate(999).section, 2);
      expect(map.locate(999).repeat, 2);
    });

    test('rows: every track gets a row inside the overview, 3 px when there is room', () {
      expect(TimelineMinimap.rowLayout(4, 20), (pitch: 4.0, rowH: 3.0));
      for (var n = 1; n <= 24; n++) {
        final g = TimelineMinimap.rowLayout(n, 20);
        expect(n * g.pitch, lessThanOrEqualTo(20 + 1e-9), reason: '$n rows');
        expect(g.rowH, greaterThan(0));
        expect(g.rowH, lessThanOrEqualTo(g.pitch));
      }
    });

    testWidgets('clicks seek into other sections and repeats; the roll rect drags the roll, clamped to the section', (tester) async {
      await open(tester, sections: _abc());
      await editTrack(tester, 'melody');
      await tester.pumpAndSettle();
      await toGrid(tester);
      final overview = tester.getRect(find.byKey(const ValueKey('minimap-overview')));
      double x(double global) => overview.left + overview.width * global / 176;
      // B, step 16 inside it
      await tester.tapAt(Offset(x(80) + .5, overview.center.dy));
      await tester.pumpAndSettle();
      expect(minimap(tester).activeIdx, 1);
      expect(minimap(tester).offset, 64);
      expect(minimap(tester).playStep.value, closeTo(16, .3));
      // the roll at 2x zoom showing B's local 16..48 = song 80..112
      final v = link(tester).view!;
      expect(v.steps, 64);
      v.setZoom(2);
      v.panTo(16);
      await tester.pump();
      expect(minimap(tester).offset + v.view.start, 80);
      expect(minimap(tester).offset + v.view.end, 112);
      // drag the rectangle 8 song steps right = the roll pans 8 steps
      final g = await tester.startGesture(Offset(x(96), overview.center.dy));
      await g.moveBy(Offset(x(100) - x(96), 0));
      await tester.pump();
      await g.moveBy(Offset(x(104) - x(100), 0));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect(link(tester).view!.view.start, closeTo(24, .3));
      expect(tester.widget<StepGrid>(find.byType(StepGrid)).viewLink!.view, same(v), reason: 'the roll moved, same view');
      // far right: stops at B's end (never spills into C)
      final g2 = await tester.startGesture(Offset(x(104), overview.center.dy));
      await g2.moveBy(Offset(x(170) - x(104), 0));
      await tester.pump();
      await g2.up();
      await tester.pumpAndSettle();
      expect(v.view.start, closeTo(32, .01));
      expect(minimap(tester).offset + v.view.end, closeTo(128, .01));
      // C's second instance, step 6: section switch + that repeat; a new roll
      await tester.tapAt(Offset(x(150) + .5, overview.center.dy));
      await tester.pumpAndSettle();
      expect(minimap(tester).activeIdx, 2);
      expect(minimap(tester).activeRepeat, 1);
      expect(minimap(tester).offset, 144);
      expect(minimap(tester).playStep.value, closeTo(6, .3));
      final c = link(tester).view!;
      expect(c, isNot(same(v)));
      expect(c.steps, 16);
      expect(c.view.start, 0, reason: 'a new section starts from its whole length');
      // A's second instance via a click, back to the active A section
      await tester.tapAt(Offset(x(40) + .5, overview.center.dy));
      await tester.pumpAndSettle();
      expect((minimap(tester).activeIdx, minimap(tester).activeRepeat), (0, 1));
      expect(minimap(tester).offset, 32);
      // the band switch starts at the first instance
      await showArrange(tester);
      await tester.pumpAndSettle();
      tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
      await showEdit(tester);
      await tester.pumpAndSettle();
      expect(minimap(tester).activeRepeat, 1, reason: 'same section kept its instance');
    });

    testWidgets('notes of every track and section reach the overview with their real timing', (tester) async {
      await open(tester, sections: [
        Section(id: 'A', name: 'A', bars: 1)
          ..tracks['melody'] = TrackData(notes: [PitchNote(midi: 60, freq: 261.63, step: 2, dur: 1, offsetSteps: .25)])
          ..tracks['drums'] = TrackData(drums: [DrumNote(step: 4, kind: 'kick', offsetSteps: .5)]),
      ]);
      final m = minimap(tester);
      final rows = {for (var i = 0; i < m.rowColors.length; i++) i: m.sections.single.rows[i]};
      expect(rows.values.where((r) => r.isNotEmpty), hasLength(2));
      final spans = rows.values.expand((r) => r).toList();
      expect(spans.first.$1 == 2.25 || spans.last.$1 == 2.25, isTrue, reason: 'pitch offset');
      expect(spans.any((s) => s.$1 == 4.5), isTrue, reason: 'drum offset');
    });
  });

  group('PitchGridViewLink', () {
    test('only the attached view detaches; notifications outside frames are immediate', () {
      final link = PitchGridViewLink();
      final a = PitchGridView(64), b = PitchGridView(64);
      var calls = 0;
      link.addListener(() => calls++);
      link.attach(a);
      link.attach(b);
      link.detach(a);
      expect(link.view, same(b));
      b.setZoom(2);
      expect(calls, 3, reason: 'attach a, attach b, b zoomed');
      a.setZoom(2);
      expect(calls, 3, reason: 'a is no longer followed');
      link.detach(b);
      expect(link.view, isNull);
      link.dispose();
      a.dispose();
      b.dispose();
    });

    testWidgets('track / section / view switches and a length change never leave a stale view', (tester) async {
      await open(tester, sections: _abc());
      await editTrack(tester, 'melody');
      await tester.pumpAndSettle();
      await toGrid(tester);
      final l = link(tester);
      final melody = l.view!;
      // another track's roll replaces it
      await editTrack(tester, 'bass');
      await tester.pumpAndSettle();
      await toGrid(tester);
      expect(link(tester), same(l));
      final bass = l.view!;
      expect(bass, isNot(same(melody)));
      // the arrange view has no roll
      await showArrange(tester);
      await tester.pumpAndSettle();
      expect(l.view, isNull);
      await showEdit(tester);
      await tester.pumpAndSettle();
      final again = l.view!;
      expect(again, isNot(same(bass)));
      again.setZoom(4);
      // a section-length change: same view, whole new length, zoom reset
      tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).onBars(4);
      await tester.pumpAndSettle();
      expect(l.view, same(again));
      expect(again.steps, 64);
      expect(again.zoom, 1);
      // closing the editor: nothing left attached, no error
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(l.view, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('acceptance heights (pitch-grid-viewport, grid_usability_test method)', () {
    Future<Rect> measure(WidgetTester tester, Size size, {required bool desktop}) async {
      // the same editor and track as the pre-stage-3 probe (ko, 2 bars, melody)
      await open(tester, size: size, locale: 'ko', desktop: desktop);
      if (desktop) {
        await editTrack(tester, 'melody');
      } else {
        tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
      }
      await tester.pumpAndSettle();
      await toGrid(tester);
      return tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
    }

    for (final (size, min) in const [(Size(1280, 720), 480.0), (Size(960, 600), 330.0), (Size(1920, 1080), 840.0)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()} edit view >= $min', (tester) async {
        await measure(tester, size, desktop: true);
        // ui-001 stage 5: the desktop lane starts folded; stage 3's numbers
        // are with the lane open (its 24 px row unfolds it)
        await tester.tap(find.byKey(const ValueKey('velocity-lane-fold')));
        await tester.pumpAndSettle();
        final vp = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
        debugPrint('[stage3-measure] ${size.width.toInt()}x${size.height.toInt()} pitch-grid-viewport '
            'height=${vp.height.toStringAsFixed(1)} top=${vp.top.toStringAsFixed(1)}');
        expect(vp.height, greaterThanOrEqualTo(min));
        expect(LoopPrefs.instance.gridVelocityLane.value, isTrue, reason: 'the velocity lane is still on');
        expect(find.byKey(const ValueKey('velocity-lane')), findsOneWidget);
      });
    }

    // measured before stage 3 at the same setup (artifacts/ui-003-view-modes/probe-baseline.log)
    for (final (size, top, height) in const [(Size(844, 390), 287.4, 0.0), (Size(390, 844), 469.0, 246.0)]) {
      testWidgets('phone ${size.width.toInt()}x${size.height.toInt()} unchanged', (tester) async {
        final vp = await measure(tester, size, desktop: false);
        expect(vp.top, closeTo(top, .05));
        expect(vp.height, closeTo(height, .05));
        expect(find.byType(TimelineMinimap), findsNothing);
        expect(find.byKey(const ValueKey('top-view-switch')), findsNothing);
      });
    }
  });
}
