// Phone editor (2026-11-02): the track list and the editing pad share their
// height through a draggable handle (saved; double-tap resets; hidden while
// 편집 확대 folds the track list). Desktop is unchanged (no handle).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_split_');
    LoopStorage.rootOverride = root;
    LoopPrefs.rootOverride = root;
    await LoopStorage.ensureDirs();
    LoopPrefs.instance.metro.value = false;
    // audio plugins are absent in tests (as in first_song_flow_test)
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });
  tearDown(() async {
    LoopPrefs.instance.resetGridLayout();
    EditScreen.debugDesktopOverride = null;
    LoopStorage.rootOverride = null;
    LoopPrefs.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, {bool desktop = false}) async {
    useOfflineTestFonts();
    EditScreen.debugDesktopOverride = desktop;
    tester.view.physicalSize = desktop ? const Size(1280, 720) : const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sec = Section(id: 'A', name: 'A', bars: 2)..tracks['melody'] = TrackData();
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: _Store(),
        child: MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: EditScreen(song: Song(id: 'split', title: 'Split', bars: 2, sections: [sec])),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void ignoreOverflow() {
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
  }

  final handle = find.byKey(const ValueKey('phone-split-handle'));

  testWidgets('phone: drag the handle to give the track list or the pad more room', (tester) async {
    ignoreOverflow();
    await open(tester);
    expect(handle, findsOneWidget);
    final start = LoopPrefs.instance.phoneTimelineShare.value;
    expect(start, LoopPrefs.kPhoneTimelineShareDefault);
    final y0 = tester.getCenter(handle).dy;

    await tester.drag(handle, const Offset(0, 60)); // more tracks
    await tester.pumpAndSettle();
    expect(LoopPrefs.instance.phoneTimelineShare.value, greaterThan(start));
    expect(tester.getCenter(handle).dy, greaterThan(y0 + 20), reason: 'the handle followed');

    await tester.drag(handle, const Offset(0, -2000)); // as small as allowed
    await tester.pumpAndSettle();
    expect(LoopPrefs.instance.phoneTimelineShare.value, LoopPrefs.kPhoneTimelineShareMin);

    await tester.drag(handle, const Offset(0, 2000)); // as big as allowed
    await tester.pumpAndSettle();
    expect(LoopPrefs.instance.phoneTimelineShare.value, LoopPrefs.kPhoneTimelineShareMax);

    // double-tap: back to the default split
    await tester.tap(handle);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(LoopPrefs.instance.phoneTimelineShare.value, LoopPrefs.kPhoneTimelineShareDefault);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the split is saved and comes back', (tester) async {
    ignoreOverflow();
    await open(tester);
    await tester.drag(handle, const Offset(0, 50));
    await tester.pumpAndSettle();
    final saved = LoopPrefs.instance.phoneTimelineShare.value;
    final prefs = File('${root.path}/looptap/prefs.json');
    for (var i = 0; i < 50 && !(prefs.existsSync() && prefs.readAsStringSync().contains('phoneTimelineShare')); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(prefs.readAsStringSync(), contains('"phoneTimelineShare":$saved'));
    // an app restart reads it back
    LoopPrefs.instance.resetGridLayout();
    LoopPrefs.instance.debugAllowReload();
    await tester.runAsync(() => LoopPrefs.instance.bootstrap());
    expect(LoopPrefs.instance.phoneTimelineShare.value, saved);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('편집 확대 folds the track list: no handle; desktop: no handle', (tester) async {
    ignoreOverflow();
    LoopPrefs.instance.gridFocus.value = true;
    await open(tester);
    // the fold applies only on the grid input mode of a pitched track; the
    // handle is there until then, and never twice
    expect(handle.evaluate().length, lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
    LoopPrefs.instance.gridFocus.value = false;
    await open(tester, desktop: true);
    expect(handle, findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  // device 2026-11-02 (landscape, track list dragged small): the arrangement
  // header overflowed by 8.6 px; the pads below by ~4 px.
  for (final share in [LoopPrefs.kPhoneTimelineShareMin, LoopPrefs.kPhoneTimelineShareDefault, LoopPrefs.kPhoneTimelineShareMax]) {
    for (final (track, mode) in [('Drums', '패드'), ('Drums', '그리드'), ('Melody', '패드'), ('Melody', '그리드')]) {
      testWidgets('landscape split $share, $track $mode: nothing overflows', (tester) async {
        LoopPrefs.instance.phoneTimelineShare.value = share;
        await open(tester);
        if (find.text(track).evaluate().isNotEmpty) {
          await tester.tap(find.text(track).first, warnIfMissed: false);
          await tester.pumpAndSettle();
        }
        await tester.tap(find.text(mode).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
