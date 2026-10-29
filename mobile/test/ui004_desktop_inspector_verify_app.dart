// QA-only Windows verification entry point for ui-001 stage 4 (the desktop
// inspector and the tool row). Never part of the product build.
//
// Same isolation as ui003_view_modes_verify_app.dart: the REAL app
// (app.main()) with every path_provider location redirected into a sandbox
// inside the repo and an in-memory shared_preferences store (the user's songs
// / prefs / AppData are never read or written; LoopPrefs' prefs.json lands in
// the sandbox). On a sandbox song it checks and captures, in Korean and then
// English, through the widgets' own callbacks (code, not mouse / keyboard
// input): the docked inspector's Track tab, the grid tool row, the Notes tab
// (select all, octave, velocity slider draft / commit, undo), Track-tab volume
// vs the mixer, Ctrl/Cmd+I collapse (saved), the drum grid's tools / Notes
// tab, the arrange view's Track tab, and the editor in a 960x600 box (bar,
// then the inspector over the editor) with the real fonts.
//
// UI004_WAIT=1 (environment variable at launch): after the automatic part
// the app does NOT exit; it stays on the editor (Korean, edit view) for real
// mouse / keyboard checks.
//
// Build (debug: the root-layer capture uses debugLayer):
//   flutter build windows --debug --no-pub -t test/ui004_desktop_inspector_verify_app.dart
//     --dart-define=UI004_ROOT=<dir inside C:/src/humming-v2>
// Launch with TMP/TEMP inside the repo (the app refuses otherwise).
//
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_inspector.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/sheets/mixer_sheet.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/services/locale_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'UI004_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\ui-004-desktop-inspector\verify',
);

String _inside(String path) {
  final full = p.normalize(p.absolute(path));
  if (!p.isWithin(p.normalize(_workspace), full)) {
    throw StateError('QA path escapes $_workspace: $path -> $full');
  }
  return full;
}

class _QaPathProvider extends PathProviderPlatform {
  _QaPathProvider(this.dirs);
  final Map<String, String> dirs;
  @override
  Future<String?> getApplicationDocumentsPath() async => dirs['documents'];
  @override
  Future<String?> getApplicationSupportPath() async => dirs['support'];
  @override
  Future<String?> getApplicationCachePath() async => dirs['cache'];
  @override
  Future<String?> getTemporaryPath() async => dirs['temp'];
  @override
  Future<String?> getLibraryPath() async => dirs['library'];
  @override
  Future<String?> getDownloadsPath() async => dirs['downloads'];
  @override
  Future<String?> getExternalStoragePath() async => dirs['documents'];
  @override
  Future<List<String>?> getExternalCachePaths() async => [dirs['cache']!];
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => [dirs['documents']!];
}

T? find<T extends Widget>([Key? key]) {
  T? result;
  void visit(Element element) {
    if (element.widget is T && (key == null || element.widget.key == key)) {
      result ??= element.widget as T;
    }
    element.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return result;
}

/// Global rect of the first render box under [key].
Rect? rectOf(Key key) {
  Rect? result;
  void visit(Element e) {
    if (result != null) return;
    if (e.widget.key == key) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize) {
        result = box.localToGlobal(Offset.zero) & box.size;
        return;
      }
    }
    e.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return result;
}

/// Text widgets under [key].
int textsUnder(Key key) {
  var n = 0;
  void count(Element e) {
    if (e.widget is Text) n++;
    e.visitChildren(count);
  }

  void start(Element e) {
    if (e.widget.key == key) {
      count(e);
      return;
    }
    e.visitChildren(start);
  }

  start(WidgetsBinding.instance.rootElement!);
  return n;
}

/// The nearest GestureDetector tap above a Text showing [label].
VoidCallback? tapOfText(String label) {
  VoidCallback? found;
  void visit(Element e, VoidCallback? tap) {
    if (found != null) return;
    final w = e.widget;
    if (w is GestureDetector && w.onTap != null) tap = w.onTap;
    if (w is Text && w.data == label && tap != null) {
      found = tap;
      return;
    }
    e.visitChildren((c) => visit(c, tap));
  }

  visit(WidgetsBinding.instance.rootElement!, null);
  return found;
}


/// The tap / press callback under [key]: a GestureDetector's onTap, an
/// InkResponse's onTap or a button's onPressed (the first one found).
VoidCallback? tapOf(Key key) {
  VoidCallback? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is GestureDetector && w.onTap != null) found = w.onTap;
    if (w is InkResponse && w.onTap != null) found = w.onTap;
    if (w is ButtonStyleButton && w.onPressed != null) found = w.onPressed;
    if (found == null) e.visitChildren(visit);
  }

  void start(Element e) {
    if (found != null) return;
    if (e.widget.key == key) {
      visit(e);
      return;
    }
    e.visitChildren(start);
  }

  start(WidgetsBinding.instance.rootElement!);
  return found;
}

String? textOf(Key key) => find<Text>(key)?.data;

/// The element of the first [T] widget (its own context, e.g. to close the
/// route it is in).
Element? elementOf<T extends Widget>() {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    if (e.widget is T) {
      found = e;
      return;
    }
    e.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return found;
}

Song _song() {
  PitchNote n(int m, int s, [int dur = 4]) => PitchNote(midi: m, freq: midiToFreq(m), step: s, dur: dur, velocity: 60);
  final sec = Section(id: 'A', name: 'Verse', bars: 2, autoName: false)
    ..tracks['melody'] = TrackData(notes: [n(60, 0), n(64, 8), n(67, 16), n(72, 24)])
    ..tracks['drums'] = TrackData(
      drums: [for (var s = 0; s < 32; s += 4) DrumNote(step: s, kind: s % 8 == 0 ? 'kick' : 'snare')],
    );
  return Song(id: 'ui004-verify', title: '인스펙터 확인', bpm: 100, bars: 2, sections: [sec]);
}

Future<void> main() async {
  final root = _inside(_root);
  final dirs = {
    for (final name in ['documents', 'support', 'cache', 'temp', 'library', 'downloads'])
      name: _inside(p.join(root, 'data', name)),
  };
  for (final d in dirs.values) {
    await Directory(d).create(recursive: true);
  }
  final sysTemp = p.normalize(p.absolute(Directory.systemTemp.path));
  if (!p.isWithin(p.normalize(_workspace), sysTemp)) {
    throw StateError('Set TMP/TEMP inside $_workspace before launching (currently $sysTemp), e.g. ${dirs['temp']}');
  }
  PathProviderPlatform.instance = _QaPathProvider(dirs);
  SharedPreferences.setMockInitialValues({}); // never the user's AppData file
  LoopStorage.rootOverride = Directory(dirs['documents']!);
  final wait = Platform.environment['UI004_WAIT'] == '1';
  final out = await Directory(p.join(root, 'captures')).create(recursive: true);
  final report = <String, dynamic>{
    'passed': false,
    'mode': 'automatic part = widget callbacks from code (no mouse/keyboard input)',
    'wait': wait,
    'sandbox': dirs,
    'systemTemp': sysTemp,
    'captures': <String, dynamic>{},
    'checks': <String, dynamic>{},
    'measure': <String, dynamic>{},
  };
  final errors = <String>[];
  final checks = report['checks'] as Map<String, dynamic>;
  final measure = report['measure'] as Map<String, dynamic>;
  NavigatorState? navigator;
  Future<void> settle([int ms = 500]) => Future<void>.delayed(Duration(milliseconds: ms));
  try {
    await app.main();
    FlutterError.onError = (d) => errors.add(d.toString());
    await settle(1000);
    LoopPrefs.instance.metro.value = false;
    measure['inspectorOpenAtStart'] = LoopPrefs.instance.inspectorOpen.value;
    void visitNav(Element e) {
      if (e is StatefulElement && e.state is NavigatorState) navigator ??= e.state as NavigatorState;
      e.visitChildren(visitNav);
    }

    visitNav(WidgetsBinding.instance.rootElement!);

    Future<void> capture(String name) async {
      await settle(700);
      final view = WidgetsBinding.instance.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final image = await layer.toImage(Offset.zero & view.size, pixelRatio: view.flutterView.devicePixelRatio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File(p.join(out.path, '$name.png'));
      await file.writeAsBytes(png!.buffer.asUint8List());
      (report['captures'] as Map<String, dynamic>)[name] = {'file': file.path, 'width': image.width, 'height': image.height};
      image.dispose();
    }

    DesktopTopBar top() => find<DesktopTopBar>()!;
    DesktopCommands commands() => find<DesktopCommands>()!;
    Future<Map> savedPrefs() async =>
        jsonDecode(await File(p.join(dirs['documents']!, 'looptap', 'prefs.json')).readAsString()) as Map;
    Future<void> tap(String key, [int ms = 500]) async {
      final f = tapOf(ValueKey(key));
      if (f == null) throw StateError('no tap callback under $key');
      f();
      await settle(ms);
    }

    Future<void> openTrack(String id) async {
      top().onView!('arrange');
      await settle();
      find<Arrangement>()!.onOpenTrack!(id);
      await settle();
    }

    Future<void> pass(String lang) async {
      await LocaleService.instance.setLocale(Locale(lang));
      await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
      await LoopPrefs.instance.setInspectorOpen(true);
      navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: _song())));
      await settle(2000);
      final c = <String, dynamic>{};
      checks[lang] = c;
      final view = WidgetsBinding.instance.renderViews.first;
      measure['window'] = '${view.size.width.toStringAsFixed(0)}x${view.size.height.toStringAsFixed(0)}';

      // 1. melody, pads: the docked inspector's Track tab, the tool row
      await openTrack('melody');
      final insp = rectOf(const ValueKey('desktop-inspector'));
      c['inspectorDocked280'] = insp?.width == 280 && (insp!.right - view.size.width).abs() < .5;
      c['trackTabShown'] = rectOf(const ValueKey('inspector-track-tab')) != null;
      c['toolRow40'] = rectOf(const ValueKey('desktop-tool-row'))?.height == 40;
      c['instrumentInTrackTab'] = rectOf(const ValueKey('inspector-instrument')) != null;
      await capture('$lang-01-track-tab-pads');

      // 2. grid: the grid's tools in the tool row, 30 px tall
      tapOfText(lang == 'ko' ? '그리드' : 'Grid')?.call();
      await settle(800);
      c['gridToolsInRow'] = ['note-draw', 'note-select', 'note-area', 'note-erase', 'note-copy', 'note-paste']
          .every((k) => rectOf(ValueKey(k)) != null);
      c['toolButton30'] = rectOf(const ValueKey('note-draw'))?.height == 30;
      measure['$lang-noteDrawHeight'] = rectOf(const ValueKey('note-draw'))?.height;
      final vp = rectOf(const ValueKey('pitch-grid-viewport'));
      measure['$lang-gridViewport'] = vp == null ? null : {'width': vp.width, 'height': vp.height};
      await capture('$lang-02-grid-tool-row');

      // 3. Notes tab: select mode, select all (the grid's own button), octave +
      await tap('note-select');
      await tap('inspector-tab-notes');
      await tap('note-select-all');
      c['notesTitle4'] = (textOf(const ValueKey('grid-notes-title')) ?? '').contains('4');
      final before = jsonEncode([for (final n in find<StepGrid>()!.notes) n.toJson()]);
      await tap('note-octave-up');
      c['octaveUp'] = find<StepGrid>()!.notes.every((n) => n.midi >= 72);
      commands().undo();
      await settle();
      c['undoOctave'] = jsonEncode([for (final n in find<StepGrid>()!.notes) n.toJson()]) == before;
      // the undo replaced the notes: the selection (and so the Notes tab) is
      // gone; select all again
      c['undoBackToTrackTab'] = rectOf(const ValueKey('inspector-track-tab')) != null;
      await tap('inspector-tab-notes');
      await tap('note-select-all');
      // velocity slider: draft (panel follows), then one commit
      final slider = find<Slider>(const ValueKey('note-velocity'))!;
      slider.onChangeStart!(slider.value);
      find<Slider>(const ValueKey('note-velocity'))!.onChanged!(110);
      await settle(300);
      c['velocityDraftShown'] = find<Slider>(const ValueKey('note-velocity'))!.value == 110 &&
          find<StepGrid>()!.notes.every((n) => n.velocity == 60);
      find<Slider>(const ValueKey('note-velocity'))!.onChangeEnd!(110);
      await settle();
      c['velocityCommitted'] = find<StepGrid>()!.notes.every((n) => n.velocity == 110);
      await capture('$lang-03-notes-tab');
      commands().undo();
      await settle();
      c['undoVelocityOnce'] = jsonEncode([for (final n in find<StepGrid>()!.notes) n.toJson()]) == before;

      // 4. Track tab volume = the mixer's value
      await tap('inspector-tab-track');
      find<InspectorTrackPanel>()!.onVolume('melody', .3);
      await settle();
      c['trackVolume30'] = textOf(const ValueKey('inspector-volume-label')) == '30';
      commands().mixer!();
      await settle(800);
      c['mixerSameVolume'] = ((find<MixerSheet>()?.vol['melody'] ?? -1) * 100).round() == 30;
      await capture('$lang-04-mixer-same-volume');
      // close the mixer through its own route (the first navigator found may
      // not be the one it opened on)
      Navigator.of(elementOf<MixerSheet>()!).pop();
      await settle(800);
      c['mixerClosed'] = find<MixerSheet>() == null;

      // 5. Ctrl/Cmd+I (the commands' callback): the 40 px bar, saved
      commands().inspector!();
      await settle();
      c['collapsedBar40'] = rectOf(const ValueKey('inspector-bar'))?.width == 40 && rectOf(const ValueKey('desktop-inspector')) == null;
      c['collapsedSaved'] = (await savedPrefs())['inspectorOpen'] == false;
      await capture('$lang-05-collapsed');
      commands().inspector!();
      await settle();
      c['reopened'] = rectOf(const ValueKey('desktop-inspector')) != null;

      // 6. drums: Draw / Select in the tool row, the drum Notes tab
      await openTrack('drums');
      tapOfText(lang == 'ko' ? '그리드' : 'Grid')?.call();
      await settle(800);
      c['drumToolsInRow'] = rectOf(const ValueKey('drum-draw-mode')) != null && rectOf(const ValueKey('drum-select-mode')) != null;
      await tap('drum-select-mode');
      await tap('inspector-tab-notes');
      c['drumNotesTab'] = rectOf(const ValueKey('drum-notes-tab')) != null && rectOf(const ValueKey('drum-velocity')) != null;
      await capture('$lang-06-drum-notes-tab');

      // 7. the arrange view: Track tab only
      top().onView!('arrange');
      await settle();
      c['arrangeTrackOnly'] = rectOf(const ValueKey('inspector-track-tab')) != null && rectOf(const ValueKey('inspector-tab-notes')) == null;
      await capture('$lang-07-arrange-track-tab');
      navigator!.pop();
      await settle(800);

      // 8. the editor in a 960x600 box (real fonts): the bar, then over the editor
      await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
      navigator!.push(
        MaterialPageRoute<void>(
          builder:
              (context) => Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 960,
                  height: 600,
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(size: const Size(960, 600)),
                    child: EditScreen(song: _song()),
                  ),
                ),
              ),
        ),
      );
      await settle(2000);
      c['narrowStartsAsBar'] = rectOf(const ValueKey('inspector-bar')) != null && rectOf(const ValueKey('desktop-inspector')) == null;
      final before960 = rectOf(const ValueKey('timeline-minimap'))?.width;
      await capture('$lang-08-960-bar');
      await tap('inspector-bar-track');
      final over = rectOf(const ValueKey('desktop-inspector'));
      c['narrowOverlay'] = over != null && (over.right - 960).abs() < .5 && rectOf(const ValueKey('inspector-bar')) != null;
      c['narrowSavedUntouched'] = LoopPrefs.instance.inspectorOpen.value;
      measure['$lang-960-minimapWidth'] = before960;
      await capture('$lang-09-960-overlay');
      navigator!.pop();
      await settle(800);
    }

    await pass('ko');
    await pass('en');
    await LocaleService.instance.setLocale(const Locale('ko'));
    await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
    await LoopPrefs.instance.setInspectorOpen(true);
    navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: _song())));
    await settle(1500);
    report['flutterErrors'] = errors;
    bool ok(Object? v) => v is Map ? v.values.every(ok) : v == true;
    report['passed'] = errors.isEmpty && checks.values.every(ok);
  } catch (e, stack) {
    report['error'] = e.toString();
    report['stack'] = stack.toString();
    report['flutterErrors'] = errors;
  }
  await File(p.join(out.path, 'native-verification.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  if (wait) {
    debugPrint('[ui004-verify] automatic part done (passed=${report['passed']}); waiting for manual checks. Close the window to quit.');
    return; // keep running: the window stays open for real mouse / keyboard checks
  }
  await LoopAudio.instance.stopAll();
  exit(report['passed'] == true ? 0 : 1);
}
