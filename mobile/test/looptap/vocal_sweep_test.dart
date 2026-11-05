// sweepVocals: regenerable `_mix_*` preview bounces are always swept, even
// while the take guard (preserved corrupt library / failed / partial load /
// empty list with takes on disk) keeps every user take.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/state/loop_storage.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt_sweep_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
  });

  tearDown(() async {
    LoopStorage.rootOverride = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> vocal(String name) async {
    final f = File('${root.path}/looptap/vocals/$name');
    await f.writeAsBytes([1, 2, 3]);
    return f;
  }

  Song songWithTake(String id, String take) {
    final s = Song(id: id, title: id);
    s.sections.first.tracks['vocal'] = TrackData(vocalPath: take);
    return s;
  }

  test('preserved corruption keeps user takes but sweeps _mix_ bounces', () async {
    await LoopStorage.save([songWithTake('s', 's_a_1.wav')]);
    await File(
      '${root.path}/looptap/songs.json.corrupt-123',
    ).writeAsString('{bad');
    final kept = await vocal('s_a_1.wav');
    final orphan = await vocal('old_a_9.wav'); // may belong to the corrupt file
    final mix = await vocal('_mix_s_a_4.wav');

    final songs = await LoopStorage.load();
    expect(songs.map((s) => s.id), ['s']);
    await LoopStorage.sweepVocals(songs);

    expect(await kept.exists(), isTrue);
    expect(await orphan.exists(), isTrue);
    expect(await mix.exists(), isFalse);
  });

  test('normal library sweeps unreferenced takes and bounces', () async {
    await LoopStorage.save([songWithTake('s', 's_a_1.wav')]);
    final kept = await vocal('s_a_1.wav');
    final orphan = await vocal('s_a_0.wav');
    final mix = await vocal('_mix_s_a_2.wav');

    await LoopStorage.sweepVocals(await LoopStorage.load());

    expect(await kept.exists(), isTrue);
    expect(await orphan.exists(), isFalse);
    expect(await mix.exists(), isFalse);
  });

  test('empty list with takes on disk keeps takes, drops bounces', () async {
    final take = await vocal('s_a_1.wav');
    final mix = await vocal('_mix_s_a_2.wav');

    expect(await LoopStorage.load(), isEmpty);
    expect(LoopStorage.loadFailed, isFalse);
    await LoopStorage.sweepVocals(const []);

    expect(await take.exists(), isTrue);
    expect(await mix.exists(), isFalse);
  });

  test('failed load keeps takes, drops bounces', () async {
    await File('${root.path}/looptap/songs.json').writeAsString('{bad');
    final take = await vocal('s_a_1.wav');
    final mix = await vocal('_mix_s_a_2.wav');

    expect(await LoopStorage.load(), isEmpty);
    expect(LoopStorage.loadFailed, isTrue);
    await LoopStorage.sweepVocals(const []);

    expect(await take.exists(), isTrue);
    expect(await mix.exists(), isFalse);
  });
}
