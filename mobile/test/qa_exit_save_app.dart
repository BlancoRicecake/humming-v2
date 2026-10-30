// QA-only (storage audit 2026-10-30): does the native title-bar X (WM_CLOSE)
// reach System.requestAppExit and save the editor's last edit? The real app
// runs on isolated data under artifacts/; one note is added through the grid's
// own place callback (an in-app call, not an OS input claim), then the run
// script sends WM_CLOSE. QA_MODE=fail blocks songs.json.tmp with a folder so
// the real save fails: the window must stay open with the save-failed dialog;
// this app then unblocks the disk and presses "Save again" (in-app callback)
// so the edit lands and the window closes. Every step goes to result.json; the
// run script reads songs.json itself — exit code 0 alone proves nothing.
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ui005_beginner_polish_verify_app.dart' as lookup;

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'QA_ROOT',
  defaultValue:
      r'C:\src\humming-v2\artifacts\storage-audit-2026-10-30\claude\exit-check',
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
}

final Map<String, dynamic> report = {};
late File _reportFile;
// written synchronously so the last line survives the process ending
void saveReport() => _reportFile.writeAsStringSync(
  const JsonEncoder.withIndent('  ').convert(report),
);
String _now() => DateTime.now().toIso8601String();

/// Records that the engine's exit request reached Dart (before the editor
/// answers it); registered first, so it always says "exit" and leaves the
/// decision to the editor.
class _ExitProbe with WidgetsBindingObserver {
  @override
  Future<AppExitResponse> didRequestAppExit() async {
    (report['exitRequests'] as List).add(_now());
    saveReport();
    return AppExitResponse.exit;
  }
}

Future<void> main() async {
  final mode = Platform.environment['QA_MODE'] ?? 'save';
  final root = _inside(p.join(_root, mode));
  final dirs = {
    for (final name in [
      'documents',
      'support',
      'cache',
      'temp',
      'library',
      'downloads',
    ])
      name: _inside(p.join(root, 'data', name)),
  };
  for (final value in dirs.values) {
    await Directory(value).create(recursive: true);
  }
  if (!p.isWithin(
    _workspace,
    p.normalize(p.absolute(Directory.systemTemp.path)),
  )) {
    throw StateError('TMP/TEMP must be isolated in repo');
  }
  _reportFile = File(p.join(root, 'result.json'));
  report.addAll({
    'mode': mode,
    'build': kReleaseMode ? 'release' : 'debug',
    'status': 'initializing',
    'exitRequests': <String>[],
    'personalDataAccess': false,
  });
  saveReport();
  PathProviderPlatform.instance = _QaPathProvider(dirs);
  SharedPreferences.setMockInitialValues({});
  final docs = Directory(dirs['documents']!);
  LoopStorage.rootOverride = docs;
  try {
    await app.main();
    WidgetsBinding.instance.addObserver(_ExitProbe());
    await Future<void>.delayed(const Duration(seconds: 1));
    await LoopPrefs.instance.setDesktopView('arrange');
    LoopPrefs.instance.metro.value = false;
    NavigatorState? navigator;
    void visit(Element e) {
      if (e is StatefulElement && e.state is NavigatorState) {
        navigator ??= e.state as NavigatorState;
      }
      e.visitChildren(visit);
    }

    visit(WidgetsBinding.instance.rootElement!);
    final section = Section(id: 'qa', name: 'QA', bars: 1, autoName: false)
      ..tracks['melody'] = TrackData(
        notes: [PitchNote(midi: 62, freq: midiToFreq(62), step: 0, dur: 2)],
      );
    final song = Song(
      id: 'qa-exit-save',
      title: 'QA exit save',
      bpm: 120,
      bars: 1,
      key: 'C',
      scale: 'chromatic',
      sections: [section],
    );
    navigator!.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: song)));
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    lookup.find<Arrangement>()!.onOpenTrack!('melody');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    lookup.tapOfText('그리드')?.call();
    lookup.tapOfText('Grid')?.call();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final looptap = Directory(p.join(docs.path, 'looptap'));
    final songsJson = File(p.join(looptap.path, 'songs.json'));
    if (mode == 'fail') {
      // the real atomic save writes songs.json.tmp first: a folder there
      // makes every save fail like a broken disk
      await Directory(p.join(looptap.path, 'songs.json.tmp', 'blocked'))
          .create(recursive: true);
    }
    final grid = lookup.find<StepGrid>()!;
    grid.onPlace(grid.ladder.firstWhere((r) => r.midi == 67), 8, 10);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    report['notesInEditor'] = [
      for (final n in lookup.find<StepGrid>()!.notes) {'midi': n.midi, 'step': n.step},
    ];
    report['songsJsonBeforeClose'] = songsJson.existsSync()
        ? songsJson.readAsStringSync().contains('"midi":67')
        : 'missing';
    report['editedAt'] = _now();
    report['status'] = 'edited';
    saveReport();
    debugPrint('[qa-exit] edited ($mode)');
    if (mode != 'fail') return;
    // wait for the save-failed dialog that the close should bring up
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (lookup.find<AlertDialog>(const ValueKey('exit-save-failed')) != null) {
        break;
      }
    }
    final shown =
        lookup.find<AlertDialog>(const ValueKey('exit-save-failed')) != null;
    report['dialogShown'] = shown;
    report['dialogAt'] = _now();
    report['songsJsonWhileBlocked'] = songsJson.existsSync()
        ? songsJson.readAsStringSync().contains('"midi":67')
        : 'missing';
    report['status'] = shown ? 'dialog' : 'no-dialog';
    saveReport();
    if (!shown) return;
    // the run script checks the window is still open, then waits for this
    await Future<void>.delayed(const Duration(seconds: 5));
    await Directory(p.join(looptap.path, 'songs.json.tmp'))
        .delete(recursive: true);
    report['unblockedAt'] = _now();
    report['status'] = 'retrying';
    saveReport();
    lookup.find<TextButton>(const ValueKey('exit-retry'))!.onPressed!();
  } catch (e, s) {
    report['status'] = 'failed';
    report['error'] = '$e';
    report['stack'] = s.toString().split('\n').take(8).join('\n');
    saveReport();
  }
}
