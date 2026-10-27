// Reference reconstruction of the MP3 intro (gotye_intro_repro.dart).
//
// ALWAYS: builds the song with the real models, checks length, note counts,
// ranges, drum kinds map to GM keys, guitar loop identical per bar, and a
// save → reload JSON round trip.
// ONLY with HUMTRACK_GOTYE_OUT set: writes song.json, the real exportWavSong
// mix, exportStems, exportMidiSong and notes.csv into that folder.
//
// Regenerate (from mobile/):
//   TMP=<out>/temp TEMP=<out>/temp HUMTRACK_GOTYE_OUT=<out> \
//     /c/src/flutter/bin/flutter test --no-pub test/looptap/gotye_intro_repro_test.dart
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
import 'package:humming/looptap/music/percussion.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import 'gotye_intro_repro.dart';

Map<String, dynamic> _semantic(Song s) {
  final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
  j.remove('updatedAt');
  j.remove('createdAt');
  return j;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('intro song: shape, counts, ranges, drum map', () {
    final s = buildGotyeIntroSong();
    final sec = s.sections.single;
    expect(sec.bars, 8);
    expect(s.bpm, 129);
    final g = sec.tracks['melody']!.pitchNotes;
    final b = sec.tracks['bass']!.pitchNotes;
    final d = sec.tracks['drums']!.drumNotes;
    expect(g.length, 32);
    expect(b.length, 21);
    expect(d.length, 16 + 6 * 7);
    // guitar loop: same content every bar
    String bar(int i) => (g.where((n) => n.step ~/ 16 == i).map((n) => '${n.midi}@${n.step % 16}:${n.dur}:${n.velocity}').toList()..sort()).join(',');
    for (var i = 1; i < 8; i++) {
      expect(bar(i), bar(0));
    }
    expect(g.every((n) => n.midi == 48 || n.midi == 50), isTrue);
    expect(b.every((n) => n.midi >= 36 && n.midi <= 48 && n.step >= 32), isTrue);
    for (final n in [...g, ...b]) {
      expect(n.step + n.dur, lessThanOrEqualTo(128));
    }
    for (final h in d) {
      expect(percussionMidi(h.kind), isNotNull, reason: h.kind);
    }
    expect({for (final h in d) percussionMidi(h.kind)}, {42, 38, 41, 45});
    expect(gotyeNoteTable().length, g.length + b.length + d.length);
  });

  test('save → reload keeps the semantic JSON', () {
    final s = buildGotyeIntroSong();
    final back = Song.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
    expect(_semantic(back), _semantic(s));
  });

  final out = Platform.environment['HUMTRACK_GOTYE_OUT'];
  test(
    'write song.json, mix, stems, MIDI, notes.csv',
    () async => _writeAll(Directory(out!)),
    skip: out == null || out.isEmpty ? 'set HUMTRACK_GOTYE_OUT to write the files' : false,
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

  final s = buildGotyeIntroSong();
  final plan = ArticulationPlan.of(s);
  final vol = Map.of(s.vol);
  await File('${outDir.path}/song.json').writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()), flush: true);

  final wav = await exportWavSong(
    s.sections,
    s.bpm,
    s.swing,
    vol,
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
    articulations: plan,
  );
  expect(wav.skippedVocals, 0);
  await File('${outDir.path}/humtrack-intro.mix.wav').writeAsBytes(await wav.file.readAsBytes(), flush: true);

  final stems = await exportStems(
    s.sections,
    s.bpm,
    s.swing,
    vol,
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
    articulations: plan,
  );
  const stemNames = {'melody': 'guitar', 'bass': 'bass', 'drums': 'drums', 'melodyDec': 'lead-empty'};
  for (final f in stems) {
    final label = f.path.split(RegExp(r'[\\/]')).last.replaceFirst('${s.title} - ', '').replaceFirst('.wav', '');
    await File('${outDir.path}/stem-${stemNames[label] ?? label}.wav').writeAsBytes(await f.readAsBytes(), flush: true);
  }

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
    articulations: plan,
  );
  final midBytes = await mid.readAsBytes();
  await File('${outDir.path}/humtrack-intro.export.mid').writeAsBytes(midBytes, flush: true);
  final ref = MidiReference.parse(midBytes);
  expect(ref.noteCount, 32 + 21 + 58);
  expect(ref.bpm.round(), gotyeBpm);

  final csv = StringBuffer('part,bar,slot16,note_or_kind,t_render_s,t_mp3_s,pitch_conf_measured,onset_conf_measured,dur_steps,velocity,dur_vel_source,sound_source,evidence\n');
  for (final r in gotyeNoteTable()) {
    csv.writeln(r.map((v) => v.toString().contains(',') ? '"$v"' : '$v').join(','));
  }
  await File('${outDir.path}/notes.csv').writeAsString(csv.toString(), flush: true);
}
