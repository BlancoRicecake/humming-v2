// Local-only emulator entrypoint. Never use for a release or store upload.
// flutter run --debug -t test/first_song_smoke_app.dart \
//   --dart-define=HUMTRACK_FIRST_SONG_QA=true
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:humming/main.dart' as app;
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/services/entitlement_cache.dart';
import 'package:humming/services/locale_service.dart';
import 'package:humming/services/product_analytics.dart';

Future<void> main() async {
  if (!kDebugMode || !const bool.fromEnvironment('HUMTRACK_FIRST_SONG_QA')) {
    throw StateError('This entrypoint is only for explicit local debug QA.');
  }
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final sandbox = Directory('${support.path}/first_song_qa_20261002');
  await sandbox.create(recursive: true);
  LoopStorage.rootOverride = sandbox;
  LoopPrefs.rootOverride = sandbox;
  EntitlementCache.rootOverride = sandbox;
  ProductAnalytics.instance.installSinks([_LocalEvents()]);
  await app.main();
  // An in-memory locale override; never changes the existing locale preference.
  LocaleService.instance.selected.value = const Locale('ko');
}

class _LocalEvents implements ProductAnalyticsSink {
  @override
  Future<void> initialize() async {}
  @override
  Future<void> reset() async {}
  @override
  Future<void> setCollectionEnabled(bool enabled) async {}
  @override
  Future<void> setContext(Map<String, Object> context) async {}
  @override
  Future<void> setUserId(String? opaqueUserId) async {}
  @override
  Future<void> track(String eventName, Map<String, Object> properties) async {
    // The ProductAnalytics privacy boundary already filtered this payload.
    debugPrint('[first-song-qa] $eventName ${jsonEncode(properties)}');
  }
}
