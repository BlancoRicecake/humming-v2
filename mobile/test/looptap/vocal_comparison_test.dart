import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/vocal_comparison.dart';
import 'package:humming/looptap/music/wav_codec.dart';

WavData constant(double value, int sr, int count) => WavData(
  samples: Float32List.fromList(List.filled(count, value)),
  sampleRate: sr,
  channels: 1,
);
double rms(Float32List values) =>
    math.sqrt(values.fold<double>(0, (sum, x) => sum + x * x) / values.length);

void main() {
  test(
    'comparison keeps trim, placement and gain across different source rates',
    () {
      final clip = VocalClip(
        path: 'wet',
        origPath: 'dry',
        startStep: 2,
        trimStart: 4000,
        trimEnd: 12000,
        gain: .5,
        fx: [FxNode(type: 'chorus')],
      );
      final before = jsonEncode(clip.toJson());
      final out = vocalComparison(
        [clip],
        {'wet': constant(.25, 16000, 16000), 'dry': constant(.5, 8000, 8000)},
        bars: 2,
        bpm: 120,
        matchLevel: false,
      );
      expect(out.original.length, 176400);
      expect(out.processed.length, out.original.length);
      expect(out.original.take(11025).every((v) => v == 0), isTrue);
      expect(out.original[12000], .25);
      expect(out.processed[12000], .125);
      expect(out.original.skip(33075).every((v) => v == 0), isTrue);
      expect(jsonEncode(clip.toJson()), before);
    },
  );
  test(
    'level matching changes only monitor buffers and keeps output below ceiling',
    () {
      final dry = constant(.9, 8000, 8000), wet = constant(.15, 8000, 8000);
      final clip = VocalClip(path: 'wet', origPath: 'dry');
      final out = vocalComparison(
        [clip],
        {'wet': wet, 'dry': dry},
        bars: 2,
        bpm: 120,
      );
      // Gain is capped at 4 to avoid amplifying nearly silent noise.
      expect(rms(out.processed) / rms(out.original), closeTo(2 / 3, .001));
      expect(out.original.every((v) => v.abs() <= .941), isTrue);
      expect(out.processed.every((v) => v.abs() <= .941), isTrue);
      expect(dry.samples.first, closeTo(.9, .0001));
      expect(wet.samples.first, closeTo(.15, .0001));
      final equal = vocalComparison(
        [clip],
        {'wet': constant(.2, 8000, 8000), 'dry': constant(.5, 8000, 8000)},
        bars: 2,
        bpm: 120,
      );
      expect(rms(equal.processed), closeTo(rms(equal.original), .00001));
    },
  );
  test(
    'silence is not amplified and missing originals cannot silently play wet as dry',
    () {
      final c = VocalClip(path: 'wet', origPath: 'dry');
      final out = vocalComparison(
        [c],
        {'wet': constant(0, 8000, 8000), 'dry': constant(0, 8000, 8000)},
        bars: 2,
        bpm: 120,
      );
      expect(out.original.every((v) => v == 0), isTrue);
      expect(out.processed.every((v) => v == 0), isTrue);
      expect(
        () => vocalComparison(
          [c],
          {'wet': constant(.1, 8000, 8000)},
          bars: 2,
          bpm: 120,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'stretch comparison maps the same source region and retains equal loop length',
    () {
      final c = VocalClip(
        path: 'wet',
        origPath: 'dry',
        trimStart: 8000,
        trimEnd: 24000,
        fadeInMs: 100,
        fadeOutMs: 100,
      );
      final out = vocalComparison(
        [c],
        {'wet': constant(.2, 16000, 32000), 'dry': constant(.2, 8000, 8000)},
        bars: 2,
        bpm: 120,
        matchLevel: false,
      );
      expect(out.original.length, out.processed.length);
      expect(out.original.first, closeTo(0, .00001));
      expect(out.processed.first, closeTo(0, .00001));
      expect(out.original[5000], closeTo(.2, .0001));
      expect(out.original.skip(22050).every((v) => v == 0), isTrue);
      expect(out.processed[30000], closeTo(.2, .0001));
    },
  );
}
