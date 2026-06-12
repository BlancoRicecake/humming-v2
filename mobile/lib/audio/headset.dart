// Output-route detection over the `humming/audio` MethodChannel
// (Android: MainActivity.kt, iOS: AppDelegate.swift).
//
// Why the route TYPE matters and not just presence:
//  - any headset → safe to play the backing loop while recording (no bleed)
//  - WIRED only → low enough round-trip latency for live autotune monitoring
//    (Bluetooth adds 150-300ms each way — disorienting to sing against)
import 'package:flutter/services.dart';

enum HeadsetRoute { wired, bluetooth, none }

const _channel = MethodChannel('humming/audio');

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
