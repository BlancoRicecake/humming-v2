import 'dart:math' as math;
import 'dart:typed_data';
import '../models/loop_models.dart';
import 'wav_codec.dart';
import 'wav_export.dart';

class VocalComparison {
  const VocalComparison(this.original, this.processed);
  final Float32List original, processed;
}

/// Match placement, selected source region, gain and fades on both sides.
/// Optional RMS matching is for monitoring only; saved/exported audio is untouched.
VocalComparison vocalComparison(
  List<VocalClip> clips,
  Map<String, WavData> sources, {
  required int bars,
  required int bpm,
  bool matchLevel = true,
}) {
  final dry = <VocalClip>[];
  for (final c in clips) {
    final name = c.origPath ?? c.fxSourcePath ?? c.path;
    final from = sources[c.path], to = sources[name];
    if (from == null ||
        to == null ||
        from.samples.isEmpty ||
        to.samples.isEmpty) {
      throw const FormatException('Missing comparison source');
    }
    final ratio = to.samples.length / from.samples.length;
    final copy =
        c.copy()
          ..path = name
          ..origPath = null
          ..fxSourcePath = null
          ..trimStart = (c.trimStart * ratio).round().clamp(
            0,
            to.samples.length - 1,
          );
    copy.trimEnd =
        c.trimEnd == -1
            ? -1
            : (c.trimEnd * ratio).round().clamp(
              copy.trimStart + 1,
              to.samples.length,
            );
    copy.fx.clear();
    dry.add(copy);
  }
  final data = {
    for (final e in sources.entries)
      e.key: (pcm: e.value.samples, sampleRate: e.value.sampleRate),
  };
  final length = (bars * 4 * 60 / bpm * 44100).round();
  final original = bounceVocalClips(dry, bars, bpm, data, minLen: length);
  final processed = bounceVocalClips(clips, bars, bpm, data, minLen: length);
  if (matchLevel) {
    double rms(Float32List y) {
      if (y.isEmpty) return 0;
      var sum = 0.0;
      for (final s in y) {
        sum += s * s;
      }
      return math.sqrt(sum / y.length);
    }

    final a = rms(original), b = rms(processed);
    if (a > .00001 && b > .00001) {
      final wetGain = (a / b).clamp(.25, 4.0);
      var peak = 0.0;
      for (final s in original) {
        peak = math.max(peak, s.abs());
      }
      for (final s in processed) {
        peak = math.max(peak, s.abs() * wetGain);
      }
      final bothGain = peak > .94 ? .94 / peak : 1.0;
      for (var i = 0; i < original.length; i++) {
        original[i] *= bothGain;
      }
      for (var i = 0; i < processed.length; i++) {
        processed[i] *= wetGain * bothGain;
      }
    }
  }
  return VocalComparison(original, processed);
}
