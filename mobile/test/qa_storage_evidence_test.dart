// QA-only (storage audit 2026-10-30, post-fix): writes real files for an
// independent check (check-evidence.py, Python stdlib only) into a NEW folder
// given by QA_EVIDENCE_DIR (inside the repo); skipped in normal test runs.
// Produces: a .humtrack with vocals and its import on an empty "device",
// B1/B2 imports, refused files, equal-length stems (melody + vocal, song
// vocal at 0.25), and a damaged take that must not become a .wav.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/state/project_backup.dart';
import 'package:path/path.dart' as p;

final _dir = Platform.environment['QA_EVIDENCE_DIR'];

Uint8List _tone(double seconds, {double amp = .5}) {
  final n = (seconds * 44100).round();
  return encodeWavMono16(
    Float32List.fromList([
      for (var i = 0; i < n; i++) amp * math.sin(2 * math.pi * 440 * i / 44100),
    ]),
    44100,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('write storage evidence', () async {
    final out = Directory(p.normalize(p.absolute(_dir!)));
    if (!p.isWithin(r'C:\src\humming-v2', out.path)) {
      throw StateError('evidence must stay in the repo');
    }
    final report = <String, Object?>{};
    Future<void> use(String name) async {
      final root = Directory(p.join(out.path, name));
      await root.create(recursive: true);
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
      await LoopStorage.load();
      await Directory(p.join(root.path, 'looptap', 'vocals')).create(recursive: true);
    }

    String vocals() => p.join(LoopStorage.rootOverride!.path, 'looptap', 'vocals');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (m) {
      final f = File(utf8.decode(m!.buffer.asUint8List(m.offsetInBytes, m.lengthInBytes)));
      return SynchronousFuture(f.existsSync() ? ByteData.sublistView(f.readAsBytesSync()) : null);
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => p.join(out.path, 'support'),
    );

    // ── 1. backup with vocals on device A, import on empty device B ──────
    await use('device-a');
    for (final (n, s) in [('fx.wav', 1.0), ('dry.wav', .8), ('song.wav', 2.0), ('legacy.wav', .5)]) {
      await File(p.join(vocals(), n)).writeAsBytes(_tone(s));
    }
    final song = Song(
      id: 'lt1',
      title: '백업 확인',
      bpm: 120,
      bars: 1,
      sections: [
        Section(id: 'A', name: 'A', bars: 1, repeats: 2)
          ..tracks['melody'] = TrackData(notes: [PitchNote(midi: 60, freq: midiToFreq(60), step: 0, dur: 4)])
          ..tracks['vocal'] = TrackData(clips: [VocalClip(path: 'fx.wav', origPath: 'dry.wav', startStep: 4)]),
        Section(id: 'B', name: 'B', bars: 1)..tracks['vocal'] = TrackData(vocalPath: 'legacy.wav'),
      ],
    )..songVocalPath = 'song.wav';
    final storeA = LoopStore();
    await storeA.upsert(song);
    final made = await createProjectBackup(song);
    final backupBytes = await made.file.readAsBytes();
    await use('device-b');
    final storeB = LoopStore();
    final imported = await importProjectBackup(storeB, backupBytes);
    report['backup'] = {
      'file': made.file.path,
      'missingAtBackup': made.missing,
      'importedId': imported.song.id,
      'importedTakes': LoopStorage.audioNamesOf(imported.song).toList()..sort(),
      'deviceBVocals': p.join(out.path, 'device-b', 'looptap', 'vocals'),
      'deviceBSongs': p.join(out.path, 'device-b', 'looptap', 'songs.json'),
      'sourceTakes': {'fx.wav': 1.0, 'dry.wav': .8, 'song.wav': 2.0, 'legacy.wav': .5},
    };

    // ── 2. B1: a missing take never binds to a same-named file ───────────
    await use('b1-source');
    await File(p.join(vocals(), 'song.wav')).writeAsBytes(_tone(1));
    final b1 = Song(id: 'lt2', title: 'B1')..songVocalPath = 'missing.wav';
    final b1Bytes = await (await createProjectBackup(b1)).file.readAsBytes();
    await use('b1-target');
    await File(p.join(vocals(), 'missing.wav')).writeAsBytes(_tone(.3, amp: .9));
    final b1Res = await importProjectBackup(LoopStore(), b1Bytes);
    report['b1'] = {
      'missingReported': b1Res.missing,
      'newReference': b1Res.song.songVocalPath,
      'newReferenceFileExists': File(p.join(vocals(), b1Res.song.songVocalPath!)).existsSync(),
      'strangerUntouched': p.join(vocals(), 'missing.wav'),
    };

    // ── 3. B2: 200-char names with an existing same-named file ───────────
    await use('b2');
    final long = '${'a' * 196}.wav';
    await File(p.join(vocals(), long)).writeAsBytes(_tone(.2));
    final b2 = Song(id: 'lt3', title: 'B2')..songVocalPath = long;
    final b2Bytes = await (await createProjectBackup(b2)).file.readAsBytes();
    final sw = Stopwatch()..start();
    final storeB2 = LoopStore();
    final names = <String>[];
    for (var i = 0; i < 3; i++) {
      names.add((await importProjectBackup(storeB2, b2Bytes).timeout(const Duration(seconds: 10))).song.songVocalPath!);
    }
    report['b2'] = {'ms': sw.elapsedMilliseconds, 'names': names, 'ids': storeB2.songs.map((s) => s.id).toList()};

    // ── 4. refused files: write nothing ─────────────────────────────────
    await use('refused');
    final refused = <String, String>{};
    Future<void> refuse(String label, List<int> bytes) async {
      try {
        await importProjectBackup(LoopStore(), Uint8List.fromList(bytes));
        refused[label] = 'ACCEPTED';
      } on ProjectBackupException catch (e) {
        refused[label] = e.problem.name;
      }
    }

    await refuse('not-zip', utf8.encode('hello'));
    final crc = Uint8List.fromList(backupBytes);
    final cd = _indexOf(crc, [0x50, 0x4B, 0x01, 0x02]);
    crc[cd + 16] ^= 0xFF;
    await refuse('crc-mismatch', crc);
    await refuse('truncated', backupBytes.sublist(0, backupBytes.length - 30));
    report['refused'] = refused;
    report['refusedWroteNothing'] = Directory(vocals()).listSync().isEmpty &&
        !File(p.join(out.path, 'refused', 'looptap', 'songs.json')).existsSync();

    // ── 5. stems: same start/end, placement, song vocal level ────────────
    await use('stems');
    await File(p.join(vocals(), 'b.wav')).writeAsBytes(_tone(1));
    await File(p.join(vocals(), 'song.wav')).writeAsBytes(_tone(3));
    List<Section> arr() => [
      Section(id: 'A', name: 'A', bars: 1, repeats: 2)
        ..tracks['melody'] = TrackData(notes: [PitchNote(midi: 60, freq: midiToFreq(60), step: 0, dur: 4)]),
      Section(id: 'B', name: 'B', bars: 1, repeats: 3)..tracks['vocal'] = TrackData(clips: [VocalClip(path: 'b.wav')]),
    ];
    final stems = await exportStems(arr(), 120, 0, const {'vocal': 1.0, 'melody': .85}, 'Stems');
    final full = await exportStems(arr(), 120, 0, const {'vocal': 1.0, 'melody': 0}, 'SongVocal full', songVocalPath: 'song.wav');
    final quarter = await exportStems(arr(), 120, 0, const {'vocal': .25, 'melody': 0}, 'SongVocal quarter', songVocalPath: 'song.wav');
    report['stems'] = {
      'sectionStems': [for (final f in stems) f.path],
      'songVocalFull': full.single.path,
      'songVocalQuarter': quarter.single.path,
      'songSeconds': 10,
      'tailSeconds': 1.2,
      'vocalRepeatsAt': [4, 6, 8],
    };

    // ── 6. a damaged take is skipped, not written as .wav ────────────────
    await use('damaged');
    await File(p.join(vocals(), 'broken.wav')).writeAsBytes([1, 2, 3, 4]);
    var skipped = 0;
    final broken = await exportStems(arr(), 120, 0, const {'vocal': 1.0, 'melody': 0}, 'Broken',
        songVocalPath: 'broken.wav', onVocalsSkipped: (n) => skipped = n);
    report['damaged'] = {
      'outputs': [for (final f in broken) f.path],
      'skippedReported': skipped,
      'exportsFolder': p.join(out.path, 'damaged', 'looptap', 'exports'),
    };

    LoopStorage.rootOverride = null;
    await File(p.join(out.path, 'evidence.json'))
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }, skip: _dir == null ? 'set QA_EVIDENCE_DIR to write evidence' : false);
}

int _indexOf(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i <= hay.length - needle.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (hay[i + k] != needle[k]) continue outer;
    }
    return i;
  }
  return -1;
}
