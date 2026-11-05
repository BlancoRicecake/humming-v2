// Storage audit 2026-10-30: `.humtrack` project backups, on real files in
// isolated folders. A song with every kind of take reference (section clip
// with original + FX source, legacy section take, song-level take) is backed
// up on "device A" and imported on an empty "device B": the song and every
// take come back byte for byte under a new id and new take names, and survive
// a reload. Importing next to the original never overwrites it. Refused files
// (not a backup, path escape, extra entries, newer versions, missing or
// altered audio) and a failed save change nothing.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/export_library.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/state/project_backup.dart';

Uint8List _wav(int seed) => encodeWavMono16(
  Float32List.fromList([for (var i = 0; i < 400; i++) ((i * seed) % 97) / 200]),
  44100,
);

Song _song() {
  final a = Section(id: 'A', name: 'Verse', bars: 1, repeats: 2)
    ..tracks['melody'] = TrackData(
      notes: [PitchNote(midi: 64, freq: midiToFreq(64), step: 0, dur: 4)],
    )
    ..tracks['vocal'] = TrackData(
      clips: [
        VocalClip(
          path: 'take_fx.wav',
          origPath: 'take_dry.wav',
          fxSourcePath: 'take_src.wav',
          startStep: 4,
          gain: .7,
          trimStart: 10,
          fadeInMs: 20,
        ),
      ],
    );
  final b = Section(id: 'B', name: '후렴', bars: 1)
    ..tracks['vocal'] = TrackData(vocalPath: 'legacy.wav');
  return Song(
    id: 'lt1000',
    title: '봄날의 허밍',
    bpm: 96,
    bars: 1,
    key: 'D',
    scale: 'dorian',
    sections: [a, b],
  )..songVocalPath = 'song_take.wav';
}

const _takes = {
  'take_fx.wav': 1,
  'take_dry.wav': 2,
  'take_src.wav': 3,
  'legacy.wav': 4,
  'song_take.wav': 5,
};

/// Song JSON with ids, times and take names normalised (via [names]).
Object? _shape(Song s, Map<String, String> names) {
  final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
  j.remove('id');
  j.remove('updatedAt');
  j.remove('createdAt');
  Object? walk(Object? n) => switch (n) {
    Map() => {
      for (final e in n.entries)
        e.key: e.value is String && names.containsKey(e.value)
            ? names[e.value]
            : walk(e.value),
    },
    List() => [for (final v in n) walk(v)],
    _ => n,
  };
  return walk(j);
}

Uint8List _zip(Map<String, List<int>> files, {Map<String, dynamic>? manifest}) {
  final archive = Archive();
  if (manifest != null) {
    final m = utf8.encode(jsonEncode(manifest));
    archive.addFile(ArchiveFile.noCompress('manifest.json', m.length, m));
  }
  for (final e in files.entries) {
    archive.addFile(ArchiveFile.noCompress(e.key, e.value.length, e.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

int _indexOf(List<int> hay, List<int> needle, int from) {
  outer:
  for (var i = from; i <= hay.length - needle.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (hay[i + k] != needle[k]) continue outer;
    }
    return i;
  }
  return -1;
}

int _lastIndexOf(List<int> hay, List<int> needle) {
  var last = -1, p = 0;
  while ((p = _indexOf(hay, needle, p)) >= 0) {
    last = p;
    p++;
  }
  return last;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory deviceA, deviceB;

  Future<void> use(Directory root) async {
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    await LoopStorage.load(); // warm the vocal path cache for this root
  }

  Directory vocalsOf(Directory root) => Directory('${root.path}/looptap/vocals');

  setUp(() async {
    deviceA = await Directory.systemTemp.createTemp('humtrack_backup_a_');
    deviceB = await Directory.systemTemp.createTemp('humtrack_backup_b_');
    await use(deviceA);
    await vocalsOf(deviceA).create(recursive: true);
    for (final e in _takes.entries) {
      await File('${vocalsOf(deviceA).path}/${e.key}').writeAsBytes(_wav(e.value));
    }
  });
  tearDown(() async {
    LoopStorage.rootOverride = null;
    await deviceA.delete(recursive: true);
    await deviceB.delete(recursive: true);
  });

  test('backup with vocals -> another device -> identical song and takes, after reload too', () async {
    final storeA = LoopStore();
    final original = _song();
    await storeA.upsert(original);
    final made = await createProjectBackup(original);
    expect(made.missing, 0);
    expect(made.file.path, endsWith('봄날의 허밍.humtrack'));
    final bytes = await made.file.readAsBytes();
    expect(bytes.sublist(0, 4), [0x50, 0x4B, 0x03, 0x04], reason: 'a ZIP');
    final listed = await listExportedFiles(
      directory: Directory('${deviceA.path}/looptap/exports'),
    );
    expect(listed.single.name, '봄날의 허밍.humtrack');
    expect(listed.single.mimeType, 'application/octet-stream');

    // device B: empty library
    await use(deviceB);
    final storeB = LoopStore();
    final result = await importProjectBackup(storeB, bytes);
    final imported = result.song;
    expect(result.missing, 0);
    expect(imported.id, isNot(original.id));
    expect(storeB.songs.single.id, imported.id);
    final newNames = LoopStorage.audioNamesOf(imported);
    expect(newNames, hasLength(_takes.length));
    final back = <String, String>{};
    for (final n in newNames) {
      final orig = n.substring(n.indexOf('_') + 1);
      expect(_takes.keys, contains(orig));
      back[n] = orig;
      expect(
        await File('${vocalsOf(deviceB).path}/$n').readAsBytes(),
        _wav(_takes[orig]!),
        reason: '$orig byte for byte',
      );
    }
    expect(_shape(imported, back), _shape(original, const {}));

    // close + reload from disk
    final reloaded = await LoopStorage.load();
    expect(LoopStorage.lastIssue, LoadIssue.none);
    expect(_shape(reloaded.single, back), _shape(original, const {}));
    // the import's takes are referenced: a cleanup keeps every one
    await LoopStorage.sweepVocals(reloaded);
    for (final n in newNames) {
      expect(File('${vocalsOf(deviceB).path}/$n').existsSync(), isTrue);
    }
  });

  test('importing next to the original adds a song and overwrites nothing', () async {
    final store = LoopStore();
    final original = _song();
    await store.upsert(original);
    final bytes = await (await createProjectBackup(original)).file.readAsBytes();
    final before = {
      for (final f in vocalsOf(deviceA).listSync().whereType<File>())
        f.path: sha256.convert(f.readAsBytesSync()).toString(),
    };
    final imported = (await importProjectBackup(store, bytes)).song;
    expect(store.songs.map((s) => s.id).toSet(), {original.id, imported.id});
    expect(
      _shape(store.songs.firstWhere((s) => s.id == original.id), const {}),
      _shape(original, const {}),
    );
    for (final e in before.entries) {
      expect(sha256.convert(File(e.key).readAsBytesSync()).toString(), e.value);
    }
    expect(
      LoopStorage.audioNamesOf(imported).intersection(LoopStorage.audioNamesOf(original)),
      isEmpty,
    );
  });

  test('a take already missing at backup time is recorded and imports as missing', () async {
    final song = _song();
    await File('${vocalsOf(deviceA).path}/legacy.wav').delete();
    final made = await createProjectBackup(song);
    expect(made.missing, 1);
    final contents = decodeProjectBackup(await made.file.readAsBytes());
    expect(contents.missing, {'legacy.wav'});
    expect(contents.audio.keys, isNot(contains('legacy.wav')));
  });

  group('refused files change nothing', () {
    late Uint8List good;
    late Map<String, dynamic> manifest;
    late Map<String, List<int>> entries;

    setUp(() async {
      good = await (await createProjectBackup(_song())).file.readAsBytes();
      final archive = ZipDecoder().decodeBytes(good);
      manifest =
          jsonDecode(utf8.decode(archive.findFile('manifest.json')!.content))
              as Map<String, dynamic>;
      entries = {
        for (final f in archive.files)
          if (f.isFile && f.name != 'manifest.json') f.name: f.content,
      };
      await use(deviceB);
    });

    Future<void> refused(Uint8List bytes, BackupProblem problem) async {
      final store = LoopStore();
      final songsBefore = store.songs.length;
      await expectLater(
        importProjectBackup(store, bytes),
        throwsA(isA<ProjectBackupException>().having((e) => e.problem, 'problem', problem)),
      );
      expect(store.songs.length, songsBefore);
      final vocals = vocalsOf(deviceB);
      expect(
        vocals.existsSync() ? vocals.listSync() : const [],
        isEmpty,
        reason: 'no take written',
      );
      expect(File('${deviceB.path}/looptap/songs.json').existsSync(), isFalse);
    }

    test('not a ZIP / not a backup', () async {
      await refused(Uint8List.fromList(utf8.encode('hello')), BackupProblem.notBackup);
      await refused(_zip({'song.json': utf8.encode('{}')}), BackupProblem.notBackup);
      await refused(
        _zip(entries, manifest: {...manifest, 'format': 'something-else'}),
        BackupProblem.notBackup,
      );
    });

    test('path escape, links, folders and extra files', () async {
      for (final bad in [
        '../evil.wav',
        '/abs.wav',
        'audio/../../evil.wav',
        r'audio\evil.wav',
        'audio/sub/x.wav',
        'C:/evil.wav',
        'readme.txt',
        'audio/CON.wav',
      ]) {
        await refused(
          _zip({...entries, bad: [1, 2, 3]}, manifest: manifest),
          BackupProblem.unsafeEntry,
        );
      }
    });

    test('a newer format or song schema', () async {
      await refused(
        _zip(entries, manifest: {...manifest, 'formatVersion': kBackupFormatVersion + 1}),
        BackupProblem.newerVersion,
      );
      await refused(
        _zip(entries, manifest: {...manifest, 'songSchema': Song.kSchemaVersion + 1}),
        BackupProblem.newerVersion,
      );
    });

    test('missing or altered audio', () async {
      final noTake = Map.of(entries)..remove('audio/take_dry.wav');
      await refused(_zip(noTake, manifest: manifest), BackupProblem.missingAudio);
      // the song needs a take the manifest doesn't list
      final files = (manifest['files'] as List)
          .where((f) => (f as Map)['name'] != 'song_take.wav')
          .toList();
      await refused(
        _zip(Map.of(entries)..remove('audio/song_take.wav'), manifest: {...manifest, 'files': files}),
        BackupProblem.missingAudio,
      );
      final flipped = [...entries['audio/take_fx.wav']!];
      flipped[flipped.length - 1] ^= 1; // same size, one bit changed
      final altered = Map.of(entries)..['audio/take_fx.wav'] = flipped;
      await refused(_zip(altered, manifest: manifest), BackupProblem.damaged);
    });
  });

  // ── Codex backup review B1/B2/B4 ──────────────────────────────────────
  test('B1: a take missing at backup never binds to a same-named file here', () async {
    await File('${vocalsOf(deviceA).path}/legacy.wav').delete();
    final bytes = await (await createProjectBackup(_song())).file.readAsBytes();
    await use(deviceB);
    // someone else's recording that happens to share the name
    await vocalsOf(deviceB).create(recursive: true);
    final stranger = File('${vocalsOf(deviceB).path}/legacy.wav')
      ..writeAsBytesSync(_wav(42));
    final res = await importProjectBackup(LoopStore(), bytes);
    expect(res.missing, 1);
    final b = res.song.sections[1].tracks['vocal']!;
    expect(b.vocalPath, isNot('legacy.wav'));
    expect(b.vocalPath, startsWith('imp'));
    expect(File('${vocalsOf(deviceB).path}/${b.vocalPath}').existsSync(), isFalse,
        reason: 'a fresh name with no file: silent, not the stranger');
    expect(stranger.readAsBytesSync(), _wav(42));
  });

  test('B2: 200-character names with an existing file finish, keep prefix and extension', () async {
    final long = '${'a' * 196}.wav';
    expect(isSafeAudioName(long), isTrue);
    final song = Song(id: 'lt7', title: 'Long')..songVocalPath = long;
    await File('${vocalsOf(deviceA).path}/$long').writeAsBytes(_wav(9));
    final bytes = await (await createProjectBackup(song)).file.readAsBytes();
    final store = LoopStore();
    final names = <String>{};
    for (var i = 0; i < 3; i++) {
      final res = await importProjectBackup(store, bytes)
          .timeout(const Duration(seconds: 10));
      final n = res.song.songVocalPath!;
      expect(n.length, lessThanOrEqualTo(200));
      expect(n, startsWith('imp'));
      expect(n, endsWith('.wav'));
      expect(isSafeAudioName(n), isTrue);
      names.add(n.toLowerCase());
    }
    expect(names, hasLength(3));
    expect(store.songs.map((s) => s.id).toSet(), hasLength(3), reason: 'distinct ids');
    expect(File('${vocalsOf(deviceA).path}/$long').readAsBytesSync(), _wav(9));
  });

  group('B4: the raw ZIP is judged before anything is extracted', () {
    late Uint8List good;
    setUp(() async {
      good = await (await createProjectBackup(_song())).file.readAsBytes();
    });

    test('our backups are stored zips (no compression) with valid CRCs', () {
      final c = decodeProjectBackup(good);
      expect(c.audio, hasLength(_takes.length));
      // every central-directory entry: method 0
      var p = 0;
      var entries = 0;
      while ((p = _indexOf(good, [0x50, 0x4B, 0x01, 0x02], p)) >= 0) {
        expect(good[p + 10] | good[p + 11] << 8, 0, reason: 'stored');
        entries++;
        p += 4;
      }
      expect(entries, _takes.length + 2);
    });

    Future<void> refusedRaw(Uint8List bytes, BackupProblem problem) async {
      expect(
        () => decodeProjectBackup(bytes),
        throwsA(isA<ProjectBackupException>().having((e) => e.problem, 'problem', problem)),
      );
    }

    test('a duplicate entry (same name twice, or differing only in case)', () async {
      final a = ZipDecoder().decodeBytes(good);
      final m = a.findFile('manifest.json')!.content;
      final s = a.findFile('song.json')!.content;
      Uint8List twice(String second) {
        final z = Archive()
          ..addFile(ArchiveFile.noCompress('manifest.json', m.length, m))
          ..addFile(ArchiveFile.noCompress('song.json', s.length, s));
        for (final f in a.files.where((f) => f.name.startsWith('audio/'))) {
          z.addFile(ArchiveFile.noCompress(f.name, f.content.length, f.content));
        }
        z.addFile(ArchiveFile.noCompress(second, s.length, s));
        return ZipEncoder().encodeBytes(z);
      }

      // the library merges same-name entries when encoding too: patch the
      // raw bytes so two central entries really share a name
      final dup = twice('song.jsoN');
      await refusedRaw(dup, BackupProblem.unsafeEntry);
      final exact = Uint8List.fromList(dup);
      final i = _lastIndexOf(exact, utf8.encode('song.jsoN'));
      exact[i + 8] = 0x6E; // central name -> 'song.json'
      final j = _indexOf(exact, utf8.encode('song.jsoN'), 0);
      exact[j + 8] = 0x6E; // local name too
      await refusedRaw(exact, BackupProblem.unsafeEntry);
    });

    test('a compressed (deflate) entry is refused before inflating', () async {
      final a = ZipDecoder().decodeBytes(good);
      final z = Archive();
      for (final f in a.files) {
        z.addFile(ArchiveFile.bytes(f.name, f.content)); // deflate
      }
      await refusedRaw(ZipEncoder().encodeBytes(z), BackupProblem.unsafeEntry);
    });

    test('a CRC that does not match the data', () async {
      final bad = Uint8List.fromList(good);
      final p = _indexOf(bad, [0x50, 0x4B, 0x01, 0x02], 0);
      bad[p + 16] ^= 0xFF; // first central entry's CRC
      await refusedRaw(bad, BackupProblem.damaged);
    });

    test('a symlink entry', () async {
      final bad = Uint8List.fromList(good);
      final p = _indexOf(bad, [0x50, 0x4B, 0x01, 0x02], 0);
      bad[p + 5] = 3; // version made by: unix
      // external attributes (p+38..41, little endian): high 16 bits = mode
      bad[p + 40] = 0xFF;
      bad[p + 41] = 0xA1; // 0xA1FF = S_IFLNK | 0777
      await refusedRaw(bad, BackupProblem.unsafeEntry);
    });

    test('not a zip at all / truncated', () async {
      await refusedRaw(Uint8List.fromList(utf8.encode('hello')), BackupProblem.notBackup);
      await refusedRaw(Uint8List.sublistView(good, 0, good.length - 30), BackupProblem.notBackup);
    });
  });

  test('a failed save removes the written takes and keeps the library', () async {
    final store = LoopStore();
    final keep = Song(id: 'keep', title: 'Keep');
    await store.upsert(keep);
    final bytes = await (await createProjectBackup(_song())).file.readAsBytes();
    final songsJson = File('${deviceA.path}/looptap/songs.json');
    final before = await songsJson.readAsString();
    final names = vocalsOf(deviceA).listSync().map((f) => f.path).toSet();
    // the atomic save writes songs.json.tmp first: a folder there fails it
    final block = Directory('${songsJson.path}.tmp')..createSync();
    await expectLater(importProjectBackup(store, bytes), throwsA(isA<FileSystemException>()));
    block.deleteSync();
    expect(store.songs.map((s) => s.id), ['keep']);
    expect(await songsJson.readAsString(), before);
    expect(vocalsOf(deviceA).listSync().map((f) => f.path).toSet(), names);
  });
}
