// Actual Dio HTTP -> production Python routers -> real local Postgres.
// R2 is an in-memory provider exposed over HTTP; NOT the production bucket.
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/cloud_backup.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const runWire = bool.fromEnvironment('QA_CLOUD_WIRE');
  if (runWire) HttpOverrides.global = null; // Allow only the explicit loopback HTTP harness below.
  test('real HTTP app-server roundtrip preserves notes, recordings and original local songs', () async {
    final qa = Directory('C:/src/humming-v2/artifacts/cloud-backup-2026-10-30/codex');
    final config = jsonDecode(await File('${qa.path}/http-config.json').readAsString()) as Map;
    final url = config['url'] as String;
    expect(Uri.parse(url).host,'127.0.0.1');
    final dio = Dio(BaseOptions(baseUrl:url,headers:{'Authorization':'Bearer ${config['token']}'}));
    // 2026-10-30 (Claude): the API acts for one account (C5)
    final api = CloudBackupApi(dio, owner: config['user'] as String);
    final phone = await qa.createTemp('wire-device-a-');
    final pc = await qa.createTemp('wire-device-b-');
    Future<void> use(Directory d) async {
      LoopStorage.rootOverride=d;
      await LoopStorage.ensureDirs();
      await LoopStorage.load();
    }
    try {
      await use(phone);
      final raw = encodeWavMono16(Float32List.fromList(List.generate(32000,(i)=>((i%109)-54)/100)),16000);
      final dry = encodeWavMono16(Float32List.fromList(List.generate(32000,(i)=>((i%89)-44)/100)),16000);
      await File('${phone.path}/looptap/vocals/wet.wav').writeAsBytes(raw);
      await File('${phone.path}/looptap/vocals/dry.wav').writeAsBytes(dry);
      final section = Section(id:'A',name:'HTTP 녹음',bars:2)
        ..tracks['melody']=TrackData(notes:[PitchNote(midi:64,freq:329.627,step:3,dur:4,velocity:93,offsetSteps:.2)])
        ..tracks['vocal']=TrackData(clips:[VocalClip(path:'wet.wav',origPath:'dry.wav')]);
      final song=Song(id:'ltWireSong',title:'노트와 녹음 HTTP 왕복',bpm:113,bars:2,sections:[section]);
      final link=await backupSong(api,song,includeAudio:true);
      final rows=await api.list();
      expect(rows.length,1);
      expect(rows.single.audioIncluded,true);
      await use(pc);
      final store=LoopStore();
      final existing=Song(id:'ltExisting',title:'기존 곡 유지',bpm:90,bars:1);
      await store.upsert(existing);
      final restored=await restoreCopy(api,store,rows.single);
      expect(restored.song.id,isNot(song.id));
      expect(restored.missing,0);
      expect(store.songs.map((s)=>s.id).toSet(),{existing.id,restored.song.id});
      expect(restored.song.bpm,song.bpm);
      expect(restored.song.sections.first.tracks['melody']!.pitchNotes.single.toJson(),section.tracks['melody']!.pitchNotes.single.toJson());
      final clip=restored.song.sections.first.tracks['vocal']!.clips!.single;
      expect(await File('${pc.path}/looptap/vocals/${clip.path}').readAsBytes(),raw);
      expect(await File('${pc.path}/looptap/vocals/${clip.origPath}').readAsBytes(),dry);
      final second=await backupSong(api,restored.song,includeAudio:true);
      expect(second.projectId,link.projectId);
      expect(second.updatedAt,isNot(link.updatedAt));
      expect((await api.list()).length,1);
      await deleteCopy(api,second.projectId);
      expect(await api.list(),isEmpty);
      expect(store.songs.length,2);
      final audit=(await Dio().get<Map<String,dynamic>>('$url/qa-audit')).data!;
      expect(audit['token_leaks'],0);
      expect(audit['puts'],2);
      expect(audit['gets'],1);
      await File('${qa.path}/http-roundtrip-evidence.json').writeAsString(jsonEncode({
        'actualHttp':true,'realPostgres':true,'realR2':false,'puts':audit['puts'],
        'downloads':audit['gets'],'tokenLeaks':audit['token_leaks'],'restoredMissing':restored.missing,
        'localSongsPreserved':store.songs.length,'waveBytesCompared':raw.length+dry.length,
        'notesPreserved':true,'cloudRowsAfterDelete':0,
      }));
    } finally {LoopStorage.rootOverride=null;dio.close(force:true);}
  }, timeout:const Timeout(Duration(minutes:2)), skip:!runWire);
}