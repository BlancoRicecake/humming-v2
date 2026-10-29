// gt-001 guitar stroke UI: guitar-only control, one undo per apply,
// shortcuts under a mounted DesktopInstrument, and editor integration
// (undo/redo, save/load, Stop cancels pending strings).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/desktop_instrument.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

PitchNote at(int midi, int step, {int dur = 2}) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

List<PitchNote> twoChords() => [
  for (final m in [60, 62, 64]) at(m, 1),
  for (final m in [60, 64]) at(m, 4),
];

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

Future<void> ctrlShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  setUp(() {
    LoopPrefs.instance.strokePattern.value = 'down';
    LoopPrefs.instance.keyboardBindings.value = {};
  });

  testWidgets('the stroke control appears only on guitar tracks', (tester) async {
    await mountGrid(tester, twoChords());
    expect(find.byKey(const ValueKey('stroke-down')), findsNothing);
    expect(find.byKey(const ValueKey('stroke-more')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await mountGrid(tester, twoChords(), guitar: true);
    for (final k in [
      'stroke-down',
      'stroke-up',
      'stroke-pattern-downUp',
      'stroke-pattern-folk',
      'stroke-more',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
  });

  testWidgets(
    'the "기타 연주" toolbar button is always visible on guitar tracks and opens the panel',
    (tester) async {
      await mountGrid(tester, twoChords());
      expect(find.byKey(const ValueKey('note-guitar-tools')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      final key = await mountGrid(tester, twoChords(), guitar: true);
      // Draw (input) mode: the inspector is hidden, the toolbar button is not.
      await tapGridButton(tester, 'note-draw');
      expect(find.byKey(const ValueKey('stroke-more')), findsNothing);
      expect(find.byKey(const ValueKey('note-guitar-tools')), findsOneWidget);
      await tapGridButton(tester, 'note-guitar-tools');
      final hint = tester.widget<Text>(
        find.byKey(const ValueKey('guitar-panel-scope')),
      );
      expect(hint.data, anyOf(contains('트랙 전체'), contains('whole track')));
      await tester.tap(find.byKey(const ValueKey('stroke-panel-down')));
      await tester.pumpAndSettle();
      final state = key.currentState!;
      expect(state.commits, 1);
      // nothing selected = whole track: every chord got a down stroke
      expect(
        state.notes.every((n) => n.stroke?.dir == StrokeDir.down),
        isTrue,
      );
      // Select mode: still there, and the hint counts the selection.
      await tapGridButton(tester, 'note-select');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note-guitar-tools')), findsOneWidget);
      await tapGridButton(tester, 'note-guitar-tools');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('guitar-panel-scope')))
            .data,
        anyOf(contains('5'), contains('selected')),
      );
    },
  );

  testWidgets('a pattern is one undo; the panel reverts exactly', (tester) async {
    final src = twoChords();
    final key = await mountGrid(tester, src, guitar: true);
    await tapGridButton(tester, 'stroke-pattern-downUp');
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(state.notes.where((n) => n.step == 1).every((n) => n.stroke!.dir == StrokeDir.down), isTrue);
    expect(state.notes.where((n) => n.step == 4).every((n) => n.stroke!.dir == StrokeDir.up), isTrue);
    expect(LoopPrefs.instance.strokePattern.value, 'downUp');
    await tapGridButton(tester, 'stroke-more');
    expect(find.byKey(const ValueKey('stroke-falloff')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stroke-panel-revert')));
    await tester.pumpAndSettle();
    expect(state.commits, 2);
    expect(
      [for (final n in state.notes) n.toJson()],
      [for (final n in src) n.toJson()],
    );
  });

  testWidgets(
    'Ctrl+Shift+↓/↑ reach the grid under a DesktopInstrument without playing '
    'notes, and win over the chance lane', (tester) async {
      var hits = 0;
      final key = await mountGrid(
        tester,
        twoChords(),
        guitar: true,
        wrap:
            (grid) => DesktopInstrument(
              // the editor's grid mode: the grid owns pointer focus
              capturePointerFocus: false,
              group: 'piano',
              identity: 'melody',
              labels: const ['C', 'D', 'E'],
              onDown: (_) {
                hits++;
                return () {};
              },
              child: grid,
            ),
      );
      final state = key.currentState!;
      await tester.tapAt(gridPoint(tester, 1.5, 60)); // select + focus
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA); // select all
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await ctrlShift(tester, LogicalKeyboardKey.arrowDown);
      expect(state.commits, 1);
      expect(state.notes.every((n) => n.stroke?.dir == StrokeDir.down), isTrue);
      // chance lane on: Ctrl+Shift+↑ is still the up stroke, chance untouched
      await tester.tap(find.byKey(const ValueKey('velocity-lane-chance')));
      await tester.pump();
      await ctrlShift(tester, LogicalKeyboardKey.arrowUp);
      expect(state.commits, 2);
      expect(state.notes.every((n) => n.stroke?.dir == StrokeDir.up), isTrue);
      expect(state.notes.every((n) => n.chance == 1), isTrue);
      expect(hits, 0, reason: 'no instrument note played');
      // the instrument itself is live: a plain key still plays
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(hits, 1);
    },
  );

  testWidgets('non-guitar tracks keep Ctrl+Shift+↑ for the chance lane', (
    tester,
  ) async {
    final key = await mountGrid(tester, [at(60, 1)]);
    await tester.tap(find.byKey(const ValueKey('velocity-lane-chance')));
    await tester.pump();
    await tester.tapAt(gridPoint(tester, 1.5, 60));
    await tester.pump();
    await ctrlShift(tester, LogicalKeyboardKey.arrowDown);
    final state = key.currentState!;
    expect(state.notes.single.stroke, isNull);
    expect(state.notes.single.chance, closeTo(.9, 1e-9));
  });

  group('editor', () {
    late Directory root;
    setUp(() async {
      useOfflineTestFonts();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'xyz.luan/audioplayers',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
      }
      root = await Directory.systemTemp.createTemp('humtrack_stroke_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopAudio.instance.debugOnPlayPitch = null;
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    Future<_Store> mountEditor(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      addTearDown(() => FlutterError.onError = onError);
      final store = _Store();
      final sec = Section(id: 'A', name: 'A', bars: 1)
        ..tracks['melody'] = TrackData(
          notes: [for (final m in [52, 56, 59, 64]) at(m, 0, dur: 4)],
        );
      final song = Song(
        id: 'g',
        title: 'Strum',
        bpm: 120,
        bars: 1,
        sections: [sec],
        instruments: {'melody': 25},
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: song),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // select the melody track, then switch it to the piano roll
      // ui-001 stage 3: arrange view, double-click the track = its editor
      await editTrack(tester, 'melody');
      await tester.pumpAndSettle();
      tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.text('Grid'),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!();
      await tester.pumpAndSettle();
      expect(find.byType(StepGrid), findsOneWidget);
      return store;
    }

    DesktopCommands commands(WidgetTester tester) =>
        tester.widget<DesktopCommands>(find.byType(DesktopCommands));
    StepGrid grid(WidgetTester tester) =>
        tester.widget<StepGrid>(find.byType(StepGrid));

    void convert(WidgetTester tester) {
      final g = grid(tester);
      expect(g.guitar, isTrue);
      expect(g.bpm, 120);
      final before = List.of(g.notes);
      final edit = applyGuitarStroke(before, {}, const StrokeSpec.down(), bpm: g.bpm);
      expect(g.onEdit!(before, edit.notes), isTrue);
    }

    testWidgets('undo/redo and save/load keep the converted notes', (
      tester,
    ) async {
      final store = await mountEditor(tester);
      convert(tester);
      await tester.pump();
      final converted = [for (final n in grid(tester).notes) n.toJson()];
      expect(grid(tester).notes.every((n) => n.stroke != null), isTrue);
      commands(tester).undo();
      await tester.pump();
      expect(grid(tester).notes.every((n) => n.stroke == null), isTrue);
      commands(tester).redo();
      await tester.pump();
      expect([for (final n in grid(tester).notes) n.toJson()], converted);
      await tester.runAsync(() async => commands(tester).save());
      await tester.pump();
      final saved = store.lastSaved!;
      final loaded = Song.fromJson(
        jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>,
      );
      expect(
        [
          for (final n in loaded.sections.single.tracks['melody']!.pitchNotes)
            n.toJson(),
        ],
        converted,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('live plays the converted strings; Stop cancels pending ones', (
      tester,
    ) async {
      await mountEditor(tester);
      convert(tester);
      await tester.pump();
      final played = <(int, int?)>[];
      LoopAudio.instance.debugOnPlayPitch =
          (ch, midi, velocity, vol) => played.add((midi, velocity));
      // stop right after the hit's first string: the later ones never sound
      commands(tester).play();
      await tester.pump();
      expect(played, [(52, 100)]);
      commands(tester).play(); // stop
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(played, [(52, 100)]);
      // a full pass of the hit: every string, low → high, at its velocity
      // (the converted data — no legacy strum on top)
      played.clear();
      commands(tester).play();
      await tester.pump();
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(played, [(52, 100), (56, 94), (59, 88), (64, 82)]);
      commands(tester).play(); // stop
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
