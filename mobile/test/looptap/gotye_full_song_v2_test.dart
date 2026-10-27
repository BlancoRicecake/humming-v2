// Full-song reconstruction v2 (gotye_full_song_v2.dart), built on the v1 helper.
//
// ALWAYS: 130 bars in 17 sections (8+2 fixed, then 15 × 8); bars 1–10 equal
// the fixed mallet v2 song (rebuilt and on disk) except the empty added lanes;
// every transcription note is in the song exactly once, no negative / out of
// section notes, velocities 1..127; vocal guides monophonic; save → reload.
// ONLY with HUMTRACK_FULLV2_OUT set: writes song.json, the exportWavSong mix,
// exportStems, the full exportMidiSong and one exportMidiSong per section
// (<= 8 bars, the app's MIDI import limit).
//
// Regenerate (from mobile/):
//   TMP=<out>/temp TEMP=<out>/temp HUMTRACK_FULLV2_OUT=<out>/render \
//     /c/src/flutter/bin/flutter test --no-pub test/looptap/gotye_full_song_v2_test.dart
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
import 'gotye_intro_mallet.dart';
import 'gotye_intro_repro.dart';

const String _malletSongJson = '../artifacts/gotye-reference-20261023/claude-mallet-v2/render/song.json';

Map<String, dynamic> _json(Object o) => jsonDecode(jsonEncode(o)) as Map<String, dynamic>;

Map<String, dynamic> _semantic(Song s) {
  final j = _json(s.toJson());
  j.remove('updatedAt');
  j.remove('createdAt');
  return j;
}

/// A section's JSON without the three added (empty) lanes.
Map<String, dynamic> _withoutAdded(Map<String, dynamic> sec) {
  final j = jsonDecode(jsonEncode(sec)) as Map<String, dynamic>;
  final ids = {for (final e in [...fullExtras, ...fullV2NewExtras]) e.id};
  (j['tracks'] as Map<String, dynamic>).removeWhere((k, _) => ids.contains(k));
  (j['extras'] as List<dynamic>).removeWhere((e) => ids.contains((e as Map<String, dynamic>)['id']));
  return j;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final tr = loadFullTranscription();
  final add = jsonDecode(File(v2AdditionsPath).readAsStringSync()) as Map<String, dynamic>;
  final dyn = jsonDecode(File(v2DynamicsPath).readAsStringSync()) as Map<String, dynamic>;
  Song build() => buildGotyeFullSongV2(additions: add, dynamics: dyn);

  test('130 bars in 17 sections, ≤ 8 bars each', () {
    final s = build();
    expect(s.sections.length, 17);
    expect(s.sections.fold<int>(0, (a, x) => a + x.bars * x.repeats), fullBars);
    expect(s.sections.every((x) => x.bars <= 8 && x.repeats == 1), isTrue);
    expect(s.bpm, gotyeBpm);
    for (final sec in s.sections) {
      expect(sec.extras.map((e) => e.id), [for (final e in [...fullExtras, ...fullV2NewExtras]) e.id]);
    }
  });

  test('bars 1–10 equal the fixed mallet v2 song (only empty added lanes)', () {
    final s = build();
    final ref = buildGotyeMalletSong();
    final disk = jsonDecode(File(_malletSongJson).readAsStringSync()) as Map<String, dynamic>;
    for (var i = 0; i < 2; i++) {
      final mine = _withoutAdded(_json(s.sections[i].toJson()));
      expect(mine, _json(ref.sections[i].toJson()), reason: 'section $i vs rebuilt v2');
      expect(mine, (disk['sections'] as List<dynamic>)[i], reason: 'section $i vs v2 song.json on disk');
      for (final e in [...fullExtras, ...fullV2NewExtras]) {
        expect(s.sections[i].tracks[e.id]!.pitchNotes, isEmpty);
      }
    }
    for (final t in ['melody', 'melodyDec', 'bass', 'drums']) {
      expect(s.instruments[t], ref.instruments[t], reason: t);
      expect(s.vol[t], ref.vol[t], reason: t);
    }
    expect(s.vol['melody'], 0.44);
    expect(s.vol['melodyDec'], 0.45);
    expect(s.vol['bass'], 0.75);
    expect(s.vol['drums'], 1.0);
    final pad = [for (final sec in s.sections) ...sec.tracks[padId]!.pitchNotes];
    expect(pad, isNotEmpty);
    expect(pad.every((n) => n.muted), isTrue, reason: 'optional pad candidates stay muted (no WAV/MIDI output)');
    expect(s.bpm, ref.bpm);
    expect(s.swing, ref.swing);
  });

  test('every transcription note lands once, inside its section, valid values', () {
    final s = build();
    final tracks = tr['tracks'] as Map<String, dynamic>;
    final want = tracks.values.fold<int>(0, (a, l) => a + (l as List<dynamic>).length) +
        (add['counter'] as List<dynamic>).length +
        (add['sustain'] as List<dynamic>).length;
    var got = 0;
    for (final sec in s.sections.skip(2)) {
      for (final t in sec.tracks.values) {
        for (final n in t.pitchNotes) {
          expect(n.step, greaterThanOrEqualTo(0));
          expect(n.dur, greaterThanOrEqualTo(1));
          expect(n.step + n.dur, lessThanOrEqualTo(sec.bars * 16));
          expect(n.startSteps, greaterThanOrEqualTo(0));
          expect(n.endSteps, lessThanOrEqualTo(sec.bars * 16 + 1e-9));
          expect(n.velocity, inInclusiveRange(1, 127));
          expect(n.midi, inInclusiveRange(21, 108));
        }
        for (final d in t.drumNotes) {
          expect(d.step, inInclusiveRange(0, sec.bars * 16 - 1));
          expect(d.velocity, inInclusiveRange(1, 127));
        }
        got += t.pitchNotes.length + t.drumNotes.length;
      }
      for (final id in [voxMaleId, voxFemaleId, counterId]) {
        final ns = [...sec.tracks[id]!.pitchNotes]..sort((a, b) => a.startSteps.compareTo(b.startSteps));
        for (var i = 0; i + 1 < ns.length; i++) {
          expect(ns[i].endSteps, lessThanOrEqualTo(ns[i + 1].startSteps + 1e-6), reason: '$id ${sec.id}');
        }
      }
    }
    expect(got, want);
  });

  test('save → reload keeps the semantic JSON', () {
    final s = build();
    expect(_semantic(Song.fromJson(_json(s.toJson()))), _semantic(s));
  });

  final out = Platform.environment['HUMTRACK_FULLV2_OUT'];
  test(
    'write song.json, mix, stems, full MIDI and section MIDI',
    () async => _writeAll(Directory(out!), build()),
    skip: out == null || out.isEmpty ? 'set HUMTRACK_FULLV2_OUT to write the files' : false,
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
  final plan = ArticulationPlan.of(s);
  final vol = Map.of(s.vol);
  final common = (
    melodyProgram: s.instruments['melody'] ?? 0,
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
  );

  final wav = await exportWavSong(
    s.sections,
    s.bpm,
    s.swing,
    vol,
    s.title,
    melodyProgram: common.melodyProgram,
    bassProgram: common.bassProgram,
    melodyDecProgram: common.melodyDecProgram,
    drumProgram: common.drumProgram,
    extras: [...fullExtras, ...fullV2NewExtras],
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: plan,
  );
  expect(wav.skippedVocals, 0);
  await File('${outDir.path}/humtrack-full.mix.wav').writeAsBytes(await wav.file.readAsBytes(), flush: true);

  final stems = await exportStems(
    s.sections,
    s.bpm,
    s.swing,
    vol,
    s.title,
    melodyProgram: common.melodyProgram,
    bassProgram: common.bassProgram,
    melodyDecProgram: common.melodyDecProgram,
    drumProgram: common.drumProgram,
    extras: [...fullExtras, ...fullV2NewExtras],
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: plan,
  );
  final names = <String>[];
  for (final f in stems) {
    final label = f.path.split(RegExp(r'[\\/]')).last.replaceFirst('${s.title} - ', '').replaceFirst('.wav', '');
    names.add(label);
    await File('${outDir.path}/stem-app-$label.wav').writeAsBytes(await f.readAsBytes(), flush: true);
  }
  await File('${outDir.path}/stem-app-labels.json').writeAsString(jsonEncode(names), flush: true);

  Future<List<int>> mid(List<Section> secs) async => (await exportMidiSong(
        secs,
        s.bpm,
        s.title,
        melodyProgram: common.melodyProgram,
        bassProgram: common.bassProgram,
        melodyDecProgram: common.melodyDecProgram,
        drumProgram: common.drumProgram,
        extras: [...fullExtras, ...fullV2NewExtras],
        instruments: Map.of(s.instruments),
        fallbackName: s.id,
        variationSeed: s.effectiveVariationSeed,
        groove: s.grooveContext,
        pan: s.pan,
        articulations: ArticulationPlan.build(sections: secs, instruments: Map.of(s.instruments)),
      ))
          .readAsBytes();
  final full = await mid(s.sections);
  await File('${outDir.path}/humtrack-full.export.mid').writeAsBytes(full, flush: true);
  final ref = MidiReference.parse(Uint8List.fromList(full));
  expect(ref.bpm.round(), gotyeBpm);
  expect(ref.bars, fullBars);
  final secDir = await Directory('${outDir.path}/sections').create(recursive: true);
  var bar = 1;
  for (final (i, sec) in s.sections.indexed) {
    final bytes = await mid([sec]);
    final name = '${(i + 1).toString().padLeft(2, '0')}-bars$bar-${bar + sec.bars - 1}.mid';
    await File('${secDir.path}/$name').writeAsBytes(bytes, flush: true);
    final r = MidiReference.parse(Uint8List.fromList(bytes));
    expect(r.bars, sec.bars, reason: name);
    bar += sec.bars;
  }
}
