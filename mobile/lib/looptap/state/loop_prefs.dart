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

  @visibleForTesting
  static Directory? rootOverride;

  /// Buzz on pad hits / step edits.
  final ValueNotifier<bool> haptics = ValueNotifier<bool>(true);

  /// Play a click while recording (metronome).
  final ValueNotifier<bool> metro = ValueNotifier<bool>(true);

  /// Anonymous product analytics (Clarity + quantitative funnel sink).
  /// Existing releases already collect Clarity under legitimate interest, so
  /// upgrades preserve that behavior while adding an explicit opt-out.
  final ValueNotifier<bool> analyticsEnabled = ValueNotifier<bool>(true);

  /// The policy notice the user has read; changing the notice ID shows it again.
  final ValueNotifier<String?> acknowledgedPolicyNotice = ValueNotifier(null);

  /// Mic/recorder lead-in compensation used to align vocal takes to the loop.
  final ValueNotifier<int> vocalLatencyMs = ValueNotifier<int>(
    Platform.isIOS ? 40 : 110,
  );

  /// User-starred instrument programs by role: melody / bass / drums.
  final ValueNotifier<Map<String, List<int>>> instrumentFavorites =
      ValueNotifier<Map<String, List<int>>>({});

  final ValueNotifier<Map<String, List<int>>> keyboardBindings = ValueNotifier(
    {},
  );

  /// Piano-roll tool settings (app preferences, not song data).
  /// Scale snap: draw / semitone moves land on the song's scale.
  final ValueNotifier<bool> scaleSnap = ValueNotifier<bool>(false);

  /// Piano-roll layout (UI only, docs/specs/grid-usability.md):
  /// 편집 확대 — the grid takes the timeline's and key hints' space.
  final ValueNotifier<bool> gridFocus = ValueNotifier<bool>(false);

  /// Secondary note tools on their own row (off = one merged row).
  final ValueNotifier<bool> gridToolsExpanded = ValueNotifier<bool>(false);

  /// Velocity / chance lane under the roll.
  final ValueNotifier<bool> gridVelocityLane = ValueNotifier<bool>(true);

  /// Desktop timeline (arrangement) collapsed to one row. Phone/tablet only
  /// since ui-001 stage 3: the desktop editor uses [desktopView] instead.
  final ValueNotifier<bool> timelineCollapsed = ValueNotifier<bool>(false);

  /// ui-001 stage 3: the desktop editor's view, 'arrange' (the timeline takes
  /// the window) or 'edit' (a 44 px minimap above the editing surface).
  final ValueNotifier<String> desktopView = ValueNotifier<String>(kDesktopViewEdit);
  static const kDesktopViewEdit = 'edit', kDesktopViewArrange = 'arrange';

  /// ui-001 stage 4: the desktop editor's right inspector open (docked on
  /// windows 1100 px wide or more; narrower windows start with the 40 px bar
  /// and open it over the editor without changing this).
  final ValueNotifier<bool> inspectorOpen = ValueNotifier<bool>(true);

  Future<void> setInspectorOpen(bool open) async {
    inspectorOpen.value = open;
    await _persist();
  }

  Future<void> setDesktopView(String view) async {
    if (view != kDesktopViewEdit && view != kDesktopViewArrange) return;
    desktopView.value = view;
    await _persist();
  }

  /// Quantize: grid id (see `QuantizeGrid.name`), strength 0..100 and
  /// whether note ends are quantized too.
  final ValueNotifier<String> quantizeGrid = ValueNotifier<String>('sixteenth');
  final ValueNotifier<double> quantizeStrength = ValueNotifier<double>(100);
  final ValueNotifier<bool> quantizeEnds = ValueNotifier<bool>(false);

  /// Humanize: timing range as a fraction of a 16th step (0..0.5) and
  /// velocity range (0..40).
  final ValueNotifier<double> humanizeTiming = ValueNotifier<double>(.1);
  final ValueNotifier<int> humanizeVelocity = ValueNotifier<int>(10);

  /// Chord stamp: chord kind (see `ChordType.name`) and inversion 0..2.
  final ValueNotifier<String> chordType = ValueNotifier<String>('diatonic3');
  final ValueNotifier<int> chordInversion = ValueNotifier<int>(0);

  Future<void> setChord({String? type, int? inversion}) async {
    if (type != null) chordType.value = type;
    if (inversion != null) chordInversion.value = inversion.clamp(0, 2).toInt();
    await _persist();
  }

  /// Arpeggiate: style / rate names, gate 10..200 %, octaves 1..4 and
  /// whether the source chord is kept (muted).
  final ValueNotifier<String> arpStyle = ValueNotifier<String>('up');
  final ValueNotifier<String> arpGrid = ValueNotifier<String>('sixteenth');
  final ValueNotifier<int> arpGate = ValueNotifier<int>(90);
  final ValueNotifier<int> arpOctaves = ValueNotifier<int>(1);
  final ValueNotifier<bool> arpKeepOriginal = ValueNotifier<bool>(false);

  Future<void> setArp({
    String? style,
    String? grid,
    int? gate,
    int? octaves,
    bool? keepOriginal,
  }) async {
    if (style != null) arpStyle.value = style;
    if (grid != null) arpGrid.value = grid;
    if (gate != null) arpGate.value = gate.clamp(10, 200).toInt();
    if (octaves != null) arpOctaves.value = octaves.clamp(1, 4).toInt();
    if (keepOriginal != null) arpKeepOriginal.value = keepOriginal;
    await _persist();
  }

  /// gt-001 guitar stroke defaults: the last pattern preset, spread (ms,
  /// 5..60) and accent (%, 50..130) per direction, and falloff (%, 0..40).
  final ValueNotifier<String> strokePattern = ValueNotifier<String>('down');
  final ValueNotifier<int> strokeDownSpread = ValueNotifier<int>(28);
  final ValueNotifier<int> strokeUpSpread = ValueNotifier<int>(18);
  final ValueNotifier<int> strokeFalloff = ValueNotifier<int>(18);
  final ValueNotifier<int> strokeDownAccent = ValueNotifier<int>(100);
  final ValueNotifier<int> strokeUpAccent = ValueNotifier<int>(80);

  Future<void> setStroke({
    String? pattern,
    int? downSpread,
    int? upSpread,
    int? falloff,
    int? downAccent,
    int? upAccent,
  }) async {
    if (pattern != null) strokePattern.value = pattern;
    if (downSpread != null) {
      strokeDownSpread.value = downSpread.clamp(5, 60).toInt();
    }
    if (upSpread != null) strokeUpSpread.value = upSpread.clamp(5, 60).toInt();
    if (falloff != null) strokeFalloff.value = falloff.clamp(0, 40).toInt();
    if (downAccent != null) {
      strokeDownAccent.value = downAccent.clamp(50, 130).toInt();
    }
    if (upAccent != null) {
      strokeUpAccent.value = upAccent.clamp(50, 130).toInt();
    }
    await _persist();
  }

  /// gt-003 articulation defaults for NEW applies only (each note keeps the
  /// snapshot it was given): 짧게 gate (ms), palm-tone gate (ms) and
  /// palm-tone velocity (%).
  final ValueNotifier<int> articulationStaccatoMs = ValueNotifier<int>(120);
  final ValueNotifier<int> articulationPalmMs = ValueNotifier<int>(250);
  final ValueNotifier<int> articulationPalmVelocity = ValueNotifier<int>(85);

  Future<void> setArticulationDefaults({
    int? staccatoMs,
    int? palmMs,
    int? palmVelocity,
  }) async {
    if (staccatoMs != null) {
      articulationStaccatoMs.value = staccatoMs.clamp(30, 1000).toInt();
    }
    if (palmMs != null) {
      articulationPalmMs.value = palmMs.clamp(30, 1000).toInt();
    }
    if (palmVelocity != null) {
      articulationPalmVelocity.value = palmVelocity.clamp(20, 120).toInt();
    }
    await _persist();
  }

  Future<void> setScaleSnap(bool v) async {
    scaleSnap.value = v;
    await _persist();
  }

  Future<void> setGridLayout({
    bool? focus,
    bool? toolsExpanded,
    bool? velocityLane,
    bool? timelineCollapsed,
  }) async {
    if (focus != null) gridFocus.value = focus;
    if (toolsExpanded != null) gridToolsExpanded.value = toolsExpanded;
    if (velocityLane != null) gridVelocityLane.value = velocityLane;
    if (timelineCollapsed != null) {
      this.timelineCollapsed.value = timelineCollapsed;
    }
    await _persist();
  }

  /// Back to the default grid layout (tests / reset).
  @visibleForTesting
  void resetGridLayout() {
    gridFocus.value = false;
    gridToolsExpanded.value = false;
    gridVelocityLane.value = true;
    timelineCollapsed.value = false;
    desktopView.value = kDesktopViewEdit;
    inspectorOpen.value = true;
  }

  Future<void> setQuantize({String? grid, double? strength, bool? ends}) async {
    if (grid != null) quantizeGrid.value = grid;
    if (strength != null) {
      quantizeStrength.value = strength.clamp(0, 100).toDouble();
    }
    if (ends != null) quantizeEnds.value = ends;
    await _persist();
  }

  Future<void> setHumanize({double? timing, int? velocity}) async {
    if (timing != null) humanizeTiming.value = timing.clamp(0, .5).toDouble();
    if (velocity != null) {
      humanizeVelocity.value = velocity.clamp(0, 40).toInt();
    }
    await _persist();
  }

  Future<void> setKeyboardBindings(String group, List<int> keys) async {
    keyboardBindings.value = {...keyboardBindings.value, group: List.of(keys)};
    await _persist();
  }

  bool _loaded = false;

  /// Lets the next [bootstrap] read the file again (an app restart in tests).
  @visibleForTesting
  void debugAllowReload() => _loaded = false;

  static Future<File> _file() async {
    final dir = rootOverride ?? await getApplicationDocumentsDirectory();
    final folder = Directory('${dir.path}/looptap');
    if (!await folder.exists()) await folder.create(recursive: true);
    return File('${folder.path}/prefs.json');
  }

  /// Load persisted values once at app start.
  Future<void> bootstrap() async {
    if (_loaded) return;
    _loaded = true;
    var migrateView = false;
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return;
      final m = (jsonDecode(raw) as Map);
      if (m['keyboardBindings'] is Map) {
        keyboardBindings.value = {
          for (final e in (m['keyboardBindings'] as Map).entries)
            if (e.key is String &&
                e.value is List &&
                (e.value as List).every((v) => v is int))
              e.key as String: List<int>.from(e.value as List),
        };
      }
      if (m['haptics'] is bool) haptics.value = m['haptics'] as bool;
      if (m['scaleSnap'] is bool) scaleSnap.value = m['scaleSnap'] as bool;
      if (m['gridFocus'] is bool) gridFocus.value = m['gridFocus'] as bool;
      if (m['gridToolsExpanded'] is bool) {
        gridToolsExpanded.value = m['gridToolsExpanded'] as bool;
      }
      if (m['gridVelocityLane'] is bool) {
        gridVelocityLane.value = m['gridVelocityLane'] as bool;
      }
      if (m['timelineCollapsed'] is bool) {
        timelineCollapsed.value = m['timelineCollapsed'] as bool;
      }
      // ui-001 stage 3: a saved valid desktopView wins. Missing (older
      // prefs: once, including users whose timeline was collapsed, who were
      // already looking at the editor) or invalid = 'edit', saved right away.
      if (m['inspectorOpen'] is bool) {
        inspectorOpen.value = m['inspectorOpen'] as bool;
      }
      final view = m['desktopView'];
      if (view == kDesktopViewEdit || view == kDesktopViewArrange) {
        desktopView.value = view as String;
      } else {
        desktopView.value = kDesktopViewEdit;
        migrateView = true;
      }
      if (m['quantizeGrid'] is String) {
        quantizeGrid.value = m['quantizeGrid'] as String;
      }
      if (m['quantizeStrength'] is num) {
        quantizeStrength.value =
            (m['quantizeStrength'] as num).toDouble().clamp(0, 100).toDouble();
      }
      if (m['quantizeEnds'] is bool) {
        quantizeEnds.value = m['quantizeEnds'] as bool;
      }
      if (m['humanizeTiming'] is num) {
        humanizeTiming.value =
            (m['humanizeTiming'] as num).toDouble().clamp(0, .5).toDouble();
      }
      if (m['humanizeVelocity'] is num) {
        humanizeVelocity.value =
            (m['humanizeVelocity'] as num).toInt().clamp(0, 40).toInt();
      }
      if (m['chordType'] is String) chordType.value = m['chordType'] as String;
      if (m['chordInversion'] is num) {
        chordInversion.value =
            (m['chordInversion'] as num).toInt().clamp(0, 2).toInt();
      }
      if (m['arpStyle'] is String) arpStyle.value = m['arpStyle'] as String;
      if (m['arpGrid'] is String) arpGrid.value = m['arpGrid'] as String;
      if (m['arpGate'] is num) {
        arpGate.value = (m['arpGate'] as num).toInt().clamp(10, 200).toInt();
      }
      if (m['arpOctaves'] is num) {
        arpOctaves.value = (m['arpOctaves'] as num).toInt().clamp(1, 4).toInt();
      }
      if (m['arpKeepOriginal'] is bool) {
        arpKeepOriginal.value = m['arpKeepOriginal'] as bool;
      }
      if (m['strokePattern'] is String) {
        strokePattern.value = m['strokePattern'] as String;
      }
      int? pct(String k, int lo, int hi) =>
          m[k] is num ? (m[k] as num).toInt().clamp(lo, hi).toInt() : null;
      strokeDownSpread.value =
          pct('strokeDownSpread', 5, 60) ?? strokeDownSpread.value;
      strokeUpSpread.value = pct('strokeUpSpread', 5, 60) ?? strokeUpSpread.value;
      strokeFalloff.value = pct('strokeFalloff', 0, 40) ?? strokeFalloff.value;
      strokeDownAccent.value =
          pct('strokeDownAccent', 50, 130) ?? strokeDownAccent.value;
      strokeUpAccent.value =
          pct('strokeUpAccent', 50, 130) ?? strokeUpAccent.value;
      articulationStaccatoMs.value =
          pct('articulationStaccatoMs', 30, 1000) ??
          articulationStaccatoMs.value;
      articulationPalmMs.value =
          pct('articulationPalmMs', 30, 1000) ?? articulationPalmMs.value;
      articulationPalmVelocity.value =
          pct('articulationPalmVelocity', 20, 120) ??
          articulationPalmVelocity.value;
      if (m['metro'] is bool) metro.value = m['metro'] as bool;
      if (m['analyticsEnabled'] is bool) {
        analyticsEnabled.value = m['analyticsEnabled'] as bool;
      }
      if (m['acknowledgedPolicyNotice'] is String) {
        acknowledgedPolicyNotice.value =
            m['acknowledgedPolicyNotice'] as String;
      }
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
    if (migrateView) await _persist();
  }

  Future<void> _persist() async {
    try {
      final f = await _file();
      await f.writeAsString(
        jsonEncode({
          'keyboardBindings': keyboardBindings.value,
          'haptics': haptics.value,
          'metro': metro.value,
          'analyticsEnabled': analyticsEnabled.value,
          'acknowledgedPolicyNotice': acknowledgedPolicyNotice.value,
          'vocalLatencyMs': vocalLatencyMs.value,
          'instrumentFavorites': instrumentFavorites.value,
          'scaleSnap': scaleSnap.value,
          'gridFocus': gridFocus.value,
          'gridToolsExpanded': gridToolsExpanded.value,
          'gridVelocityLane': gridVelocityLane.value,
          'timelineCollapsed': timelineCollapsed.value,
          'desktopView': desktopView.value,
          'inspectorOpen': inspectorOpen.value,
          'quantizeGrid': quantizeGrid.value,
          'quantizeStrength': quantizeStrength.value,
          'quantizeEnds': quantizeEnds.value,
          'humanizeTiming': humanizeTiming.value,
          'humanizeVelocity': humanizeVelocity.value,
          'chordType': chordType.value,
          'chordInversion': chordInversion.value,
          'arpStyle': arpStyle.value,
          'arpGrid': arpGrid.value,
          'arpGate': arpGate.value,
          'arpOctaves': arpOctaves.value,
          'arpKeepOriginal': arpKeepOriginal.value,
          'strokePattern': strokePattern.value,
          'strokeDownSpread': strokeDownSpread.value,
          'strokeUpSpread': strokeUpSpread.value,
          'strokeFalloff': strokeFalloff.value,
          'strokeDownAccent': strokeDownAccent.value,
          'strokeUpAccent': strokeUpAccent.value,
          'articulationStaccatoMs': articulationStaccatoMs.value,
          'articulationPalmMs': articulationPalmMs.value,
          'articulationPalmVelocity': articulationPalmVelocity.value,
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

  Future<void> acknowledgePolicyNotice(String id) async {
    acknowledgedPolicyNotice.value = id;
    await _persist();
  }

  Future<void> setMetro(bool v) async {
    metro.value = v;
    await _persist();
  }

  Future<void> setAnalyticsEnabled(bool v) async {
    analyticsEnabled.value = v;
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
