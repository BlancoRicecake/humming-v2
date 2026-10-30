// Cloud backup (contract 1, 2026-10-30): the app side against an in-memory
// API + R2 behind Dio adapters (the server's own rules — atomic switch,
// isolation, quota — are tested in backend/tests/test_cloud_backup.py on a
// real Postgres). Checked here, on real files in an isolated folder:
// - the account token goes to our API only, never to the signed R2 URLs, and
//   the PUT carries exactly the signed headers;
// - a server without the feature / contract stops before anything uploads;
// - backup with recordings → restore on an empty "device" = same song and
//   byte-identical takes as a NEW local song; a notes-only copy says so and
//   restores silent takes;
// - a failed upload commits nothing and keeps the link; a conflict offers
//   keep this device's / take the cloud's / keep both; a damaged download
//   is refused; deleting the cloud copy leaves local songs alone.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/cloud_backup.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';

import '../support/fake_cloud.dart';


Uint8List _wav(int seed) => encodeWavMono16(
  Float32List.fromList([for (var i = 0; i < 300; i++) ((i * seed) % 89) / 200]),
  44100,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory phone, pc;
  late FakeCloud cloud;
  late CloudBackupApi api;

  Future<void> use(Directory root) async {
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    await LoopStorage.load();
    await Directory('${root.path}/looptap/vocals').create(recursive: true);
  }

  Song song() => Song(
    id: 'lt100',
    title: '클라우드 곡',
    bpm: 100,
    bars: 1,
    sections: [
      Section(id: 'A', name: 'A', bars: 1)
        ..tracks['vocal'] = TrackData(clips: [VocalClip(path: 'take.wav', origPath: 'dry.wav')]),
    ],
  );

  setUp(() async {
    phone = await Directory.systemTemp.createTemp('humtrack_cloud_phone_');
    pc = await Directory.systemTemp.createTemp('humtrack_cloud_pc_');
    await use(phone);
    await File('${phone.path}/looptap/vocals/take.wav').writeAsBytes(_wav(3));
    await File('${phone.path}/looptap/vocals/dry.wav').writeAsBytes(_wav(5));
    cloud = FakeCloud();
    api = fakeCloudApi(cloud);
  });
  tearDown(() async {
    LoopStorage.rootOverride = null;
    await phone.delete(recursive: true);
    await pc.delete(recursive: true);
  });

  void expectNoTokenToStorage() {
    for (final r in cloud.requests) {
      final auth = r.headers['Authorization'] ?? r.headers['authorization'];
      if (r.uri.host == 'r2.test') {
        expect(auth, isNull, reason: 'no account token to ${r.method} R2');
      } else {
        expect(auth, 'Bearer $kFakeToken');
      }
    }
  }

  test('backup with recordings on the phone -> restore on the PC: same song, same takes, new local song', () async {
    final s = song();
    final link = await backupSong(api, s, includeAudio: true);
    expect(link.audioIncluded, isTrue);
    expect(cloud.puts, 1);
    expectNoTokenToStorage();
    final put = cloud.requests.firstWhere((r) => r.method == 'PUT');
    expect(put.headers['If-None-Match'], '*');

    await use(pc);
    final pcStore = LoopStore();
    final copies = await api.list();
    expect(copies.single.title, '클라우드 곡');
    expect(copies.single.audioIncluded, isTrue);
    final res = await restoreCopy(api, pcStore, copies.single);
    expect(res.missing, 0);
    expect(pcStore.songs.single.id, res.song.id);
    expect(res.song.id, isNot(s.id));
    final clip = res.song.sections.single.tracks['vocal']!.clips!.single;
    expect(await File('${pc.path}/looptap/vocals/${clip.path}').readAsBytes(), _wav(3));
    expect(await File('${pc.path}/looptap/vocals/${clip.origPath}').readAsBytes(), _wav(5));
    // the restored song continues the same cloud copy
    expect((await CloudLinks.load(api.owner))[res.song.id]!.projectId, s.id);
    expectNoTokenToStorage();
  });

  test('a notes-only copy leaves the recordings on the device and says so', () async {
    final link = await backupSong(api, song(), includeAudio: false);
    expect(link.audioIncluded, isFalse);
    final copy = (await api.list()).single;
    expect(copy.audioIncluded, isFalse);
    expect(copy.takes, 2);
    final stored = latin1.decode(cloud.objects[cloud.rows.values.single['meta']['key']]!);
    expect(stored.contains('audio/'), isFalse, reason: 'no recording inside');
    expect(stored.contains('"audioIncluded": false'), isTrue);
    await use(pc);
    final res = await restoreCopy(api, LoopStore(), copy);
    expect(res.missing, 2, reason: 'silent placeholders, not other files');
  });

  test('no feature / an older server: nothing is uploaded', () async {
    cloud.featureOn = false;
    await expectLater(backupSong(api, song(), includeAudio: true), throwsA(isA<CloudUnavailable>()));
    cloud.featureOn = true;
    cloud.contract = 0;
    await expectLater(backupSong(api, song(), includeAudio: true), throwsA(isA<CloudUnavailable>()));
    expect(cloud.puts, 0);
    expect(cloud.requests.where((r) => r.uri.path == '/storage/presign'), isEmpty);
    expect(await CloudLinks.load(api.owner), isEmpty);
  });

  test('not Pro / over quota: refused before the upload, nothing linked', () async {
    cloud.pro = false;
    await expectLater(backupSong(api, song(), includeAudio: true), throwsA(isA<CloudProRequired>()));
    cloud.pro = true;
    cloud.quota = 100;
    await expectLater(backupSong(api, song(), includeAudio: true), throwsA(isA<CloudQuotaExceeded>()));
    expect(cloud.puts, 0);
    expect(cloud.rows, isEmpty);
  });

  test('a failed upload commits nothing and keeps the previous copy and link', () async {
    final s = song();
    final first = await backupSong(api, s, includeAudio: true);
    final before = Map.of(cloud.rows[s.id]!);
    cloud.failPut = true;
    await File('${phone.path}/looptap/vocals/take.wav').writeAsBytes(_wav(7));
    await expectLater(backupSong(api, s, includeAudio: true), throwsA(isA<CloudFailed>()));
    expect(cloud.rows[s.id], before);
    expect((await CloudLinks.load(api.owner))[s.id]!.updatedAt, first.updatedAt);
  });

  group('conflict (another device backed up in between)', () {
    late Song s;
    setUp(() async {
      s = song();
      await backupSong(api, s, includeAudio: true);
      // the other device's newer version
      final row = cloud.rows[s.id]!;
      row['updated_at'] = '2026-10-30T10:00:00+00:00';
      row['title'] = 'PC version';
    });

    test('keep this device\'s: commits the same upload over the shown version', () async {
      late CloudConflict c;
      try {
        await backupSong(api, s, includeAudio: true);
        fail('expected a conflict');
      } on CloudConflict catch (e) {
        c = e;
      }
      expect(c.cloud!.title, 'PC version');
      final putsBefore = cloud.puts;
      final link = await keepThisDevice(api, s, c);
      expect(cloud.puts, putsBefore, reason: 'no second upload');
      expect(cloud.rows[s.id]!['title'], s.title);
      expect((await CloudLinks.load(api.owner))[s.id]!.updatedAt, link.updatedAt);
    });

    test('take the cloud\'s: a new local song, this device\'s song untouched', () async {
      final store = LoopStore();
      await store.upsert(s);
      final res = await restoreCopy(api, store, (await api.list()).single);
      expect(store.songs.map((x) => x.id).toSet(), {s.id, res.song.id});
      expect(store.songs.firstWhere((x) => x.id == s.id).title, s.title);
    });

    test('keep both: this device\'s song becomes a separate cloud copy', () async {
      final link = await backupAsNewCopy(api, s, includeAudio: true);
      expect(link.projectId, isNot(s.id));
      expect(cloud.rows.keys.toSet(), {s.id, link.projectId});
      expect(cloud.rows[s.id]!['title'], 'PC version');
    });
  });

  test('a damaged download is refused and nothing is added', () async {
    await backupSong(api, song(), includeAudio: true);
    cloud.corruptDownload = true;
    await use(pc);
    final store = LoopStore();
    await expectLater(restoreCopy(api, store, (await api.list()).single), throwsA(isA<CloudDamaged>()));
    expect(store.songs, isEmpty);
  });

  test('deleting the cloud copy keeps local songs and forgets the link', () async {
    final s = song();
    final store = LoopStore();
    await store.upsert(s);
    await backupSong(api, s, includeAudio: true);
    await deleteCopy(api, s.id);
    expect(cloud.rows, isEmpty);
    expect(cloud.objects, isEmpty);
    expect(store.songs.single.id, s.id);
    expect(await CloudLinks.load(api.owner), isEmpty);
    // next backup is a first upload again
    await backupSong(api, s, includeAudio: false);
    expect(cloud.rows.keys, [s.id]);
  });

  test('upload checksum matches the bytes the server stores', () async {
    await backupSong(api, song(), includeAudio: true);
    final row = cloud.rows.values.single;
    final data = cloud.objects[row['meta']['key']]!;
    expect(sha256.convert(data).toString(), row['meta']['sha256']);
    expect(data.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04]);
  });

  // ── Codex independent review 2 (2026-10-30): C1, C4, C5 ───────────────
  // (initial failures: artifacts/cloud-backup-2026-10-30/codex/app-initial.log)
  test('C1: a lost commit answer is confirmed from the cloud copy, not retried blindly', () async {
    final s = song();
    cloud.loseCommitResponse = true;
    final link = await backupSong(api, s, includeAudio: true);
    expect(cloud.rows[s.id]!['updated_at'], link.updatedAt);
    expect((await CloudLinks.load(api.owner))[s.id]!.updatedAt, link.updatedAt);
    expect(cloud.puts, 1, reason: 'no second upload');
  });

  test('C1: a retry whose first commit did land counts as committed', () async {
    final s = song();
    final first = await backupSong(api, s, includeAudio: true);
    // the same bytes again with a stale version (the answer to a commit that
    // landed was lost): the 409 shows our own bytes → committed
    final conflict = CloudConflict(
      cloud: (await api.list()).single,
      upload: CloudUpload(projectId: s.id, title: s.title, meta: {
        ...(cloud.rows[s.id]!['meta'] as Map).cast<String, Object>(),
      }),
    );
    expect(conflict.cloud!.rawUpdatedAt, first.updatedAt);
    expect(await api.commit(conflict.upload, expected: '2000-01-01T00:00:00+00:00'), first.updatedAt);
  });

  test('C4: 20 simultaneous link writes all land, no temp-file race', () async {
    final errors = <Object>[];
    await Future.wait([
      for (var i = 0; i < 20; i++)
        CloudLinks.put('user-a', 'song$i', CloudLink('cloud$i', 'v$i', false)).catchError((Object e) {
          errors.add(e);
        }),
    ]);
    expect(errors, isEmpty);
    final links = await CloudLinks.load('user-a');
    expect(links.length, 20);
    expect(links['song7']!.projectId, 'cloud7');
    final dir = Directory('${phone.path}/looptap/cloud_links');
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('C4: parallel backups of different songs keep every link', () async {
    final songs = [
      for (var i = 0; i < 5; i++) Song(id: 'ltPar$i', title: 'P$i', bpm: 100, bars: 1),
    ];
    await Future.wait([for (final s in songs) backupSong(api, s, includeAudio: false)]);
    final links = await CloudLinks.load(api.owner);
    expect(songs.every((s) => links[s.id]?.projectId == s.id), isTrue);
    expect(cloud.rows.length, 5);
  });

  test('C5: account B never gets account A\'s cloud version for the same local song', () async {
    final s = song();
    final cloudB = FakeCloud();
    final apiA = fakeCloudApi(cloud, owner: 'account-a');
    final apiB = fakeCloudApi(cloudB, owner: 'account-b');
    await backupSong(apiA, s, includeAudio: false);
    await backupSong(apiB, s, includeAudio: false); // empty account: a first upload
    expect(cloud.rows.length, 1);
    expect(cloudB.rows.length, 1);
    final commitB = cloudB.requests.lastWhere((r) => r.uri.path == '/projects' && r.method == 'POST');
    expect((commitB.data as Map)['expect_absent'], isTrue);
    expect((commitB.data as Map).containsKey('expected_updated_at'), isFalse);
    expect((await CloudLinks.load('account-a'))[s.id]!.updatedAt, cloud.rows[s.id]!['updated_at']);
    expect((await CloudLinks.load('account-b'))[s.id]!.updatedAt, cloudB.rows[s.id]!['updated_at']);
  });

  test('C5: switching accounts mid-upload stops before the commit and writes no link', () async {
    var signedIn = 'account-a';
    final a = fakeCloudApi(cloud, owner: 'account-a', signedIn: () => signedIn);
    cloud.onPut = () => signedIn = 'account-b';
    await expectLater(backupSong(a, song(), includeAudio: true), throwsA(isA<CloudAccountChanged>()));
    expect(cloud.rows, isEmpty, reason: 'no commit sent');
    expect(cloud.requests.where((r) => r.uri.path == '/projects' && r.method == 'POST'), isEmpty);
    expect(await CloudLinks.load('account-a'), isEmpty);
    expect(await CloudLinks.load('account-b'), isEmpty);
  });

  test('C5: switching accounts mid-download adds nothing to the new account\'s library', () async {
    await backupSong(api, song(), includeAudio: true);
    var signedIn = 'user-a';
    final a = fakeCloudApi(cloud, owner: 'user-a', signedIn: () => signedIn);
    cloud.onGet = () => signedIn = 'user-b';
    await use(pc);
    final store = LoopStore();
    final copy = (await a.list()).single;
    await expectLater(restoreCopy(a, store, copy), throwsA(isA<CloudAccountChanged>()));
    expect(store.songs, isEmpty);
    expect(Directory('${pc.path}/looptap/vocals').listSync(), isEmpty);
    expect(await CloudLinks.load('user-b'), isEmpty);
  });

  test('C5: an API made for a signed-out session refuses to send anything', () async {
    final a = fakeCloudApi(cloud, owner: 'user-a', signedIn: () => null);
    await expectLater(a.list(), throwsA(isA<CloudAccountChanged>()));
    expect(cloud.requests, isEmpty);
  });

  // Codex C5 additional boundaries: the account switches while an ANSWER is
  // on its way back (account-boundaries-initial.log).
  test('C5: a switch right after the upload grant sends no bytes', () async {
    var signedIn = 'user-a';
    final a = fakeCloudApi(cloud, owner: 'user-a', signedIn: () => signedIn);
    a.api.interceptors.add(InterceptorsWrapper(onResponse: (r, h) {
      if (r.requestOptions.path == '/storage/presign') signedIn = 'user-b';
      h.next(r);
    }));
    await expectLater(backupSong(a, song(), includeAudio: true), throwsA(isA<CloudAccountChanged>()));
    expect(cloud.puts, 0, reason: 'no private bytes after the switch');
    expect(cloud.rows, isEmpty);
  });

  test('C5: a list answered after a switch is never returned', () async {
    await backupSong(api, song(), includeAudio: false);
    var signedIn = 'user-a';
    final a = fakeCloudApi(cloud, owner: 'user-a', signedIn: () => signedIn);
    a.api.interceptors.add(InterceptorsWrapper(onResponse: (r, h) {
      if (r.requestOptions.path == '/projects') signedIn = 'user-b';
      h.next(r);
    }));
    await expectLater(a.list(), throwsA(isA<CloudAccountChanged>()));
  });

  test('C5: every API call names its account (server refuses a mismatched token)', () async {
    await backupSong(api, song(), includeAudio: false);
    final apiCalls = cloud.requests.where((r) => r.uri.host == 'api.test');
    expect(apiCalls, isNotEmpty);
    for (final r in apiCalls) {
      expect(r.headers['X-Expected-User'], 'user-a', reason: r.uri.path);
    }
    for (final r in cloud.requests.where((r) => r.uri.host == 'r2.test')) {
      expect(r.headers.containsKey('X-Expected-User'), isFalse);
    }
  });

  test('C5: the server\'s account_mismatch answer stops the action', () async {
    cloud.accountMismatch = true;
    await expectLater(backupSong(api, song(), includeAudio: false), throwsA(isA<CloudAccountChanged>()));
    await expectLater(api.delete('lt100'), throwsA(isA<CloudAccountChanged>()));
    expect(cloud.puts, 0);
  });

  // C4 follow-up (codex/flutter-full-final.log): Windows refused the
  // replace for a moment (errno 5) during parallel backups.
  test('C4: a briefly refused link-file replace is retried; nothing is lost', () async {
    await CloudLinks.put('user-a', 'keep', const CloudLink('cloud-keep', 'v0', false));
    var refusals = 2;
    CloudLinks.debugRename = (tmp, target) async {
      if (refusals-- > 0) {
        throw const PathAccessException('rename', OSError('Access is denied', 5));
      }
      await tmp.rename(target);
    };
    addTearDown(() => CloudLinks.debugRename = null);
    await CloudLinks.put('user-a', 'new', const CloudLink('cloud-new', 'v1', false));
    final links = await CloudLinks.load('user-a');
    expect(links.keys.toSet(), {'keep', 'new'});
  });

  test('C4: a replace that keeps failing reports it and keeps the previous links', () async {
    await CloudLinks.put('user-a', 'keep', const CloudLink('cloud-keep', 'v0', false));
    CloudLinks.debugRename = (tmp, target) async =>
        throw const PathAccessException('rename', OSError('Access is denied', 5));
    addTearDown(() => CloudLinks.debugRename = null);
    await expectLater(
      CloudLinks.put('user-a', 'new', const CloudLink('cloud-new', 'v1', false)),
      throwsA(isA<FileSystemException>()),
    );
    CloudLinks.debugRename = null;
    final links = await CloudLinks.load('user-a');
    expect(links.keys.toSet(), {'keep'}, reason: 'the previous file was never deleted');
    final dir = Directory('${phone.path}/looptap/cloud_links');
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty, reason: 'temp removed');
  });
}
