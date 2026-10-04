import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/sample_library.dart';

void main() {
  late Directory dir;
  late SampleLibrary library;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('humtrack_sample_test');
    library = SampleLibrary(root: dir);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test(
    'trim keeps source, fades edges, persists and reopens independently',
    () async {
      final wave = WavData(
        samples: Float32List.fromList(List.filled(8000, 0.5)),
        sampleRate: 8000,
        channels: 1,
      );
      final cut = selectSample(wave, 0.25, 0.75);
      expect(cut, hasLength(4000));
      expect(cut.first, 0);
      expect(cut.last, 0);
      expect(cut[100], 0.5);
      expect(wave.samples.every((v) => v == 0.5), isTrue);
      final saved = await library.save(cut, 8000);
      final reopened = SampleLibrary(root: dir);
      expect((await reopened.list()).single.path, saved.path);
      expect((await reopened.read(saved)).samples, hasLength(4000));
      final imported = await reopened.import(saved);
      expect(imported.path, isNot(saved.path));
      expect(await reopened.list(), hasLength(2));
    },
  );
  test(
    'invalid format, excessive duration and size fail before import',
    () async {
      final invalid = File('${dir.path}/bad.wav');
      await invalid.writeAsString('not audio');
      await expectLater(library.import(invalid), throwsFormatException);
      await invalid.writeAsBytes(encodeWavMono16(Float32List(8000 * 61), 8000));
      await expectLater(library.import(invalid), throwsFormatException);
      final handle = await invalid.open(mode: FileMode.write);
      await handle.truncate(25 * 1024 * 1024);
      await handle.close();
      await expectLater(library.import(invalid), throwsFormatException);
      expect(await library.list(), isEmpty);
    },
  );
}
