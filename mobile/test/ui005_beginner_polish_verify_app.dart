// QA-only Windows verification entry point for ui-001 stage 5 (the key in
// the piano roll, "in-key notes only", the primary hum button and its
// shortcut, the folded velocity lane). Never part of the product build.
//
// Same isolation as ui004_desktop_inspector_verify_app.dart: the REAL app
// (app.main()) with every path_provider location redirected into a sandbox
// inside the repo and an in-memory shared_preferences store (the user's songs
// / prefs / AppData are never read or written; LoopPrefs' prefs.json lands in
// the sandbox). On a D dorian sandbox song (one F# note out of the key) it
// checks and captures, in Korean and then English, through the widgets' own
// callbacks and synthesized pointer events in the app itself (no OS mouse /
// keyboard): the rows in the key and the kept F# row with its count, the key
// colours, a note drawn on the F# row landing on F, the toggle saved, the
// folded / unfolded velocity lane (saved), the hum button and Ctrl/Cmd+Shift+H
// callback opening humming for the active track, the quiet-Solo "강약 보기"
// unfolding the lane, and the editor in a 960x600 box with the real fonts.
//
// UI005_WAIT=1 (environment variable at launch): after the automatic part
// the app does NOT exit; it stays on the editor (Korean, edit view, melody
// grid) for real mouse / keyboard checks.
//
// Build (debug: the root-layer capture uses debugLayer):
//   flutter build windows --debug --no-pub -t test/ui005_beginner_polish_verify_app.dart
//     --dart-define=UI005_ROOT=<dir inside C:/src/humming-v2>
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
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:flutter/gestures.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/services/locale_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'UI005_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\ui-005-beginner-polish\verify',
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

/// Element of the first widget whose runtime type is named [name] (private
/// widgets such as the hum modal).
Element? elementNamed(String name) {
  Element? found;
  void visit(Element e) {
    if (found != null) return;
    if (e.widget.runtimeType.toString() == name) {
      found = e;
      return;
    }
    e.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return found;
}

/// A primary mouse click at [at] (global), synthesized inside the app.
var _pointer = 900;
Future<void> clickAt(Offset at) async {
  final id = _pointer++;
  final now = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch % 100000000);
  GestureBinding.instance.handlePointerEvent(
    PointerDownEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton, timeStamp: now),
  );
  await Future<void>.delayed(const Duration(milliseconds: 40));
  GestureBinding.instance.handlePointerEvent(
    PointerUpEvent(pointer: id, position: at, kind: PointerDeviceKind.mouse, timeStamp: now + const Duration(milliseconds: 40)),
  );
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

Song _song() {
  // D dorian; one F# (66) outside the key; quiet velocities for the Solo check
  PitchNote n(int m, int s, [int dur = 2]) => PitchNote(midi: m, freq: midiToFreq(m), step: s, dur: dur, velocity: 3);
  final sec = Section(id: 'A', name: 'Verse', bars: 2, autoName: false)
    ..tracks['melody'] = TrackData(notes: [n(62, 0), n(66, 8), n(69, 16, 4), n(74, 24)]);
  return Song(id: 'ui005-verify', title: '키 안의 음 확인', bpm: 100, bars: 2, key: 'D', scale: 'dorian', sections: [sec]);
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
  final wait = Platform.environment['UI005_WAIT'] == '1';
  final out = await Directory(p.join(root, 'captures')).create(recursive: true);
  final report = <String, dynamic>{
    'passed': false,
    'mode': 'automatic part = widget callbacks and in-app synthesized pointer events (no OS mouse/keyboard)',
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
    measure['atStart'] = {
      'gridInKeyOnly': LoopPrefs.instance.gridInKeyOnly.value,
      'velocityLaneChosen': LoopPrefs.instance.gridVelocityLaneChosen.value,
    };
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
    StepGrid grid() => find<StepGrid>()!;
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

    /// Global point of [step] on [midi]'s row (scrolls it into view).
    Future<Offset?> rowPoint(double step, int midi) async {
      final ladder = grid().ladder.reversed.toList();
      final row = ladder.indexWhere((r) => r.midi == midi);
      final scroll = find<SingleChildScrollView>(const ValueKey('pitch-grid-viewport'))?.controller;
      final vp = rectOf(const ValueKey('pitch-grid-viewport'));
      var lane = rectOf(const ValueKey('pitch-grid-lane'));
      if (row < 0 || scroll == null || vp == null || lane == null) return null;
      final rowH = lane.height / ladder.length;
      scroll.jumpTo(((row + .5) * rowH - vp.height / 2).clamp(0.0, scroll.position.maxScrollExtent));
      await settle(300);
      lane = rectOf(const ValueKey('pitch-grid-lane'))!;
      final v = find<PitchGridSurface>()!.view!.view;
      return Offset(lane.left + (step - v.start) / v.length * lane.width, lane.top + (row + .5) * rowH);
    }

    Future<bool> closeHum() async {
      final e = elementNamed('_HumModal');
      if (e == null) return false;
      Navigator.of(e).pop();
      await settle(800);
      return elementNamed('_HumModal') == null;
    }

    Future<void> pass(String lang) async {
      await LocaleService.instance.setLocale(Locale(lang));
      await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
      await LoopPrefs.instance.setGridInKeyOnly(true);
      navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: _song())));
      await settle(2000);
      final c = <String, dynamic>{};
      checks[lang] = c;
      final view = WidgetsBinding.instance.renderViews.first;
      measure['window'] = '${view.size.width.toStringAsFixed(0)}x${view.size.height.toStringAsFixed(0)}';

      // 1. melody grid in D dorian: in-key rows + the kept F# row, its count
      await openTrack('melody');
      tapOfText(lang == 'ko' ? '그리드' : 'Grid')?.call();
      await settle(800);
      const dorian = {2, 4, 5, 7, 9, 11, 0};
      final rows = {for (final r in grid().ladder) r.midi};
      c['inKeyRowsOnly'] = rows.where((m) => !dorian.contains(m % 12)).toList().toString() == '[66]';
      c['outOfKeyCountShown'] = find<Text>(const ValueKey('grid-out-of-key-count')) != null;
      c['keyHighlightRootD'] = grid().keyHighlight?.root == 2;
      c['velocityLaneFolded'] = rectOf(const ValueKey('velocity-lane-fold'))?.height == 24 && rectOf(const ValueKey('velocity-lane')) == null;
      final vp = rectOf(const ValueKey('pitch-grid-viewport'));
      measure['$lang-foldedViewport'] = vp == null ? null : {'width': vp.width, 'height': vp.height};
      c['humButton30'] = rectOf(const ValueKey('desktop-hum'))?.height == 30;
      await capture('$lang-01-in-key-rows');

      // 2. draw on the kept F# row (an empty step): lands on F (65); undo
      final before = jsonEncode([for (final n in grid().notes) n.toJson()]);
      await tap('note-draw');
      final at = await rowPoint(28.5, 66);
      if (at != null) await clickAt(at);
      await settle();
      final added = grid().notes.where((n) => n.startSteps == 28).toList();
      c['drawSnapsIntoKey'] = added.length == 1 && added.single.midi == 65;
      measure['$lang-drawn'] = [for (final n in added) n.midi];
      await capture('$lang-02-drawn-in-key');
      commands().undo();
      await settle();
      c['undoDraw'] = jsonEncode([for (final n in grid().notes) n.toJson()]) == before;

      // 3. the toggle (saved): every row, then back
      await tap('grid-in-key-only');
      c['toggleOffAllRows'] = grid().ladder.length == 128 && (await savedPrefs())['gridInKeyOnly'] == false;
      await capture('$lang-03-all-rows');
      await tap('grid-in-key-only');
      c['toggleOnSaved'] = (await savedPrefs())['gridInKeyOnly'] == true;

      // 4. the velocity lane: unfold (saved), fold
      await tap('velocity-lane-fold');
      c['laneUnfolded'] = rectOf(const ValueKey('velocity-lane')) != null && (await savedPrefs())['gridVelocityLane'] == true;
      await capture('$lang-04-lane-unfolded');
      await tap('velocity-lane-fold');
      c['laneFoldedAgain'] = rectOf(const ValueKey('velocity-lane')) == null && (await savedPrefs())['gridVelocityLane'] == false;

      // 5. humming: the button, then Ctrl/Cmd+Shift+H's callback
      await tap('desktop-hum', 1000);
      final modal = elementNamed('_HumModal');
      c['humButtonOpens'] = modal != null && (modal.widget as dynamic).trackLabel == 'Melody';
      await capture('$lang-05-hum-modal');
      c['humClosed'] = await closeHum();
      commands().hum!();
      await settle(1000);
      c['humShortcutOpens'] = elementNamed('_HumModal') != null;
      c['humShortcutClosed'] = await closeHum();

      // 6. quiet Solo -> 강약 보기 opens the edit view with the lane unfolded
      top().onView!('arrange');
      await settle();
      find<Arrangement>()!.onToggleSolo!('melody');
      await settle();
      await tap('solo-status-notice', 800);
      c['quietSoloUnfoldsLane'] = find<StepGrid>() != null && rectOf(const ValueKey('velocity-lane')) != null;
      await capture('$lang-06-quiet-solo-velocity');
      await tap('velocity-lane-fold');
      find<DesktopSoloHeader>()?.onClear();
      await settle();
      navigator!.pop();
      await settle(800);

      // 7. the editor in a 960x600 box (real fonts): the tool row's end
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
      await openTrack('melody');
      tapOfText(lang == 'ko' ? '그리드' : 'Grid')?.call();
      await settle(800);
      final hum = rectOf(const ValueKey('desktop-hum'));
      c['narrowHumInside'] = hum != null && hum.right <= 960;
      c['narrowToggleInside'] = (rectOf(const ValueKey('grid-in-key-only'))?.right ?? 9999) <= 960;
      await capture('$lang-07-960-tool-row');
      navigator!.pop();
      await settle(800);
    }

    await pass('ko');
    await pass('en');
    await LocaleService.instance.setLocale(const Locale('ko'));
    await LoopPrefs.instance.setDesktopView(LoopPrefs.kDesktopViewEdit);
    navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: _song())));
    await settle(1500);
    await openTrack('melody');
    tapOfText('그리드')?.call();
    await settle(800);
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
    debugPrint('[ui005-verify] automatic part done (passed=${report['passed']}); waiting for manual checks. Close the window to quit.');
    return; // keep running: the window stays open for real mouse / keyboard checks
  }
  await LoopAudio.instance.stopAll();
  exit(report['passed'] == true ? 0 : 1);
}
