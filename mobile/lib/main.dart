// HumTrack — app entrypoint. Landscape tap-to-make-beats DAW.
//
// The product lives in lib/looptap/ (the former "LoopTap" module, now HumTrack).
// The legacy portrait recording app was removed; this is the single entry:
// lock landscape, load persisted settings + language, then run the app.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'looptap/app.dart';
import 'looptap/state/loop_prefs.dart';
import 'services/locale_service.dart';

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
