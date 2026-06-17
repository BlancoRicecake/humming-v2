// Output-route detection over the `humming/audio` MethodChannel
// (Android: MainActivity.kt, iOS: AppDelegate.swift).
//
// Why the route TYPE matters and not just presence:
//  - any headset → safe to play the backing loop while recording (no bleed)
//  - WIRED only → low enough round-trip latency for live autotune monitoring
//    (Bluetooth adds 150-300ms each way — disorienting to sing against)
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart' show IosAudioCategory;

import 'melty_synth_backend.dart';

enum HeadsetRoute { wired, bluetooth, none }

const _channel = MethodChannel('humming/audio');

/// Prepare the iOS audio stack for a mic recording *before* opening the mic.
///
/// The recorder switches the shared session to `.playAndRecord`. If
/// flutter_pcm_sound's output engine is still bound to `.playback` when that
/// happens, the session change breaks it — the backing loop garbles during the
/// take and pad taps go muddy/silent afterward. So we bind the output engine to
/// `.playAndRecord` up front (and set the native session to .playAndRecord on
/// speaker at 44.1 kHz); the recorder then re-applies its own good options
/// (defaultToSpeaker/mixWithOthers) as a mere route change the live engine
/// survives. Call right before `recorder.start()`. No-op on Android.
Future<void> prepareRecordingSession() async {
  if (!Platform.isIOS) return;
  // Re-create the output engine bound to .playAndRecord first…
  await MeltyEngine().restartOutput(category: IosAudioCategory.playAndRecord);
  // …then re-assert the session with speaker routing + 44.1 kHz (the
  // flutter_pcm_sound setup above only sets a bare category).
  try {
    await _channel.invokeMethod<void>('configureRecordingSession');
  } catch (_) {
    // older native side without the handler → MissingPluginException; ignore
  }
}

/// Restore the resting `.playback` session after a recording and re-bind the
/// synth output to it. The recorder leaves the session in `.playAndRecord`; if
/// flutter_pcm_sound keeps running against that, playback comes out muddy/
/// silent. Call right after the recorder stops. No-op on Android.
Future<void> restorePlaybackSession() async {
  if (!Platform.isIOS) return;
  try {
    await _channel.invokeMethod<void>('restorePlaybackSession');
  } catch (_) {
    // older native side without the handler → MissingPluginException; ignore
  }
  // Re-create the PCM output bound to the just-restored .playback session.
  await MeltyEngine().restartOutput(category: IosAudioCategory.playback);
}

/// Current audio output route. Errors (simulator, missing impl) → none.
Future<HeadsetRoute> headsetRoute() async {
  try {
    final r = await _channel.invokeMethod<String>('headsetRoute');
    switch (r) {
      case 'wired':
        return HeadsetRoute.wired;
      case 'bluetooth':
        return HeadsetRoute.bluetooth;
      default:
        return HeadsetRoute.none;
    }
  } on PlatformException {
    return _presenceFallback();
  } on MissingPluginException {
    // notImplemented/missing handler surfaces as MissingPluginException,
    // NOT PlatformException — same conservative fallback
    return _presenceFallback();
  } catch (_) {
    return HeadsetRoute.none;
  }
}

/// Older native side without headsetRoute — presence only, assume the
/// conservative type (bluetooth: backing OK, no live monitoring).
Future<HeadsetRoute> _presenceFallback() async {
  try {
    final has = await _channel.invokeMethod<bool>('hasHeadset') ?? false;
    return has ? HeadsetRoute.bluetooth : HeadsetRoute.none;
  } catch (_) {
    return HeadsetRoute.none;
  }
}

/// Any headset (wired/BT/USB) on the output — safe to monitor the backing
/// loop while the mic is open.
Future<bool> hasHeadset() async => (await headsetRoute()) != HeadsetRoute.none;
