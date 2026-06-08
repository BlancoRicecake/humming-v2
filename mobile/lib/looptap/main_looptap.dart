// LoopTap dev entrypoint — run with:
//   flutter run -t lib/looptap/main_looptap.dart
// Locks the app to landscape (README: "landscape mobile DAW") and launches the
// new UI in isolation from the legacy app. Final switchover repoints main.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/locale_service.dart';
import 'app.dart';
import 'state/loop_prefs.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  // Load persisted settings (haptics/metronome) + saved language before first frame.
  await Future.wait([
    LoopPrefs.instance.bootstrap(),
    LocaleService.instance.bootstrap(),
  ]);
  runApp(const LoopTapApp());
}
