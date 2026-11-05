// In-app announcements (2026-10-30): the feed contract checked again on the
// device, targeting, critical once-per-revision, withdrawals, offline /
// damaged responses, old caches, shared refreshes, and the on-disk state
// written atomically (parallel writes, Windows' brief rename refusals).
// Real files in an isolated folder; fixture rows only.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/announcements/announcement.dart';
import 'package:humming/looptap/announcements/announcement_service.dart';
import 'package:humming/looptap/state/atomic_json.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import '../support/announcement_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeFeed feed;
  var now = kFixtureNow;

  AnnouncementService service({
    AnnouncementPlatform platform = AnnouncementPlatform.windows,
    int? build = 43,
  }) => AnnouncementService(
    fetch: feed.call,
    platform: platform,
    build: build,
    buildKnown: true,
    now: () => now,
  );

  /// start() + the background refresh it kicks off.
  Future<AnnouncementService> started({
    AnnouncementPlatform platform = AnnouncementPlatform.windows,
    int? build = 43,
  }) async {
    final s = service(platform: platform, build: build);
    await s.start();
    await s.refresh(); // joins the running one
    return s;
  }

  File stateFile() => File('${root.path}/looptap/announcements/state.json');
  File feedFile() => File('${root.path}/looptap/announcements/feed.json');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_ann_');
    LoopStorage.rootOverride = root;
    feed = FakeFeed();
    now = kFixtureNow;
  });
  tearDown(() async {
    AtomicJsonFile.debugRename = null;
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  group('contract checked on the device', () {
    test('a mistyped optional action never discards other announcements', () {
      final parsed = Announcement.parseFeed([
        {...annRow('broken-action'), 'action_url': 42},
        annRow('important', kind: 'critical'),
      ]);
      expect(parsed!.map((a) => a.id), ['broken-action', 'important']);
      expect(parsed.first.action, isNull);
    });
    test('bad rows are skipped, good rows kept; a non-list body is not a feed', () {
      final rows = [
        annRow('ok'),
        annRow('bad-kind', kind: 'urgent'),
        {...annRow('bad-id'), 'id': 'Bad ID'},
        {...annRow('no-rev'), 'revision': 0},
        annRow('bad-period', startsAt: kFixtureNow, endsAt: kFixtureNow.subtract(const Duration(hours: 1))),
        annRow('long', bodyEn: 'x' * 4001),
        annRow('linux', platforms: ['linux']),
        annRow('builds', minBuild: 50, maxBuild: 40),
        {...annRow('neg-build'), 'min_build': -3},
        annRow('ok'), // duplicate id
        'not a row',
      ];
      expect(Announcement.parseFeed(rows)!.map((a) => a.id), ['ok']);
      expect(Announcement.parseFeed({'rows': []}), isNull);
      expect(Announcement.parseFeed([for (var i = 0; i < 80; i++) annRow('a$i')])!.length, kAnnouncementMaxItems);
    });

    test('only vetted links become a button; the rest show without one', () {
      for (final ok in [
        'https://hum-track.com/status',
        'https://www.hum-track.com/news/1?x=1',
        'https://apps.apple.com/app/id1',
        'https://play.google.com/store/apps/details?id=x',
        'mailto:humtrack@gmail.com',
      ]) {
        expect(safeAnnouncementAction(ok), isNotNull, reason: ok);
      }
      for (final bad in [
        'http://hum-track.com/x',
        'https://hum-track.com.evil.io/x',
        'https://evil.io/hum-track.com',
        'https://user@hum-track.com/',
        'https://hum-track.com:8443/',
        'file:///C:/Windows/system32',
        'C:\\Windows\\notepad.exe',
        'intent://x#Intent;end',
        'javascript:alert(1)',
        'mailto:someone@else.com',
        'mailto:humtrack@gmail.com?body=hi',
        'humtrack://open',
      ]) {
        expect(safeAnnouncementAction(bad), isNull, reason: bad);
      }
      final a = Announcement.fromJson(annRow('link', actionUrl: 'file:///etc/passwd'))!;
      expect(a.action, isNull);
      expect(a.actionLabelEn, isNull);
    });
  });

  test('period, platform and build targeting', () async {
    feed.rows = [
      annRow('all'),
      annRow('future', startsAt: kFixtureNow.add(const Duration(hours: 1))),
      annRow('ended', startsAt: kFixtureNow.subtract(const Duration(days: 3)), endsAt: kFixtureNow.subtract(const Duration(days: 1))),
      annRow('ios-only', platforms: ['ios']),
      annRow('old-builds', maxBuild: 40),
      annRow('new-builds', minBuild: 44),
      annRow('this-build', minBuild: 43, maxBuild: 43),
    ];
    final s = await started();
    expect(s.visible.map((a) => a.id).toSet(), {'all', 'this-build'});
    // the scheduled one appears when its time comes (no refetch needed)
    now = kFixtureNow.add(const Duration(hours: 2));
    expect(s.visible.map((a) => a.id).toSet(), {'all', 'this-build', 'future'});
    now = kFixtureNow;
    final ios = await started(platform: AnnouncementPlatform.ios, build: null);
    expect(ios.visible.map((a) => a.id).toSet(), {'all', 'ios-only'}, reason: 'unknown build: untargeted rows only');
  });

  group('critical: once per run, until confirmed, again for a new revision', () {
    setUp(() => feed.rows = [annRow('outage', kind: 'critical'), annRow('news')]);

    test('first run shows it once; "later" shows it again next run; "confirm" never', () async {
      var s = await started();
      final a = s.pendingCritical()!;
      expect(a.id, 'outage');
      s.markShownThisRun(a);
      expect(s.pendingCritical(), isNull, reason: 'not again in the same run');
      await s.markRead(a); // "Later"
      s = await started(); // next launch
      expect(s.pendingCritical()?.id, 'outage', reason: 'later is not confirm');
      await s.acknowledge(s.pendingCritical()!);
      s = await started();
      expect(s.pendingCritical(), isNull, reason: 'confirmed on this device');
      expect(s.visible.map((a) => a.id), contains('outage'), reason: 'still in the list');
      // an edited announcement (new revision) is shown again
      feed.rows = [annRow('outage', kind: 'critical', revision: 2), annRow('news')];
      s = await started();
      expect(s.pendingCritical()?.revision, 2);
    });

    test('info / important never pop up', () async {
      feed.rows = [annRow('a', kind: 'important'), annRow('b')];
      final s = await started();
      expect(s.pendingCritical(), isNull);
      expect(s.forHome.length, 2);
    });
  });

  test('a successful empty feed withdraws everything (cache too)', () async {
    feed.rows = [annRow('a', kind: 'critical')];
    var s = await started();
    expect(s.visible, hasLength(1));
    feed.rows = [];
    await s.refresh(force: true);
    expect(s.visible, isEmpty);
    expect(s.pendingCritical(), isNull);
    feed.fail = true; // offline next launch: the (empty) cache rules
    s = await started();
    expect(s.visible, isEmpty);
  });

  test('offline / damaged / oversized answers never replace the last good feed', () async {
    feed.rows = [annRow('kept')];
    await started();
    final good = feedFile().readAsStringSync();
    for (final setUpBad in <void Function()>[
      () => feed.fail = true,
      () => feed.body = utf8.encode('{not json'),
      () => feed.body = utf8.encode(jsonEncode({'message': 'error'})),
      () => feed.body = List.filled(kAnnouncementMaxResponseBytes + 1, 32),
    ]) {
      feed
        ..fail = false
        ..body = null;
      setUpBad();
      final s = await started();
      expect(s.visible.map((a) => a.id), ['kept']);
      expect(feedFile().readAsStringSync(), good);
    }
  });

  test('a damaged cache or state file on disk: starts clean, never crashes', () async {
    feedFile()
      ..createSync(recursive: true)
      ..writeAsStringSync('garbage');
    stateFile().writeAsStringSync('{"read": 5');
    feed.fail = true;
    final s = await started();
    expect(s.loaded, isTrue);
    expect(s.visible, isEmpty);
    feed.fail = false;
    feed.rows = [annRow('back')];
    await s.refresh(force: true);
    expect(s.visible.single.id, 'back');
    expect(jsonDecode(feedFile().readAsStringSync())['rows'], hasLength(1));
  });

  test('an old cache (offline 8 days) is list-only: no banner, no popup', () async {
    feed.rows = [annRow('c', kind: 'critical')];
    await started();
    now = kFixtureNow.add(const Duration(days: 8));
    feed.fail = true;
    final s = await started();
    expect(s.stale, isTrue);
    expect(s.visible, hasLength(1));
    expect(s.forHome, isEmpty);
    expect(s.pendingCritical(), isNull);
  });

  test('start never waits for the network; overlapping refreshes share one request', () async {
    feed.rows = [annRow('a')];
    feed.hold = Completer<void>();
    final s = service();
    await s.start().timeout(const Duration(seconds: 2)); // network still hanging
    expect(s.loaded, isTrue);
    final r1 = s.refresh(force: true), r2 = s.refresh(force: true), r3 = s.refresh();
    feed.hold!.complete();
    await Future.wait([r1, r2, r3]);
    expect(feed.calls, 1, reason: 'one request for start + 3 overlapping refreshes');
    await s.refresh(); // within the interval: no request
    expect(feed.calls, 1);
    now = kFixtureNow.add(const Duration(minutes: 16));
    await s.refresh();
    expect(feed.calls, 2);
  });

  test('a build without the feed configured: quiet, nothing shown', () async {
    final s = AnnouncementService(fetch: () async => null, buildKnown: true, now: () => now);
    await s.start();
    await s.refresh();
    expect(s.enabled, isFalse);
    expect(s.visible, isEmpty);
  });

  group('state on disk (atomic)', () {
    test('parallel read marks all land', () async {
      feed.rows = [for (var i = 0; i < 20; i++) annRow('n$i')];
      final s = await started();
      await Future.wait([for (final a in s.visible) s.markRead(a)]);
      final disk = jsonDecode(stateFile().readAsStringSync()) as Map;
      expect((disk['read'] as List).length, 20);
      expect(stateFile().parent.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });

    test('a briefly refused replace is retried; a persistent one keeps the previous state', () async {
      feed.rows = [annRow('a', kind: 'critical'), annRow('b'), annRow('c')];
      final s = await started();
      await s.acknowledge(s.visible.firstWhere((a) => a.id == 'a'));
      var refusals = 2;
      AtomicJsonFile.debugRename = (tmp, target) async {
        if (refusals-- > 0) throw const PathAccessException('rename', OSError('Access is denied', 5));
        await tmp.rename(target);
      };
      await s.markRead(s.visible.firstWhere((a) => a.id == 'b'));
      expect((jsonDecode(stateFile().readAsStringSync())['read'] as List), containsAll(['a@1', 'b@1']));
      AtomicJsonFile.debugRename = (tmp, target) async =>
          throw const PathAccessException('rename', OSError('Access is denied', 5));
      await s.markRead(s.visible.firstWhere((a) => a.id == 'c')); // logged, not thrown
      AtomicJsonFile.debugRename = null;
      final disk = jsonDecode(stateFile().readAsStringSync()) as Map;
      expect(disk['acked'], ['a@1'], reason: 'the confirmation survived');
      expect((disk['read'] as List), isNot(contains('c@1')));
      expect(stateFile().parent.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
    });
  });
}
