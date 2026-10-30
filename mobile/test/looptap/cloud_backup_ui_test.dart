// Cloud backup UI (2026-10-30, flag-gated): recordings are off by default
// and go along only when ticked; turning them off over a copy that had them
// warns first; cancelling uploads nothing; a conflict changes nothing until
// a choice; the cloud screen restores as a new song and deletes only after a
// confirmation that says local songs stay.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  @override
  bool get isSignedIn => true;
  @override
  bool get proActive => true;
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
    await tester.pumpAndSettle();
    return tester.element(find.byType(Scaffold).first);
  }

  /// Let real IO / isolate work finish, pumping frames.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      // advance the test clock too (Dio's timers live in the test zone)
      await tester.pump(const Duration(milliseconds: 20));
    }
    // a few frames, not pumpAndSettle: progress indicators never settle
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('recordings are off by default; cancel uploads nothing', (tester) async {
    final ctx = await host(tester);
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).hasFound);
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
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).hasFound);
    await tester.tap(find.byKey(const ValueKey('cloud-include-audio')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.text('Uploaded to the cloud: Mine').hasFound);
    expect(cloud.rows.values.single['meta']['audioIncluded'], isTrue);
    expect(find.text('Uploaded to the cloud: Mine'), findsOneWidget);

    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).hasFound);
    expect(find.byKey(const ValueKey('cloud-optout-warning')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.text('Uploaded without recordings: Mine').hasFound);
    expect(cloud.rows.values.single['meta']['audioIncluded'], isFalse);
    expect(find.text('Uploaded without recordings: Mine'), findsOneWidget);
  });

  testWidgets('a conflict asks first; closing the question changes nothing', (tester) async {
    final ctx = await host(tester);
    await tester.runAsync(() => backupSong(api, song, includeAudio: false));
    cloud.rows['lt5']!['updated_at'] = '2026-10-30T11:00:00+00:00'; // other device
    final before = Map.of(cloud.rows['lt5']!);
    backupSongToCloud(ctx, song, api: api);
    await settle(tester, () => find.byKey(const ValueKey('cloud-backup-dialog')).hasFound);
    await tester.tap(find.byKey(const ValueKey('cloud-backup-confirm')));
    await settle(tester, () => find.byKey(const ValueKey('cloud-conflict')).hasFound);
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
    await settle(tester, () => find.byKey(const ValueKey('cloud-usage')).hasFound);
    expect(find.textContaining('with recordings'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cloud-restore-lt5')));
    await settle(tester, () => find.text('Added as a new song: Mine').hasFound);
    expect(store.songs.single.title, 'Mine');
    expect(find.text('Added as a new song: Mine'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cloud-delete-lt5')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Songs saved on this and other devices stay'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cloud.rows, isNotEmpty);
    await tester.tap(find.byKey(const ValueKey('cloud-delete-lt5')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-delete-yes')));
    await settle(tester, () => cloud.rows.isEmpty && find.text('Cloud copy deleted.').hasFound);
    expect(cloud.rows, isEmpty);
    expect(store.songs, hasLength(1), reason: 'the local song stays');
  });

  testWidgets('a server without the feature: the screen says so', (tester) async {
    cloud.featureOn = false;
    await host(tester, home: CloudBackupScreen(api: api));
    await settle(tester, () => find.textContaining("isn't available").hasFound);
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
      await settle(tester, () => find.byKey(const ValueKey('cloud-restore-lt5')).hasFound);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      for (final k in ['cloud-restore-lt5', 'cloud-delete-lt5']) {
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
    await settle(tester, () => find.text('Mine').hasFound);
    expect(find.text('Mine'), findsOneWidget);
    signedIn = 'user-b';
    store.sessionChanged(); // what an auth session change does
    await tester.pump();
    expect(find.text('Mine'), findsNothing);
    expect(find.byKey(const ValueKey('cloud-account-changed')), findsOneWidget);
  });
}
