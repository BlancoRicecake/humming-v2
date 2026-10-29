// ui-001 stage 2 (docs/specs/ui/ui-001-desktop-b2-layout.md "2단계 — 섹션 띠와
// 눈금 구간 반복"): on desktop the section band sits in the track header, the
// ruler sets the loop range by drag (whole bars, end bar included), the Solo
// controls replace AuditionBar / SoloStatusNotice, the grid hides the key-hint
// row; phone keeps SectionBar / AuditionBar / SoloStatusNotice.
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerScrollEvent, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/timeline_view.dart';
import 'package:humming/looptap/widgets/timeline_ruler.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/audition_bar.dart';
import 'package:humming/looptap/widgets/desktop_section_band.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/section_bar.dart';
import 'package:humming/looptap/widgets/solo_status_notice.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/timeline_minimap.dart';
import 'package:provider/provider.dart';

import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

void main() {
  late Directory root;
  late _Store store;
  final layoutErrors = <String>[];

  setUp(() async {
    useOfflineTestFonts();
    root = await Directory.systemTemp.createTemp('humtrack_section_ruler_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    store = _Store();
    LoopPrefs.instance.metro.value = false;
  });
  tearDown(() async {
    LoopPrefs.instance.resetGridLayout();
    EditScreen.debugDesktopOverride = null;
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<Song> open(
    WidgetTester tester, {
    Size size = const Size(1280, 720),
    String locale = 'en',
    bool desktop = true,
    int bars = 4,
    List<Section>? sections,
    List<PitchNote> melody = const [],
    GlobalKey<NavigatorState>? nav,
    bool arrange = true,
  }) async {
    EditScreen.debugDesktopOverride = desktop;
    layoutErrors.clear();
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      final text = d.toString();
      // Ahem glyphs overflow unrelated fixed-width labels elsewhere; only the
      // stage-2 widgets are this test's concern.
      if (RegExp(r'desktop_section_band\.dart|timeline_ruler\.dart|arrangement\.dart').hasMatch(text)) {
        layoutErrors.add(text);
      }
      if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final secs = sections ?? [Section(id: 'A', name: 'A', bars: bars)..tracks['melody'] = TrackData(notes: List.of(melody))];
    final song = Song(id: 'band', title: 'Band', bpm: 120, bars: bars, sections: secs);
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          navigatorKey: nav,
          locale: Locale(locale),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: nav == null ? EditScreen(song: song) : const Scaffold(body: Text('songs')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // ui-001 stage 3: the band and the ruler are the arrange view's (the
    // editor opens in the edit view)
    if (desktop && nav == null && arrange) await showArrange(tester);
    return song;
  }

  Arrangement arrangement(WidgetTester tester) => tester.widget<Arrangement>(find.byType(Arrangement));
  DesktopSectionBand band(WidgetTester tester) => tester.widget<DesktopSectionBand>(find.byType(DesktopSectionBand).first);
  DesktopTopBar top(WidgetTester tester) => tester.widget<DesktopTopBar>(find.byType(DesktopTopBar));

  /// Global x of song step [step] on the ruler, through the timeline view.
  double xOf(WidgetTester tester, double step) {
    final r = tester.getRect(find.byKey(const ValueKey('timeline-ruler')));
    final v = arrangement(tester).visible;
    return r.left + r.width * (step - v.start) / v.length;
  }

  double rulerY(WidgetTester tester) => tester.getRect(find.byKey(const ValueKey('timeline-ruler'))).center.dy;

  Future<void> drag(WidgetTester tester, double fromStep, double toStep) async {
    final y = rulerY(tester);
    final g = await tester.startGesture(Offset(xOf(tester, fromStep), y));
    await g.moveTo(Offset((xOf(tester, fromStep) + xOf(tester, toStep)) / 2, y));
    await tester.pump();
    await g.moveTo(Offset(xOf(tester, toStep), y));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();
  }

  group('ruler loop range (whole bars, end bar included)', () {
    testWidgets('drag bars 2→3 and 3→2 = bars 2–3; header 36 px with the band on top', (tester) async {
      await open(tester);
      expect(tester.getSize(find.byKey(const ValueKey('arrangement-header'))).height, 36);
      expect(tester.getSize(find.byKey(const ValueKey('desktop-section-band'))).height, 16);
      expect(tester.getRect(find.byKey(const ValueKey('desktop-section-band'))).bottom,
          lessThanOrEqualTo(tester.getRect(find.byKey(const ValueKey('timeline-ruler'))).top));
      await drag(tester, 16 + 2, 32 + 8);
      expect(arrangement(tester).loopRange, isNotNull);
      expect([arrangement(tester).loopRange!.start, arrangement(tester).loopRange!.end], [16, 48]);
      expect(top(tester).rangeLoop, isTrue);
      await drag(tester, 32 + 14, 16 + 1);
      expect([arrangement(tester).loopRange!.start, arrangement(tester).loopRange!.end], [16, 48]);
    });

    testWidgets('end handle: to the exact bar line 64 = bars 2–4; back to 48 = bars 2–3; start handle', (tester) async {
      await open(tester);
      await drag(tester, 17, 40);
      await drag(tester, 48, 64);
      expect([arrangement(tester).loopRange!.start, arrangement(tester).loopRange!.end], [16, 64]);
      // grab the end, go out and come back to where it was
      final y = rulerY(tester);
      // (64 is the song end = the ruler's right edge; press just inside it)
      final g = await tester.startGesture(Offset(xOf(tester, 64) - 1, y));
      await g.moveTo(Offset(xOf(tester, 58), y));
      await tester.pump();
      await g.moveTo(Offset(xOf(tester, 48), y));
      await tester.pump();
      await g.up();
      await tester.pumpAndSettle();
      expect([arrangement(tester).loopRange!.start, arrangement(tester).loopRange!.end], [16, 48]);
      // start handle to bar line 0, then past the end: one bar is kept
      await drag(tester, 16, 0);
      expect([arrangement(tester).loopRange!.start, arrangement(tester).loopRange!.end], [0, 48]);
      await drag(tester, 0, 60);
      expect([arrangement(tester).loopRange!.start, arrangement(tester).loopRange!.end], [32, 48]);
    });

    testWidgets('pointer-down bar kept next to a bar line (no touch-slop shift)', (tester) async {
      await open(tester);
      // down 0.3 step before bar line 32 (still bar 2), then far right
      await drag(tester, 31.7, 56);
      expect([arrangement(tester).loopRange!.start, arrangement(tester).loopRange!.end], [16, 64]);
    });

    testWidgets('click = seek, no range change', (tester) async {
      await open(tester);
      await drag(tester, 17, 40);
      final before = arrangement(tester).loopRange;
      await tester.tapAt(Offset(xOf(tester, 40), rulerY(tester)));
      await tester.pumpAndSettle();
      expect(arrangement(tester).loopRange!.start, before!.start);
      expect(arrangement(tester).loopRange!.end, before.end);
      expect(arrangement(tester).playStep.value, closeTo(40, 1.0));
    });

    testWidgets('zoomed + scrolled view: bars from the view, edges clamp to the song', (tester) async {
      await open(tester, bars: 8);
      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('timeline-zoom-in')));
        await tester.pumpAndSettle();
      }
      final scroll = find.byKey(const ValueKey('timeline-scroll'));
      await tester.drag(scroll, const Offset(-200, 0));
      await tester.pumpAndSettle();
      final v = arrangement(tester).visible;
      expect(v.start, greaterThan(0));
      expect(v.length, lessThan(128));
      final a = (v.start / 16).ceil() * 16 + 1.0; // first full bar in view
      await drag(tester, a, a + 17);
      final r = arrangement(tester).loopRange!;
      expect(r.start, (a / 16).floor() * 16);
      expect(r.end, ((a + 17) / 16).floor() * 16 + 16);
      // dragging beyond the right edge clamps to the view end (inside the song)
      await drag(tester, a, v.end + 40);
      expect(arrangement(tester).loopRange!.end, lessThanOrEqualTo(128));
    });
  });

  group('section band = every SectionBar action', () {
    List<Section> three() => [
      Section(id: 'A', name: 'Verse', bars: 2),
      Section(id: 'B', name: 'Chorus', bars: 2),
      Section(id: 'C', name: 'Bridge', bars: 2),
    ];

    testWidgets('click selects, wheel changes repeats, + adds, play song', (tester) async {
      await open(tester, sections: three());
      await tester.tap(find.byKey(const ValueKey('B')));
      await tester.pump(const Duration(milliseconds: 400)); // past the double-tap window
      await tester.pumpAndSettle();
      expect(band(tester).activeIdx, 1);
      final cell = tester.getCenter(find.byKey(const ValueKey('C')));
      tester.binding.handlePointerEvent(PointerScrollEvent(position: cell, scrollDelta: const Offset(0, -20)));
      await tester.pumpAndSettle();
      expect(band(tester).sections[2].repeats, 2);
      tester.binding.handlePointerEvent(PointerScrollEvent(position: cell, scrollDelta: const Offset(0, 20)));
      tester.binding.handlePointerEvent(PointerScrollEvent(position: cell, scrollDelta: const Offset(0, 20)));
      await tester.pumpAndSettle();
      expect(band(tester).sections[2].repeats, 1, reason: 'clamped at 1');
      await tester.tap(find.byKey(const ValueKey('section-add')));
      await tester.pumpAndSettle();
      expect(band(tester).sections, hasLength(4));
      await tester.tap(find.byKey(const ValueKey('section-play-song')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(band(tester).songMode, isTrue);
      await tester.tap(find.byKey(const ValueKey('section-play-song')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(band(tester).songMode, isFalse);
    });

    testWidgets('double-click renames (long names kept), right-click menu: repeats, linked duplicate, unique, delete', (tester) async {
      final long = 'A very long section name that is kept as it is';
      await open(tester, sections: [Section(id: 'A', name: long, bars: 2), Section(id: 'B', name: 'Chorus', bars: 2)]);
      // rename B
      await tester.tap(find.byKey(const ValueKey('B')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('B')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('section-rename-field')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('section-rename-field')), 'Hook');
      await tester.tap(find.byKey(const ValueKey('section-rename-apply')));
      await tester.pumpAndSettle();
      expect(band(tester).sections[1].name, 'Hook');
      // the long name opens untouched and stays the same on apply
      await tester.tap(find.byKey(const ValueKey('A')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('A')));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('section-rename-field'))).controller!.text, long);
      await tester.tap(find.byKey(const ValueKey('section-rename-apply')));
      await tester.pumpAndSettle();
      expect(band(tester).sections[0].name, long);

      // right-click → the existing menu, plus desktop repeats / delete rows
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('B'))), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('section-dup-linked')), findsOneWidget);
      expect(find.byKey(const ValueKey('section-midi-import')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('section-menu-repeats-plus')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('section-menu-repeats'))).data, '×2');
      expect(band(tester).sections[1].repeats, 2);
      await tester.tap(find.byKey(const ValueKey('section-menu-repeats-minus')));
      await tester.pumpAndSettle();
      expect(band(tester).sections[1].repeats, 1);
      await tester.tap(find.byKey(const ValueKey('section-dup-linked')));
      await tester.pumpAndSettle();
      expect(band(tester).sections, hasLength(3));
      final b = band(tester).sections[1], dup = band(tester).sections[2];
      expect(b.linkId, isNotNull);
      expect(dup.linkId, b.linkId);
      expect(identical(b.tracks, dup.tracks), isTrue);
      expect(find.byKey(ValueKey('section-link-${b.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('section-link-${dup.id}')), findsOneWidget);
      expect(find.byKey(const ValueKey('section-link-notice')), findsOneWidget);
      // make unique
      band(tester).onMenu(2);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section-make-unique')));
      await tester.pumpAndSettle();
      expect(band(tester).sections[2].linkId, isNull);
      // delete from the menu
      band(tester).onMenu(2);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section-menu-delete')));
      await tester.pumpAndSettle();
      expect(band(tester).sections, hasLength(2));
    });

    testWidgets('rename dialog answered after the editor closed underneath: no error', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final song = await open(tester, nav: nav);
      final editor = MaterialPageRoute<void>(builder: (_) => EditScreen(song: song));
      nav.currentState!.push(editor);
      await tester.pumpAndSettle();
      await showArrange(tester);
      band(tester);
      await tester.tap(find.byKey(const ValueKey('A')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const ValueKey('A')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('section-rename-field')), 'Late');
      nav.currentState!.removeRoute(editor);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section-rename-apply')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('songs'), findsOneWidget);
    });

    // ui-001 stage 3: the edit view replaces the desktop timeline fold. Its
    // minimap keeps every section reachable; the arrange view has the band
    // (and restart) for the section actions.
    testWidgets('edit view (replaces the fold): sections from the minimap; band and restart in the arrange view', (tester) async {
      await open(tester, sections: three(), arrange: false);
      expect(find.byKey(const ValueKey('timeline-collapse')), findsNothing);
      expect(find.byKey(const ValueKey('timeline-expand')), findsNothing);
      expect(find.byType(Arrangement), findsNothing);
      expect(find.byType(DesktopSectionBand), findsNothing);
      final map = tester.widget<TimelineMinimap>(find.byType(TimelineMinimap)).map;
      final overview = tester.getRect(find.byKey(const ValueKey('minimap-overview')));
      await tester.tapAt(Offset(overview.left + overview.width * (map.instanceStart(2, 0) + 4) / map.total, overview.center.dy));
      await tester.pumpAndSettle();
      expect(tester.widget<TimelineMinimap>(find.byType(TimelineMinimap)).activeIdx, 2);
      await showArrange(tester);
      expect(band(tester).activeIdx, 2);
      expect(find.byKey(const ValueKey('audition-restart')), findsOneWidget);
    });
  });

  group('Solo in the header (desktop)', () {
    testWidgets('only while a Solo is on: compare / clear; quiet warning tooltip opens velocity', (tester) async {
      await open(tester, melody: [PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4, velocity: 3)]);
      expect(find.byType(AuditionBar), findsNothing);
      expect(find.byType(SoloStatusNotice), findsNothing);
      expect(find.byType(DesktopSoloHeader), findsNothing);
      arrangement(tester).onToggleSolo!('melody');
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSoloHeader), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audition-compare')));
      await tester.pumpAndSettle();
      expect(arrangement(tester).bypassSolo, isTrue);
      await tester.tap(find.byKey(const ValueKey('audition-compare')));
      await tester.pumpAndSettle();
      expect(arrangement(tester).bypassSolo, isFalse);
      final tip = tester.widget<Tooltip>(
        find.ancestor(of: find.byKey(const ValueKey('solo-status-notice')), matching: find.byType(Tooltip)),
      );
      expect(tip.message, contains('Velocity 3–3/127'));
      await tester.tap(find.byKey(const ValueKey('solo-status-notice')));
      await tester.pumpAndSettle();
      // ui-001 stage 3: 강약 보기 opens the edit view on that track's grid,
      // where the Solo controls sit beside the minimap's track button
      expect(find.byType(Arrangement), findsNothing);
      expect(find.byType(StepGrid), findsOneWidget);
      expect(find.byType(DesktopSoloHeader), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audition-clear-solo')));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSoloHeader), findsNothing);
      await showArrange(tester);
      expect(arrangement(tester).activeId, 'melody');
      expect(arrangement(tester).solos, isEmpty);
    });
  });

  group('key-hint row and phone', () {
    testWidgets('desktop: pad keeps the key-hint row, grid hides it', (tester) async {
      await open(tester, arrange: false);
      await editTrack(tester, 'melody');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Instrument keys'), findsOneWidget, reason: 'pad mode');
      tester.widget<GestureDetector>(find.ancestor(of: find.text('Grid'), matching: find.byType(GestureDetector)).first).onTap!();
      await tester.pumpAndSettle();
      expect(find.byType(StepGrid), findsOneWidget);
      expect(find.byTooltip('Instrument keys'), findsNothing, reason: 'grid mode');
    });

    for (final size in const [Size(390, 844), Size(844, 390)]) {
      testWidgets('phone ${size.width.toInt()}x${size.height.toInt()}: SectionBar + AuditionBar, no band', (tester) async {
        await open(tester, size: size, desktop: false);
        expect(find.byType(SectionBar), findsOneWidget);
        expect(find.byType(AuditionBar), findsOneWidget);
        expect(find.byType(DesktopSectionBand), findsNothing);
        expect(find.byKey(const ValueKey('arrangement-header')), findsNothing);
      });
    }
  });

  testWidgets('section menu: desktop 20 px wider (English rows fit), phone keeps 300', (tester) async {
    // Ahem cannot reproduce Inter's widths; the real-font check (no overflow
    // in the English desktop menu) is the native QA run. Here: the widths.
    await open(tester);
    band(tester).onMenu(0);
    await tester.pumpAndSettle();
    final desktopRow = tester.getSize(find.byKey(const ValueKey('section-dup-linked'))).width;
    Navigator.of(tester.element(find.byKey(const ValueKey('section-dup-linked')))).pop();
    await tester.pumpAndSettle();
    await open(tester, size: const Size(390, 844), desktop: false);
    tester.widget<SectionBar>(find.byType(SectionBar)).onLongPress(0);
    await tester.pumpAndSettle();
    final phoneRow = tester.getSize(find.byKey(const ValueKey('section-dup-linked'))).width;
    expect(desktopRow - phoneRow, 20, reason: 'desktop menu 320, phone 300');
  });

  group('layout: no overflow in the new header pieces', () {
    for (final size in const [Size(960, 600), Size(1280, 720), Size(1920, 1080)]) {
      for (final locale in const ['ko', 'en']) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} $locale, linked + long names + quiet Solo', (tester) async {
          final a = Section(id: 'A', name: 'Intro with a fairly long name', bars: 2)
            ..tracks['melody'] = TrackData(notes: [PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4, velocity: 3)]);
          await open(tester, size: size, locale: locale, sections: [a, Section(id: 'B', name: 'Chorus', bars: 2), Section(id: 'C', name: 'Outro', bars: 2)]);
          band(tester).onMenu(0);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('section-dup-linked')));
          await tester.pumpAndSettle();
          arrangement(tester).onToggleSolo!('melody');
          arrangement(tester).onToggleSolo!('bass');
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('section-link-notice')), findsOneWidget);
          expect(find.byKey(const ValueKey('solo-status-notice')), findsOneWidget);
          await drag(tester, 1, 20);
          expect(layoutErrors, isEmpty);
          for (final key in const ['desktop-section-band', 'timeline-ruler', 'audition-compare', 'audition-clear-solo', 'audition-restart', 'section-add', 'section-play-song']) {
            final r = tester.getRect(find.byKey(ValueKey(key)));
            expect(r.left >= 0 && r.right <= size.width, isTrue, reason: '$key $r');
          }
        });
      }
    }
  });

  group('ruler review regressions', () {
    Future<void> mountRuler(WidgetTester tester, PlaybackRange? range, TimelineView view,
        ValueChanged<PlaybackRange>? onRange, {bool enabled = true}) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 640,
              height: 16,
              child: TimelineRuler(view: view, steps: 128, loopRange: range, onRange: onRange, onSeek: (_) {}, rangeEnabled: enabled),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('an end outside the view has no handle; the edge acts as a new range', (tester) async {
      PlaybackRange range = const PlaybackRange(16, 80);
      const view = TimelineView(32, 96); // start (16) is off the left edge
      await mountRuler(tester, range, view, (r) => range = r);
      expect(find.byKey(const ValueKey('loop-handle-start')), findsNothing);
      expect(find.byKey(const ValueKey('loop-handle-end')), findsOneWidget);
      final o = tester.getTopLeft(find.byKey(const ValueKey('timeline-ruler')));
      double x(double step) => (step - 32) / 64 * 640;
      // dragging from the left edge starts a new range there, it is not a handle
      final g = await tester.startGesture(o + Offset(x(32) + 1, 8));
      await g.moveTo(o + Offset(x(40), 8));
      await tester.pump();
      await g.moveTo(o + Offset(x(50), 8));
      await tester.pump();
      await g.up();
      await tester.pump();
      expect([range.start, range.end], [32, 64]);
      // the visible end handle works (80 → line 96 at the right edge, clamped in view)
      range = const PlaybackRange(16, 80);
      await mountRuler(tester, range, view, (r) => range = r);
      final h = await tester.startGesture(o + Offset(x(80), 8));
      await h.moveTo(o + Offset(x(86), 8));
      await tester.pump();
      await h.moveTo(o + Offset(x(64), 8));
      await tester.pump();
      await h.up();
      await tester.pump();
      expect([range.start, range.end], [16, 64]);
    });

    testWidgets('disabled (recording / count-in / song preview): no preview, no commit; disabling mid-drag drops it', (tester) async {
      var calls = 0;
      const view = TimelineView(0, 128);
      await mountRuler(tester, null, view, (_) => calls++, enabled: false);
      final o = tester.getTopLeft(find.byKey(const ValueKey('timeline-ruler')));
      await tester.dragFrom(o + const Offset(100, 8), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.byKey(const ValueKey('timeline-ruler-range')), findsNothing);
      // enabled, start a drag, then disable before release
      await mountRuler(tester, null, view, (_) => calls++);
      final g = await tester.startGesture(o + const Offset(100, 8));
      await g.moveTo(o + const Offset(150, 8));
      await tester.pump();
      await g.moveTo(o + const Offset(250, 8));
      await tester.pump();
      expect(find.byKey(const ValueKey('timeline-ruler-range')), findsOneWidget, reason: 'preview while dragging');
      await mountRuler(tester, null, view, (_) => calls++, enabled: false);
      expect(find.byKey(const ValueKey('timeline-ruler-range')), findsNothing);
      await g.up();
      await tester.pumpAndSettle();
      expect(calls, 0);
      // and the callback going away mid-drag is safe too
      await mountRuler(tester, null, view, (_) => calls++);
      final g2 = await tester.startGesture(o + const Offset(100, 8));
      await g2.moveTo(o + const Offset(200, 8));
      await tester.pump();
      await mountRuler(tester, null, view, null);
      await g2.up();
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the loop turned off (range → null) during an end-handle drag: cancelled, no commit, no error', (tester) async {
      var calls = 0;
      const view = TimelineView(0, 128);
      await mountRuler(tester, const PlaybackRange(16, 48), view, (_) => calls++);
      final o = tester.getTopLeft(find.byKey(const ValueKey('timeline-ruler')));
      final g = await tester.startGesture(o + const Offset(240, 8)); // the end handle (48)
      await g.moveTo(o + const Offset(270, 8));
      await tester.pump();
      await mountRuler(tester, null, view, (_) => calls++); // e.g. Ctrl+L turns the loop off
      await g.moveTo(o + const Offset(300, 8));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('timeline-ruler-range')), findsNothing);
      await g.up();
      await tester.pump();
      expect(calls, 0);
    });

    testWidgets('editor: while recording the ruler range drag is disabled', (tester) async {
      await open(tester);
      if (tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).countIn) {
        await tester.tap(find.byKey(const ValueKey('top-count-in')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('top-record')));
      await tester.pump();
      expect(arrangement(tester).loopRangeEnabled, isFalse);
      expect(tester.widget<TimelineRuler>(find.byType(TimelineRuler)).rangeEnabled, isFalse);
      await tester.tap(find.byKey(const ValueKey('top-stop')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(arrangement(tester).loopRangeEnabled, isTrue);
    });
  });

  testWidgets('1280x720 grid: measured stack (SectionBar / AuditionBar / key-hint rows gone)', (tester) async {
    await open(tester, melody: [PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4)], arrange: false);
    // ui-001 stage 3: the editing surface is the edit view's
    await editTrack(tester, 'melody');
    await tester.pumpAndSettle();
    tester.widget<GestureDetector>(find.ancestor(of: find.text('Grid'), matching: find.byType(GestureDetector)).first).onTap!();
    await tester.pumpAndSettle();
    expect(find.byType(SectionBar), findsNothing);
    expect(find.byType(AuditionBar), findsNothing);
    expect(find.byTooltip('Instrument keys'), findsNothing);
    final viewport = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
    await showArrange(tester);
    final header = tester.getRect(find.byKey(const ValueKey('arrangement-header')));
    debugPrint('[stage2-measure] 1280x720 grid (stage 3 edit view): pitch-grid-viewport height=${viewport.height.toStringAsFixed(1)} '
        'top=${viewport.top.toStringAsFixed(1)} arrange header=${header.height}');
    expect(header.height, 36);
  });
}
