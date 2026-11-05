import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/state/loop_prefs.dart';

/// ui-001 stage 3: LoopPrefs is a singleton, so a test that switched the
/// desktop editor to the arrange view must not leak it into the next test.
/// Every test starts from the default (edit) view and (stage 4) an open
/// inspector.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    LoopPrefs.instance.desktopView.value = LoopPrefs.kDesktopViewEdit;
    LoopPrefs.instance.inspectorOpen.value = true;
    // stage 5 defaults: in-key rows only, the desktop lane not yet chosen
    LoopPrefs.instance.gridInKeyOnly.value = true;
    LoopPrefs.instance.gridVelocityLane.value = true;
    LoopPrefs.instance.gridVelocityLaneChosen.value = false;
  });
  await testMain();
}
