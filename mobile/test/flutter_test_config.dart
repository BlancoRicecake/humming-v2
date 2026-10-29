import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/state/loop_prefs.dart';

/// ui-001 stage 3: LoopPrefs is a singleton, so a test that switched the
/// desktop editor to the arrange view must not leak it into the next test.
/// Every test starts from the default (edit) view.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => LoopPrefs.instance.desktopView.value = LoopPrefs.kDesktopViewEdit);
  await testMain();
}
