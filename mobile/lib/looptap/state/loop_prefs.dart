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

  /// Mic/recorder lead-in compensation used to align vocal takes to the loop.
  final ValueNotifier<int> vocalLatencyMs = ValueNotifier<int>(
    Platform.isIOS ? 40 : 110,
  );

  /// User-starred instrument programs by role: melody / bass / drums.
  final ValueNotifier<Map<String, List<int>>> instrumentFavorites =
      ValueNotifier<Map<String, List<int>>>({});

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
      if (m['vocalLatencyMs'] is num) {
        vocalLatencyMs.value =
            (m['vocalLatencyMs'] as num).toInt().clamp(0, 250).toInt();
      }
      if (m['instrumentFavorites'] is Map) {
        final favs = <String, List<int>>{};
        (m['instrumentFavorites'] as Map).forEach((key, value) {
          if (key is! String || value is! List) return;
          favs[key] = [
            for (final v in value)
              if (v is num) v.toInt(),
          ];
        });
        instrumentFavorites.value = favs;
      }
    } catch (e) {
      debugPrint('[looptap] prefs load failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'haptics': haptics.value,
          'metro': metro.value,
          'vocalLatencyMs': vocalLatencyMs.value,
          'instrumentFavorites': instrumentFavorites.value,
        }),
      );
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

  Future<void> setVocalLatencyMs(int v) async {
    vocalLatencyMs.value = v.clamp(0, 250).toInt();
    await _persist();
  }

  List<int> favoritesForInstrumentRole(String role) =>
      List<int>.of(instrumentFavorites.value[role] ?? const []);

  bool isInstrumentFavorite(String role, int program) =>
      instrumentFavorites.value[role]?.contains(program) ?? false;

  Future<void> toggleInstrumentFavorite(String role, int program) async {
    final next = {
      for (final e in instrumentFavorites.value.entries)
        e.key: List<int>.of(e.value),
    };
    final list = next.putIfAbsent(role, () => <int>[]);
    if (list.contains(program)) {
      list.remove(program);
    } else {
      list.add(program);
      list.sort();
    }
    if (list.isEmpty) next.remove(role);
    instrumentFavorites.value = next;
    await _persist();
  }
}
