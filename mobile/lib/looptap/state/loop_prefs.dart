// LoopTap settings prefs — haptics / metronome toggles, persisted to a single
// JSON file <Documents>/looptap/prefs.json (mirrors LoopStorage's pattern).
//
// Exposed as a tiny singleton with ValueNotifiers so deep widgets (pad_fx,
// step_grid) can gate haptics without Provider plumbing, and the Settings sheet
// can two-way bind the switches. Bootstrap once in main_looptap.dart's main().
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class LoopPrefs {
  LoopPrefs._();
  static final LoopPrefs instance = LoopPrefs._();

  /// Buzz on pad hits / step edits.
  final ValueNotifier<bool> haptics = ValueNotifier<bool>(true);

  /// Play a click while recording (metronome).
  final ValueNotifier<bool> metro = ValueNotifier<bool>(true);

  bool _loaded = false;

  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/looptap');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/prefs.json');
  }

  /// Load persisted values once at app start.
  Future<void> bootstrap() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final m = (jsonDecode(raw) as Map);
      if (m['haptics'] is bool) haptics.value = m['haptics'] as bool;
      if (m['metro'] is bool) metro.value = m['metro'] as bool;
    } catch (e) {
      debugPrint('[looptap] prefs load failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode({'haptics': haptics.value, 'metro': metro.value}));
    } catch (e) {
      debugPrint('[looptap] prefs save failed: $e');
    }
  }

  Future<void> setHaptics(bool v) async {
    haptics.value = v;
    await _persist();
  }

  Future<void> setMetro(bool v) async {
    metro.value = v;
    await _persist();
  }
}
