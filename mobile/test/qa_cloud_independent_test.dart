import 'package:dio/dio.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/state/cloud_backup.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'support/fake_cloud.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    root = await Directory('C:/src/humming-v2/artifacts/cloud-backup-2026-10-30/codex').createTemp('app-safety-');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    await LoopStorage.load();
  });
  tearDown(() { LoopStorage.rootOverride = null; });
  // 2026-10-30 (Claude): the links are per account now (C5) — this writes
  // account A's; the race and the 20-links check are unchanged.
  test('simultaneous link writes preserve every successful backup', () async {
    final errors = <String>[];
    await Future.wait(List.generate(20, (i) async {
      try { await CloudLinks.put('account-a', 'song$i', CloudLink('cloud$i', 'version$i', false)); }
      catch(e) { errors.add(e.runtimeType.toString()); }
    }));
    final links = await CloudLinks.load('account-a');
    expect(errors, isEmpty, reason:'shared tmp file must not race: $errors');
    expect(links.length, 20, reason:'all successful backups need durable links');
  });
  test('switching account API must not reuse the previous account cloud version', () async {
    final song = Song(id:'ltAccountSwitch', title:'Local song', bpm:100, bars:1);
    final accountA = FakeCloud(), accountB = FakeCloud();
    // accounts A and B made explicit (2026-10-30): each API acts for its own
    await backupSong(fakeCloudApi(accountA, owner:'account-a'), song, includeAudio:false);
    // Account B has an empty backend; the local song stays on this device.
    await backupSong(fakeCloudApi(accountB, owner:'account-b'), song, includeAudio:false);
    expect(accountB.rows.length, 1);
    expect(accountA.rows.length, 1);
  });
  test('account switch after presign must stop before sending project bytes', () async {
    var signedIn='account-a';
    final cloud=FakeCloud();
    final api=fakeCloudApi(cloud,owner:'account-a',signedIn:()=>signedIn);
    api.api.interceptors.add(InterceptorsWrapper(onResponse:(r,h){
      if(r.requestOptions.path=='/storage/presign') signedIn='account-b';
      h.next(r);
    }));
    final song=Song(id:'ltPresignSwitch',title:'private notes',bpm:100,bars:1);
    await expectLater(backupSong(api,song,includeAudio:false),throwsA(isA<CloudAccountChanged>()));
    expect(cloud.puts,0,reason:'account changed BEFORE bytes were sent');
  });
  test('account switch while cloud list is arriving must discard old account response', () async {
    var signedIn='account-a';
    final cloud=FakeCloud();
    final api=fakeCloudApi(cloud,owner:'account-a',signedIn:()=>signedIn);
    final song=Song(id:'ltListSwitch',title:'account A private title',bpm:100,bars:1);
    await backupSong(api,song,includeAudio:false);
    api.api.interceptors.add(InterceptorsWrapper(onResponse:(r,h){
      if(r.requestOptions.path=='/projects') signedIn='account-b';
      h.next(r);
    }));
    await expectLater(api.list(),throwsA(isA<CloudAccountChanged>()));
  });
}