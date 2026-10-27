// Explicit local DSP integration test; never contacts production.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/api/engine_api.dart';
import 'package:humming/looptap/audio/vocal_fx_processor.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/loop_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This explicit loopback-only test exercises the real HTTP adapter.
  HttpOverrides.global = null;
  test(
    'real DSP: deleting EQ leaves only compression; tuning and dry restore remain exact',
    () async {
      expect(EngineConfig.baseUrl, 'http://127.0.0.1:18791');
      final root = await Directory.systemTemp.createTemp(
        'humtrack_fx_http_test_',
      );
      LoopStorage.rootOverride = root;
      try {
        await LoopStorage.ensureDirs();
        const sr = 44100;
        final pcm = Float32List.fromList(
          List.generate(sr, (i) {
            final envelope = i < sr ~/ 2 ? .55 : .16;
            return envelope *
                (math.sin(2 * math.pi * 225 * i / sr) +
                    .25 * math.sin(2 * math.pi * 450 * i / sr));
          }),
        );
        final dry = encodeWavMono16(pcm, sr);
        await File(LoopStorage.resolveVocal('dry.wav')).writeAsBytes(dry);
        final renderer = vocalFxRenderer('http', 'a');
        final eq = FxNode(type: 'eq', params: {'low': -3.0, 'high': 5.0});
        final comp = FxNode(
          type: 'comp',
          params: {'threshold': -18.0, 'ratio': 4.0},
        );
        final source = VocalClip(
          path: 'dry.wav',
          startStep: 3,
          trimStart: 4410,
          trimEnd: 35280,
          gain: .8,
          fadeInMs: 150,
        );
        final wet = await renderer.render(
          source,
          [eq, comp],
          bpm: 120,
          bars: 2,
        );
        final reduced = await renderer.render(wet, [comp], bpm: 120, bars: 2);
        final expected = await processVocalFx(dry, comp);
        expect(
          await File(LoopStorage.resolveVocal(reduced.path)).readAsBytes(),
          expected,
        );
        expect(reduced.fx.single.type, 'comp');
        expect(reduced.trimStart, source.trimStart);
        expect(reduced.trimEnd, source.trimEnd);
        final cleared = await renderer.render(reduced, [], bpm: 120, bars: 2);
        expect(cleared.path, 'dry.wav');
        expect(cleared.gain, .8);
        expect(cleared.fadeInMs, 150);
        expect(
          await File(LoopStorage.resolveVocal(cleared.path)).readAsBytes(),
          dry,
        );
        final tune = FxNode(
          type: 'autotune',
          params: {
            'keyTonic': 'C',
            'scale': 'major',
            'strength': .7,
            'retuneMs': 120.0,
            'preserveLength': true,
          },
        );
        final tunedEq = await renderer.render(
          source,
          [tune, eq],
          bpm: 120,
          bars: 2,
        );
        final onlyTune = await renderer.render(
          tunedEq,
          [tune],
          bpm: 120,
          bars: 2,
        );
        final tunedExpected = await processVocalFx(dry, tune);
        final actualTune =
            await File(LoopStorage.resolveVocal(onlyTune.path)).readAsBytes();
        expect(actualTune, tunedExpected);
        expect(parseWav(actualTune)!.samples.length, sr);
        final restored = await renderer.restoreOriginal(
          onlyTune,
          bpm: 120,
          bars: 2,
        );
        expect(restored.path, 'dry.wav');
        expect(restored.fx, isEmpty);
        expect(restored.origPath, isNull);
        expect(restored.trimStart, 0);
        expect(restored.gain, 1);
        final before = jsonEncode(wet.toJson());
        await expectLater(
          renderer.render(
            wet,
            [eq, FxNode(type: 'unsupported')],
            bpm: 120,
            bars: 2,
          ),
          throwsA(isA<EngineApiException>()),
        );
        expect(jsonEncode(wet.toJson()), before);
        expect(
          await File(LoopStorage.resolveVocal('dry.wav')).readAsBytes(),
          dry,
        );
        const output = String.fromEnvironment('VOCAL_FX_SMOKE_OUTPUT');
        if (output.isNotEmpty) {
          await File(output).writeAsString(
            jsonEncode({
              'passed': true,
              'realDspRemovalExactPcm': true,
              'autotuneRetained': true,
              'originalRestoredByteExact': true,
              'failedChainUnchanged': true,
              'sourceSamples': sr,
              'tunedSamples': parseWav(actualTune)!.samples.length,
            }),
          );
        }
      } finally {
        LoopStorage.rootOverride = null;
        final target = await root.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (!target.startsWith(
          '$temp${Platform.pathSeparator}humtrack_fx_http_test_',
        )) {
          throw StateError('Unsafe integration cleanup');
        }
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
