// Real modal + a file-backed fake recorder. No microphone or live API calls.
// ignore_for_file: depend_on_referenced_packages
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:humming/api/engine_api.dart';
import 'package:humming/models/models.dart' as eng;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_midi_pro/flutter_midi_pro.dart';
import 'package:humming/audio/synth.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/sheets/hum_modal.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

import '../support/offline_fonts.dart';

// Use the existing synth seam: a native output queue created in an earlier
// widget test's fake clock must not hold subsequent recording tests open.
class _SilentMidi implements MidiPro {
  @override
  Future<int> loadSoundfontAsset({
    required String assetPath,
    int bank = 0,
    int program = 0,
  }) async => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _Recorder extends RecordPlatform with MockPlatformInterfaceMixin {
  static const bytes = [82, 73, 70, 70, 10, 20, 30, 40];
  int starts = 0;
  int stops = 0;
  String? path;
  List<int> takeBytes = bytes;

  @override
  Future<void> create(String id) async {}
  @override
  Future<bool> hasPermission(String id, {bool request = true}) async => true;
  @override
  Future<bool> isEncoderSupported(String id, AudioEncoder encoder) async =>
      true;
  @override
  Future<void> start(
    String id,
    RecordConfig config, {
    required String path,
  }) async {
    starts++;
    this.path = path;
    File(path).writeAsBytesSync(takeBytes);
  }

  @override
  Future<String?> stop(String id) async {
    stops++;
    return path;
  }

  @override
  Future<void> dispose(String id) async {}
  @override
  Future<bool> isRecording(String id) async => starts > stops;
  @override
  Future<Amplitude> getAmplitude(String id) async =>
      Amplitude(current: -40, max: -40);
  @override
  Stream<RecordState> onStateChanged(String id) => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _MemoryStore extends LoopStore {
  @override
  bool get loaded => true;
  @override
  Future<void> upsert(Song song) async {}
  @override
  Future<void> sweepVocals() async {}
}

Finder get _modal =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_HumModal');
Finder get _retry => find.byKey(const ValueKey('hum-retry-recording'));

class _Engine extends EngineApi {
  _Engine() : super(baseUrl: 'http://test.invalid');
  Future<eng.AnalyzeResponse> Function(eng.AnalyzeOptions)? respond;
  @override
  Future<eng.AnalyzeResponse> analyze(
    String path,
    eng.AnalyzeOptions options, {
    CancelToken? cancelToken,
  }) => respond!(options);
}

eng.AnalyzeResponse _melody(int pitch, int step) =>
    eng.AnalyzeResponse.fromJson({
      'waveform': <String, dynamic>{},
      'notes': <Map<String, dynamic>>[
        <String, dynamic>{
          'pitch': pitch,
          'pitch_original': pitch,
          'step': step,
          'dur_steps': 4,
          'start': step / 8,
          'duration': .5,
          'end': step / 8 + .5,
          'confidence': .9,
        },
      ],
    });

void main() {
  late Directory root;
  late RecordPlatform originalRecord;
  late PathProviderPlatform originalPaths;
  late _Recorder recorder;
  late List<String> playerSources;
  final channels = <String>[
    'humming/audio',
    'xyz.luan/audioplayers.global',
    'xyz.luan/audioplayers.global/events',
    'xyz.luan/audioplayers',
  ];

  setUp(() async {
    useOfflineTestFonts();
    SynthEngine().debugUseMidiPro(_SilentMidi(), loadedSfId: 1);
    root = await Directory.systemTemp.createTemp('humtrack_hum_retry_');
    originalRecord = RecordPlatform.instance;
    originalPaths = PathProviderPlatform.instance;
    recorder = _Recorder();
    playerSources = [];
    RecordPlatform.instance = recorder;
    PathProviderPlatform.instance = _Paths(root.path);
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (call) async {
        if (channel == 'xyz.luan/audioplayers' &&
            call.method == 'setSourceUrl') {
          playerSources.add((call.arguments as Map)['url'] as String);
          final id = (call.arguments as Map)['playerId'];
          ServicesBinding.instance.channelBuffers.push(
            'xyz.luan/audioplayers/events/$id',
            const StandardMethodCodec().encodeSuccessEnvelope({
              'event': 'audio.onPrepared',
              'value': true,
            }),
            (_) {},
          );
        }
        if (channel == 'xyz.luan/audioplayers' && call.method == 'create') {
          final name =
              'xyz.luan/audioplayers/events/${(call.arguments as Map)['playerId']}';
          messenger.setMockMethodCallHandler(
            MethodChannel(name),
            (_) async => null,
          );
        }
        return null;
      });
    }
    await AudioPlayer.global.ensureInitialized();
  });
  tearDown(() async {
    SynthEngine().debugUseMidiPro(null);
    RecordPlatform.instance = originalRecord;
    PathProviderPlatform.instance = originalPaths;
    LoopStorage.rootOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), null);
    }
    // Delete only this test's isolated directory, never real recordings.
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    final resolved = await root.resolveSymbolicLinks();
    if (!resolved.startsWith(
      '$parent${Platform.pathSeparator}humtrack_hum_retry_',
    )) {
      throw StateError('Unexpected test cleanup path');
    }
    await root.delete(recursive: true);
  });

  Future<void> settleIo(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> disposeUi(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settleIo(tester);
  }

  Future<void> begin(
    WidgetTester tester,
    Future<HumConversionResult> Function(HumConversionRequest) convert, {
    String lang = 'en',
    Size size = const Size(800, 600),
    double textScale = 1,
  }) async {
    addTearDown(() => disposeUi(tester));
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        builder:
            (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!,
            ),
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => showHumModal(
                        context,
                        trackLabel: 'Melody',
                        accent: Colors.green,
                        onConvert: convert,
                        bpm: 120,
                        bars: 64,
                        countInBeats: 1,
                      ),
                  child: const Text('Open hum'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('Open hum'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await settleIo(tester);
    expect(recorder.starts, 1);
    await tester.ensureVisible(find.text(lang == 'ko' ? '변환' : 'Convert'));
    await tester.tap(find.text(lang == 'ko' ? '변환' : 'Convert'));
    await tester.pump();
    await settleIo(tester);
  }

  testWidgets(
    'failure survives 30 seconds; retry uses identical take, succeeds once and releases it',
    (tester) async {
      final attempts = <HumConversionRequest>[];
      await begin(tester, (request) async {
        expect(File(request.audioPath).readAsBytesSync(), _Recorder.bytes);
        attempts.add(request);
        return attempts.length == 1
            ? const HumConversionResult.failure('Network unavailable')
            : const HumConversionResult.success();
      });
      expect(find.text('Network unavailable'), findsOneWidget);
      expect(find.text('Done! Notes added.'), findsNothing);
      expect(_retry, findsOneWidget);
      await tester.pump(const Duration(seconds: 30));
      expect(_modal, findsOneWidget);
      expect(File(recorder.path!).readAsBytesSync(), _Recorder.bytes);
      await tester.tap(_retry);
      await tester.pump();
      expect(attempts.length, 2);
      expect(attempts[1].audioPath, attempts[0].audioPath);
      expect(
        identical(attempts[0].cancelToken, attempts[1].cancelToken),
        isFalse,
      );
      expect(recorder.starts, 1);
      expect(recorder.stops, 1);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(_modal, findsNothing);
      expect(File(recorder.path!).existsSync(), isFalse);
      await disposeUi(tester);
    },
  );

  testWidgets(
    'a throwing converter stays in failure and keeps its take over repeated retries',
    (tester) async {
      var count = 0;
      await begin(tester, (request) async {
        count++;
        throw StateError('network');
      });
      expect(find.text("Couldn't convert your hum"), findsOneWidget);
      await tester.tap(_retry);
      await tester.pump();
      await settleIo(tester);
      expect(count, 2);
      expect(_retry, findsOneWidget);
      expect(File(recorder.path!).readAsBytesSync(), _Recorder.bytes);
      await disposeUi(tester);
      expect(File(recorder.path!).existsSync(), isFalse);
    },
  );

  testWidgets(
    'discard requires a choice; keeping it preserves the retry; confirm discards',
    (tester) async {
      await begin(tester, (_) async => const HumConversionResult.failure());
      await tester.tap(find.byKey(const ValueKey('hum-discard-recording')));
      await tester.pumpAndSettle();
      expect(find.text('Discard this recording?'), findsOneWidget);
      await tester.tap(find.text('Keep this recording'));
      await tester.pumpAndSettle();
      expect(File(recorder.path!).existsSync(), isTrue);
      expect(_retry, findsOneWidget);
      // System back follows the same explicit keep/discard path.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard this recording?'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('hum-confirm-discard')));
      await tester.pumpAndSettle();
      expect(_modal, findsNothing);
      expect(File(recorder.path!).existsSync(), isFalse);
      await disposeUi(tester);
    },
  );

  testWidgets(
    'double retry cannot start parallel conversions; closing cancels and ignores late success',
    (tester) async {
      var calls = 0;
      final pending = Completer<HumConversionResult>();
      HumConversionRequest? active;
      await begin(tester, (request) async {
        calls++;
        if (calls == 1) return const HumConversionResult.failure();
        active = request;
        return pending.future;
      });
      final button = tester.widget<FilledButton>(_retry);
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(calls, 2);
      expect(_retry, findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hum-confirm-discard')));
      await tester.pumpAndSettle();
      expect(active!.cancelled, isTrue);
      expect(_modal, findsNothing);
      expect(
        File(recorder.path!).existsSync(),
        isTrue,
        reason: 'callback is still using it',
      );
      pending.complete(const HumConversionResult.success());
      await settleIo(tester);
      expect(File(recorder.path!).existsSync(), isFalse);
      expect(tester.takeException(), isNull);
      await disposeUi(tester);
    },
  );

  testWidgets(
    'keyboard cancel opens discard prompt; success closes both prompt and modal',
    (tester) async {
      final pending = Completer<HumConversionResult>();
      await begin(tester, (_) => pending.future);
      final cancel = find.byKey(const ValueKey('hum-cancel-conversion'));
      expect(cancel, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Discard this recording?'), findsOneWidget);
      pending.complete(const HumConversionResult.success());
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('Discard this recording?'), findsNothing);
      expect(find.text('Done! Notes added.'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(_modal, findsNothing);
      expect(find.text('Open hum'), findsOneWidget);
      expect(File(recorder.path!).existsSync(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disposing during conversion defers cleanup until the callback completes',
    (tester) async {
      final pending = Completer<HumConversionResult>();
      HumConversionRequest? active;
      await begin(tester, (request) {
        active = request;
        return pending.future;
      });
      await disposeUi(tester);
      expect(active!.cancelled, isTrue);
      expect(File(recorder.path!).existsSync(), isTrue);
      pending.complete(const HumConversionResult.failure());
      await settleIo(tester);
      expect(File(recorder.path!).existsSync(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final lang in ['ko', 'en']) {
    for (final textScale in [1.0, 1.5, 2.0]) {
      for (final size in [const Size(640, 320), const Size(320, 640)]) {
        testWidgets(
          'persistent failure actions fit $size ($lang ${textScale}x)',
          (tester) async {
            await begin(
              tester,
              (_) async => const HumConversionResult.failure(),
              lang: lang,
              size: size,
              textScale: textScale,
            );
            expect(_retry, findsOneWidget);
            expect(tester.takeException(), isNull);
            await tester.ensureVisible(_retry);
            await tester.pump();
            expect(tester.takeException(), isNull);
            await disposeUi(tester);
          },
        );
      }
    }
  }

  testWidgets(
    'real editor reports an analysis error without inserting notes or deleting the modal take',
    (tester) async {
      // Flutter's test HttpClient returns 400, so no request reaches the real API.
      final store = _MemoryStore();
      await tester.binding.setSurfaceSize(const Size(1000, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: store.createNew(), guidedStart: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guided-choice-hum')));
      await tester.pump();
      // The editor uses four count-in beats at the new song's default BPM.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settleIo(tester);
      }
      expect(recorder.starts, 1);
      await tester.tap(find.text('Convert'));
      await tester.pump();
      await settleIo(tester);
      expect(_retry, findsOneWidget);
      expect(
        tester.widget<GuidedHumPanel>(find.byType(GuidedHumPanel)).notes,
        isEmpty,
      );
      expect(File(recorder.path!).existsSync(), isTrue);
      final dynamic modal = tester.widget(_modal);
      final request = HumConversionRequest(recorder.path!)..cancel();
      final result = await modal.onConvert(request) as HumConversionResult;
      expect(result.status, HumConversionStatus.cancelled);
      expect(
        tester.widget<GuidedHumPanel>(find.byType(GuidedHumPanel)).notes,
        isEmpty,
      );
      await disposeUi(tester);
      store.dispose();
    },
  );

  Future<void> openGuided(WidgetTester tester, _Engine engine) async {
    final store = _MemoryStore();
    addTearDown(store.dispose);
    addTearDown(() => disposeUi(tester));
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final song = Song(
      id: 'retake',
      title: 'Retake',
      key: 'C',
      scale: 'chromatic',
      bpm: 120,
      sections: [Section(id: 'A', name: 'A', bars: 1)],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: EditScreen(song: song, guidedStart: true, humEngine: engine),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> recordGuided(
    WidgetTester tester, {
    bool again = false,
    bool longTake = false,
  }) async {
    final action = find.byKey(
      ValueKey(again ? 'guided-retake' : 'guided-choice-hum'),
    );
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      await settleIo(tester);
    }
    if (longTake) await tester.pump(const Duration(seconds: 11));
    await tester.tap(find.text('Convert'));
    await tester.pump();
    await settleIo(tester);
  }

  Future<void> finishSuccess(WidgetTester tester) async {
    // Success copies the take with real file I/O, which only advances inside
    // runAsync; a slow runner can need more than one settleIo window. Wait for
    // the observable result (the modal closing), capped, instead of fixed time.
    for (var i = 0; i < 100 && _modal.evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(_modal, findsNothing);
  }

  testWidgets(
    'guided retake preserves old notes, original and length on failure, replaces once on retry and undoes together',
    (tester) async {
      final engine = _Engine()..respond = (_) async => _melody(60, 0);
      await openGuided(tester, engine);
      await recordGuided(tester);
      await finishSuccess(tester);
      GuidedHumPanel panel() =>
          tester.widget<GuidedHumPanel>(find.byType(GuidedHumPanel));
      expect(panel().notes.map((n) => n.midi), [60]);
      final oldSteps = panel().steps;
      final originals =
          root
              .listSync()
              .whereType<File>()
              .where((f) => f.path.contains('guided_take'))
              .toList();
      expect(originals, hasLength(1));
      final oldPath = originals.single.path;
      engine.respond = (options) async {
        expect(options.loopBars, 8);
        throw StateError('offline');
      };
      recorder.takeBytes = [82, 73, 70, 70, 99, 98, 97, 96];
      await recordGuided(tester, again: true, longTake: true);
      expect(_retry, findsOneWidget);
      expect(panel().notes.map((n) => n.midi), [60]);
      expect(panel().steps, oldSteps);
      expect(File(oldPath).readAsBytesSync(), _Recorder.bytes);
      engine.respond = (_) async => _melody(67, 100);
      await tester.tap(_retry);
      await finishSuccess(tester);
      expect(recorder.starts, 2);
      expect(panel().notes, hasLength(1));
      expect(panel().notes.single.step, 100);
      expect(panel().steps, 128);
      final newPath =
          root
              .listSync()
              .whereType<File>()
              .where((f) => f.path.contains('guided_take') && f.path != oldPath)
              .single
              .path;
      expect(File(newPath).readAsBytesSync(), recorder.takeBytes);
      panel().onPlayTake!();
      await settleIo(tester);
      expect(File(playerSources.last).readAsBytesSync(), recorder.takeBytes);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
      await tester.pump();
      expect(panel().notes.map((n) => n.midi), [60]);
      expect(panel().steps, oldSteps);
      panel().onPlayTake!();
      await settleIo(tester);
      expect(File(playerSources.last).readAsBytesSync(), _Recorder.bytes);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).redo();
      await tester.pump();
      expect(panel().notes.single.step, 100);
      expect(panel().steps, 128);
      await disposeUi(tester);
      expect(File(oldPath).existsSync(), isFalse);
      expect(File(newPath).existsSync(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discarding a pending retake keeps the old comparison and ignores a late result',
    (tester) async {
      final engine = _Engine()..respond = (_) async => _melody(60, 0);
      await openGuided(tester, engine);
      await recordGuided(tester);
      await finishSuccess(tester);
      final original =
          root
              .listSync()
              .whereType<File>()
              .where((f) => f.path.contains('guided_take'))
              .single
              .path;
      final pending = Completer<eng.AnalyzeResponse>();
      engine.respond = (_) => pending.future;
      await recordGuided(tester, again: true);
      await tester.tap(find.byKey(const ValueKey('hum-cancel-conversion')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('hum-confirm-discard')));
      await tester.pumpAndSettle();
      pending.complete(_melody(67, 4));
      await settleIo(tester);
      final panel = tester.widget<GuidedHumPanel>(find.byType(GuidedHumPanel));
      expect(panel.notes.map((n) => n.midi), [60]);
      expect(File(original).readAsBytesSync(), _Recorder.bytes);
      expect(_modal, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
