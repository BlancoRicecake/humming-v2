import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LoopStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt_store_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    await LoopStorage.load();
    store = LoopStore();
  });

  tearDown(() async {
    store.dispose();
    LoopStorage.rootOverride = null;
    final resolved = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved.startsWith('$temp${Platform.pathSeparator}lt_store_')) {
      throw StateError('Unexpected test cleanup path');
    }
    await root.delete(recursive: true);
  });

  Directory blockedTemp() => Directory('${root.path}/looptap/songs.json.tmp');

  test(
    'duplicate retains song vocal metadata and survives deleting source',
    () async {
      final source = Song(
        id: 'source',
        title: 'Recorded song',
        songVocalPath: 'voice.wav',
        songVocalPeaks: [0.2, 0.8],
        songVocalBpm: 120,
        songVocalBars: 8,
      );
      final vocal = File('${root.path}/looptap/vocals/voice.wav');
      await vocal.writeAsBytes([1, 2, 3]);
      await store.upsert(source);
      final duplicate = await store.duplicate(source);
      expect(duplicate.songVocalPath, source.songVocalPath);
      expect(duplicate.songVocalPeaks, source.songVocalPeaks);
      expect(duplicate.songVocalBpm, source.songVocalBpm);
      expect(duplicate.songVocalBars, source.songVocalBars);
      duplicate.songVocalPeaks![0] = 1;
      expect(source.songVocalPeaks![0], 0.2);

      await store.delete(source.id);
      expect(await vocal.exists(), isTrue);
      final restored = (await LoopStorage.load()).single;
      expect(restored.id, duplicate.id);
      expect(restored.songVocalPath, 'voice.wav');
      expect(restored.songVocalPeaks, [0.2, 0.8]);
    },
  );

  test(
    'failed delete keeps memory, persisted song and its vocal; retry succeeds',
    () async {
      await store.upsert(
        Song(id: 'a', title: 'Vocal song', songVocalPath: 'a.wav'),
      );
      await store.upsert(Song(id: 'b', title: 'Other song'));
      final vocal = File('${root.path}/looptap/vocals/a.wav');
      await vocal.writeAsBytes([1, 2, 3]);
      await blockedTemp().create();
      await expectLater(store.delete('a'), throwsA(isA<FileSystemException>()));
      expect(store.songs.any((song) => song.id == 'a'), isTrue);
      expect((await LoopStorage.load()).any((song) => song.id == 'a'), isTrue);
      await store.sweepVocals();
      expect(await vocal.exists(), isTrue);

      await blockedTemp().delete();
      await store.delete('a');
      expect(store.songs.map((s) => s.id), ['b']);
      expect((await LoopStorage.load()).map((s) => s.id), ['b']);
      expect(await vocal.exists(), isFalse);
    },
  );

  test('failed save or rename does not publish unpersisted edits', () async {
    await store.upsert(Song(id: 'a', title: 'Original'));
    var notifications = 0;
    store.addListener(() => notifications++);
    await blockedTemp().create();
    await expectLater(
      store.upsert(Song(id: 'a', title: 'Unsaved')),
      throwsA(isA<FileSystemException>()),
    );
    await expectLater(
      store.rename('a', 'Also unsaved'),
      throwsA(isA<FileSystemException>()),
    );
    expect(store.songs.single.title, 'Original');
    expect((await LoopStorage.load()).single.title, 'Original');
    expect(notifications, 0);

    await blockedTemp().delete();
    await store.rename('a', 'Saved');
    expect(store.songs.single.title, 'Saved');
    expect(notifications, 1);
  });

  test('queued edits preserve order and snapshot the caller data', () async {
    final source = Song(id: 'a', title: 'A');
    final first = store.upsert(source);
    source.title = 'Mutation after save started';
    await Future.wait([
      first,
      store.upsert(Song(id: 'b', title: 'B')),
      store.rename('b', 'B renamed'),
    ]);
    final persisted = {for (final s in await LoopStorage.load()) s.id: s.title};
    expect(persisted, {'a': 'A', 'b': 'B renamed'});
  });
}
