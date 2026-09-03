// loop_storage — durability of songs.json (audit C1/C30/C33): atomic
// tmp→rename saves with a .bak of the previous file, recovery from .bak when
// the main file is unreadable (the bad file is preserved, never discarded),
// per-song skip on a partially corrupt list, legacy bare-list reads, and the
// once-per-install seed marker. Pure dart:io on a temp dir (no path_provider).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/state/loop_storage.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt_storage_');
    LoopStorage.rootOverride = root;
  });

  tearDown(() async {
    LoopStorage.rootOverride = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  File songsFile() => File('${root.path}/looptap/songs.json');
  File bakFile() => File('${root.path}/looptap/songs.json.bak');
  File tmpFile() => File('${root.path}/looptap/songs.json.tmp');
  Song song(String id, [String title = 't']) => Song(id: id, title: title);

  test('save writes a v2 envelope atomically (no tmp left) and keeps a .bak', () async {
    await LoopStorage.save([song('a')]);
    expect(await songsFile().exists(), isTrue);
    expect(await tmpFile().exists(), isFalse);
    expect(await bakFile().exists(), isFalse); // nothing to back up yet
    final j = jsonDecode(await songsFile().readAsString()) as Map;
    expect(j['v'], Song.kSchemaVersion);
    expect((j['songs'] as List).length, 1);

    await LoopStorage.save([song('a'), song('b')]);
    expect(await tmpFile().exists(), isFalse);
    expect(await bakFile().exists(), isTrue);
    // .bak is the PREVIOUS good file, songs.json the new one
    expect(((jsonDecode(await bakFile().readAsString()) as Map)['songs'] as List).length, 1);
    final loaded = await LoopStorage.load();
    expect(loaded.map((s) => s.id), ['a', 'b']);
    expect(LoopStorage.loadFailed, isFalse);
  });

  test('corrupt songs.json is preserved and the library recovers from .bak', () async {
    await LoopStorage.save([song('a')]);
    await LoopStorage.save([song('a'), song('b')]); // creates .bak = [a]
    await songsFile().writeAsString('{not json');
    final loaded = await LoopStorage.load();
    expect(loaded.map((s) => s.id), ['a']); // recovered from the backup
    expect(LoopStorage.loadFailed, isFalse);
    // the bad file was kept, not deleted
    final kept = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.contains('songs.json.corrupt-'))
        .toList();
    expect(kept.length, 1);
    expect(await kept.first.readAsString(), '{not json');
    // the main file is gone (renamed) — a later save must not trip on that
    await LoopStorage.save(loaded);
    expect((await LoopStorage.load()).map((s) => s.id), ['a']);
  });

  test('corrupt songs.json with no backup → loadFailed, empty list, file kept', () async {
    await Directory('${root.path}/looptap').create(recursive: true);
    await songsFile().writeAsString('[1, 2');
    final loaded = await LoopStorage.load();
    expect(loaded, isEmpty);
    expect(LoopStorage.loadFailed, isTrue);
    expect(await songsFile().exists(), isFalse); // renamed to .corrupt-*
    expect(
      root.listSync(recursive: true).any((f) => f.path.contains('songs.json.corrupt-')),
      isTrue,
    );
  });

  test('a single bad song entry is skipped, the rest of the library loads', () async {
    await Directory('${root.path}/looptap').create(recursive: true);
    final good = song('good', 'Good').toJson();
    await songsFile().writeAsString(jsonEncode({
      'v': 2,
      'songs': [good, {'id': 42, 'title': null, 'sections': 'nope'}, song('also', 'Also').toJson()],
    }));
    final loaded = await LoopStorage.load();
    expect(loaded.map((s) => s.id), ['good', 'also']);
    expect(LoopStorage.loadFailed, isFalse);
    expect(LoopStorage.skippedOnLoad, 1);
    // a copy of the original is kept for recovery of the skipped entry
    expect(
      root.listSync(recursive: true).any((f) => f.path.contains('songs.json.corrupt-')),
      isTrue,
    );
    expect(await songsFile().exists(), isTrue); // main file still in place
  });

  test('legacy v1 bare-list file loads', () async {
    await Directory('${root.path}/looptap').create(recursive: true);
    await songsFile().writeAsString(jsonEncode([song('old').toJson()]));
    final loaded = await LoopStorage.load();
    expect(loaded.single.id, 'old');
    expect(LoopStorage.loadFailed, isFalse);
  });

  test('missing songs.json with a .bak (crash mid-swap) restores the backup', () async {
    await LoopStorage.save([song('a')]);
    await LoopStorage.save([song('a'), song('b')]);
    await songsFile().delete(); // simulate a crash between the two renames
    final loaded = await LoopStorage.load();
    expect(loaded.map((s) => s.id), ['a']);
    expect(LoopStorage.loadFailed, isFalse);
  });

  test('missing songs.json and no backup is a legitimately empty library', () async {
    expect(await LoopStorage.load(), isEmpty);
    expect(LoopStorage.loadFailed, isFalse);
  });

  test('seed marker persists', () async {
    expect(await LoopStorage.seeded(), isFalse);
    await LoopStorage.markSeeded();
    expect(await LoopStorage.seeded(), isTrue);
  });

  test('unknown scale normalises to minor on read (C5)', () {
    final s = Song.fromJson({'id': 'x', 'title': 'x', 'scale': 'lydian'});
    expect(s.scale, 'minor');
    expect(Song.fromJson({'id': 'x', 'title': 'x', 'scale': 'dorian'}).scale, 'dorian');
  });

  test('decodeListLenient counts skipped entries; strict decodeList throws', () {
    final raw = jsonEncode({'v': 2, 'songs': [song('ok').toJson(), 'garbage']});
    final r = Song.decodeListLenient(raw);
    expect(r.songs.single.id, 'ok');
    expect(r.skipped, 1);
    expect(() => Song.decodeList(raw), throwsA(anything));
    expect(() => Song.decodeListLenient('{"v": 2}'), throwsFormatException);
  });
}
