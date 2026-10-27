// gt-002 UI: guitar-only string actions in the expanded panel, the
// unassignable count + highlight, one undo per action, shortcuts under a
// mounted DesktopInstrument, and editor integration (undo/redo, save/load,
// linked section, copy/paste, live gates == export, Stop, groove).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_instrument.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

PitchNote at(int midi, int step, {int dur = 1}) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

/// Seven simultaneous notes (one more than strings) at step 1.
List<PitchNote> sevenChord() => [
  for (final m in [40, 45, 50, 55, 59, 64, 69]) at(m, 1, dur: 2),
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

Future<void> panelTap(WidgetTester tester, String key) async {
  await tapGridButton(tester, 'stroke-more');
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

List<Map<String, dynamic>> js(Iterable<PitchNote> notes) => [
  for (final n in notes) n.toJson(),
];

void main() {
  setUp(() {
    LoopPrefs.instance.strokePattern.value = 'down';
    LoopPrefs.instance.keyboardBindings.value = {};
  });

  testWidgets('string actions live only in the guitar panel', (tester) async {
    await mountGrid(tester, sevenChord());
    expect(find.byKey(const ValueKey('stroke-more')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await mountGrid(tester, sevenChord(), guitar: true);
    await tapGridButton(tester, 'stroke-more');
    for (final k in [
      'guitar-assign',
      'guitar-ring',
      'guitar-ring-revert',
      'guitar-string-view',
      'guitar-string-1',
      'guitar-string-auto',
    ]) {
      expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const ValueKey('guitar-groove-hint')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await mountGrid(tester, sevenChord(), guitar: true, grooved: true);
    await tapGridButton(tester, 'stroke-more');
    final hint = find.byKey(const ValueKey('guitar-groove-hint'));
    await tester.ensureVisible(hint);
    expect(hint, findsOneWidget);
  });

  testWidgets('assign / ring / revert are one undo each; unassignable notes '
      'are counted and highlighted', (tester) async {
    final key = await mountGrid(tester, sevenChord(), guitar: true);
    final state = key.currentState!;
    await panelTap(tester, 'guitar-assign');
    expect(state.commits, 1);
    expect(state.notes.where((n) => n.guitarString != null), hasLength(6));
    expect(state.notes.map((n) => n.midi), sevenChord().map((n) => n.midi));
    final count = find.byKey(const ValueKey('guitar-unassigned-count'));
    await tester.ensureVisible(count);
    expect(find.text('No string 1'), findsOneWidget);
    // the highlight set reaches the painter surface
    final warn = tester.widget<PitchGridSurface>(find.byType(PitchGridSurface));
    expect(warn.warnNotes.map((n) => n.midi), [69]);
    expect(warn.stringMarks, isTrue);
    final assigned = js(state.notes);
    await panelTap(tester, 'guitar-ring');
    expect(state.commits, 2);
    expect(state.notes.where((n) => n.ringBaseDur != null), isNotEmpty);
    await panelTap(tester, 'guitar-ring-revert');
    expect(state.commits, 3);
    expect(js(state.notes), assigned);
    // tapping the count selects the flagged note
    await tester.ensureVisible(count);
    await tester.pumpAndSettle();
    await tester.tap(count);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
  });

  testWidgets('manual string: only playable strings; one undo', (tester) async {
    final key = await mountGrid(tester, [at(64, 1, dur: 2)], guitar: true);
    await tester.tapAt(gridPoint(tester, 1.5, 64));
    await tester.pump();
    await tapGridButton(tester, 'stroke-more');
    final six = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('guitar-string-6')),
    );
    expect(six.onPressed, isNull, reason: 'E4 is fret 24 on string 6');
    final two = find.byKey(const ValueKey('guitar-string-2'));
    await tester.ensureVisible(two);
    await tester.pumpAndSettle();
    await tester.tap(two);
    await tester.pumpAndSettle();
    final n = key.currentState!.notes.single;
    expect(key.currentState!.commits, 1);
    expect(n.guitarString, 2);
    expect(n.stringLocked, isTrue);
    expect(noteFret(n), 5);
  });

  testWidgets('Ctrl+Shift+G / Ctrl+Shift+I reach the grid under a '
      'DesktopInstrument without playing notes', (tester) async {
    var hits = 0;
    final arp = [
      at(40, 0),
      at(47, 1),
      at(52, 2),
      at(56, 3),
    ];
    final key = await mountGrid(
      tester,
      arp,
      guitar: true,
      wrap:
          (grid) => DesktopInstrument(
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
    await tester.tapAt(gridPoint(tester, 7.5, 60)); // focus, empty spot
    await tester.pump();
    await ctrlShift(tester, LogicalKeyboardKey.keyG);
    expect(state.commits, 1);
    expect(state.notes.map((n) => n.guitarString), [6, 5, 4, 3]);
    await ctrlShift(tester, LogicalKeyboardKey.keyI);
    expect(state.commits, 2);
    expect(state.notes.every((n) => n.endSteps == 8), isTrue);
    expect(hits, 0, reason: 'no instrument note played');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(hits, 1, reason: 'the instrument itself is live');
  });

  testWidgets('non-guitar tracks ignore the string shortcuts', (tester) async {
    final key = await mountGrid(tester, [at(60, 1)]);
    await tester.tapAt(gridPoint(tester, 1.5, 60));
    await tester.pump();
    await ctrlShift(tester, LogicalKeyboardKey.keyG);
    await ctrlShift(tester, LogicalKeyboardKey.keyI);
    expect(key.currentState!.commits, 0);
    expect(key.currentState!.notes.single.guitarString, isNull);
  });

  testWidgets('copy/paste in the grid keeps string and ring fields', (
    tester,
  ) async {
    final ringed =
        applyRing(
          assignStrings([at(60, 0), at(64, 1)], {}).notes,
          {},
          rangeEnd: 3,
        ).notes;
    final key = await mountGrid(tester, ringed, guitar: true);
    await tester.tapAt(gridPoint(tester, .5, 60));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final notes = key.currentState!.notes;
    expect(notes, hasLength(4));
    for (var i = 0; i < 2; i++) {
      final a = notes[i].toJson()..remove('step');
      final b = notes[i + 2].toJson()..remove('step');
      expect(b, a);
      expect(notes[i + 2].ringBaseDur, isNotNull);
    }
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
      root = await Directory.systemTemp.createTemp('humtrack_strings_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopAudio.instance.debugOnPlayPitch = null;
      LoopAudio.instance.debugOnPitchGate = null;
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    /// E-shape arpeggio, then 45 at 4 (re-plucks string 5 after 47).
    List<PitchNote> arpeggio() => [
      at(40, 0),
      at(47, 1),
      at(52, 2),
      at(56, 3),
      at(45, 4),
    ];

    Future<_Store> mountEditor(
      WidgetTester tester, {
      List<PitchNote>? notes,
      bool grooved = false,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      addTearDown(() => FlutterError.onError = onError);
      final store = _Store();
      final sec = Section(id: 'A', name: 'A', bars: 1)
        ..tracks['melody'] = TrackData(notes: notes ?? arpeggio());
      final song = Song(
        id: 'g2',
        title: 'Strings',
        bpm: 120,
        bars: 1,
        sections: [sec],
        instruments: {'melody': 25},
        trackGrooves:
            grooved
                ? {'melody': const GrooveAssign(grooveId: 'builtin:laidback')}
                : null,
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
      tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
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

    /// Assign, then ring the whole track, as two editor commits.
    Future<void> assignAndRing(WidgetTester tester) async {
      var g = grid(tester);
      expect(g.guitar, isTrue);
      final a = assignStrings(List.of(g.notes), {}).notes;
      expect(g.onEdit!(List.of(g.notes), a), isTrue);
      await tester.pump();
      g = grid(tester);
      final r = applyRing(List.of(g.notes), {}, rangeEnd: 16).notes;
      expect(g.onEdit!(List.of(g.notes), r), isTrue);
      await tester.pump();
    }

    testWidgets('undo/redo, linked section, save/load keep the fields', (
      tester,
    ) async {
      final store = await mountEditor(tester);
      await assignAndRing(tester);
      final ringed = js(grid(tester).notes);
      expect(grid(tester).notes.map((n) => n.endSteps), [16, 4, 16, 16, 16]);
      commands(tester).undo();
      await tester.pump();
      expect(grid(tester).notes.every((n) => n.ringBaseDur == null), isTrue);
      expect(grid(tester).notes.every((n) => n.guitarString != null), isTrue);
      commands(tester).undo();
      await tester.pump();
      expect(js(grid(tester).notes), js(arpeggio()));
      commands(tester).redo();
      commands(tester).redo();
      await tester.pump();
      expect(js(grid(tester).notes), ringed);
      commands(tester).duplicateLinked!();
      await tester.pumpAndSettle();
      await tester.runAsync(() async => commands(tester).save());
      await tester.pump();
      final loaded = Song.fromJson(
        jsonDecode(jsonEncode(store.lastSaved!.toJson()))
            as Map<String, dynamic>,
      );
      expect(loaded.sections, hasLength(2));
      for (final s in loaded.sections) {
        expect(js(s.tracks['melody']!.pitchNotes), ringed);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final grooved in [false, true]) {
      testWidgets('live gates == export lengths; Stop silences pending '
          'notes${grooved ? ' (grooved)' : ''}', (tester) async {
        await mountEditor(tester, grooved: grooved);
        await assignAndRing(tester);
        final gates = <int, double>{};
        LoopAudio.instance.debugOnPitchGate =
            (ch, midi, durSec) => gates[midi] = durSec;
        commands(tester).play();
        for (var i = 0; i < 70; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        commands(tester).play(); // stop
        await tester.pump();
        const sps = 60 / 120 / kStepsPerBeat;
        final sec = Section(id: 'A', name: 'A', bars: 1)
          ..tracks['melody'] = TrackData(notes: grid(tester).notes);
        final flat =
            flattenSong(
              [sec],
              groove:
                  grooved
                      ? const GrooveContext(
                        trackGrooves: {
                          'melody': GrooveAssign(grooveId: 'builtin:laidback'),
                        },
                      )
                      : null,
            ).melody;
        expect(gates.keys.toSet(), {40, 47, 52, 56, 45});
        for (final x in flat) {
          final exported = (x.endSteps.clamp(0, 16) - x.startSteps) * sps;
          // a gate clamped at the section end is measured from the (frame-
          // late) trigger, so it is shorter by that lateness and still ends
          // at the section end; unclamped gates are exact
          final clamped = x.endSteps >= 16 - 1e-9;
          expect(
            gates[x.midi],
            closeTo(exported, clamped ? .011 : .002),
            reason: '${x.midi}',
          );
        }
        // Stop: nothing more sounds
        final before = gates.length;
        gates.clear();
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(gates, isEmpty, reason: 'stopped ($before played)');
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('a stroke-converted hit: assign + ring keep the stroke', (
      tester,
    ) async {
      await mountEditor(
        tester,
        notes: [for (final m in [40, 45, 50, 55, 59, 64]) at(m, 0, dur: 2)],
      );
      var g = grid(tester);
      final s = applyGuitarStroke(List.of(g.notes), {}, const StrokeSpec.down(), bpm: 120).notes;
      expect(g.onEdit!(List.of(g.notes), s), isTrue);
      await tester.pump();
      await assignAndRing(tester);
      g = grid(tester);
      expect(g.notes.map((n) => n.guitarString), [6, 5, 4, 3, 2, 1]);
      expect(g.notes.every((n) => n.stroke != null), isTrue);
      expect(g.notes.every((n) => n.endSteps == 16), isTrue);
      expect(
        [for (final n in g.notes) n.startSteps],
        [for (final n in s) n.startSteps],
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
