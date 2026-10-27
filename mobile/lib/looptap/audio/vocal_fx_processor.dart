import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute;

import '../../api/engine_api.dart';
import '../models/loop_models.dart';
import '../music/vocal_fx.dart';
import '../music/vocal_fx_local.dart';
import '../music/wav_codec.dart';
import '../state/loop_storage.dart';

VocalFxRenderer vocalFxRenderer(String songId, String sectionId) =>
    VocalFxRenderer(
      read: (path) => File(LoopStorage.resolveVocal(path)).readAsBytes(),
      process: processVocalFx,
      persist: (bytes) async {
        final path = await LoopStorage.saveVocalBytes(
          bytes,
          songId,
          sectionId,
          suffix: '_fx',
        );
        if (path == null) throw const FileSystemException('Vocal save failed');
        return path;
      },
    );

/// Only the completed chain is persisted. Intermediate PCM travels in memory,
/// so a failed upload cannot leave an open temporary file on Windows.
Future<Uint8List> processVocalFx(Uint8List audio, FxNode fx) async {
  if (isLocalVocalEffect(fx.type)) {
    return compute(renderLocalVocalFx, {
      'audio': audio,
      'type': fx.type,
      'params': Map<String, dynamic>.from(fx.params),
    });
  }
  final api = EngineApi();
  if (fx.type != 'autotune') {
    return (await api.processFxBytes(
      audio,
      fxType: fx.type,
      params: fx.params,
    )).wav;
  }
  final p = fx.params;
  var bytes =
      (await api.autotuneVocalBytes(
        audio,
        keyTonic: p['keyTonic'] as String,
        scale: p['scale'] as String,
        strength: (p['strength'] as num).toDouble(),
        retuneMs: (p['retuneMs'] as num).toDouble(),
      )).wav;
  if (p['preserveLength'] == true) {
    final input = parseWav(audio);
    final output = parseWav(bytes);
    if (input == null || output == null) {
      throw const FormatException('Invalid autotune audio');
    }
    final pcm =
        output.sampleRate == 44100
            ? output.samples
            : resampleLinear(output.samples, output.sampleRate, 44100);
    final fixed = Float32List(
      (input.samples.length * 44100 / input.sampleRate).round(),
    );
    fixed.setRange(0, pcm.length.clamp(0, fixed.length), pcm);
    bytes = encodeWavMono16(fixed, 44100);
  }
  return bytes;
}
