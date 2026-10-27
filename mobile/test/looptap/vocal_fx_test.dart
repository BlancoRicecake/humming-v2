import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/vocal_fx.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/vocal_surface.dart';
import 'package:provider/provider.dart';
import 'package:humming/looptap/theme/atoms.dart';
import 'package:humming/looptap/widgets/sheets/vocal_editor.dart';
import '../support/offline_fonts.dart';

Uint8List wav(double value, {int count = 8000, int rate = 8000}) =>
    encodeWavMono16(Float32List.fromList(List.filled(count, value)), rate);

/// Noncommutative PCM transforms expose wrong source/order and stale baked FX.
Future<Uint8List> transform(Uint8List bytes, FxNode fx) async {
  final s = parseWav(bytes)!;
  if (fx.type == 'stretch') {
    final ratio = (fx.params['ratio'] as num).toDouble();
    return encodeWavMono16(
      Float32List.fromList(
        List.generate(
          (s.samples.length * ratio).round(),
          (i) => s.samples[(i / ratio).floor()],
        ),
      ),
      s.sampleRate,
    );
  }
  final delta = fx.type == 'eq' ? .1 : 0.0;
  final multiplier = fx.type == 'comp' ? .5 : 1.0;
  return encodeWavMono16(
    Float32List.fromList([for (final v in s.samples) (v + delta) * multiplier]),
    s.sampleRate,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, Uint8List> files;
  late List<String> calls;
  late int saves;
  late VocalFxRenderer renderer;

  setUp(() {
    files = {'dry.wav': wav(.2), 'wet.wav': wav(.15)};
    calls = [];
    saves = 0;
    renderer = VocalFxRenderer(
      read: (path) async => files[path] ?? (throw StateError('missing $path')),
      process: (audio, fx) async {
        calls.add(fx.type);
        return transform(audio, fx);
      },
      persist: (audio) async {
        final path = 'render_${++saves}.wav';
        files[path] = audio;
        return path;
      },
    );
  });

  VocalClip wet() => VocalClip(
    path: 'wet.wav',
    origPath: 'dry.wav',
    fxSourcePath: 'dry.wav',
    startStep: 7,
    gain: .8,
    fadeInMs: 150,
    fadeOutMs: 400,
    trimStart: 800,
    trimEnd: 5600,
    fx: [FxNode(type: 'eq'), FxNode(type: 'comp')],
  );
  Future<VocalClip> render(VocalClip c, List<FxNode> chain) =>
      renderer.render(c, chain, bpm: 120, bars: 2);

  test(
    'deleting first or last FX changes PCM, keeps remaining order and edits',
    () async {
      final input = wet();
      final snapshot = jsonEncode(input.toJson());
      final onlyComp = await render(input, [input.fx[1]]);
      expect(calls, ['comp']);
      expect(
        parseWav(files[onlyComp.path]!)!.samples.first,
        closeTo(.1, .0001),
      );
      final onlyEq = await render(input, [input.fx[0]]);
      expect(parseWav(files[onlyEq.path]!)!.samples.first, closeTo(.3, .0001));
      expect(onlyComp.startStep, 7);
      expect(onlyComp.trimStart, 800);
      expect(onlyComp.trimEnd, 5600);
      expect(onlyComp.gain, .8);
      expect(onlyComp.fadeInMs, 150);
      expect(onlyComp.fadeOutMs, 400);
      expect(onlyComp.durSteps, 5);
      expect(onlyComp.peaks.first, 1); // display peaks normalize independently
      expect(jsonEncode(input.toJson()), snapshot);
    },
  );

  test(
    'middle deletion replays noncommutative remaining effects once from source',
    () async {
      final input = wet()..fx.insert(1, FxNode(type: 'delay'));
      final out = await render(input, [input.fx.first, input.fx.last]);
      expect(calls, ['eq', 'comp']);
      expect(saves, 1);
      expect(parseWav(files[out.path]!)!.samples.first, closeTo(.15, .0001));
      final reloaded = VocalClip.fromJson(jsonDecode(jsonEncode(out.toJson())));
      final second = await render(reloaded, [reloaded.fx.first]);
      expect(parseWav(files[second.path]!)!.samples.first, closeTo(.3, .0001));
      expect(reloaded.fxSourcePath, 'dry.wav');
    },
  );

  test(
    'last FX removal restores source bytes without network or writing',
    () async {
      final c = wet()..fx.removeLast();
      final originalBytes = Uint8List.fromList(files['dry.wav']!);
      final out = await render(c, []);
      expect(out.path, 'dry.wav');
      expect(out.origPath, isNull);
      expect(out.fxSourcePath, isNull);
      expect(out.fx, isEmpty);
      expect(calls, isEmpty);
      expect(saves, 0);
      expect(files['dry.wav'], originalBytes);
      expect(out.trimStart, c.trimStart);
      expect(out.gain, c.gain);
    },
  );

  test(
    'legacy FX history uses original; missing chain source fails safely',
    () async {
      final c = wet()..fxSourcePath = null;
      final out = await render(c, [c.fx.first]);
      expect(out.fxSourcePath, 'dry.wav');
      final broken =
          wet()
            ..fxSourcePath = null
            ..origPath = null;
      await expectLater(
        render(broken, []),
        throwsA(isA<VocalFxSourceMissing>()),
      );
      expect(broken.fx.length, 2);
      expect(broken.path, 'wet.wav');
    },
  );

  test(
    'pre-existing autotune is retained by FX removal; full restore is dry',
    () async {
      files['tuned.wav'] = wav(.4);
      final c = wet()..fxSourcePath = 'tuned.wav';
      final out = await render(c, []);
      expect(out.path, 'tuned.wav');
      expect(out.origPath, 'dry.wav');
      expect(parseWav(files[out.path]!)!.samples.first, closeTo(.4, .0001));
      final dry = await renderer.restoreOriginal(out, bpm: 120, bars: 2);
      expect(dry.path, 'dry.wav');
      expect(dry.trimStart, 0);
      expect(dry.trimEnd, -1);
      expect(dry.gain, 1);
      expect(dry.fadeInMs, 0);
      expect(dry.fadeOutMs, 0);
      expect(dry.startStep, 7);
      expect(dry.durSteps, 8);
      expect(dry.origPath, isNull);
      expect(dry.fxSourcePath, isNull);
      expect(dry.fx, isEmpty);
      expect(dry.peaks.first, 1);
    },
  );

  test(
    'new autotune nodes survive other FX removal and disabled nodes are skipped',
    () async {
      final c = wet();
      final tune = FxNode(
        type: 'autotune',
        params: {'keyTonic': 'C', 'scale': 'major'},
      );
      final out = await render(c, [tune, FxNode(type: 'eq', enabled: false)]);
      expect(calls, ['autotune']);
      expect(out.fx[1].enabled, isFalse);
      expect(out.fx.first.params['keyTonic'], 'C');
    },
  );

  test('stretch removal remaps trim and waveform to source samples', () async {
    files['long.wav'] = wav(.2, count: 16000);
    final c =
        wet()
          ..path = 'long.wav'
          ..trimStart = 4000
          ..trimEnd = 12000;
    c.fx
      ..clear()
      ..add(FxNode(type: 'stretch', params: {'ratio': 2}));
    final out = await render(c, []);
    expect(out.trimStart, 2000);
    expect(out.trimEnd, 6000);
    expect(out.durSteps, 4);
    final restoredStretch = await render(out, [
      FxNode(type: 'stretch', params: {'ratio': 2}),
    ]);
    expect(restoredStretch.trimStart, 4000);
    expect(restoredStretch.trimEnd, 12000);
    expect(restoredStretch.durSteps, 8);
  });

  test('sample-rate changes keep same selected time interval', () async {
    files['wet.wav'] = wav(.15, count: 16000, rate: 16000);
    final c =
        wet()
          ..trimStart = 4000
          ..trimEnd = 12000;
    final out = await render(c, []);
    expect(out.trimStart, 2000);
    expect(out.trimEnd, 6000);
    expect(out.durSteps, 4);
  });

  test(
    'DSP or persistence failure never changes caller or writes partial chain',
    () async {
      final c = wet();
      final before = jsonEncode(c.toJson());
      final failing = VocalFxRenderer(
        read: renderer.read,
        process: (audio, fx) async {
          if (fx.type == 'comp') throw StateError('offline');
          return transform(audio, fx);
        },
        persist: renderer.persist,
      );
      await expectLater(
        failing.render(c, c.fx, bpm: 120, bars: 2),
        throwsStateError,
      );
      expect(saves, 0);
      final diskFull = VocalFxRenderer(
        read: renderer.read,
        process: renderer.process,
        persist: (_) async => throw StateError('disk full'),
      );
      await expectLater(
        diskFull.render(c, c.fx, bpm: 120, bars: 2),
        throwsStateError,
      );
      expect(jsonEncode(c.toJson()), before);
    },
  );

  test(
    'missing original or invalid DSP audio cannot replace playable clip',
    () async {
      final c = wet();
      final before = jsonEncode(c.toJson());
      files.remove('dry.wav');
      await expectLater(render(c, []), throwsStateError);
      await expectLater(
        renderer.restoreOriginal(c, bpm: 120, bars: 2),
        throwsStateError,
      );
      files['dry.wav'] = wav(.2);
      final invalid = VocalFxRenderer(
        read: renderer.read,
        process: (_, _) async => Uint8List(2),
        persist: renderer.persist,
      );
      await expectLater(
        invalid.render(c, c.fx, bpm: 120, bars: 2),
        throwsFormatException,
      );
      expect(jsonEncode(c.toJson()), before);
      expect(saves, 0);
    },
  );

  test('export bounce uses restored PCM and retains clip placement', () async {
    final c = await render(wet(), []);
    final s = parseWav(files[c.path]!)!;
    final lane = bounceVocalClips(
      [c],
      2,
      120,
      {c.path: (pcm: s.samples, sampleRate: s.sampleRate)},
    );
    final before = (c.startStep * 60 / 120 / 4 * 44100).floor();
    expect(lane.take(before).every((v) => v == 0), isTrue);
    expect(
      lane.skip(before + 7000).take(1000).any((v) => v.abs() > .1),
      isTrue,
    );
  });

  test(
    'saving and cleanup retain a distinct FX source needed after reopening',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'humtrack_fx_storage_',
      );
      LoopStorage.rootOverride = root;
      try {
        await LoopStorage.ensureDirs();
        final c = wet()..fxSourcePath = 'tuned.wav';
        for (final name in ['dry.wav', 'wet.wav', 'tuned.wav']) {
          await File(LoopStorage.resolveVocal(name)).writeAsBytes(wav(.2));
        }
        final song = Song(id: 'fx-storage', title: 'FX');
        song.sections.first.tracks['vocal'] = TrackData(clips: [c]);
        await LoopStorage.save([song]);
        final loaded = await LoopStorage.load();
        await LoopStorage.sweepVocals(loaded);
        final reopened =
            loaded.single.sections.first.tracks['vocal']!.clips!.single;
        expect(reopened.fxSourcePath, 'tuned.wav');
        expect(
          await File(LoopStorage.resolveVocal('tuned.wav')).exists(),
          isTrue,
        );
        final copy = reopened.copy();
        copy.fx.first.params['wet'] = .9;
        expect(reopened.fx.first.params, isEmpty);
      } finally {
        LoopStorage.rootOverride = null;
        final target = await root.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (!target.startsWith(
          '$temp${Platform.pathSeparator}humtrack_fx_storage_',
        )) {
          throw StateError('Unsafe storage cleanup');
        }
        await root.delete(recursive: true);
      }
    },
  );

  group('editor', () {
    late Directory root;
    final playbackCalls = <MethodCall>[];
    var failPlayback = false;
    var playPosition = 0;
    VocalEditorResult? result;
    setUp(() async {
      useOfflineTestFonts();
      playbackCalls.clear();
      failPlayback = false;
      playPosition = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final name in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(name),
          (_) async => null,
        );
      }
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
          playbackCalls.add(call);
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          }
          if (call.method == 'setSourceUrl' || call.method == 'seek') {
            final id = (call.arguments as Map)['playerId'];
            ServicesBinding.instance.channelBuffers.push(
              'xyz.luan/audioplayers/events/$id',
              const StandardMethodCodec().encodeSuccessEnvelope({
                'event':
                    call.method == 'seek'
                        ? 'audio.onSeekComplete'
                        : 'audio.onPrepared',
                if (call.method != 'seek') 'value': true,
              }),
              (_) {},
            );
            if (call.method == 'setSourceUrl' && failPlayback) {
              throw PlatformException(code: 'load_failed');
            }
          }
          if (call.method == 'getCurrentPosition') return playPosition;
          return null;
        },
      );
      // Initialize the shared audio queue outside each widget's FakeAsync zone.
      await LoopAudio.instance.stopVocal();
      root = await Directory.systemTemp.createTemp('humtrack_vocal_fx_test_');
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => root.path,
      );
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
      for (final entry in files.entries) {
        await File(
          LoopStorage.resolveVocal(entry.key),
        ).writeAsBytes(entry.value);
      }
      final memory = renderer;
      renderer = VocalFxRenderer(
        read: memory.read,
        process: memory.process,
        persist: (bytes) async {
          final name = await memory.persist(bytes);
          await File(LoopStorage.resolveVocal(name)).writeAsBytes(bytes);
          return name;
        },
      );
      result = null;
    });
    tearDown(() async {
      LoopStorage.rootOverride = null;
      final target = await root.resolveSymbolicLinks();
      final temp = await Directory.systemTemp.resolveSymbolicLinks();
      if (!target.startsWith(
        '$temp${Platform.pathSeparator}humtrack_vocal_fx_test_',
      )) {
        throw StateError('Unsafe test cleanup');
      }
      await root.delete(recursive: true);
    });
    Future<void> show(WidgetTester tester, TrackData track) async {
      await tester.binding.setSurfaceSize(const Size(1100, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await Navigator.of(
                        context,
                      ).push<VocalEditorResult>(
                        MaterialPageRoute(
                          builder:
                              (_) => VocalEditorScreen(
                                autoPreview: false,
                                vocal: track,
                                bpm: 120,
                                bars: 2,
                                songId: 's',
                                sectionId: 'a',
                                keyRoot: 'C',
                                scale: 'major',
                                swing: 0,
                                fxRenderer: renderer,
                              ),
                        ),
                      );
                    },
                    child: const Text('Open'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, String text) async {
      await tester.ensureVisible(find.text(text));
      await tester.tap(find.text(text));
      // File IO and method-channel completions alternate with Flutter frames.
      for (var i = 0; i < 20; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      await tester.pumpAndSettle();
    }

    Future<void> scenario0(WidgetTester tester) async {
      final track = TrackData(
        clips: [wet(), VocalClip(path: 'dry.wav', startStep: 16)],
      );
      final original = jsonEncode(track.toJson());
      await show(tester, track);
      await tap(tester, '1. EQ');
      expect(find.text('1. Comp'), findsOneWidget);
      expect(jsonEncode(track.toJson()), original);
      await tap(tester, 'Done');
      final edited = result!.vocal;
      expect(edited.clips!.first.fx.single.type, 'comp');
      expect(
        parseWav(files[edited.clips!.first.path]!)!.samples.first,
        closeTo(.1, .0001),
      );
      expect(edited.clips![1].toJson(), track.clips![1].toJson());
      expect(edited.vocalPath, edited.clips!.first.path);
      expect(jsonEncode(track.toJson()), original);
      expect(tester.takeException(), isNull);
    }

    Future<void> scenario1(WidgetTester tester) async {
      await show(tester, TrackData(clips: [wet()]));
      await tap(tester, 'Remove all effects');
      expect(calls, isEmpty);
      await tap(tester, 'Restore original');
      await tap(tester, 'Done');
      final c = result!.vocal.clips!.single;
      expect(c.path, 'dry.wav');
      expect(c.fx, isEmpty);
      expect(c.trimStart, 0);
      expect(c.gain, 1);
      expect(c.fadeInMs, 0);
      expect(c.startStep, 7);
    }

    Future<void> scenario2(WidgetTester tester) async {
      final track = TrackData(clips: [wet()]);
      final before = jsonEncode(track.toJson());
      final memory = renderer;
      renderer = VocalFxRenderer(
        read: memory.read,
        process: (_, _) async => throw StateError('offline'),
        persist: memory.persist,
      );
      await show(tester, track);
      await tap(tester, '1. EQ');
      expect(find.text('1. EQ'), findsOneWidget);
      expect(find.text('2. Comp'), findsOneWidget);
      await tap(tester, 'Done');
      expect(result!.vocal.clips!.first.path, 'wet.wav');
      renderer = memory;
      await tester.pumpWidget(const SizedBox());
      await show(tester, track);
      await tap(tester, '1. EQ');
      final close = find.byWidgetPredicate(
        (w) => w is IconBtn && w.tooltip == 'Cancel',
      );
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(jsonEncode(track.toJson()), before);
    }

    Future<void> scenario3(WidgetTester tester) async {
      final track = TrackData(clips: [wet(), VocalClip(path: 'dry.wav')]);
      final before = jsonEncode(track.toJson());
      final pending = Completer<Uint8List>();
      renderer = VocalFxRenderer(
        read: renderer.read,
        process: (_, _) => pending.future,
        persist: renderer.persist,
      );
      await show(tester, track);
      await tester.ensureVisible(find.text('1. EQ'));
      await tester.tap(find.text('1. EQ'));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump();
      final done = tester.widget<Pill>(find.widgetWithText(Pill, 'Done'));
      expect(done.onTap, isNull);
      await tester.tap(find.text('Take 2'));
      await tester.pump();
      expect(find.text('2. Comp'), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate((w) => w is IconBtn && w.tooltip == 'Cancel'),
      );
      await tester.pumpAndSettle();
      pending.complete(wav(.1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pumpAndSettle();
      expect(result, isNull);
      expect(jsonEncode(track.toJson()), before);
      expect(tester.takeException(), isNull);
    }

    Future<void> laneRestore(WidgetTester tester) async {
      final store = LoopStore();
      final song = Song(id: 'lane-restore', title: 'Restore');
      song.sections.first.tracks['vocal'] = TrackData(
        vocalPath: 'dry.wav',
        clip: [1],
        clips: [VocalClip(path: 'dry.wav'), wet(), wet()..startStep = 18],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: song),
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(.7)),
                  child: child!,
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('vocal');
      await tester.pumpAndSettle();
      TrackData track() =>
          tester
              .widget<Arrangement>(find.byType(Arrangement))
              .section
              .tracks['vocal']!;
      Future<void> settleIo() async {
        for (var i = 0; i < 30; i++) {
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        await tester.pumpAndSettle();
      }

      final before = jsonEncode(track().toJson());
      tester.widget<VocalSurface>(find.byType(VocalSurface)).onRevert!();
      await settleIo();
      expect(
        track().clips!
            .skip(1)
            .every(
              (c) =>
                  c.path == 'dry.wav' &&
                  c.fx.isEmpty &&
                  c.fxSourcePath == null &&
                  c.trimStart == 0 &&
                  c.gain == 1,
            ),
        isTrue,
      );
      expect(track().clips![2].startStep, 18);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
      await settleIo();
      expect(jsonEncode(track().toJson()), before);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).redo();
      await settleIo();
      expect(track().clips!.first.fx, isEmpty);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
      await settleIo();
      track().clips![2].origPath = 'missing.wav';
      final broken = jsonEncode(track().toJson());
      tester.widget<VocalSurface>(find.byType(VocalSurface)).onRevert!();
      await settleIo();
      expect(
        jsonEncode(track().toJson()),
        broken,
        reason: 'One missing original must not restore only half the lane',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await settleIo();
      store.dispose();
    }

    Future<void> presetsAndAmount(WidgetTester tester) async {
      final clip =
          wet()..fx.add(FxNode(type: 'autotune', params: {'strength': .7}));
      final track = TrackData(clips: [clip]);
      final before = jsonEncode(track.toJson());
      calls.clear();
      await show(tester, track);
      await tap(tester, 'Clean vocal');
      expect(calls, ['autotune', 'gate', 'deess']);
      expect(find.text('1. Autotune'), findsOneWidget);
      expect(find.text('2. Noise gate'), findsOneWidget);
      final slider = find.byKey(const ValueKey('vocal-fx-amount'));
      await tester.ensureVisible(slider);
      tester.widget<Slider>(slider).onChanged!(.4);
      await tester.pump();
      await tap(tester, 'Chorus');
      expect(find.text('4. Chorus'), findsOneWidget);
      await tap(tester, 'Done');
      expect(result!.vocal.clips!.single.fx.last.params['mix'], .4);
      await show(tester, result!.vocal);
      await tap(tester, 'Phone call');
      await tester.binding.setSurfaceSize(const Size(640, 500));
      await tester.pumpAndSettle();
      await tap(tester, 'Existing effects · internet required');
      expect(find.text('Reverb'), findsOneWidget);
      await tap(tester, 'Done');
      expect(result!.vocal.clips!.single.fx.map((f) => f.type), [
        'autotune',
        'telephone',
        'saturation',
      ]);
      expect(jsonEncode(track.toJson()), before);
      expect(tester.takeException(), isNull);
      await tester.binding.setSurfaceSize(const Size(1100, 850));
    }

    Future<void> comparisonPlayback(WidgetTester tester) async {
      Future<void> playTap(String label, String status) async {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        for (var i = 0; i < 150; i++) {
          await tester.pump(const Duration(milliseconds: 16));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (find.text(status).evaluate().isNotEmpty) return;
        }
        throw TestFailure(
          'Expected $status; actual ${tester.widget<Text>(find.byKey(const ValueKey("vocal-preview-status"))).data}; calls ${playbackCalls.map((c) => c.method).toList()}',
        );
      }

      renderer = VocalFxRenderer(
        read: renderer.read,
        process: renderer.process,
        persist: renderer.persist,
      );
      await show(tester, TrackData(clips: [wet()]));
      // Keep the signal levels distinct so uploaded preview bytes prove mode selection.
      await tap(tester, 'Match volume');
      playbackCalls.clear();
      await playTap('Hear effects', 'Playing effects');
      expect(find.text('Playing effects'), findsOneWidget);
      final wetPath =
          (playbackCalls.lastWhere((c) => c.method == 'setSourceUrl').arguments
                  as Map)['url']
              as String;
      final wetAudio = await tester.runAsync(() => File(wetPath).readAsBytes());
      playPosition = 1400;
      await playTap('Hear original', 'Playing original');
      expect(find.text('Playing original'), findsOneWidget);
      final dryPath =
          (playbackCalls.lastWhere((c) => c.method == 'setSourceUrl').arguments
                  as Map)['url']
              as String;
      final dryAudio = await tester.runAsync(() => File(dryPath).readAsBytes());
      expect(dryPath, isNot(wetPath));
      expect(dryAudio, isNot(wetAudio));
      expect(
        (playbackCalls.lastWhere((c) => c.method == 'seek').arguments
            as Map)['position'],
        1400,
      );
      // Applying another preset while listening must resume the actual processed file.
      await playTap('Phone call', 'Playing effects');
      expect(find.text('Playing effects'), findsOneWidget);
      final presetButton = tester.widget<Pill>(
        find.byKey(const ValueKey('vocal-preset-phone')),
      );
      expect(presetButton.tone, PillTone.lime);
      failPlayback = true;
      await playTap('Hear original', 'Stopped');
      expect(find.text('Stopped'), findsOneWidget);
      failPlayback = false;
      await tap(tester, 'Done');
      expect(tester.takeException(), isNull);
    }

    testWidgets(
      'delete, restore, failure and cancellation keep audio and history consistent',
      (tester) async {
        final normal = renderer;
        await scenario0(tester);
        calls.clear();
        await scenario1(tester);
        await scenario2(tester);
        renderer = normal;
        await presetsAndAmount(tester);
        renderer = normal;
        await comparisonPlayback(tester);
        renderer = normal;
        await scenario3(tester);
        await laneRestore(tester);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      },
    );
  });
}
