// QA-only Windows verification entry point for ui-001 stage 2 (section band +
// ruler loop range). Never part of the product build.
//
// Same isolation as ui001_top_bar_verify_app.dart: the REAL app (app.main())
// with every path_provider location redirected into a sandbox inside the repo
// and an in-memory shared_preferences store (the user's songs / prefs /
// AppData are never read or written). It opens EditScreen on a sandbox song
// (three sections, two of them linked, a quiet melody) and, through the
// widgets' own callbacks (code, not mouse input), captures in Korean and then
// English: the track header (band + ruler), a bars 2-3 loop range, the section
// menu, a Solo with the header controls, the folded timeline and grid mode
// without the key-hint row, into UI002_OUTPUT with native-verification.json.
//
// UI002_WAIT=1 (environment variable at launch): after the automatic part the
// app does NOT exit; it stays on the editor (Korean, loop range cleared) so a
// person can check drag / handles / click seek / double-click / right-click /
// wheel with the real mouse.
//
// Build (debug: the root-layer capture uses debugLayer):
//   flutter build windows --debug --no-pub -t test/ui002_section_ruler_verify_app.dart
//     --dart-define=UI002_ROOT=<dir inside C:/src/humming-v2>
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
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/audition_bar.dart';
import 'package:humming/looptap/widgets/desktop_section_band.dart';
import 'package:humming/looptap/widgets/section_bar.dart';
import 'package:humming/looptap/widgets/timeline_ruler.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/services/locale_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'UI002_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\ui-002-section-ruler\verify',
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

/// Global rect of the first render box under [key] / of type [T].
Rect? rectOf<T extends Widget>([Key? key]) {
  Rect? result;
  void visit(Element e) {
    if (result != null) return;
    if (e.widget is T && (key == null || e.widget.key == key)) {
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
  PitchNote n(int m, int s) => PitchNote(midi: m, freq: midiToFreq(m), step: s, dur: 4, velocity: 6);
  Section sec(String id, String name, {String? link}) => Section(id: id, name: name, bars: 4, autoName: false, linkId: link)
    ..tracks['melody'] = TrackData(
      notes: [for (final (m, s) in [(60, 0), (64, 8), (67, 16), (72, 24), (67, 32), (64, 40), (62, 48), (60, 56)]) n(m, s)],
    );
  return Song(
    id: 'ui002-verify',
    title: '섹션 띠 확인',
    bpm: 100,
    bars: 4,
    sections: [
      sec('A', 'Verse', link: 'L1'),
      sec('B', 'Chorus with a very long section name'),
      sec('C', 'Verse 2', link: 'L1'),
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
  final wait = Platform.environment['UI002_WAIT'] == '1';
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
    LoopPrefs.instance.timelineCollapsed.value = false;
    void visitNav(Element e) {
      if (e is StatefulElement && e.state is NavigatorState) navigator ??= e.state as NavigatorState;
      e.visitChildren(visitNav);
    }

    visitNav(WidgetsBinding.instance.rootElement!);
    await LocaleService.instance.setLocale(const Locale('ko'));
    navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: _song())));
    await settle(2000);

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

    Arrangement arr() => find<Arrangement>()!;
    DesktopSectionBand band() => find<DesktopSectionBand>()!;

    Future<void> pass(String lang) async {
      await LocaleService.instance.setLocale(Locale(lang));
      await settle(800);
      final c = <String, dynamic>{};
      checks[lang] = c;
      final view = WidgetsBinding.instance.renderViews.first;
      measure['window'] = '${view.size.width.toStringAsFixed(0)}x${view.size.height.toStringAsFixed(0)}';

      band().onSwitch(0); // a linked section is active: the linked notice shows
      await settle();

      // 1. header: band + ruler, standalone rows gone
      c['bandPresent'] = find<DesktopSectionBand>() != null;
      c['sectionBarAbsent'] = find<SectionBar>() == null;
      c['auditionBarAbsent'] = find<AuditionBar>() == null;
      c['soloHeaderAbsentWithoutSolo'] = find<DesktopSoloHeader>() == null;
      c['linkNoticeShown'] = find<Text>(const ValueKey('section-link-notice')) != null;
      final header = rectOf(const ValueKey('arrangement-header'));
      c['headerHeight36'] = header?.height == 36;
      await capture('$lang-01-header');

      // 2. ruler loop range: bars 2-3
      arr().onLoopRange!(const PlaybackRange(16, 48));
      await settle();
      final r = find<TimelineRuler>()!.loopRange;
      c['rulerRange16to48'] = r?.start == 16 && r?.end == 48;
      c['rulerRangeTintShown'] = rectOf(const ValueKey('timeline-ruler-range')) != null;
      c['handlesShown'] = rectOf(const ValueKey('loop-handle-start')) != null && rectOf(const ValueKey('loop-handle-end')) != null;
      await capture('$lang-02-ruler-range-bars2-3');

      // 3. section select + menu (right-click handler)
      band().onSwitch(1);
      await settle();
      c['switchedTo1'] = band().activeIdx == 1;
      band().onMenu(0);
      await settle();
      c['menuRepeatsShown'] = find<Text>(const ValueKey('section-menu-repeats')) != null;
      c['menuDeleteShown'] = find<Widget>(const ValueKey('section-menu-delete')) != null;
      await capture('$lang-03-section-menu');
      navigator!.pop();
      await settle();

      // 4. wheel repeats handler
      final before = band().sections[1].repeats;
      band().onRepeats(1, before + 1);
      await settle();
      c['repeatsUp'] = band().sections[1].repeats == before + 1;
      band().onRepeats(1, before);
      await settle();

      // 5. Solo with the quiet warning
      arr().onToggleSolo!('melody');
      await settle();
      c['soloHeaderShown'] = find<DesktopSoloHeader>() != null;
      c['soloWarningShown'] = find<Widget>(const ValueKey('solo-status-notice')) != null;
      await capture('$lang-04-solo-header');
      find<DesktopSoloHeader>()!.onCompare();
      await settle();
      c['compareBypass'] = arr().bypassSolo == true;
      await capture('$lang-04b-solo-compare');
      find<DesktopSoloHeader>()!.onClear();
      await settle();
      c['soloCleared'] = find<DesktopSoloHeader>() == null;

      // 6. folded timeline keeps the band + restart
      LoopPrefs.instance.timelineCollapsed.value = true;
      await settle();
      c['foldedBandShown'] = find<DesktopSectionBand>() != null && find<Arrangement>() == null;
      c['foldedRestartShown'] = find<Widget>(const ValueKey('audition-restart')) != null;
      await capture('$lang-05-folded');
      LoopPrefs.instance.timelineCollapsed.value = false;
      await settle();

      // 7. grid mode: key-hint row gone
      arr().onSelect('melody');
      await settle();
      final hintTip = lang == 'ko' ? '연주 키 설정' : 'Instrument keys';
      c['padHintShown'] = _hasTooltip(hintTip);
      tapOfText(lang == 'ko' ? '그리드' : 'Grid')!();
      await settle(800);
      c['gridHintHidden'] = !_hasTooltip(hintTip);
      final vp = rectOf(const ValueKey('pitch-grid-viewport'));
      measure['$lang-gridViewport'] = vp == null ? null : {'top': vp.top, 'height': vp.height};
      await capture('$lang-06-grid-no-hint-row');
      tapOfText(lang == 'ko' ? '패드' : 'Pad')?.call();
      await settle();

      arr().onLoopRange!(const PlaybackRange(0, 32));
      await settle();
    }

    await pass('ko');
    await pass('en');
    await LocaleService.instance.setLocale(const Locale('ko'));
    await settle();
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
    debugPrint('[ui002-verify] automatic part done (passed=${report['passed']}); waiting for manual mouse checks. Close the window to quit.');
    return; // keep running: the window stays open for real mouse checks
  }
  await LoopAudio.instance.stopAll();
  exit(report['passed'] == true ? 0 : 1);
}

bool _hasTooltip(String message) {
  var found = false;
  void visit(Element e) {
    if (found) return;
    final w = e.widget;
    if (w is Tooltip && w.message == message) {
      found = true;
      return;
    }
    e.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return found;
}
