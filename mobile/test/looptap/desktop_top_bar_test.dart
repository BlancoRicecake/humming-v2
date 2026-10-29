// ui-001 stage 1 (docs/specs/ui/ui-001-desktop-b2-layout.md "1단계 — 상단 바에
// 재생 통합"): the desktop top bar replaces the phone top bar and the bottom
// TransportBar on desktop only, every control drives the editor's existing
// state, and the shortcut help lists exactly what DesktopCommands registers.
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryButton;
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
import 'package:humming/looptap/widgets/shortcut_help.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/transport_bar.dart';
import 'package:provider/provider.dart';

import '../support/drum_grid_harness.dart';
import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

const _buttons = [
  'top-back',
  'top-metro',
  'top-count-in',
  'top-loop',
  'top-stop',
  'top-play',
  'top-record',
  'top-song-info',
  'top-bpm',
  'top-key',
  'top-song-settings',
  'top-undo',
  'top-redo',
  'top-more',
  'top-shortcuts',
  'top-export',
];

/// Pressed modifiers + [key], then release.
Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {bool ctrl = false, bool shift = false, bool settle = true}) async {
  if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  late Directory root;
  late _Store store;
  final topBarErrors = <String>[];

  setUp(() async {
    useOfflineTestFonts();
    root = await Directory.systemTemp.createTemp('humtrack_top_bar_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    store = _Store();
    LoopPrefs.instance.metro.value = false;
  });
  tearDown(() async {
    EditScreen.debugDesktopOverride = null;
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<Song> open(WidgetTester tester, Size size, {String locale = 'en', bool desktop = true, List<PitchNote> notes = const []}) async {
    EditScreen.debugDesktopOverride = desktop;
    topBarErrors.clear();
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      final text = d.toString();
      // Ahem test glyphs overflow unrelated fixed-width labels elsewhere in the
      // editor; only errors raised inside the top bar are this test's concern.
      if (text.contains('desktop_top_bar.dart')) topBarErrors.add(text);
      if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sec = Section(id: 'A', name: 'A', bars: 2)..tracks['melody'] = TrackData(notes: List.of(notes));
    final song = Song(id: 'top-bar', title: 'Top bar', bpm: 120, bars: 2, sections: [sec]);
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: EditScreen(song: song),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return song;
  }

  DesktopTopBar top(WidgetTester tester) => tester.widget<DesktopTopBar>(find.byType(DesktopTopBar));

  group('layout', () {
    for (final size in const [Size(960, 600), Size(1280, 720), Size(1920, 1080)]) {
      for (final locale in const ['ko', 'en']) {
        testWidgets('${size.width.toInt()}x${size.height.toInt()} $locale: 52 px bar, no bottom transport, '
            'every button inside the window, no top-bar overflow', (tester) async {
          await open(tester, size, locale: locale);
          final bar = tester.getRect(find.byKey(const ValueKey('desktop-top-bar')));
          expect(bar.height, DesktopTopBar.height);
          expect(bar.top, 0);
          expect(find.byType(TransportBar), findsNothing);
          for (final key in _buttons) {
            final f = find.byKey(ValueKey(key));
            expect(f, findsOneWidget, reason: key);
            final r = tester.getRect(f);
            expect(r.left >= 0 && r.right <= size.width && r.top >= bar.top && r.bottom <= bar.bottom, isTrue, reason: '$key $r');
            expect(r.width, greaterThan(0), reason: key);
          }
          for (final key in const ['top-back', 'top-metro', 'top-loop', 'top-undo', 'top-more', 'top-shortcuts']) {
            expect(tester.getSize(find.byKey(ValueKey(key))).width, greaterThanOrEqualTo(36), reason: key);
          }
          // every icon button has a tooltip
          for (final key in const ['top-back', 'top-metro', 'top-count-in', 'top-loop', 'top-stop', 'top-undo', 'top-redo', 'top-more', 'top-shortcuts']) {
            final f = find.byKey(ValueKey(key));
            final tips = find.descendant(of: f, matching: find.byType(Tooltip)).evaluate().length +
                find.ancestor(of: f, matching: find.byType(Tooltip)).evaluate().length;
            expect(tips, greaterThan(0), reason: key);
          }
          expect(topBarErrors, isEmpty);
          // the bar sits above the section bar; the old save / mixer icons are gone from it
          expect(find.descendant(of: find.byKey(const ValueKey('desktop-top-bar')), matching: find.byTooltip('Save')), findsNothing);
        });
      }
    }

    testWidgets('phone 844x390 keeps the old top bar and TransportBar', (tester) async {
      await open(tester, const Size(844, 390), desktop: false);
      expect(find.byType(DesktopTopBar), findsNothing);
      expect(find.byType(TransportBar), findsOneWidget);
    });

    testWidgets('the timeline header no longer repeats the shortcut hint', (tester) async {
      await open(tester, const Size(1280, 720));
      expect(find.textContaining('Space ▶/Ⅱ'), findsNothing);
      expect(find.byType(DesktopTimeline), findsOneWidget);
    });
  });

  group('controls drive the existing editor state (1280x720)', () {
    testWidgets('metronome, count-in, range loop, play/stop', (tester) async {
      await open(tester, const Size(1280, 720));
      final countIn = top(tester).countIn;
      await tester.tap(find.byKey(const ValueKey('top-metro')));
      await tester.pumpAndSettle();
      expect(LoopPrefs.instance.metro.value, isTrue);
      expect(top(tester).metro, isTrue);
      await tester.tap(find.byKey(const ValueKey('top-count-in')));
      await tester.pumpAndSettle();
      expect(top(tester).countIn, !countIn);
      await tester.tap(find.byKey(const ValueKey('top-loop')));
      await tester.pumpAndSettle();
      expect(top(tester).rangeLoop, isTrue);
      expect(tester.widget<Arrangement>(find.byType(Arrangement)).loopRange, isNotNull);
      await tester.tap(find.byKey(const ValueKey('top-play')));
      await tester.pump();
      expect(top(tester).playing, isTrue);
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('top-position')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('top-stop')));
      await tester.pumpAndSettle();
      expect(top(tester).playing, isFalse);
      LoopPrefs.instance.metro.value = false;
    });

    testWidgets('BPM: type a value (40–220 kept), stepper, undo; key sheet', (tester) async {
      await open(tester, const Size(1280, 720));
      await tester.tap(find.byKey(const ValueKey('top-bpm')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '300');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('40–220'), findsWidgets, reason: 'out of range stays in the dialog');
      await tester.enterText(find.byType(TextField).last, '140');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(top(tester).bpm, 140);
      expect(find.byKey(const ValueKey('top-bpm')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const ValueKey('top-bpm')), matching: find.text('140')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('top-undo')));
      await tester.pumpAndSettle();
      expect(top(tester).bpm, 120);
      // stepper in the song settings popover
      await tester.tap(find.byKey(const ValueKey('top-song-settings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('song-settings-popover')), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('song-settings-bpm')), matching: find.text('+')));
      await tester.pumpAndSettle();
      expect(top(tester).bpm, 121);
      await tester.tapAt(const Offset(5, 700)); // dismiss
      await tester.pumpAndSettle();
      // key sheet
      await tester.tap(find.byKey(const ValueKey('top-key')));
      await tester.pumpAndSettle();
      expect(find.text('Key & scale'), findsOneWidget);
    });

    testWidgets('BPM dialog answered after the editor closed underneath it: no error, no stale write', (tester) async {
      EditScreen.debugDesktopOverride = true;
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      addTearDown(() => FlutterError.onError = onError);
      final song = Song(id: 'bpm-close', title: 'Close', bpm: 120, bars: 2);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            navigatorKey: nav,
            locale: const Locale('en'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: const Scaffold(body: Text('songs')),
          ),
        ),
      );
      final editor = MaterialPageRoute<void>(builder: (_) => EditScreen(song: song));
      nav.currentState!.push(editor);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('top-bpm')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '150');
      nav.currentState!.removeRoute(editor); // the editor goes away under the dialog
      await tester.pumpAndSettle();
      expect(find.byType(DesktopTopBar), findsNothing);
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('songs'), findsOneWidget);
    });

    testWidgets('song settings popover: swing 0–60 %, section length 1|2|4, right-click opens it', (tester) async {
      final song = await open(tester, const Size(1280, 720));
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('top-song-info'))), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('song-settings-popover')), findsOneWidget);
      final slider = find.byKey(const ValueKey('song-settings-swing'));
      await tester.drag(slider, const Offset(400, 0));
      await tester.pumpAndSettle();
      expect(top(tester).swing, closeTo(0.6, 1e-9), reason: 'clamped at 60 %');
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('song-settings-bars')), matching: find.text('4')));
      await tester.pumpAndSettle();
      expect(top(tester).bars, 4);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).save();
      await tester.pumpAndSettle();
      expect(store.lastSaved!.swing, closeTo(0.6, 1e-9));
      expect(store.lastSaved!.sections.first.bars, 4);
      expect(song.id, store.lastSaved!.id);
    });

    testWidgets('record from the top bar; while recording Ctrl+L / Ctrl+M / F1 do nothing', (tester) async {
      await open(tester, const Size(1280, 720));
      if (top(tester).countIn) {
        await tester.tap(find.byKey(const ValueKey('top-count-in')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(const ValueKey('top-record')));
      await tester.pump();
      expect(top(tester).recording, isTrue);
      final loop = top(tester).rangeLoop;
      // recording animates continuously: step frames instead of settling
      await press(tester, LogicalKeyboardKey.keyL, ctrl: true, settle: false);
      expect(top(tester).rangeLoop, loop);
      await press(tester, LogicalKeyboardKey.keyM, ctrl: true, settle: false);
      expect(find.text('Mixer'), findsNothing);
      await press(tester, LogicalKeyboardKey.f1, settle: false);
      expect(find.byKey(const ValueKey('shortcut-help')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('top-stop')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(top(tester).recording, isFalse);
    });

    testWidgets('more menu (mixer, guided, clear), help button, F1 / Ctrl+/ / Ctrl+M / Ctrl+L', (tester) async {
      await open(tester, const Size(1280, 720));
      await tester.tap(find.byKey(const ValueKey('top-more')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('top-more-guide')), findsOneWidget);
      expect(find.byKey(const ValueKey('top-more-clear')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('top-more-mixer')));
      await tester.pumpAndSettle();
      expect(find.text('Mixer'), findsWidgets);
      Navigator.of(tester.element(find.text('Mixer').first)).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('top-shortcuts')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shortcut-help')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const ValueKey('shortcut-help')))).pop();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.f1);
      expect(find.byKey(const ValueKey('shortcut-help')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const ValueKey('shortcut-help')))).pop();
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.slash, ctrl: true);
      expect(find.byKey(const ValueKey('shortcut-help')), findsOneWidget);
      Navigator.of(tester.element(find.byKey(const ValueKey('shortcut-help')))).pop();
      await tester.pumpAndSettle();

      await press(tester, LogicalKeyboardKey.keyM, ctrl: true);
      expect(find.text('Mixer'), findsWidgets);
      Navigator.of(tester.element(find.text('Mixer').first)).pop();
      await tester.pumpAndSettle();

      expect(top(tester).rangeLoop, isFalse);
      await press(tester, LogicalKeyboardKey.keyL, ctrl: true);
      expect(top(tester).rangeLoop, isTrue);
      await press(tester, LogicalKeyboardKey.keyL, ctrl: true);
      expect(top(tester).rangeLoop, isFalse);
    });

    testWidgets('typing in the title field: no shortcut fires', (tester) async {
      await open(tester, const Size(1280, 720));
      await tester.tap(find.byKey(const ValueKey('top-title')));
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.keyL, ctrl: true);
      await press(tester, LogicalKeyboardKey.f1);
      await press(tester, LogicalKeyboardKey.space);
      expect(top(tester).rangeLoop, isFalse);
      expect(top(tester).playing, isFalse);
      expect(find.byKey(const ValueKey('shortcut-help')), findsNothing);
    });

    // Legato (StepGrid._canScope) acts on the selection, or on the whole track
    // when nothing is selected, so a focused piano roll in select/edit mode
    // with notes keeps Ctrl+L either way; elsewhere Ctrl+L is the range loop.
    for (final selectAll in [true, false]) {
      testWidgets('Ctrl+L on a focused piano roll (select/edit, '
          '${selectAll ? 'all selected' : 'nothing selected'}) = legato, not the loop', (tester) async {
        await open(
          tester,
          const Size(1280, 720),
          notes: [
            PitchNote(midi: 60, freq: 261.63, step: 0, dur: 2),
            PitchNote(midi: 62, freq: 293.66, step: 8, dur: 2),
          ],
        );
        tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
        await tester.pumpAndSettle();
        if (find.byType(StepGrid).evaluate().isEmpty) {
          tester
              .widget<GestureDetector>(find.ancestor(of: find.text('Grid'), matching: find.byType(GestureDetector)).first)
              .onTap!();
          await tester.pumpAndSettle();
        }
        tester.widget<TextButton>(find.byKey(const ValueKey('note-select'), skipOffstage: false)).onPressed!();
        await tester.pumpAndSettle();
        // focus the roll: click an empty spot of the lane (select mode = no new note)
        final lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
        final view = tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
        await tester.tapAt(Offset(lane.right - 8, view.top + 10));
        await tester.pumpAndSettle();
        expect(FocusManager.instance.primaryFocus?.debugLabel, contains('MIDI note editor'));
        if (selectAll) await press(tester, LogicalKeyboardKey.keyA, ctrl: true);
        final before = tester.widget<StepGrid>(find.byType(StepGrid)).notes.map((n) => n.soundingSteps).toList();
        await press(tester, LogicalKeyboardKey.keyL, ctrl: true);
        final after = tester.widget<StepGrid>(find.byType(StepGrid)).notes.map((n) => n.soundingSteps).toList();
        expect(top(tester).rangeLoop, isFalse);
        expect(after, isNot(before), reason: 'legato lengthened the first note');
        // the loop itself stays reachable from the top bar button
        await tester.tap(find.byKey(const ValueKey('top-loop')));
        await tester.pumpAndSettle();
        expect(top(tester).rangeLoop, isTrue);
      });
    }
  });

  group('editing shortcuts in the help = what the grids handle', () {
    Future<bool> send(WidgetTester tester, LogicalKeyboardKey key, {bool ctrl = false, bool shift = false}) async {
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      final handled = await tester.sendKeyDownEvent(key);
      await tester.sendKeyUpEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      return handled;
    }

    PitchNote at(int midi, int step) => PitchNote(midi: midi, freq: 261.63, step: step, dur: 2);

    /// A focused piano roll in select/edit mode with every precondition met:
    /// notes, a scale, a selection, a clipboard and the chance lane.
    Future<void> piano(WidgetTester tester, {required bool guitar}) async {
      // a fresh tree: re-pumping an equal MaterialApp would keep a sheet the
      // previous key opened
      await tester.pumpWidget(const SizedBox());
      await mountGrid(tester, [at(60, 0), at(64, 4), at(62, 8)], low: 58, high: 66, steps: 16, scaleRoot: 'C', scaleName: 'major', guitar: guitar);
      await tester.tapAt(gridPoint(tester, 14.5, 65, low: 58, high: 66, steps: 16));
      await tester.pump();
      await send(tester, LogicalKeyboardKey.keyA, ctrl: true);
      await send(tester, LogicalKeyboardKey.keyC, ctrl: true);
      final chance = find.byKey(const ValueKey('velocity-lane-chance'));
      if (chance.evaluate().isNotEmpty) {
        await tester.tap(chance);
        await tester.pump();
      }
    }

    Future<void> drums(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await mountDrums(tester, [
        DrumNote(kind: 'kick', step: 0, velocity: 90),
        DrumNote(kind: 'snare', step: 4, velocity: 90),
      ]);
      await tester.tapAt(drumPoint(tester, 14.5, 2));
      await tester.pump();
      await send(tester, LogicalKeyboardKey.keyA, ctrl: true);
      final chance = find.byKey(const ValueKey('drum-lane-chance'));
      if (chance.evaluate().isNotEmpty) {
        await tester.tap(chance);
        await tester.pump();
      }
    }

    bool listed(Set<EditShortcutContext> ctx, LogicalKeyboardKey key, bool ctrl, bool shift) => kEditShortcuts.any(
      (s) => ctx.contains(s.context) && s.matches(key, command: ctrl, shift: shift),
    );

    final candidates = [
      for (var k = LogicalKeyboardKey.keyA.keyId; k <= LogicalKeyboardKey.keyZ.keyId; k++) LogicalKeyboardKey(k),
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.delete,
      LogicalKeyboardKey.backspace,
      LogicalKeyboardKey.escape,
    ];
    const mods = [(false, false), (false, true), (true, false), (true, true)];

    testWidgets('piano roll + guitar: every listed key is handled', (tester) async {
      final missing = <String>[];
      for (final s in kEditShortcuts.where((s) => s.context != EditShortcutContext.drums)) {
        for (final key in s.keys) {
          await piano(tester, guitar: s.context == EditShortcutContext.guitar);
          if (!await send(tester, key, ctrl: s.command, shift: s.shift)) missing.add('${s.keysLabel(mac: false)} ${key.keyLabel} pressed=${HardwareKeyboard.instance.logicalKeysPressed} focus=${FocusManager.instance.primaryFocus}');
        }
      }
      expect(missing, isEmpty);
    });

    testWidgets('piano roll + guitar: every handled key is listed', (tester) async {
      final unlisted = <String>[];
      await piano(tester, guitar: true);
      for (final key in candidates) {
        for (final (ctrl, shift) in mods) {
          if (await send(tester, key, ctrl: ctrl, shift: shift)) {
            if (!listed({EditShortcutContext.pianoRoll, EditShortcutContext.guitar}, key, ctrl, shift)) {
              unlisted.add('${key.keyLabel} ctrl=$ctrl shift=$shift');
            }
            await piano(tester, guitar: true); // the key may have changed notes / opened a sheet
          }
        }
      }
      expect(unlisted, isEmpty);
    });

    testWidgets('drum grid: listed = handled', (tester) async {
      final missing = <String>[];
      for (final s in kEditShortcuts.where((s) => s.context == EditShortcutContext.drums)) {
        for (final key in s.keys) {
          await drums(tester);
          if (!await send(tester, key, ctrl: s.command, shift: s.shift)) missing.add('${s.keysLabel(mac: false)} ${key.keyLabel} pressed=${HardwareKeyboard.instance.logicalKeysPressed} focus=${FocusManager.instance.primaryFocus}');
        }
      }
      expect(missing, isEmpty);
      final unlisted = <String>[];
      await drums(tester);
      for (final key in candidates) {
        for (final (ctrl, shift) in mods) {
          if (await send(tester, key, ctrl: ctrl, shift: shift)) {
            if (!listed({EditShortcutContext.drums}, key, ctrl, shift)) unlisted.add('${key.keyLabel} ctrl=$ctrl shift=$shift');
            await drums(tester);
          }
        }
      }
      expect(unlisted, isEmpty);
    });
  });

  group('shortcut catalog = registered shortcuts = help', () {
    testWidgets('every catalog entry fires exactly its own command; the old ones are kept', (tester) async {
      final fired = <DesktopShortcutId>[];
      await tester.pumpWidget(MaterialApp(
        home: DesktopCommands(
          enabled: true,
          play: () => fired.add(DesktopShortcutId.play),
          record: () => fired.add(DesktopShortcutId.record),
          save: () => fired.add(DesktopShortcutId.save),
          undo: () => fired.add(DesktopShortcutId.undo),
          redo: () => fired.add(DesktopShortcutId.redo),
          groove: () => fired.add(DesktopShortcutId.groove),
          duplicateLinked: () => fired.add(DesktopShortcutId.duplicateLinked),
          rangeLoop: () => fired.add(DesktopShortcutId.rangeLoop),
          mixer: () => fired.add(DesktopShortcutId.mixer),
          help: () => fired.add(DesktopShortcutId.help),
          child: const Scaffold(body: SizedBox.expand()),
        ),
      ));
      await tester.pump();
      for (final s in kDesktopShortcuts) {
        fired.clear();
        await press(tester, s.key, ctrl: s.command, shift: s.shift);
        expect(fired, [s.id], reason: s.keysLabel(mac: false));
      }
      // the shortcuts that existed before stage 1, written out by hand
      const legacy = [
        (LogicalKeyboardKey.space, false, false, DesktopShortcutId.play),
        (LogicalKeyboardKey.keyS, true, false, DesktopShortcutId.save),
        (LogicalKeyboardKey.keyR, true, true, DesktopShortcutId.record),
        (LogicalKeyboardKey.keyZ, true, false, DesktopShortcutId.undo),
        (LogicalKeyboardKey.keyZ, true, true, DesktopShortcutId.redo),
        (LogicalKeyboardKey.keyG, true, false, DesktopShortcutId.groove),
        (LogicalKeyboardKey.keyD, true, true, DesktopShortcutId.duplicateLinked),
      ];
      for (final (key, ctrl, shift, id) in legacy) {
        fired.clear();
        await press(tester, key, ctrl: ctrl, shift: shift);
        expect(fired, [id], reason: '$key ctrl=$ctrl shift=$shift');
      }
      // near misses do nothing
      for (final (key, ctrl, shift) in const [
        (LogicalKeyboardKey.keyS, true, true),
        (LogicalKeyboardKey.keyL, false, false),
        (LogicalKeyboardKey.keyM, false, false),
        (LogicalKeyboardKey.slash, false, false),
      ]) {
        fired.clear();
        await press(tester, key, ctrl: ctrl, shift: shift);
        expect(fired, isEmpty, reason: '$key ctrl=$ctrl shift=$shift');
      }
    });

    testWidgets('the help window lists every registered command with its keys', (tester) async {
      useOfflineTestFonts();
      await tester.pumpWidget(MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => showShortcutHelp(context), child: const Text('help')),
          ),
        ),
      ));
      await tester.tap(find.text('help'));
      await tester.pumpAndSettle();
      final ids = {for (final s in kDesktopShortcuts) s.id};
      expect(ids, DesktopShortcutId.values.toSet(), reason: 'every command has a registered key');
      for (final id in ids) {
        final row = find.byKey(ValueKey('shortcut-help-${id.name}'));
        expect(row, findsOneWidget, reason: id.name);
        final keys = [for (final s in kDesktopShortcuts) if (s.id == id) s.keysLabel(mac: false)].join(', ');
        expect(find.descendant(of: row, matching: find.text(keys)), findsOneWidget, reason: id.name);
      }
      expect(find.byKey(const ValueKey('shortcut-help-help')), findsOneWidget);
      expect(find.text('F1, Ctrl+/'), findsOneWidget);
      for (final (i, s) in kEditShortcuts.indexed) {
        final row = find.byKey(ValueKey('shortcut-help-edit-$i'), skipOffstage: false);
        expect(row, findsOneWidget, reason: s.keysLabel(mac: false));
        expect(find.descendant(of: row, matching: find.text(s.keysLabel(mac: false)), skipOffstage: false), findsOneWidget);
      }
    });
  });
}
