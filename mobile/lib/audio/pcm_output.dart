import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

/// Platform output only; synthesis, instruments and song data remain shared.
class PcmOutput {
  static const _channel = MethodChannel('humtrack/desktop_pcm');
  static Timer? _timer;
  static void Function(int)? _callback;
  static int _threshold = 1024, _generation = 0;
  static bool _polling = false;
  static Future<void> setLogLevel(LogLevel level) async {
    if (!Platform.isWindows) await FlutterPcmSound.setLogLevel(level);
  }

  static Future<void> setup({
    required int sampleRate,
    required int channelCount,
    IosAudioCategory iosAudioCategory = IosAudioCategory.playback,
  }) async {
    if (!Platform.isWindows) {
      await FlutterPcmSound.setup(
        sampleRate: sampleRate,
        channelCount: channelCount,
        iosAudioCategory: iosAudioCategory,
      );
      return;
    }
    _timer?.cancel();
    final generation = ++_generation;
    await _channel.invokeMethod<void>('setup', {
      'sampleRate': sampleRate,
      'channels': channelCount,
    });
    if (generation != _generation) return;
    _timer = Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => _poll(generation),
    );
  }

  static Future<void> _poll(int generation) async {
    if (_polling || generation != _generation) return;
    _polling = true;
    try {
      final remaining = await _channel.invokeMethod<int>('remainingFrames');
      if (generation == _generation &&
          remaining != null &&
          remaining <= _threshold) {
        _callback?.call(remaining);
      }
    } catch (_) {
      if (generation == _generation) {
        _timer?.cancel();
        // A feed on the failed device propagates to the synth's bounded recovery.
        _callback?.call(0);
      }
    } finally {
      _polling = false;
    }
  }

  static Future<void> setFeedThreshold(int value) async {
    _threshold = value;
    if (!Platform.isWindows) await FlutterPcmSound.setFeedThreshold(value);
  }

  static void setFeedCallback(void Function(int)? callback) {
    _callback = callback;
    if (!Platform.isWindows) FlutterPcmSound.setFeedCallback(callback);
  }

  static bool start() {
    if (!Platform.isWindows) return FlutterPcmSound.start();
    _callback?.call(0);
    return _callback != null;
  }

  static Future<void> feed(PcmArrayInt16 samples) async {
    if (!Platform.isWindows) {
      await FlutterPcmSound.feed(samples);
      return;
    }
    await _channel.invokeMethod<void>(
      'feed',
      samples.bytes.buffer.asUint8List(),
    );
  }

  static Future<void> release() async {
    if (!Platform.isWindows) {
      await FlutterPcmSound.release();
      return;
    }
    ++_generation;
    _timer?.cancel();
    _timer = null;
    await _channel.invokeMethod<void>('release');
  }
}
