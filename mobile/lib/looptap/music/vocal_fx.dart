import 'dart:typed_data';

import '../models/loop_models.dart';
import 'theory.dart';
import 'wav_codec.dart';

class VocalFxSourceMissing implements Exception {}

/// Reads and renders into detached copies. A failed read, DSP request or write
/// never changes the caller's clip, history or currently audible file.
class VocalFxRenderer {
  const VocalFxRenderer({
    required this.read,
    required this.process,
    required this.persist,
  });

  final Future<Uint8List> Function(String path) read;
  final Future<Uint8List> Function(Uint8List audio, FxNode fx) process;
  final Future<String> Function(Uint8List audio) persist;

  Future<VocalClip> render(
    VocalClip clip,
    List<FxNode> effects, {
    required int bpm,
    required int bars,
  }) async {
    final chain = effects.map((f) => f.copy()).toList();
    final base =
        clip.fxSourcePath ?? (clip.fx.isEmpty ? clip.path : clip.origPath);
    if (base == null) throw VocalFxSourceMissing();
    final old = _decode(await read(clip.path));
    var bytes = await read(base);
    var audio = _decode(bytes);
    var processed = false;
    for (final fx in chain.where((f) => f.enabled)) {
      bytes = await process(bytes, fx);
      audio = _decode(bytes);
      processed = true;
    }
    // Removing the last effect restores the actual source file byte-for-byte.
    final path = processed ? await persist(bytes) : base;
    final out =
        clip.copy()
          ..path = path
          ..origPath = clip.origPath ?? (processed ? base : null)
          ..fxSourcePath = chain.isEmpty ? null : base;
    if (chain.isEmpty && out.origPath == base) out.origPath = null;
    out.fx
      ..clear()
      ..addAll(chain);
    // Trim positions belong to the old PCM domain. Preserve the selected
    // portion through stretch/removal and sample-rate changes, not stale indices.
    final ratio = audio.samples.length / old.samples.length;
    out.trimStart = (clip.trimStart * ratio).round().clamp(
      0,
      audio.samples.length - 1,
    );
    out.trimEnd =
        clip.trimEnd == -1
            ? -1
            : (clip.trimEnd * ratio).round().clamp(
              out.trimStart + 1,
              audio.samples.length,
            );
    return measureVocalClip(out, audio, bpm: bpm, bars: bars);
  }

  /// Full restoration also removes trim, fades and gain. Placement is retained.
  Future<VocalClip> restoreOriginal(
    VocalClip clip, {
    required int bpm,
    required int bars,
  }) async {
    final path = clip.origPath ?? clip.fxSourcePath ?? clip.path;
    final audio = _decode(await read(path));
    final out =
        clip.copy()
          ..path = path
          ..origPath = null
          ..fxSourcePath = null
          ..trimStart = 0
          ..trimEnd = -1
          ..gain = 1
          ..fadeInMs = 0
          ..fadeOutMs = 0;
    out.fx.clear();
    return measureVocalClip(out, audio, bpm: bpm, bars: bars);
  }

  WavData _decode(Uint8List bytes) {
    final audio = parseWav(bytes);
    if (audio == null || audio.samples.isEmpty) {
      throw const FormatException('Invalid vocal audio');
    }
    return audio;
  }
}

VocalClip measureVocalClip(
  VocalClip clip,
  WavData audio, {
  required int bpm,
  required int bars,
}) {
  final out = clip.copy();
  final a = out.trimStart.clamp(0, audio.samples.length);
  final b = (out.trimEnd == -1 ? audio.samples.length : out.trimEnd).clamp(
    a,
    audio.samples.length,
  );
  out.peaks = peaksFromPcm(trimPcm(audio.samples, a, b), buckets: 64);
  out.durSteps = ((b - a) / audio.sampleRate / (60 / bpm / kStepsPerBeat))
      .round()
      .clamp(1, stepsForBars(bars));
  return out;
}
