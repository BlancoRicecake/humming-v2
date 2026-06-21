// Live autotune monitoring over the `humming/autotune_monitor` MethodChannel
// (iOS: AutotuneMonitor.swift — AVAudioEngine mic→TimePitch→headphones).
//
// iOS + WIRED headphones only: Bluetooth round-trip latency (150-300 ms)
// makes live monitoring disorienting, and Android needs an Oboe/C++ path
// that hasn't been built yet. The recorded take stays DRY — this only colors
// what the singer hears; the final take goes through the server-side
// /autotune with the same key/scale, so monitored ≈ final.
import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('humming/autotune_monitor');

/// Whether live monitoring is implemented on this platform at all.
bool get autotuneMonitorSupported => Platform.isIOS;

/// Fired when the NATIVE side stops the monitor on its own (wired headphones
/// unplugged mid-recording → route-change stop). The recording UI sets this
/// to clear its "LIVE AUTOTUNE" badge; cleared (set null) on dispose.
void Function()? onAutotuneMonitorStopped;

bool _callHandlerInstalled = false;

void _ensureCallHandler() {
  if (_callHandlerInstalled) return;
  _callHandlerInstalled = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method == 'monitorStopped') onAutotuneMonitorStopped?.call();
  });
}

/// Start the native monitor graph. Returns false when unavailable (no native
/// impl, engine start failure, mic conflict) — caller records un-monitored.
Future<bool> startAutotuneMonitor({
  required String key,
  required String scale,
  double strength = 1.0,
}) async {
  if (!autotuneMonitorSupported) return false;
  _ensureCallHandler();
  try {
    return await _channel.invokeMethod<bool>('start', {
          'key': key,
          'scale': scale,
          'strength': strength,
        }) ??
        false;
  } catch (_) {
    return false;
  }
}

Future<void> stopAutotuneMonitor() async {
  if (!autotuneMonitorSupported) return;
  try {
    await _channel.invokeMethod<void>('stop');
  } catch (_) {}
}

/// Deactivate the shared AVAudioSession the monitor activated. Call AFTER the
/// recorder has fully stopped — [stopAutotuneMonitor] alone keeps the session
/// active because the modal stops the monitor while the recorder is still
/// writing, and deactivating then would cut the take short. No-op when the
/// monitor never activated the session.
Future<void> releaseAutotuneMonitorSession() async {
  if (!autotuneMonitorSupported) return;
  try {
    await _channel.invokeMethod<void>('releaseSession');
  } catch (_) {}
}
