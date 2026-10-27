// Instrumental cut of the full-song v2 reconstruction
// (gotye_full_song_v2_instrumental.dart).
//
// ALWAYS: no vocal-guide lane anywhere (extras, tracks, instruments, vol);
// every other lane of every section is the v2 song's JSON unchanged; bars
// 1–10 equal the fixed mallet v2 song on disk (minus empty added lanes);
// save → reload.
// ONLY with HUMTRACK_FULLV2_INST_OUT set: writes song.json, the exportWavSong
// mix, the full exportMidiSong and one per section (<= 8 bars). No stems (the
// v2 stems already exist under full-song-v2/render/stems-humtrack-render/).
//
// Regenerate (from mobile/):
//   TMP=<out>/temp TEMP=<out>/temp HUMTRACK_FULLV2_INST_OUT=<out>/render \
//     /c/src/flutter/bin/flutter test --no-pub test/looptap/gotye_full_song_v2_instrumental_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import 'gotye_full_song.dart';
import 'gotye_full_song_v2.dart';
import 'gotye_full_song_v2_instrumental.dart';
import 'gotye_intro_repro.dart';

const String _malletSongJson = '../artifacts/gotye-reference-20261023/claude-mallet-v2/render/song.json';

Map<String, dynamic> _json(Object o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

Map<String, dynamic> _semantic(Song s) {
  final j = _json(s.toJson());
  j.remove('updatedAt');
  j.remove('createdAt');
  return j;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no vocal-guide lane anywhere', () {
    final s = buildGotyeFullSongV2Instrumental();
    for (final sec in s.sections) {
      expect(sec.extras.map((e) => e.id), [for (final e in instrumentalExtras) e.id]);
      for (final id in vocalGuideIds) {
        expect(sec.tracks.containsKey(id), isFalse);
      }
    }
    for (final id in vocalGuideIds) {
      expect(s.instruments.containsKey(id), isFalse);
      expect(s.vol.containsKey(id), isFalse);
    }
    expect(s.sections.fold<int>(0, (a, x) => a + x.bars), 130);
    expect(s.bpm, gotyeBpm);
  });

  test('every other lane equals the v2 song (notes, velocity, timing, instruments, vol)', () {
    final v2 = buildGotyeFullSongV2();
    final s = buildGotyeFullSongV2Instrumental();
    expect(s.sections.length, v2.sections.length);
    for (var i = 0; i < s.sections.length; i++) {
      final a = _json(s.sections[i].toJson()), b = _json(v2.sections[i].toJson());
      final bt = b['tracks'] as Map<String, dynamic>;
      for (final id in vocalGuideIds) {
        bt.remove(id);
      }
      (b['extras'] as List<dynamic>).removeWhere((e) => vocalGuideIds.contains((e as Map<String, dynamic>)['id']));
      (b['order'] as List<dynamic>?)?.removeWhere(vocalGuideIds.contains);
      expect(a, b, reason: 'section $i');
    }
    for (final e in v2.instruments.entries) {
      if (!vocalGuideIds.contains(e.key)) expect(s.instruments[e.key], e.value, reason: e.key);
    }
    for (final e in v2.vol.entries) {
      if (!vocalGuideIds.contains(e.key)) expect(s.vol[e.key], e.value, reason: e.key);
    }
    expect(s.swing, v2.swing);
    final pad = [for (final sec in s.sections) ...sec.tracks[padId]!.pitchNotes];
    expect(pad.length, 450);
    expect(pad.every((n) => n.muted), isTrue);
  });

  test('bars 1–10 equal the fixed mallet v2 song on disk (minus empty added lanes)', () {
    final s = buildGotyeFullSongV2Instrumental();
    final disk = jsonDecode(File(_malletSongJson).readAsStringSync()) as Map<String, dynamic>;
    final added = {for (final e in instrumentalExtras) e.id};
    for (var i = 0; i < 2; i++) {
      final j = _json(s.sections[i].toJson());
      (j['tracks'] as Map<String, dynamic>).removeWhere((k, _) => added.contains(k));
      (j['extras'] as List<dynamic>).removeWhere((e) => added.contains((e as Map<String, dynamic>)['id']));
      expect(j, (disk['sections'] as List<dynamic>)[i], reason: 'section $i');
    }
  });

  test('save → reload keeps the semantic JSON', () {
    final s = buildGotyeFullSongV2Instrumental();
    expect(_semantic(Song.fromJson(_json(s.toJson()))), _semantic(s));
  });

  final out = Platform.environment['HUMTRACK_FULLV2_INST_OUT'];
  test(
    'write song.json, mix, full MIDI and section MIDI',
    () async => _writeAll(Directory(out!), buildGotyeFullSongV2Instrumental()),
    skip: out == null || out.isEmpty ? 'set HUMTRACK_FULLV2_INST_OUT to write the files' : false,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

Future<void> _writeAll(Directory outDir, Song s) async {
  await outDir.create(recursive: true);
  final temp = Directory('${outDir.path}/temp/render-work');
  if (await temp.exists()) await temp.delete(recursive: true);
  await temp.create(recursive: true);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) {
    final path = utf8.decode(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
    final file = File(path);
    return SynchronousFuture(file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null);
  });
  messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => temp.path);
  LoopStorage.rootOverride = temp;
  addTearDown(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    LoopStorage.rootOverride = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });
  final catalog = SoundfontCatalog.instance;
  catalog.debugSetDirectory(await Directory('${temp.path}/soundfonts').create(recursive: true));
  await catalog.warm();
  expect(await catalog.ensureDownloaded(gotyeNylonSlot), isNotNull);

  await File('${outDir.path}/song.json').writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()), flush: true);
  final wav = await exportWavSong(
    s.sections,
    s.bpm,
    s.swing,
    Map.of(s.vol),
    s.title,
    melodyProgram: s.instruments['melody'] ?? 0,
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: instrumentalExtras,
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: ArticulationPlan.of(s),
  );
  expect(wav.skippedVocals, 0);
  await File('${outDir.path}/humtrack-full-instrumental.mix.wav').writeAsBytes(await wav.file.readAsBytes(), flush: true);

  Future<List<int>> mid(List<Section> secs) async => (await exportMidiSong(
        secs,
        s.bpm,
        s.title,
        melodyProgram: s.instruments['melody'] ?? 0,
        bassProgram: s.instruments['bass'] ?? 33,
        melodyDecProgram: s.instruments['melodyDec'] ?? 48,
        drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
        extras: instrumentalExtras,
        instruments: Map.of(s.instruments),
        fallbackName: s.id,
        variationSeed: s.effectiveVariationSeed,
        groove: s.grooveContext,
        pan: s.pan,
        articulations: ArticulationPlan.build(sections: secs, instruments: Map.of(s.instruments)),
      ))
          .readAsBytes();
  final full = await mid(s.sections);
  await File('${outDir.path}/humtrack-full-instrumental.export.mid').writeAsBytes(full, flush: true);
  final ref = MidiReference.parse(Uint8List.fromList(full));
  expect(ref.bpm.round(), gotyeBpm);
  expect(ref.bars, 130);
  final secDir = await Directory('${outDir.path}/sections').create(recursive: true);
  var bar = 1;
  for (final (i, sec) in s.sections.indexed) {
    final bytes = await mid([sec]);
    final name = '${(i + 1).toString().padLeft(2, '0')}-bars$bar-${bar + sec.bars - 1}.mid';
    await File('${secDir.path}/$name').writeAsBytes(bytes, flush: true);
    expect(MidiReference.parse(Uint8List.fromList(bytes)).bars, sec.bars, reason: name);
    bar += sec.bars;
  }
}
