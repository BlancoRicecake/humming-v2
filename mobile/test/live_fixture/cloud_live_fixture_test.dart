// Live cloud fixtures (2026-11-04, Codex LIVE-FIXTURE-WORKORDER): two
// SYNTHETIC `.humtrack` files made by the real app exporter
// ([buildProjectBackup], the same call cloud backup uploads), and an offline
// check that runs the real importer on copies downloaded back from the
// service. No network, no credentials: the files go up and come back through
// Codex's own QA run; this only makes and checks bytes.
//
//  * always: make both fixtures in a temp folder and verify them as if they
//    had come back (the helper checks itself in CI).
//  * HUMTRACK_FIXTURE_OUT=<dir>: write notes-only.humtrack,
//    with-recordings.humtrack and manifest.json there.
//  * HUMTRACK_LIVE_DOWNLOADS=<dir> (+ HUMTRACK_FIXTURE_MANIFEST=<manifest>):
//    verify every fixture file found in <dir> with the real importer in an
//    isolated library that already holds another song.
//
// Each song is artificial QA content (generated tones), never a user song.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/state/project_backup.dart';

const _notesOnly = 'notes-only.humtrack';
const _withRecordings = 'with-recordings.humtrack';

/// A short generated tone (no microphone, no customer audio).
Uint8List _tone(double hz, {int ms = 600}) {
  const rate = 44100;
  final n = rate * ms ~/ 1000;
  return encodeWavMono16(
    Float32List.fromList([
      for (var i = 0; i < n; i++)
        .3 * math.sin(2 * math.pi * hz * i / rate) * math.min(1, (n - i) / 2000),
    ]),
    rate,
  );
}

/// Takes the synthetic song references: an FX'd clip with its dry original
/// and FX source, a legacy section take and a song-level take.
final _takes = <String, Uint8List Function()>{
  'qa_clip_wet.wav': () => _tone(440),
  'qa_clip_dry.wav': () => _tone(330),
  'qa_clip_src.wav': () => _tone(392),
  'qa_legacy.wav': () => _tone(262, ms: 400),
  'qa_song.wav': () => _tone(523, ms: 300),
};

PitchNote _n(int midi, int step, int dur, {int? velocity, double offset = 0}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  velocity: velocity,
  offsetSteps: offset,
);

/// Representative timing / velocity / metadata.
Song _qaSong() {
  final verse = Section(id: 'A', name: 'QA verse', bars: 2, repeats: 2)
    ..tracks['melody'] = TrackData(
      notes: [
        _n(69, 0, 4, velocity: 100),
        _n(71, 4, 2, velocity: 72),
        _n(72, 6, 2, velocity: 88, offset: .5),
        _n(76, 8, 8, velocity: 120),
        _n(74, 16, 3, velocity: 40),
        _n(72, 20, 4),
      ],
    )
    ..tracks['vocal'] = TrackData(
      clips: [
        VocalClip(
          path: 'qa_clip_wet.wav',
          origPath: 'qa_clip_dry.wav',
          fxSourcePath: 'qa_clip_src.wav',
          startStep: 4,
          gain: .8,
          trimStart: 12,
          fadeInMs: 15,
        ),
      ],
    );
  final chorus = Section(id: 'B', name: 'QA 후렴', bars: 1)
    ..tracks['melody'] = TrackData(notes: [_n(81, 0, 2, velocity: 127), _n(79, 2, 6, velocity: 1)])
    ..tracks['vocal'] = TrackData(vocalPath: 'qa_legacy.wav');
  return Song(
    id: 'ltqa20261104',
    title: 'HumTrack QA fixture (synthetic)',
    bpm: 104,
    bars: 2,
    key: 'A',
    scale: 'minor',
    sections: [verse, chorus],
  )..songVocalPath = 'qa_song.wav';
}

/// Song JSON without id / times, take names mapped through [names].
Object? _shape(Song s, Map<String, String> names) {
  final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>
    ..remove('id')
    ..remove('updatedAt')
    ..remove('createdAt');
  Object? walk(Object? n) => switch (n) {
    Map() => {
      for (final e in n.entries)
        e.key: e.value is String && names.containsKey(e.value) ? names[e.value] : walk(e.value),
    },
    List() => [for (final v in n) walk(v)],
    _ => n,
  };
  return walk(j);
}

String _sha(List<int> b) => sha256.convert(b).toString();

Future<void> _useRoot(Directory root) async {
  LoopStorage.rootOverride = root;
  await LoopStorage.ensureDirs();
  await LoopStorage.load();
}

Directory _vocals(Directory root) => Directory('${root.path}/looptap/vocals');

/// Make both fixtures with the real exporter; returns name → bytes and the
/// manifest (descriptors as the cloud API gets them + expectations).
Future<({Map<String, Uint8List> files, Map<String, dynamic> manifest})> _make(Directory work) async {
  await _useRoot(work);
  await _vocals(work).create(recursive: true);
  final recordings = <String, String>{};
  for (final e in _takes.entries) {
    final bytes = e.value();
    await File('${_vocals(work).path}/${e.key}').writeAsBytes(bytes, flush: true);
    recordings[e.key] = _sha(bytes);
  }
  final song = _qaSong();
  final files = <String, Uint8List>{};
  final entries = <Map<String, dynamic>>[];
  for (final (name, audio) in [(_notesOnly, false), (_withRecordings, true)]) {
    final built = await buildProjectBackup(song, includeAudio: audio);
    files[name] = built.bytes;
    entries.add({
      'file': name,
      'size': built.bytes.length,
      'sha256': _sha(built.bytes),
      // what CloudBackupApi.upload sends as the commit's meta
      'descriptor': {
        'format': 'humtrack',
        'formatVersion': kBackupFormatVersion,
        'audioIncluded': audio,
        'takes': built.takes,
        'missingTakes': built.missing,
        'songSchema': Song.kSchemaVersion,
      },
      'recordings': audio ? recordings : <String, String>{},
    });
  }
  final shape = _shape(song, const {});
  return (
    files: files,
    manifest: {
      'kind': 'humtrack-cloud-live-fixtures',
      'synthetic': true,
      'note': 'Artificial QA content (generated tones). Not a user song. No credentials.',
      'exporter': 'mobile/lib/looptap/state/project_backup.dart buildProjectBackup',
      'song': {
        'title': song.title,
        'bpm': song.bpm,
        'key': song.key,
        'scale': song.scale,
        'sections': song.sections.length,
        'notes': [for (final s in song.sections) s.tracks['melody']?.pitchNotes.length ?? 0].reduce((a, b) => a + b),
        'takes': _takes.length,
        'shapeSha256': _sha(utf8.encode(jsonEncode(shape))),
      },
      'shape': shape,
      'fixtures': entries,
    },
  );
}

/// Verify one downloaded fixture with the real importer in [library] (an
/// isolated folder that already holds another song). Returns a report line.
Future<Map<String, dynamic>> _verify(
  Uint8List bytes,
  Map<String, dynamic> entry,
  Map<String, dynamic> manifest,
  Directory library,
) async {
  final name = entry['file'] as String;
  expect(bytes.length, entry['size'], reason: '$name: size as uploaded');
  expect(_sha(bytes), entry['sha256'], reason: '$name: byte-identical to what was uploaded');

  // a library that already has a song with its own take, same id as the
  // fixture's source song and a take of the same name (nothing may be reused)
  await _useRoot(library);
  await _vocals(library).create(recursive: true);
  final keepTake = _tone(200);
  await File('${_vocals(library).path}/qa_clip_wet.wav').writeAsBytes(keepTake, flush: true);
  final store = LoopStore();
  final existing = Song(
    id: 'ltqa20261104',
    title: 'Existing local song',
    sections: [
      Section(id: 'X', name: 'X', bars: 1)
        ..tracks['melody'] = TrackData(notes: [_n(60, 0, 4, velocity: 90)])
        ..tracks['vocal'] = TrackData(clips: [VocalClip(path: 'qa_clip_wet.wav')]),
    ],
  );
  await store.upsert(existing);
  final existingShape = _shape(existing, const {});

  final res = await importProjectBackup(store, bytes);
  final imported = res.song;
  final descriptor = entry['descriptor'] as Map<String, dynamic>;
  expect(imported.id, isNot(existing.id), reason: '$name: a fresh song id');
  expect(store.songs.map((s) => s.id).toSet(), {existing.id, imported.id});
  expect(res.missing, descriptor['missingTakes'], reason: '$name: missing takes as described');

  // musical state: identical apart from id / time / the new take names
  final newNames = LoopStorage.audioNamesOf(imported);
  expect(newNames, hasLength(descriptor['takes']));
  final back = {for (final n in newNames) n: n.substring(n.indexOf('_') + 1)};
  expect(back.values.toSet(), _takes.keys.toSet());
  expect(jsonEncode(_shape(imported, back)), jsonEncode(manifest['shape']), reason: '$name: musical state');

  // recordings: byte for byte when included; none written when notes-only
  final recordings = (entry['recordings'] as Map).cast<String, String>();
  for (final e in back.entries) {
    final f = File('${_vocals(library).path}/${e.key}');
    if (descriptor['audioIncluded'] == true) {
      expect(_sha(await f.readAsBytes()), recordings[e.value], reason: '$name: ${e.value} bytes');
    } else {
      expect(f.existsSync(), isFalse, reason: '$name: notes only writes no recording');
    }
  }

  // the existing song and its take are untouched, also after a reload
  expect(_shape(store.songs.firstWhere((s) => s.id == existing.id), const {}), existingShape);
  expect(await File('${_vocals(library).path}/qa_clip_wet.wav').readAsBytes(), keepTake);
  final reloaded = await LoopStorage.load();
  expect(reloaded.map((s) => s.id).toSet(), {existing.id, imported.id});
  expect(jsonEncode(_shape(reloaded.firstWhere((s) => s.id == imported.id), back)), jsonEncode(manifest['shape']));

  return {
    'file': name,
    'sha256': entry['sha256'],
    'bytes_identical': true,
    'fresh_song_id': true,
    'musical_state_identical': true,
    'recordings_identical': descriptor['audioIncluded'] == true,
    'recordings_written': descriptor['audioIncluded'] == true ? newNames.length : 0,
    'existing_song_preserved': true,
  };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final temps = <Directory>[];
  Future<Directory> temp(String tag) async {
    final d = await Directory.systemTemp.createTemp('humtrack_live_$tag');
    temps.add(d);
    return d;
  }

  tearDown(() async {
    LoopStorage.rootOverride = null;
    for (final d in temps) {
      if (d.existsSync()) await d.delete(recursive: true);
    }
    temps.clear();
  });

  test('fixtures: made by the real exporter, they verify as if downloaded back', () async {
    final made = await _make(await temp('make_'));
    final fixtures = (made.manifest['fixtures'] as List).cast<Map<String, dynamic>>();
    expect(fixtures.map((f) => f['descriptor']['audioIncluded']), [false, true]);
    expect(fixtures.first['descriptor']['missingTakes'], _takes.length);
    expect(fixtures.last['descriptor']['missingTakes'], 0);
    for (final f in fixtures) {
      // JSON round trip, exactly what a reader of manifest.json gets
      final manifest = jsonDecode(jsonEncode(made.manifest)) as Map<String, dynamic>;
      await _verify(made.files[f['file']]!, f, manifest, await temp('lib_'));
    }
    // a changed byte is caught before anything is imported
    final bad = Uint8List.fromList(made.files[_withRecordings]!)..[200] ^= 1;
    await expectLater(
      _verify(bad, fixtures.last, made.manifest, await temp('bad_')),
      throwsA(isA<TestFailure>()),
    );
  });

  final out = Platform.environment['HUMTRACK_FIXTURE_OUT'];
  test('write the fixtures to HUMTRACK_FIXTURE_OUT', () async {
    final dir = Directory(out!)..createSync(recursive: true);
    final made = await _make(await temp('out_'));
    for (final e in made.files.entries) {
      File('${dir.path}/${e.key}').writeAsBytesSync(e.value, flush: true);
    }
    File('${dir.path}/manifest.json')
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(made.manifest), flush: true);
  }, skip: out == null ? 'set HUMTRACK_FIXTURE_OUT to write the fixtures' : false);

  final downloads = Platform.environment['HUMTRACK_LIVE_DOWNLOADS'];
  final manifestPath = Platform.environment['HUMTRACK_FIXTURE_MANIFEST'];
  test('verify downloaded copies in HUMTRACK_LIVE_DOWNLOADS with the real importer', () async {
    final manifest = jsonDecode(File(manifestPath!).readAsStringSync()) as Map<String, dynamic>;
    final report = <Map<String, dynamic>>[];
    for (final f in (manifest['fixtures'] as List).cast<Map<String, dynamic>>()) {
      final file = File('${downloads!}/${f['file']}');
      if (!file.existsSync()) continue;
      report.add(await _verify(file.readAsBytesSync(), f, manifest, await temp('lib_')));
    }
    expect(report, isNotEmpty, reason: 'no fixture file found in $downloads');
    File('$downloads/importer-verification.json').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'kind': 'humtrack-live-fixture-import-check',
        'checked_at': DateTime.now().toUtc().toIso8601String(),
        'offline': true,
        'results': report,
      }),
    );
  }, skip: downloads == null || manifestPath == null
      ? 'set HUMTRACK_LIVE_DOWNLOADS and HUMTRACK_FIXTURE_MANIFEST to check downloaded copies'
      : false);
}
