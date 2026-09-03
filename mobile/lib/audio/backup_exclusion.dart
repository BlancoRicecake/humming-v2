// iCloud / iTunes backup exclusion for regenerable app data (audit C18).
//
// path_provider's Documents directory maps to the iOS app container's
// Documents/, which iOS backs up to iCloud in full. That is correct for the
// user's irreplaceable work (`looptap/songs.json`, `meta.json`,
// `entitlement.json`, `vocals/`) but wrong for data the app can recreate on
// demand:
//   - `looptap/soundfonts/` — catalog SF2s, 200-400MB each, re-downloadable
//     from the backend
//   - `looptap/exports/`    — rendered WAV/MID, regenerable from the song
// Leaving those in the backup burns the user's iCloud quota and violates the
// iOS Data Storage Guidelines (App Store Review 2.5.x).
//
// The fix is applied IN PLACE — the files stay exactly where they are (moving
// them would strand every already-downloaded font and existing export) and we
// just set NSURLIsExcludedFromBackupKey on the containing directory, which
// covers everything inside it. Applied on every launch at the point each
// directory is resolved, so existing installs get flagged retroactively.
//
// Native side: `excludeFromBackup` on the `humming/audio` MethodChannel
// (ios/Runner/AppDelegate.swift — this lives next to headset.dart, the other
// client of that channel). No-op everywhere except iOS; Android relies on the
// backup rules XML wired into AndroidManifest.xml instead.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('humming/audio');

/// Mark [path] (normally a directory) as excluded from iCloud/iTunes backup.
///
/// Idempotent — re-setting the flag on an already-excluded path is a no-op at
/// the OS level, so callers just invoke it every time the directory is
/// resolved (which is also how existing installs get flagged retroactively).
///
/// Never throws: this decorates cold paths (bootstrap, the export writer)
/// where a failure must not break anything — worst case the directory keeps
/// being backed up. No-op off iOS.
Future<void> excludeFromBackup(String path) async {
  if (!Platform.isIOS || path.isEmpty) return;
  try {
    final ok = await _channel
        .invokeMethod<bool>('excludeFromBackup', <String, Object>{'path': path});
    if (ok != true) debugPrint('[backup] exclude not applied: $path');
  } catch (e) {
    // simulator / older native side / MissingPluginException in tests
    debugPrint('[backup] exclude failed: $path ($e)');
  }
}
