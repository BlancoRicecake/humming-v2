// QA-only development entry point for the song end-to-end UI test
// (artifacts/song-e2e-20261023/plan.md). Runs the REAL app (`app.main()`)
// with no scripted scenario and no fixture injection. It only redirects every
// path_provider location (documents, support, cache, temporary, downloads,
// library) into an isolated folder inside the repo, so the user's Documents
// songs/settings and AppData copies are never read or written. Production
// `lib/main.dart` and the platform plugins are unchanged; this wrapper exists
// only in this QA entry point.
//
// Build (debug; existing QA-only Pro switch, ignored by release builds):
//   flutter build windows --debug --no-pub --target test/qa_song_e2e_app.dart
//     --dart-define=HUMTRACK_QA_PRO=true
//     [--dart-define=HUMTRACK_QA_ROOT=<dir inside C:/src/humming-v2>]
// Launch with TMP/TEMP set to <root>/temp so Dart's Directory.systemTemp
// (outside path_provider) also stays inside the repo.
//
// path / path_provider_platform_interface are transitive dependencies of the
// app (pubspec.lock); importing them here avoids touching pubspec.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'HUMTRACK_QA_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\song-e2e-20261023\ui-data',
);

/// Normalized absolute path; refuses anything outside the fixed workspace.
String _inside(String path) {
  final full = p.normalize(p.absolute(path));
  if (!p.isWithin(p.normalize(_workspace), full)) {
    throw StateError('QA path escapes $_workspace: $path -> $full');
  }
  return full;
}

/// Every path_provider location answered from inside the QA root.
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
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async =>
      [dirs['documents']!];
}

Future<void> main() async {
  final root = _inside(_root);
  final dirs = {
    for (final name in [
      'documents',
      'support',
      'cache',
      'temp',
      'library',
      'downloads',
    ])
      name: _inside(p.join(root, name)),
  };
  for (final d in dirs.values) {
    await Directory(d).create(recursive: true);
  }
  // Dart's own temp (Directory.systemTemp) follows TMP/TEMP, not
  // path_provider: refuse to start unless the launcher points it inside too.
  final sysTemp = p.normalize(p.absolute(Directory.systemTemp.path));
  if (!p.isWithin(p.normalize(_workspace), sysTemp)) {
    throw StateError('Set TMP/TEMP inside $_workspace before launching '
        '(currently $sysTemp), e.g. ${dirs['temp']}');
  }
  PathProviderPlatform.instance = _QaPathProvider(dirs);
  // Same hook desktop_smoke_app.dart uses; points at the redirected Documents.
  LoopStorage.rootOverride = Directory(dirs['documents']!);
  debugPrint('[QA song-e2e] isolated root: $root');
  for (final e in dirs.entries) {
    debugPrint('[QA song-e2e]   ${e.key}: ${e.value}');
  }
  debugPrint('[QA song-e2e]   systemTemp: $sysTemp (debug=$kDebugMode)');
  await app.main();
}
