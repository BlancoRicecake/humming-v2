import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/audio/vocal_fx_processor.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/vocal_fx.dart';
import 'package:humming/looptap/music/vocal_fx_catalog.dart';
import 'package:humming/looptap/music/vocal_fx_local.dart';
import 'package:humming/looptap/music/wav_codec.dart';

const sr = 44100;
Float32List tone(double frequency, {int count = sr, double level = .4}) =>
    Float32List.fromList(
      List.generate(
        count,
        (i) => level * math.sin(2 * math.pi * frequency * i / sr),
      ),
    );
Float32List effect(
  String type,
  Float32List y, [
  Map<String, dynamic> params = const {},
]) =>
    parseWav(
      renderLocalVocalFx({
        'type': type,
        'params': params,
        'audio': encodeWavMono16(y, sr),
      }),
    )!.samples;
double rms(Float32List y, [int start = 0, int? end]) {
  var sum = 0.0;
  final b = end ?? y.length;
  for (var i = start; i < b; i++) {
    sum += y[i] * y[i];
  }
  return math.sqrt(sum / (b - start));
}

double amplitude(Float32List y, double frequency) {
  var real = 0.0, imaginary = 0.0;
  for (var i = sr ~/ 4; i < y.length; i++) {
    final phase = 2 * math.pi * frequency * i / sr;
    real += y[i] * math.cos(phase);
    imaginary += y[i] * math.sin(phase);
  }
  return 2 *
      math.sqrt(real * real + imaginary * imaginary) /
      (y.length - sr ~/ 4);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final choice in localVocalEffects) {
    test(
      '${choice.type} preserves silence, duration and finite bounded PCM at each common rate',
      () {
        for (final rate in [8000, 16000, 44100, 48000]) {
          final input = encodeWavMono16(Float32List(rate), rate);
          final output =
              parseWav(
                renderLocalVocalFx({
                  'type': choice.type,
                  'params': choice.params,
                  'audio': input,
                }),
              )!;
          expect(output.sampleRate, rate);
          expect(output.samples.length, rate);
          expect(output.samples.every((v) => v == 0), isTrue);
          final loud = encodeWavMono16(
            Float32List.fromList(
              List.generate(rate, (i) => i % 2 == 0 ? .99 : -.99),
            ),
            rate,
          );
          final wet =
              parseWav(
                renderLocalVocalFx({
                  'type': choice.type,
                  'params': {
                    ...choice.params,
                    'rate': double.nan,
                    'depth': double.infinity,
                  },
                  'audio': loud,
                }),
              )!;
          expect(
            wet.samples.every((v) => v.isFinite && v.abs() <= .981),
            isTrue,
          );
        }
      },
    );
  }
  test(
    'zero mix returns original WAV bytes; invalid formats and effects are rejected',
    () {
      final input = encodeWavMono16(tone(400), sr);
      for (final choice in localVocalEffects) {
        final output = renderLocalVocalFx({
          'type': choice.type,
          'params': {'mix': 0},
          'audio': input,
        });
        expect(output, same(input));
      }
      expect(
        () => renderLocalVocalFx({
          'type': 'unknown',
          'params': {},
          'audio': input,
        }),
        throwsArgumentError,
      );
      expect(
        () => renderLocalVocalFx({
          'type': 'chorus',
          'params': {},
          'audio': Uint8List(4),
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'telephone attenuates lows and highs while preserving speech-band content',
    () {
      final low = effect('telephone', tone(80));
      final mid = effect('telephone', tone(1000));
      final high = effect('telephone', tone(10000));
      expect(rms(mid, sr ~/ 4), greaterThan(.22));
      expect(rms(low, sr ~/ 4), lessThan(rms(mid, sr ~/ 4) * .1));
      expect(rms(high, sr ~/ 4), lessThan(rms(mid, sr ~/ 4) * .1));
    },
  );
  test('gate reduces quiet noise and opens smoothly for voiced phrases', () {
    final input = tone(220, count: sr * 2, level: .0008);
    final voice = tone(220, level: .4);
    input.setRange(sr ~/ 2, sr ~/ 2 + sr, voice);
    final output = effect('gate', input);
    expect(
      rms(output, sr ~/ 4, sr ~/ 2),
      lessThan(rms(input, sr ~/ 4, sr ~/ 2) * .05),
    );
    expect(
      rms(output, sr, sr + sr ~/ 4),
      greaterThan(rms(input, sr, sr + sr ~/ 4) * .95),
    );
    expect(rms(output, sr * 7 ~/ 4), lessThan(rms(input, sr * 7 ~/ 4) * .1));
  });
  test(
    'de-esser attenuates sibilant high-band energy more than low fundamental',
    () {
      final high = tone(8000, level: .5), low = tone(220, level: .5);
      expect(
        rms(effect('deess', high), sr ~/ 4),
        lessThan(rms(high, sr ~/ 4) * .65),
      );
      expect(
        rms(effect('deess', low), sr ~/ 4),
        greaterThan(rms(low, sr ~/ 4) * .9),
      );
    },
  );
  test('saturation adds odd harmonics without DC shift', () {
    final source = tone(200, level: .7);
    final output = effect('saturation', source, {'drive': 4});
    expect(amplitude(output, 600), greaterThan(.02));
    expect(
      output.reduce((a, b) => a + b).abs() / output.length,
      lessThan(.0001),
    );
  });
  test('lo-fi quantizes and holds samples rather than changing clip speed', () {
    final output = effect('lofi', tone(440), {'bits': 6, 'rate': 8000});
    expect(output.toSet().length, lessThan(70));
    var repeats = 0;
    for (var i = 1; i < output.length; i++) {
      if (output[i] == output[i - 1]) repeats++;
    }
    expect(repeats / output.length, greaterThan(.7));
    expect(output.length, sr);
  });
  test(
    'tremolo changes the envelope; robot creates ring-modulation sidebands',
    () {
      final source = tone(400);
      final tremolo = effect('tremolo', source, {'rate': 4, 'depth': 1});
      expect(
        rms(tremolo, 0, sr ~/ 32),
        greaterThan(rms(tremolo, sr * 3 ~/ 32, sr * 5 ~/ 32) * 2),
      );
      final robot = effect('robot', source, {'rate': 80, 'wet': 1});
      expect(amplitude(robot, 320), greaterThan(.15));
      expect(amplitude(robot, 480), greaterThan(.15));
      expect(amplitude(robot, 400), lessThan(.001));
    },
  );
  for (final type in ['chorus', 'doubler', 'flanger']) {
    test(
      '$type adds delayed voices without shifting the dry attack or leading audio',
      () {
        final source = Float32List(sr)..[1000] = .7;
        final output = effect(type, source);
        expect(output.take(1000).every((v) => v == 0), isTrue);
        expect(output[1000], greaterThan(.3));
        expect(output.skip(1001).any((v) => v.abs() > .01), isTrue);
        expect(output.length, sr);
      },
    );
  }
  test(
    'presets are independent, local, and replace other effects while retaining autotune',
    () {
      final clip = VocalClip(
        path: 'wet.wav',
        fx: [
          FxNode(type: 'eq'),
          FxNode(type: 'autotune', params: {'strength': .7}),
        ],
      );
      expect(vocalEffectPresets.length, 8);
      for (final preset in vocalEffectPresets) {
        final chain = vocalPresetChain(clip, preset);
        expect(chain.first.type, 'autotune');
        expect(chain.skip(1).every((f) => isLocalVocalEffect(f.type)), isTrue);
        chain.last.params['mix'] = 0;
        expect(preset.nodes().last.params['mix'], isNot(0));
      }
      expect(clip.fx.length, 2);
    },
  );
  test(
    'all presets use real offline isolates and retain deletion/original restoration',
    () async {
      final dry = encodeWavMono16(tone(225, count: sr ~/ 2), sr);
      final files = <String, Uint8List>{'dry.wav': dry};
      final renderer = VocalFxRenderer(
        read: (path) async => files[path]!,
        process: processVocalFx,
        persist: (bytes) async {
          final path = 'r${files.length}.wav';
          files[path] = bytes;
          return path;
        },
      );
      final source = VocalClip(
        path: 'dry.wav',
        startStep: 4,
        trimStart: 100,
        trimEnd: 18000,
        gain: .8,
        fadeInMs: 150,
      );
      for (final preset in vocalEffectPresets) {
        final wet = await renderer.render(
          source,
          preset.nodes(),
          bpm: 120,
          bars: 2,
        );
        expect(files[wet.path], isNot(dry));
        expect(wet.fx.length, preset.nodes().length);
        expect(wet.trimStart, 100);
        final reduced = await renderer.render(
          wet,
          wet.fx.sublist(1),
          bpm: 120,
          bars: 2,
        );
        expect(reduced.fx.length, wet.fx.length - 1);
        final restored = await renderer.restoreOriginal(
          reduced,
          bpm: 120,
          bars: 2,
        );
        expect(files[restored.path], dry);
        expect(restored.startStep, 4);
        expect(restored.fx, isEmpty);
      }
    },
  );
}
