// Mallet v2 of the reference reconstruction (gotye_intro_mallet.dart).
//
// ALWAYS: bars 1–8 accompaniment equals v1 (gotye_intro_repro.dart) note for
// note with the same instruments and vol; melody count/range/monophony;
// save → reload round trip.
// ONLY with HUMTRACK_MALLET_OUT set: writes song.json, the exportWavSong mix
// (marimba), exportStems (incl. the mallet solo stem), the xylophone mix for
// comparison, exportMidiSong (checked: melody notes and GM program) and notes.csv.
//
// Regenerate (from mobile/):
//   TMP=<out>/temp TEMP=<out>/temp HUMTRACK_MALLET_OUT=<out> \
//     /c/src/flutter/bin/flutter test --no-pub test/looptap/gotye_intro_mallet_test.dart
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

import 'gotye_intro_mallet.dart';
import 'gotye_intro_repro.dart';
import 'song_v2_arrangement.dart' show noteMidi;

Map<String, dynamic> _json(Object o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

Map<String, dynamic> _semantic(Song s) {
  final j = _json(s.toJson());
  j.remove('updatedAt');
  j.remove('createdAt');
  return j;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bars 1–8 accompaniment is the v1 song, unchanged', () {
    final v1 = buildGotyeIntroSong();
    final s = buildGotyeMalletSong();
    final a = v1.sections.single, b = s.sections.first;
    expect(b.bars, 8);
    for (final t in ['melody', 'bass', 'drums']) {
      expect(_json(b.tracks[t]!.toJson()), _json(a.tracks[t]!.toJson()), reason: t);
    }
    for (final t in ['melody', 'bass', 'drums']) {
      expect(s.instruments[t], v1.instruments[t], reason: t);
      expect(s.vol[t], v1.vol[t], reason: t);
    }
    expect(s.vol['melody'], 0.44);
    expect(s.vol['bass'], 0.75);
    expect(s.vol['drums'], 1.0);
    expect(s.instruments['melodyDec'], malletMarimba);
    expect(s.vol['melodyDec'], malletVol);
    expect(a.tracks['melodyDec']!.pitchNotes, isEmpty, reason: 'v1 still has no melody');
  });

  test('bars 9–10 continue the measured accompaniment pattern', () {
    final sec = buildGotyeMalletSong().sections[1];
    expect(sec.bars, 2);
    final g = sec.tracks['melody']!.pitchNotes;
    expect(g.map((n) => '${n.midi}@${n.step}'), ['50@0', '50@6', '48@8', '48@14', '50@16', '50@22', '48@24', '48@30']);
    final b = sec.tracks['bass']!.pitchNotes;
    expect(b.map((n) => '${n.midi}@${n.step}'), ['38@0', '38@6', '36@8', '38@16', '38@22', '36@24', '36@30']);
    expect(sec.tracks['drums']!.drumNotes.length, 2 * 9);
  });

  test('melody: count, range, monophonic, inside the bars', () {
    final s = buildGotyeMalletSong();
    final all = malletMelody();
    expect(all.length, 30);
    expect(all.first.bar, 3, reason: 'enters at bar 3');
    expect(all.every((n) => n.midi >= 84 && n.midi <= 96), isTrue);
    var total = 0;
    for (final sec in s.sections) {
      final ns = [...sec.tracks['melodyDec']!.pitchNotes]..sort((a, b) => a.step.compareTo(b.step));
      total += ns.length;
      for (var i = 0; i + 1 < ns.length; i++) {
        expect(ns[i].step + ns[i].dur, lessThanOrEqualTo(ns[i + 1].step));
      }
      for (final n in ns) {
        expect(n.step + n.dur, lessThanOrEqualTo(sec.bars * 16));
      }
    }
    expect(total, all.length);
    expect(malletNoteTable().length, all.length);
  });

  test('save → reload keeps the semantic JSON', () {
    final s = buildGotyeMalletSong();
    expect(_semantic(Song.fromJson(_json(s.toJson()))), _semantic(s));
  });

  test('notes.csv rows cover every note event of the song', () {
    final s = buildGotyeMalletSong();
    var events = 0;
    for (final sec in s.sections) {
      for (final t in sec.tracks.values) {
        events += t.pitchNotes.length + t.drumNotes.length;
      }
    }
    final rows = malletCsvRows();
    expect(events, 174);
    expect(rows.length, events);
    final ext = accompanimentBars9to10Table();
    expect(ext.length, 33);
    final sec = s.sections[1];
    final fromSong = [
      for (final n in sec.tracks['melody']!.pitchNotes) 'guitar ${n.step ~/ 16 + 9} ${n.step % 16 + 1} ${n.midi} ${n.dur} ${n.velocity}',
      for (final n in sec.tracks['bass']!.pitchNotes) 'bass ${n.step ~/ 16 + 9} ${n.step % 16 + 1} ${n.midi} ${n.dur} ${n.velocity}',
      for (final d in sec.tracks['drums']!.drumNotes) 'drums ${d.step ~/ 16 + 9} ${d.step % 16 + 1} ${d.kind} 1 ${d.velocity}',
    ];
    String key(List<Object> r) {
      final what = r[0] == 'drums' ? r[3] : '${noteMidi(r[3] as String)}';
      return '${r[0]} ${r[1]} ${r[2]} $what ${r[8]} ${r[9]}';
    }

    expect([for (final r in ext) key(r)]..sort(), fromSong..sort());
    expect(ext.every((r) => r[6] == 'pattern-extension' && r[7] == 'pattern-extension'), isTrue);
  });

  final csvOut = Platform.environment['HUMTRACK_MALLET_CSV_OUT'];
  test(
    'write notes.csv only (no audio/MIDI render)',
    () async => writeMalletCsv(Directory(csvOut!)),
    skip: csvOut == null || csvOut.isEmpty ? 'set HUMTRACK_MALLET_CSV_OUT to write notes.csv' : false,
  );

  final out = Platform.environment['HUMTRACK_MALLET_OUT'];
  test(
    'write song.json, mixes, stems, MIDI, notes.csv',
    () async => _writeAll(Directory(out!)),
    skip: out == null || out.isEmpty ? 'set HUMTRACK_MALLET_OUT to write the files' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _writeAll(Directory outDir) async {
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
  expect(catalog.bySlot(gotyeNylonSlot)!.id, 'freepats_nylon');
  expect(await catalog.ensureDownloaded(gotyeNylonSlot), isNotNull);

  final s = buildGotyeMalletSong();
  await File('${outDir.path}/song.json').writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()), flush: true);

  Future<File> mix(Song song) async => (await exportWavSong(
        song.sections,
        song.bpm,
        song.swing,
        Map.of(song.vol),
        song.title,
        melodyProgram: song.instruments['melody'] ?? 0,
        bassProgram: song.instruments['bass'] ?? 33,
        melodyDecProgram: song.instruments['melodyDec'] ?? 48,
        drumProgram: song.instruments['drums'] ?? kDefaultDrumKit,
        extras: const [],
        instruments: Map.of(song.instruments),
        fallbackName: song.id,
        variationSeed: song.effectiveVariationSeed,
        groove: song.grooveContext,
        pan: song.pan,
        articulations: ArticulationPlan.of(song),
      ))
          .file;

  await File('${outDir.path}/humtrack-mallet.mix.wav').writeAsBytes(await (await mix(s)).readAsBytes(), flush: true);
  final xylo = buildGotyeMalletSong(malletProgram: malletXylophone);
  await File('${outDir.path}/compare-xylophone.mix.wav').writeAsBytes(await (await mix(xylo)).readAsBytes(), flush: true);

  final stems = await exportStems(
    s.sections,
    s.bpm,
    s.swing,
    Map.of(s.vol),
    s.title,
    melodyProgram: s.instruments['melody'] ?? 0,
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: const [],
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: ArticulationPlan.of(s),
  );
  const stemNames = {'melody': 'guitar', 'bass': 'bass', 'drums': 'drums', 'melodyDec': 'mallet-solo'};
  final written = <String>[];
  for (final f in stems) {
    final label = f.path.split(RegExp(r'[\\/]')).last.replaceFirst('${s.title} - ', '').replaceFirst('.wav', '');
    final name = stemNames[label] ?? label;
    written.add(name);
    await File('${outDir.path}/stem-$name.wav').writeAsBytes(await f.readAsBytes(), flush: true);
  }
  expect(written, contains('mallet-solo'));

  final mid = await exportMidiSong(
    s.sections,
    s.bpm,
    s.title,
    melodyProgram: s.instruments['melody'] ?? 0,
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: const [],
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: ArticulationPlan.of(s),
  );
  final midBytes = await mid.readAsBytes();
  await File('${outDir.path}/humtrack-mallet.export.mid').writeAsBytes(midBytes, flush: true);
  final ref = MidiReference.parse(midBytes);
  expect(ref.bpm.round(), gotyeBpm);
  expect(ref.bars, malletBars);

  await writeMalletCsv(outDir);
  await File('${outDir.path}/omitted-candidates.txt').writeAsString('${malletCandidatesOmitted.join('\n')}\n', flush: true);
}

/// All note events of the song: v1 bars 1–8 (111) + bars 9–10 accompaniment
/// (33, pattern extension) + mallet melody (30).
List<List<Object>> malletCsvRows() => [...gotyeNoteTable(), ...accompanimentBars9to10Table(), ...malletNoteTable()];

Future<void> writeMalletCsv(Directory outDir) async {
  final csv = StringBuffer('part,bar,slot16,note_or_kind,t_render_s,t_mp3_s,pitch_conf_measured,onset_conf_measured,dur_steps,velocity,dur_vel_source,sound_source,evidence\n');
  for (final r in malletCsvRows()) {
    csv.writeln(r.map((v) => v.toString().contains(',') ? '"$v"' : '$v').join(','));
  }
  await File('${outDir.path}/notes.csv').writeAsString(csv.toString(), flush: true);
}
