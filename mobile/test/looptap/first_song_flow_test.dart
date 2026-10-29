import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/screens/songs_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/desktop_section_band.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/first_song_card.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/services/product_analytics.dart';
import 'package:provider/provider.dart';

class _Sink implements ProductAnalyticsSink {
  final events = <(String, Map<String, Object>)>[];
  @override
  Future<void> track(String name, Map<String, Object> p) async =>
      events.add((name, p));
  @override
  Future<void> initialize() async {}
  @override
  Future<void> reset() async {}
  @override
  Future<void> setCollectionEnabled(bool enabled) async {}
  @override
  Future<void> setContext(Map<String, Object> context) async {}
  @override
  Future<void> setUserId(String? id) async {}
}

class _Store extends LoopStore {
  Future<void>? operation;
  bool memoryOnly = false;
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) {
    lastSaved = song;
    return operation = memoryOnly ? Future<void>.value() : super.upsert(song);
  }

  @override
  Future<void> sweepVocals() => operation = super.sweepVocals();
  @override
  bool get loaded => true;
}

void main() {
  final sink = _Sink();
  setUpAll(() {
    ProductAnalytics.instance.installSinks([sink]);
  });
  late Directory root;
  late _Store store;
  setUp(() async {
    useOfflineTestFonts();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
    root = await Directory.systemTemp.createTemp('humtrack_first_song_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    store = _Store();
    sink.events.clear();
  });
  tearDown(() async {
    store.dispose();
    LoopStorage.rootOverride = null;
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    final resolved = await root.resolveSymbolicLinks();
    if (!resolved.startsWith(
      '$temp${Platform.pathSeparator}humtrack_first_song_',
    )) {
      throw StateError('Unexpected cleanup path');
    }
    await root.delete(recursive: true);
  });

  Future<void> showHome(WidgetTester tester, String lang) async {
    await tester.binding.setSurfaceSize(const Size(800, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          locale: Locale(lang),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const SongsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final lang in ['en', 'ko']) {
    testWidgets(
      '$lang guest starts before demos with no mode or login dialog',
      (tester) async {
        await tester.runAsync(
          () => store.upsert(Song(id: 'seed-a', title: 'Demo')),
        );
        await showHome(tester, lang);
        expect(find.byType(FirstSongCard), findsOneWidget);
        expect(
          tester.getTopLeft(find.byType(FirstSongCard)).dx,
          lessThan(tester.getTopLeft(find.text('Demo')).dx),
        );
        expect(
          sink.events.where((e) => e.$1 == ProductEvent.firstSongPromptViewed),
          hasLength(1),
        );
        await tester.tap(find.byKey(const ValueKey('first-song-start')));
        await tester.pumpAndSettle();
        expect(find.byType(SimpleDialog), findsNothing);
        expect(find.byType(GuidedHumPanel), findsOneWidget);
        expect(store.isSignedIn, isFalse);
        expect(
          tester.widget<EditScreen>(find.byType(EditScreen)).guidedEntrySource,
          'first_song',
        );
        await tester.runAsync(() async {
          await tester.tap(find.byIcon(Icons.arrow_back));
          await store.operation;
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(userSongCount(store.songs), 0);
        final exit = sink.events.lastWhere(
          (e) => e.$1 == ProductEvent.guidedExited,
        );
        expect(exit.$2['stage'], 'empty');
        expect(
          sink.events.where((e) => e.$1 == ProductEvent.guidedSongSaved),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'returning creator keeps mode chooser; first-song card disappears after saving',
    (tester) async {
      await tester.runAsync(
        () => store.upsert(Song(id: 'mine', title: 'My song')),
      );
      await showHome(tester, 'en');
      expect(find.byType(FirstSongCard), findsNothing);
      await tester.tap(find.text('New song'));
      await tester.pumpAndSettle();
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.text('Start with a hum'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('guest content saves on back and remains after reload', (
    tester,
  ) async {
    final song = store.createNew();
    song.sections.first.tracks['melody']!.pitchNotes.add(
      PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4),
    );
    await showHome(tester, 'en');
    final context = tester.element(find.byType(SongsScreen));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => EditScreen(
              song: song,
              guidedStart: true,
              guidedEntrySource: 'first_song',
            ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.arrow_back));
      await store.operation;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(store.isSignedIn, isFalse);
    final saved =
        sink.events.where((e) => e.$1 == ProductEvent.guidedSongSaved).toList();
    expect(saved, hasLength(1));
    expect(saved.single.$2['save_method'], 'back');
    expect(
      sink.events
          .lastWhere((e) => e.$1 == ProductEvent.guidedExited)
          .$2['stage'],
      'saved',
    );
    expect(
      (await tester.runAsync(
        LoopStorage.load,
      ))!.single.sections.first.tracks['melody']!.pitchNotes,
      hasLength(1),
    );
    expect(find.byType(FirstSongCard), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('precise grid edit survives editor undo and redo', (
    tester,
  ) async {
    store.memoryOnly = true;
    // Ahem's wide glyphs otherwise overflow the unrelated fixed-width BPM label.
    tester.platformDispatcher.textScaleFactorTestValue = .9;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final song = Song(
      id: 'precise-edit',
      title: 'MIDI edit',
      key: 'C',
      scale: 'chromatic',
      sections: [Section(id: 'precise-section', name: 'A')],
    );
    final source = PitchNote(
      midi: 60,
      freq: 261.625565,
      step: 2,
      dur: 5,
      velocity: 47,
      offsetSteps: .3,
      durationSteps: 4.4,
      sourceMidi: 61,
      confidence: .72,
      assisted: true,
    );
    song.sections.single.tracks['melody']!
      ..label = 'Imported MIDI'
      ..pitchNotes.add(source);
    await showHome(tester, 'en');
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    Navigator.of(
      tester.element(find.byType(SongsScreen)),
    ).push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: song)));
    await tester.pumpAndSettle();
    // ui-001 stage 3: arrange view, double-click the track = its editor
    await editTrack(tester, 'melody');
    await tester.pumpAndSettle();
    if (find.byType(StepGrid).evaluate().isEmpty) {
      await tester.tap(find.text('Grid'));
      await tester.pumpAndSettle();
    }
    StepGrid grid() => tester.widget<StepGrid>(find.byType(StepGrid));
    final rows = grid().ladder.map((n) => n.midi).toList();
    expect(rows, List.generate(128, (i) => i));
    grid().onPlace(grid().ladder.last, 12, 12);
    await tester.pump();
    expect(grid().ladder.map((n) => n.midi), rows);
    tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
    await tester.pump();
    final rung = grid().ladder.firstWhere((n) => n.midi == 60);
    grid().onErase(rung, 4);
    await tester.pump();
    final edited = grid().notes.map((n) => n.toJson()).toList();
    expect(grid().notes, hasLength(2));
    for (final note in grid().notes) {
      expect(note.velocity, 47);
      expect(note.sourceMidi, 61);
      expect(note.confidence, .72);
      expect(note.assisted, isTrue);
    }
    expect(grid().notes.first.startSteps, closeTo(2.3, 1e-10));
    expect(grid().notes.last.endSteps, closeTo(6.7, 1e-10));
    tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
    await tester.pump();
    expect(grid().notes.single.toJson(), source.toJson());
    tester.widget<DesktopCommands>(find.byType(DesktopCommands)).redo();
    await tester.pump();
    expect(grid().notes.map((n) => n.toJson()).toList(), edited);
    // An immediate new edit after redo must start a fresh undo group.
    grid().onPlace(rung, 6, 8);
    await tester.pump();
    final extended = grid().notes.singleWhere((n) => n.startSteps == 5);
    expect(extended.endSteps, 9);
    expect(extended.velocity, 47);
    expect(extended.sourceMidi, 61);
    expect(grid().notes.first.toJson(), edited.first);
    tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
    await tester.pump();
    expect(grid().notes.map((n) => n.toJson()).toList(), edited);
    grid().onErase(rung, 3);
    await tester.pump();
    final branched = grid().notes.map((n) => n.toJson()).toList();
    tester.widget<DesktopCommands>(find.byType(DesktopCommands)).redo();
    await tester.pump();
    expect(grid().notes.map((n) => n.toJson()).toList(), branched);
    // Exercise the new editor through its focused keyboard route and the real
    // screen transaction callback, then verify undo restores every field.
    final lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final row = grid().ladder.reversed.toList().indexWhere((r) => r.midi == 60);
    await tester.tapAt(
      Offset(
        lane.left + lane.width * 5.5 / grid().steps,
        lane.top + lane.height * (row + .5) / grid().ladder.length,
      ),
    );
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'MIDI note editor');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(
      grid().notes.map((n) => n.startSteps),
      contains(6),
      reason: 'Keyboard move should use the selected grid note',
    );
    final moved = grid().notes.singleWhere((n) => n.startSteps == 6);
    expect(moved.velocity, 47);
    expect(moved.durationSteps, closeTo(1.7, 1e-10));
    tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
    await tester.pump();
    expect(grid().notes.map((n) => n.toJson()).toList(), branched);
    expect(
      song.sections.single.tracks['melody']!.pitchNotes.single.toJson(),
      source.toJson(),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() async {
      await store.operation;
    });
  });

  testWidgets(
    'Solo comparison preserves mutes and a live phrase stays inside its loop',
    (tester) async {
      store.memoryOnly = true;
      tester.platformDispatcher.textScaleFactorTestValue = .7;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final song = Song(
        id: 'audition',
        title: 'Compare',
        bpm: 120,
        mutes: {'bass': true},
        sections: [Section(id: 'phrase', name: 'A', bars: 4)],
      );
      song.sections.single.tracks['melody']!.label = 'Tenor Sax · 4';
      final note = PitchNote(
        midi: 60,
        freq: 261.63,
        step: 34,
        dur: 2,
        velocity: 47,
        offsetSteps: .3,
        durationSteps: 1.4,
      );
      song.sections.single.tracks['melody']!.pitchNotes.add(note);
      await showHome(tester, 'en');
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      Navigator.of(
        tester.element(find.byType(SongsScreen)),
      ).push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: song)));
      await tester.pumpAndSettle();
      // ui-001 stage 3: the timeline (Solo, mute, ruler) is the arrange view
      await showArrange(tester);
      Arrangement arrangement() =>
          tester.widget<Arrangement>(find.byType(Arrangement));
      // ui-001 stage 2: on desktop the range is set on the ruler and the Solo
      // controls sit in the track header (same handlers as AuditionBar)
      DesktopSoloHeader solo() =>
          tester.widget<DesktopSoloHeader>(find.byType(DesktopSoloHeader));
      void range(PlaybackRange r) => arrangement().onLoopRange!(r);
      // ui-001 stage 1: on desktop the transport lives in the top bar
      DesktopTopBar transport() =>
          tester.widget<DesktopTopBar>(find.byType(DesktopTopBar));
      expect(
        arrangement().tracks.firstWhere((t) => t.id == 'melody').label,
        'Tenor Sax · 4',
      );
      await tester.tap(find.byKey(const ValueKey('solo-melody')));
      await tester.pump();
      arrangement().onToggleSolo!('drums');
      await tester.pump();
      expect(arrangement().solos, {'melody', 'drums'});
      expect(arrangement().mutes['bass'], isTrue);
      arrangement().onToggleMute('melody');
      await tester.pump();
      expect(arrangement().mutes['melody'], isTrue);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
      await tester.pump();
      expect(arrangement().mutes['melody'] ?? false, isFalse);
      expect(arrangement().solos, {'melody', 'drums'});
      range(const PlaybackRange(32, 48));
      await tester.pump();
      expect(arrangement().loopRange!.start, 32);
      expect(arrangement().playStep.value, 32);
      transport().onPlay();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(arrangement().playStep.value, closeTo(36, .01));
      // A frame spanning one complete pass must still land on the same phrase.
      await tester.pump(const Duration(seconds: 2));
      expect(arrangement().playStep.value, closeTo(36, .01));
      solo().onCompare();
      await tester.pump();
      expect(arrangement().bypassSolo, isTrue);
      expect(arrangement().solos, {'melody', 'drums'});
      expect(arrangement().mutes['bass'], isTrue);
      expect(arrangement().playStep.value, closeTo(32, .01));
      solo().onCompare();
      await tester.pump();
      expect(arrangement().bypassSolo, isFalse);
      // Scrubbing beyond a selected range cannot escape it.
      arrangement().onSeek!(0);
      await tester.pump();
      expect(arrangement().playStep.value, closeTo(32, .01));
      range(const PlaybackRange(16, 32));
      await tester.pump();
      expect(arrangement().playStep.value, closeTo(16, .01));
      transport().onStop();
      await tester.pump();
      expect(arrangement().playStep.value, 16);
      // Shrinking the section keeps a complete musical bar, never a stray
      // final sixteenth from the old range.
      transport().onBars(1);
      await tester.pump();
      expect(arrangement().loopRange!.start, 0);
      expect(arrangement().loopRange!.end, 16);
      transport().onCountIn(false);
      await tester.pump();
      transport().onRec();
      await tester.pump();
      expect(transport().recording, isTrue);
      expect(arrangement().loopRange, isNull);
      expect(solo().enabled, isFalse);
      transport().onBars(4);
      await tester.pump();
      expect(transport().bars, 1);
      transport().onStop();
      await tester.pump();
      solo().onClear();
      await tester.pump();
      expect(arrangement().solos, isEmpty);
      expect(arrangement().mutes['bass'], isTrue);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).save();
      await tester.runAsync(() async {
        await store.operation;
      });
      await tester.pump();
      expect(store.lastSaved!.mutes['bass'], isTrue);
      expect(
        store.lastSaved!.sections.single.tracks['melody']!.pitchNotes.single
            .toJson(),
        note.toJson(),
      );
      expect(song.mutes['bass'], isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await store.operation;
      });
    },
  );

  testWidgets(
    'quiet Solo opens velocity bars and one drag supports editor undo/redo',
    (tester) async {
      store.memoryOnly = true;
      tester.platformDispatcher.textScaleFactorTestValue = .7;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final source = PitchNote(
        midi: 66,
        freq: 369.99,
        step: 67,
        dur: 3,
        velocity: 3,
        offsetSteps: .225,
        durationSteps: 2.258,
        sourceMidi: 65,
        assisted: true,
        confidence: .72,
      );
      final song = Song(
        id: 'quiet-solo',
        title: 'Quiet source',
        bpm: 100,
        sections: [Section(id: 'A', name: 'A', bars: 8)],
      );
      song.sections.single.tracks['melodyDec']!
        ..label = 'Piano 1'
        ..pitchNotes.add(source);
      await showHome(tester, 'en');
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      Navigator.of(
        tester.element(find.byType(SongsScreen)),
      ).push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: song)));
      await tester.pumpAndSettle();
      // ui-001 stage 3: Solo and the ruler are in the arrange view
      await showArrange(tester);
      Arrangement arrangement() =>
          tester.widget<Arrangement>(find.byType(Arrangement));
      arrangement().onToggleSolo!('melodyDec');
      arrangement().onLoopRange!(const PlaybackRange(64, 128));
      await tester.pump();
      expect(find.byKey(const ValueKey('solo-status-notice')), findsOneWidget);
      // desktop: the reason is the warning icon's tooltip; the icon opens 강약 보기
      expect(
        tester
            .widget<Tooltip>(
              find.ancestor(
                of: find.byKey(const ValueKey('solo-status-notice')),
                matching: find.byType(Tooltip),
              ),
            )
            .message,
        contains('Velocity 3–3/127'),
      );
      await tester.tap(find.byKey(const ValueKey('solo-status-notice')));
      await tester.pumpAndSettle();
      // ui-001 stage 3: 강약 보기 from the arrange view opens the edit view
      // (the velocity lane lives there) on that track's grid
      expect(find.byType(Arrangement), findsNothing);
      expect(find.byKey(const ValueKey('timeline-minimap')), findsOneWidget);
      StepGrid grid() => tester.widget<StepGrid>(find.byType(StepGrid));
      expect(grid().notes.single.velocity, 3);
      final lane = tester.getRect(find.byKey(const ValueKey('velocity-lane')));
      final gesture = await tester.startGesture(
        Offset(
          lane.left + lane.width * source.startSteps / 128,
          lane.bottom - 4 - 3 / 127 * (lane.height - 8),
        ),
      );
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump();
      // the stored note (the grid's input) changes only on release
      expect(grid().notes.single.velocity, 3);
      await gesture.up();
      await tester.pump();
      final edited = grid().notes.single;
      expect(edited.velocity, greaterThan(8));
      expect(edited.offsetSteps, .225);
      expect(edited.durationSteps, 2.258);
      expect(edited.sourceMidi, 65);
      expect(edited.confidence, .72);
      expect(find.byKey(const ValueKey('solo-status-notice')), findsNothing);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
      await tester.pump();
      expect(grid().notes.single.toJson(), source.toJson());
      expect(find.byKey(const ValueKey('solo-status-notice')), findsOneWidget);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).redo();
      await tester.pump();
      expect(grid().notes.single.toJson(), edited.toJson());
      await tester.binding.setSurfaceSize(const Size(960, 600));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('velocity-lane')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        song.sections.single.tracks['melodyDec']!.pitchNotes.single.toJson(),
        source.toJson(),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await store.operation;
      });
    },
  );

  testWidgets('first-song card fits small landscape with enlarged text', (
    tester,
  ) async {
    await showHome(tester, 'ko');
    await tester.binding.setSurfaceSize(const Size(640, 360));
    tester.platformDispatcher.textScaleFactorTestValue = 1.15;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('first-song-start')));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'autosave and explicit save count one completion per guided visit',
    (tester) async {
      store.memoryOnly = true;
      final song = store.createNew();
      song.sections.first.tracks['melody']!.pitchNotes.add(
        PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4),
      );
      await showHome(tester, 'en');
      final context = tester.element(find.byType(SongsScreen));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => EditScreen(song: song, guidedStart: true),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 12));
      // Storage succeeds immediately here; the back-save test checks real disk persistence.
      await tester.runAsync(() async {
        await store.operation;
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save my song'));
      await tester.runAsync(() async {
        await store.operation;
      });
      await tester.pumpAndSettle();
      final saved =
          sink.events
              .where((e) => e.$1 == ProductEvent.guidedSongSaved)
              .toList();
      expect(saved, hasLength(1));
      expect(saved.single.$2['save_method'], 'autosave');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
