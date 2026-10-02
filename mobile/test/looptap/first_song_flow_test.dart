import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/offline_fonts.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/screens/songs_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/first_song_card.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';
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
  @override
  Future<void> upsert(Song song) => operation = memoryOnly ? Future<void>.value() : super.upsert(song);
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
