// QA-only Windows verification entry point for ui-001 stage 1 (desktop top
// bar). Never part of the product build.
//
// Runs the REAL app (app.main()) with every path_provider location redirected
// into a sandbox inside the repo (the same isolation as qa_song_e2e_app.dart:
// the user's Documents songs / prefs.json / AppData are never read or
// written) and an in-memory shared_preferences store. It opens the current
// EditScreen on a sandbox song and, through the widgets' own callbacks (code,
// not mouse/keyboard input), captures: the top bar, the song-settings
// popover, the more menu, the shortcut help window, the BPM entry and a
// playing state, into UI001_OUTPUT with native-verification.json.
//
// UI001_WAIT=1 (environment variable at launch): after the automatic part the
// app does NOT exit; it closes the overlays and stays on the editor so a
// person can check the same top bar with the real mouse and keyboard.
//
// Build (debug: the root-layer capture uses debugLayer):
//   flutter build windows --debug --no-pub -t test/ui001_top_bar_verify_app.dart
//     --dart-define=UI001_ROOT=<dir inside C:/src/humming-v2>
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
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/transport_bar.dart';
import 'package:humming/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'UI001_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\ui-001-desktop-top-bar\verify',
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

/// The first GestureDetector / InkResponse tap callback under [key].
VoidCallback? tapOf(Key key) {
  VoidCallback? found;
  void visit(Element e) {
    if (found != null) return;
    final w = e.widget;
    if (w is GestureDetector && w.onTap != null) found = w.onTap;
    if (w is InkResponse && w.onTap != null) found = w.onTap;
    if (found == null) e.visitChildren(visit);
  }

  void start(Element e) {
    if (e.widget.key == key) {
      visit(e);
      return;
    }
    e.visitChildren(start);
  }

  start(WidgetsBinding.instance.rootElement!);
  return found;
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
  final wait = Platform.environment['UI001_WAIT'] == '1';
  final out = await Directory(p.join(root, 'captures')).create(recursive: true);
  final report = <String, dynamic>{
    'passed': false,
    'mode': 'automatic part = widget callbacks from code (no mouse/keyboard input)',
    'wait': wait,
    'sandbox': dirs,
    'systemTemp': sysTemp,
    'captures': <String, dynamic>{},
    'checks': <String, dynamic>{},
  };
  final errors = <String>[];
  final checks = report['checks'] as Map<String, dynamic>;
  try {
    await app.main();
    FlutterError.onError = (d) => errors.add(d.toString());
    await Future<void>.delayed(const Duration(seconds: 1));
    LoopPrefs.instance.metro.value = false;
    NavigatorState? navigator;
    void visitNav(Element e) {
      if (e is StatefulElement && e.state is NavigatorState) navigator ??= e.state as NavigatorState;
      e.visitChildren(visitNav);
    }

    visitNav(WidgetsBinding.instance.rootElement!);
    final song = Song(id: 'ui001-verify', title: '상단 바 확인', bpm: 100, bars: 2);
    song.sections.single.tracks['melody'] = TrackData(
      notes: [
        for (final (m, s) in [(60, 0), (64, 4), (67, 8), (72, 12), (67, 16), (64, 20), (62, 24), (60, 28)])
          PitchNote(midi: m, freq: midiToFreq(m), step: s, dur: 4, velocity: 96),
      ],
    );
    navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: song)));
    await Future<void>.delayed(const Duration(seconds: 2));

    Future<void> capture(String name) async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
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
    final bar = find<Container>(const ValueKey('desktop-top-bar'));
    checks['topBarPresent'] = bar != null;
    checks['transportBarAbsent'] = find<TransportBar>() == null;
    await capture('01-top-bar');

    tapOf(const ValueKey('top-song-settings'))!();
    await capture('02-song-settings');
    find<Slider>(const ValueKey('song-settings-swing'))!.onChanged!(30);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    checks['swingSetTo30'] = (top().swing * 100).round() == 30;
    await capture('02b-song-settings-swing30');
    tapOf(const ValueKey('top-song-settings'))!();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    tapOf(const ValueKey('top-more'))!();
    await capture('03-more-menu');
    tapOf(const ValueKey('top-more'))!();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    find<DesktopCommands>()!.help!();
    await capture('04-shortcut-help');
    navigator!.pop();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    tapOf(const ValueKey('top-bpm'))!();
    await capture('05-bpm-entry');
    navigator!.pop();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    top().onPlay();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    checks['playingAfterPlay'] = top().playing;
    await capture('06-playing');
    top().onStop();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    checks['stoppedAfterStop'] = !top().playing;

    // undo the swing change so the manual session starts from the sandbox song
    find<DesktopCommands>()!.undo();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    checks['swingUndone'] = top().swing == 0;
    report['flutterErrors'] = errors;
    report['passed'] = errors.isEmpty && checks.values.every((v) => v == true);
  } catch (e, stack) {
    report['error'] = e.toString();
    report['stack'] = stack.toString();
    report['flutterErrors'] = errors;
  }
  await File(p.join(out.path, 'native-verification.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  if (wait) {
    debugPrint('[ui001-verify] automatic part done (passed=${report['passed']}); waiting for manual checks. Close the window to quit.');
    return; // keep running: the window stays open for real mouse/keyboard checks
  }
  await LoopAudio.instance.stopAll();
  exit(report['passed'] == true ? 0 : 1);
}
