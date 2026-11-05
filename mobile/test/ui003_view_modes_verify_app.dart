// QA-only Windows verification entry point for ui-001 stage 3 (arrange / edit
// views). Never part of the product build.
//
// Same isolation as ui002_section_ruler_verify_app.dart: the REAL app
// (app.main()) with every path_provider location redirected into a sandbox
// inside the repo and an in-memory shared_preferences store (the user's songs
// / prefs / AppData are never read or written; LoopPrefs' prefs.json lands in
// the sandbox). It opens EditScreen on a sandbox song (A 2 bars x2, B 4 bars,
// C 1 bar x3) and, through the widgets' own callbacks (code, not mouse /
// keyboard input), checks and captures in Korean and then English: the
// default edit view, the arrange view, Enter / Tab paths, the piano roll's
// height, minimap seek into another section and the roll rectangle (song
// steps), the Solo controls in the edit view, the saved desktopView, and the
// editor laid out in a 960x600 box with the real fonts (the view switch).
//
// UI003_WAIT=1 (environment variable at launch): after the automatic part
// the app does NOT exit; it stays on the editor (Korean, edit view) for real
// mouse / keyboard checks.
//
// Build (debug: the root-layer capture uses debugLayer):
//   flutter build windows --debug --no-pub -t test/ui003_view_modes_verify_app.dart
//     --dart-define=UI003_ROOT=<dir inside C:/src/humming-v2>
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
import 'package:humming/looptap/widgets/desktop_section_band.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/timeline_minimap.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/services/locale_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'UI003_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\ui-003-view-modes\verify',
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

Song _song() {
  PitchNote n(int m, int s, [int dur = 4]) => PitchNote(midi: m, freq: midiToFreq(m), step: s, dur: dur, velocity: 6);
  Section sec(String id, String name, int bars, int repeats, List<PitchNote> notes) =>
      Section(id: id, name: name, bars: bars, repeats: repeats, autoName: false)..tracks['melody'] = TrackData(notes: notes);
  return Song(
    id: 'ui003-verify',
    title: '보기 전환 확인',
    bpm: 100,
    bars: 2,
    sections: [
      sec('A', 'Verse', 2, 2, [n(60, 0), n(64, 8), n(67, 16), n(72, 24)]),
      sec('B', 'Chorus', 4, 1, [n(72, 0), n(71, 16), n(69, 32, 8), n(67, 48)]),
      sec('C', 'Bridge', 1, 3, [n(65, 4), n(64, 12)]),
    ],
  );
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
  final wait = Platform.environment['UI003_WAIT'] == '1';
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
    measure['desktopViewAtStart'] = LoopPrefs.instance.desktopView.value;
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

    Arrangement? arr() => find<Arrangement>();
    TimelineMinimap? mini() => find<TimelineMinimap>();
    DesktopTopBar top() => find<DesktopTopBar>()!;
    DesktopCommands commands() => find<DesktopCommands>()!;
    Future<Map> savedPrefs() async =>
        jsonDecode(await File(p.join(dirs['documents']!, 'looptap', 'prefs.json')).readAsString()) as Map;

    Future<void> pass(String lang) async {
      await LocaleService.instance.setLocale(Locale(lang));
      await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
      navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: _song())));
      await settle(2000);
      final c = <String, dynamic>{};
      checks[lang] = c;
      final view = WidgetsBinding.instance.renderViews.first;
      measure['window'] = '${view.size.width.toStringAsFixed(0)}x${view.size.height.toStringAsFixed(0)}';

      // 1. the edit view (default): minimap 44, no timeline, both switch keys
      c['editViewDefault'] = mini() != null && arr() == null;
      c['minimap44'] = rectOf(const ValueKey('timeline-minimap'))?.height == 44;
      c['switchBothKeys'] =
          rectOf(const ValueKey('view-arrange')) != null && rectOf(const ValueKey('view-edit')) != null;
      measure['$lang-switchStyle'] = textsUnder(const ValueKey('top-view-switch')) == 2 ? 'labels' : 'icons';
      c['noFoldNoFocus'] =
          rectOf(const ValueKey('timeline-collapse')) == null &&
          rectOf(const ValueKey('timeline-expand')) == null &&
          rectOf(const ValueKey('grid-focus')) == null;
      await capture('$lang-01-edit-view');

      // 2. the arrange view (segment): 64 px rows, hint, no surface
      top().onView!('arrange');
      await settle();
      c['arrangeViaSegment'] = arr() != null && mini() == null && find<StepGrid>() == null;
      c['row64'] = rectOf(const ValueKey('track-label-melody'))?.height == 64;
      c['hint40'] = rectOf(const ValueKey('arrange-hint'))?.height == 40;
      c['bandInArrange'] = find<DesktopSectionBand>() != null;
      c['prefsSavedArrange'] = (await savedPrefs())['desktopView'] == 'arrange';
      await capture('$lang-02-arrange-view');

      // 3. select melody, Enter (the commands' openEditor) = its edit view
      arr()!.onSelect('melody');
      await settle(300);
      commands().openEditor!();
      await settle();
      c['enterOpensEditor'] = mini() != null && arr() == null;
      c['prefsSavedEdit'] = (await savedPrefs())['desktopView'] == 'edit';
      tapOfText(lang == 'ko' ? '그리드' : 'Grid')?.call();
      await settle(800);
      final vp = rectOf(const ValueKey('pitch-grid-viewport'));
      measure['$lang-gridViewport'] = vp == null ? null : {'top': vp.top, 'height': vp.height};
      c['velocityLaneShown'] = rectOf(const ValueKey('velocity-lane')) != null;
      await capture('$lang-03-edit-grid');

      // 4. minimap: B's step 16 = song 80; the roll at 2x showing 16..48 = song 80..112
      mini()!.onSeek!(1, 0, 16);
      await settle();
      c['minimapSeekB'] = mini()!.activeIdx == 1 && (mini()!.playStep.value - 16).abs() < .5;
      tapOfText(lang == 'ko' ? '그리드' : 'Grid')?.call();
      await settle(600);
      final roll = find<StepGrid>()?.viewLink?.view;
      if (roll != null) {
        roll.setZoom(2);
        roll.panTo(16);
        await settle();
        measure['$lang-rollRectSong'] = [mini()!.offset + roll.view.start, mini()!.offset + roll.view.end];
      }
      c['rollRectB80to112'] = roll != null && mini()!.offset + roll.view.start == 80 && mini()!.offset + roll.view.end == 112;
      await capture('$lang-04-minimap-rect');

      // 5. Tab (viewToggle) to arrange, Solo melody, Tab back: Solo controls in the edit view
      commands().viewToggle!();
      await settle();
      c['tabToArrange'] = arr() != null;
      arr()!.onToggleSolo!('melody');
      await settle();
      commands().viewToggle!();
      await settle();
      c['soloInEditView'] = mini()?.soloHeader != null && find<DesktopSoloHeader>() != null;
      await capture('$lang-05-solo-edit-view');
      find<DesktopSoloHeader>()?.onClear();
      await settle();
      navigator!.pop();
      await settle(800);

      // 6. the editor in a 960x600 box with the real fonts: the view switch
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
      final sw = rectOf(const ValueKey('top-view-switch'));
      c['narrow960SwitchShown'] =
          sw != null && sw.right <= 960 && rectOf(const ValueKey('view-arrange')) != null && rectOf(const ValueKey('view-edit')) != null;
      measure['$lang-960-switchStyle'] = textsUnder(const ValueKey('top-view-switch')) == 2 ? 'labels' : 'icons';
      measure['$lang-960-title'] = rectOf(const ValueKey('top-title'))?.width;
      await capture('$lang-06-edit-view-960x600');
      navigator!.pop();
      await settle(800);
    }

    await pass('ko');
    await pass('en');
    await LocaleService.instance.setLocale(const Locale('ko'));
    await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
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
    debugPrint('[ui003-verify] automatic part done (passed=${report['passed']}); waiting for manual checks. Close the window to quit.');
    return; // keep running: the window stays open for real mouse / keyboard checks
  }
  await LoopAudio.instance.stopAll();
  exit(report['passed'] == true ? 0 : 1);
}
