// Output-route detection over the `humming/audio` MethodChannel
// (Android: MainActivity.kt, iOS: AppDelegate.swift).
//
// Why the route TYPE matters and not just presence:
//  - any headset → safe to play the backing loop while recording (no bleed)
//  - WIRED only → low enough round-trip latency for live autotune monitoring
//    (Bluetooth adds 150-300ms each way — disorienting to sing against)
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

enum HeadsetRoute { wired, bluetooth, none }

const _channel = MethodChannel('humming/audio');

/// AVAudioSession interruption (iOS) forwarded by AppDelegate.swift over the
/// `humming/audio` channel. [began] = the system stopped our audio (phone
/// call, Siri, alarm); otherwise the interruption ended and [shouldResume]
/// mirrors `.shouldResume` (the native side already re-activated the session
/// when it is set).
class AudioInterruptionEvent {
  const AudioInterruptionEvent({required this.began, required this.shouldResume});
  final bool began;
  final bool shouldResume;
}

void Function(AudioInterruptionEvent)? _interruptionListener;
bool _callHandlerInstalled = false;

/// Register the (single) listener for native audio-interruption events. The
/// channel's method-call handler is installed on first use.
void setAudioInterruptionListener(void Function(AudioInterruptionEvent)? listener) {
  _interruptionListener = listener;
  if (_callHandlerInstalled) return;
  _callHandlerInstalled = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'audioInterruption') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    _interruptionListener?.call(AudioInterruptionEvent(
      began: args['began'] == true,
      shouldResume: args['shouldResume'] == true,
    ));
    return null;
  });
}

/// Android `Build.VERSION.SDK_INT`, or null off Android / on error.
Future<int?> androidSdkInt() async {
  if (!Platform.isAndroid) return null;
  try {
    return await _channel.invokeMethod<int>('sdkInt');
  } catch (_) {
    return null;
  }
}

/// Open this app's page in the OS Settings (where the user re-enables a
/// denied microphone permission). iOS: the `app-settings:` URL via
/// url_launcher; Android: ACTION_APPLICATION_DETAILS_SETTINGS on the native
/// side. Returns false when nothing could be opened.
Future<bool> openAppSettings() async {
  try {
    if (Platform.isIOS) {
      return await launchUrl(Uri.parse('app-settings:'));
    }
    if (Platform.isAndroid) {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    }
  } catch (_) {/* simulator / older native side */}
  return false;
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

/// Current shared AVAudioSession hardware sample rate (iOS), or null if
/// unavailable. Record at this exact rate so recording doesn't drag the hardware
/// to a lower rate and leave it there (the synth output then crackles after).
Future<int?> outputSampleRate() async {
  try {
    final r = await _channel.invokeMethod<double>('outputSampleRate');
    if (r == null || r <= 0) return null;
    return r.round();
  } catch (_) {
    return null;
  }
}

/// Full session reset to .playback (iOS): deactivate → .playback → reactivate.
///
/// Recording configures the shared session for duplex IO; flipping the category
/// back on an active session doesn't undo that, so the synth output stays
/// crackly after. This forces a clean hardware-IO renegotiation. Call with the
/// PCM output unit already released (nothing rendering across the reset).
Future<void> resetToPlaybackSession() async {
  try {
    await _channel.invokeMethod<bool>('resetToPlaybackSession');
  } catch (_) {/* Android / simulator / older native side */}
}

/// Force output to the built-in speaker (iOS, only while .playAndRecord).
///
/// Used after rebuilding the synth output under .playAndRecord during recording:
/// flutter_pcm_sound's setCategory drops the .defaultToSpeaker option, so without
/// this the backing would play out the quiet receiver. No-op off iOS / on error.
Future<void> overrideOutputToSpeaker() async {
  try {
    await _channel.invokeMethod<bool>('overrideOutputToSpeaker');
  } catch (_) {/* simulator / Android / older native side */}
}
