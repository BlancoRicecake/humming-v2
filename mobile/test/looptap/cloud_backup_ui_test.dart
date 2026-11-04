// Cloud backup UI (2026-10-30, flag-gated): recordings are off by default
// and go along only when ticked; turning them off over a copy that had them
// warns first; cancelling uploads nothing; a conflict changes nothing until
// a choice; the cloud screen restores as a new song and deletes only after a
// confirmation that says local songs stay.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_test/flutter_test.dart' as flutter_test show testWidgets;
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/screens/cloud_backup_screen.dart';
import 'package:humming/looptap/state/cloud_backup.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/cloud_backup_actions.dart';
import 'package:provider/provider.dart';

import '../support/fake_cloud.dart';
import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  bool signedIn = true;
  bool pro = true;
  @override
  bool get isSignedIn => signedIn;
  @override
  bool get proActive => pro;
  @override
  bool get loaded => true;
  void sessionChanged() => notifyListeners();
}

void main() {
  late Directory root;
  late FakeCloud cloud;
  late CloudBackupApi api;
  late _Store store;
  final song = Song(id: 'lt5', title: 'Mine', sections: [
    Section(id: 'A', name: 'A', bars: 1)..tracks['vocal'] = TrackData(clips: [VocalClip(path: 't.wav')]),
  ]);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_cloud_ui_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    await LoopStorage.load();
    await Directory('${root.path}/looptap/vocals').create(recursive: true);
    File('${root.path}/looptap/vocals/t.wav')
        .writeAsBytesSync(encodeWavMono16(Float32List.fromList(List.filled(200, .2)), 44100));
    cloud = FakeCloud();
    api = fakeCloudApi(cloud);
    store = _Store();
  });
  tearDown(() async {
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<BuildContext> host(WidgetTester tester, {Widget? home}) async {
    useOfflineTestFonts();
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: home ?? const Scaffold(body: SizedBox()),
        ),
      ),
    );
    // a few frames, not pumpAndSettle: the cloud screen reads real files
    // (links), which finish only under runAsync — each test settles itself
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return tester.element(find.byType(Scaffold).first);
  }

  /// Let real IO / isolate work finish, pumping frames.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    // a real-time budget, not a round count: isolate start-up (compute) and
    // file IO vary in speed from run to run
    final clock = Stopwatch()..start();
    while (!done() && clock.elapsed < const Duration(seconds: 30)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      // advance the test clock too (Dio's timers live in the test zone)
      await tester.pump(const Duration(milliseconds: 20));
    }
    // a few frames, not pumpAndSettle: progress indicators never settle
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // a wait that never came true is a failure, not a slow pass
    if (!done()) fail('settle: the awaited state never came');
  }

  /// Real file work a test started on its fake clock (a library save, a
  /// cloud link write) must finish inside that test: the save queues are
  /// process-wide, and a save left waiting for a clock that no longer runs
  /// would hold up every later test's saves.
  Future<void> drain(WidgetTester tester) async {
    bool idle() => !LoopStorage.saving && !CloudLinks.busy;
    await settle(tester, idle);
    if (!idle()) {
      fail('library saves / cloud link writes still running at the end of the test');
    }
  }

  // every test drains its file work, also when it fails
  void testWidgets(String description, Future<void> Function(WidgetTester) body) =>
      flutter_test.testWidgets(description, (tester) async {
        try {
          await body(tester);
        } finally {
          await drain(tester);
        }
      });

  testWidgets('recordings are off by default; cancel uploads nothing', (tester) async {
    final ctx = await host(tester);
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    final box = tester.widget<CheckboxListTile>(find.byKey(const ValueKey('cloud-include-audio')));
    expect(box.value, isFalse);
    expect(find.text('Also upload 1 recording(s)'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cloud.requests, isEmpty);
  });

  testWidgets('ticking recordings uploads them; unticking later warns first', (tester) async {
    final ctx = await host(tester);
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('cloud-include-audio')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.text('Uploaded to the cloud: Mine').evaluate().isNotEmpty);
    expect(cloud.rows.values.single['meta']['audioIncluded'], isTrue);
    expect(find.text('Uploaded to the cloud: Mine'), findsOneWidget);

    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('cloud-optout-warning')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.text('Uploaded without recordings: Mine').evaluate().isNotEmpty);
    expect(cloud.rows.values.single['meta']['audioIncluded'], isFalse);
    expect(find.text('Uploaded without recordings: Mine'), findsOneWidget);
  });

  testWidgets('a conflict asks first; closing the question changes nothing', (tester) async {
    final ctx = await host(tester);
    await tester.runAsync(() => backupSong(api, song, includeAudio: false));
    cloud.rows['lt5']!['updated_at'] = '2026-10-30T11:00:00+00:00'; // other device
    final before = Map.of(cloud.rows['lt5']!);
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.byKey(const ValueKey('cloud-conflict')).evaluate().isNotEmpty);
    expect(find.text('Use this device\'s'), findsOneWidget);
    expect(find.text('Get the cloud\'s (new song)'), findsOneWidget);
    expect(find.text('Keep both'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // dismiss
    await tester.pumpAndSettle();
    expect(cloud.rows['lt5'], before);
    expect(store.songs, isEmpty);
  });

  testWidgets('cloud screen: usage, restore as a new song, delete after confirming', (tester) async {
    await tester.runAsync(() => backupSong(api, song, includeAudio: true));
    await host(tester, home: CloudBackupScreen(api: api));
    await settle(tester, () => find.byKey(const ValueKey('cloud-usage')).evaluate().isNotEmpty);
    expect(find.textContaining('with recordings'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('cloud-restore-lt5')));
    await tester.tap(find.byKey(const ValueKey('cloud-restore-lt5')));
    await settle(tester, () => find.text('Added as a new song: Mine').evaluate().isNotEmpty);
    expect(store.songs.single.title, 'Mine');
    expect(find.text('Added as a new song: Mine'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('cloud-delete-lt5')));
    await tester.tap(find.byKey(const ValueKey('cloud-delete-lt5')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Songs saved on this and other devices stay'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cloud.rows, isNotEmpty);
    await tester.ensureVisible(find.byKey(const ValueKey('cloud-delete-lt5')));
    await tester.tap(find.byKey(const ValueKey('cloud-delete-lt5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-delete-yes')));
    await settle(tester, () => cloud.rows.isEmpty && find.text('Cloud copy deleted.').evaluate().isNotEmpty);
    expect(cloud.rows, isEmpty);
    expect(store.songs, hasLength(1), reason: 'the local song stays');
  });

  testWidgets('a server without the feature: the screen says so', (tester) async {
    cloud.featureOn = false;
    await host(tester, home: CloudBackupScreen(api: api));
    await settle(tester, () => find.textContaining("isn't available").evaluate().isNotEmpty);
    expect(find.text("Cloud backup isn't available yet. Nothing was uploaded."), findsOneWidget);
  });

  // Codex C6: restore / delete stay reachable on a 320 px screen with large
  // text (test font here; real Segoe UI + Malgun Gothic in
  // test/qa_cloud_layout_test.dart).
  for (final c in [('en', 1.0), ('en', 1.5), ('ko', 1.0), ('ko', 1.5)]) {
    testWidgets('cloud screen fits 320 px, ${c.$1} text x${c.$2}', (tester) async {
      await tester.runAsync(() => backupSong(api, song, includeAudio: true));
      cloud.rows['lt5']!['title'] = 'A complete song with recordings · 내 곡';
      useOfflineTestFonts();
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            locale: Locale(c.$1),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(c.$2)),
              child: child!,
            ),
            home: CloudBackupScreen(api: api),
          ),
        ),
      );
      // loaded: the guide is up and the list's spinner is gone (the usage
      // line itself may sit below a 320 x 640 screen with large text)
      await settle(
        tester,
        () =>
            find.byKey(const ValueKey('cloud-guide')).evaluate().isNotEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      expect(find.byKey(const ValueKey('cloud-retry')), findsNothing);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      for (final k in ['cloud-restore-lt5', 'cloud-delete-lt5']) {
        // the guide sits above the list: scroll to the copy first
        await tester.scrollUntilVisible(find.byKey(ValueKey(k)), 120);
        final r = tester.getRect(find.byKey(ValueKey(k)));
        expect(r.left >= 0 && r.right <= 320, isTrue, reason: '$k on screen: $r');
      }
    });
  }

  testWidgets('C5: the cloud list of the previous account leaves the screen on a switch', (tester) async {
    var signedIn = 'user-a';
    final a = fakeCloudApi(cloud, owner: 'user-a', signedIn: () => signedIn);
    await tester.runAsync(() => backupSong(a, song, includeAudio: false));
    await host(tester, home: CloudBackupScreen(api: a));
    await settle(tester, () => find.text('Mine').evaluate().isNotEmpty);
    expect(find.text('Mine'), findsOneWidget);
    signedIn = 'user-b';
    store.sessionChanged(); // what an auth session change does
    await tester.pump();
    expect(find.text('Mine'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-account-changed')), findsOneWidget);
  });

  // ── 2026-11-04: customer-facing cloud flow ──
  testWidgets('opened signed out: signing in from the screen binds that account and loads its list', (tester) async {
    // fixture: B's copy is made while B is signed in (the account guard
    // stays on); the screen then opens signed out
    String? signedIn = 'user-b';
    final b = fakeCloudApi(cloud, owner: 'user-b', signedIn: () => signedIn);
    await tester.runAsync(() => backupSong(b, song, includeAudio: false));
    signedIn = null;
    cloud.requests.clear(); // count only what the screen asks
    store.signedIn = false;
    await host(
      tester,
      home: CloudBackupScreen(apiFactory: () => signedIn == null ? null : b),
    );
    expect(find.byKey(const ValueKey('cloud-guide')), findsOneWidget, reason: 'where / how, before signing in');
    expect(find.byKey(const ValueKey('cloud-sign-in')), findsOneWidget);
    // signed out, no request started: nothing failed in the background
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull, reason: 'initial signed-out: no uncaught error');
    expect(cloud.requests, isEmpty, reason: 'nothing asked of the server while signed out');

    // the button opens the account sheet; closing it (cancel) leaves the
    // screen signed out and quiet
    await tester.tap(find.byKey(const ValueKey('cloud-sign-in')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(const Offset(4, 4)); // outside the sheet
    await tester.pump(const Duration(milliseconds: 400));
    store.sessionChanged(); // an auth event without a session
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('cloud-sign-in')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'sign-in cancelled: no uncaught error');
    expect(cloud.requests, isEmpty);

    // what finishing sign-in does: the session and the store change
    signedIn = 'user-b';
    store.signedIn = true;
    store.sessionChanged();
    await settle(tester, () => find.text('Mine').evaluate().isNotEmpty);
    expect(tester.takeException(), isNull, reason: 'signed in: no uncaught error');
    expect(find.byKey(const ValueKey('cloud-sign-in')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-usage')), findsOneWidget);
    expect(find.text('Mine'), findsOneWidget);
    // and the C5 guard still holds for a later switch
    signedIn = 'user-c';
    store.sessionChanged();
    await tester.pump();
    expect(find.text('Mine'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-account-changed')), findsOneWidget);
  });

  testWidgets('a restore that worked but a list that failed to reload: both said, retry reloads', (tester) async {
    await tester.runAsync(() => backupSong(api, song, includeAudio: true));
    await host(tester, home: CloudBackupScreen(api: api));
    await settle(tester, () => find.byKey(const ValueKey('cloud-usage')).evaluate().isNotEmpty);
    cloud.failUsage = true; // the reload after the action fails
    await tester.ensureVisible(find.byKey(const ValueKey('cloud-restore-lt5')));
    await tester.tap(find.byKey(const ValueKey('cloud-restore-lt5')));
    await settle(tester, () => find.byKey(const ValueKey('cloud-retry')).evaluate().isNotEmpty);
    expect(find.text('Added as a new song: Mine'), findsOneWidget, reason: 'the restore did happen');
    expect(find.byKey(const ValueKey('cloud-retry')), findsOneWidget);
    expect(store.songs.single.title, 'Mine');
    cloud.failUsage = false;
    await tester.tap(find.byKey(const ValueKey('cloud-retry')));
    await settle(tester, () => find.byKey(const ValueKey('cloud-usage')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('cloud-retry')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-restore-lt5')), findsOneWidget);
  });

  testWidgets('guide, Pro note, linked song, last backup, upload progress and "view"', (tester) async {
    final ctx = await host(tester);
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('cloud-last-backup')), findsNothing, reason: 'never backed up');
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await tester.pump();
    expect(find.byKey(const ValueKey('cloud-progress')), findsOneWidget, reason: 'the upload shows progress');
    await settle(tester, () => find.text('Uploaded without recordings: Mine').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('cloud-progress')), findsNothing, reason: 'closed when done');
    expect(find.text('View'), findsOneWidget);
    // the next backup says when the last one was
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('cloud-last-backup')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // the screen: the guide, which local song a copy belongs to; without Pro
    // the note says uploads are locked but restore/delete stay
    await tester.runAsync(() => store.upsert(song)); // real file IO
    store.pro = false;
    await host(tester, home: CloudBackupScreen(api: api));
    await settle(tester, () => find.byKey(const ValueKey('cloud-usage')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('cloud-guide')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-pro-note')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-restore-lt5')), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-delete-lt5')), findsOneWidget);
  });

  testWidgets('a network failure offers "try again", which asks again', (tester) async {
    final ctx = await host(tester);
    cloud.failPut = true;
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.text('Try again').evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('cloud-progress')), findsNothing);
    expect(cloud.rows, isEmpty);
    cloud.failPut = false;
    await tester.tap(find.text('Try again'));
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).evaluate().isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.text('Uploaded without recordings: Mine').evaluate().isNotEmpty);
    expect(cloud.rows, hasLength(1));
  });
}
