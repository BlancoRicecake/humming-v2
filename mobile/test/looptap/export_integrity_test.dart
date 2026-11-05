// Storage audit 2026-10-30 (Codex S3–S6), on real files in an isolated folder:
// - S3 the song-level vocal stem carries the Vocal lane's level (and pan);
// - S4 vocal stems cover the whole song from t=0 — section offset, repeats —
//   so they line up with the instrument stems in a DAW;
// - S5 a damaged take is never written out as a "successful" .wav: it is
//   skipped and counted (stems and the full mix alike);
// - S6 Windows device names (CON, NUL, COM1…) never become export names;
//   same-title exports at once get distinct files; a failed write leaves no
//   half file or reservation behind.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/export_library.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

const _sr = 44100;

/// [seconds] of a 440 Hz tone at amplitude 0.5, mono PCM16.
Uint8List _tone(double seconds, {int rate = _sr}) {
  final n = (seconds * rate).round();
  final pcm = Float32List(n);
  for (var i = 0; i < n; i++) {
    pcm[i] = .5 * math.sin(2 * math.pi * 440 * i / rate);
  }
  return encodeWavMono16(pcm, rate);
}

double _rms(Float32List s, double from, double to) {
  final a = (from * _sr).round(), b = math.min((to * _sr).round(), s.length);
  var sum = 0.0;
  for (var i = a; i < b; i++) {
    sum += s[i] * s[i];
  }
  return b > a ? math.sqrt(sum / (b - a)) : 0;
}

double _peak(Float32List s) => s.fold(0.0, (m, v) => math.max(m, v.abs()));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory vocals;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_export_integrity_');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // the full mix loads the bundled GM font: assets straight from the repo,
    // its cache copy under the isolated root
    messenger.setMockMessageHandler('flutter/assets', (message) {
      final path = utf8.decode(
        message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
      );
      final file = File(path);
      return SynchronousFuture(
        file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null,
      );
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => root.path,
    );
    addTearDown(() {
      messenger.setMockMessageHandler('flutter/assets', null);
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
    });
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    await LoopStorage.load(); // warms the vocal path cache
    vocals = Directory('${root.path}/looptap/vocals');
    await vocals.create(recursive: true);
  });
  tearDown(() async {
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> take(String name, List<int> bytes) =>
      File('${vocals.path}/$name').writeAsBytes(bytes);

  group('S6 file names', () {
    test('Windows device names get a safe name; Korean and ordinary names stay', () {
      expect(exportFileName('CON'), '_CON');
      expect(exportFileName('nul'), '_nul');
      expect(exportFileName('Com1'), '_Com1');
      expect(exportFileName('lpt9.mix'), '_lpt9.mix');
      expect(exportFileName('aux '), '_aux');
      expect(exportFileName('CONSOLE'), 'CONSOLE');
      expect(exportFileName('CON - melody'), 'CON - melody');
      expect(exportFileName('봄날의 허밍'), '봄날의 허밍');
      expect(exportFileName('a/b:c*?'), 'abc');
      expect(exportFileName('', fallback: 'PRN'), '_PRN', reason: 'fallback too');
      expect(exportFileName('...', fallback: ''), 'loop');
    });

    test('same-title exports at once get distinct files', () async {
      final folder = Directory('${root.path}/out')..createSync();
      final files = await Future.wait([
        for (var i = 0; i < 6; i++) uniqueExportFile(folder, 'Song', 'wav'),
      ]);
      expect(files.map((f) => f.path).toSet(), hasLength(6));
      expect(
        files.map((f) => f.uri.pathSegments.last).toSet(),
        containsAll(['Song.wav', 'Song (2).wav', 'Song (6).wav']),
      );
    });

    test('a failed write leaves neither a half file nor the reservation', () async {
      final folder = Directory('${root.path}/out')..createSync();
      final f = await uniqueExportFile(folder, 'Broken', 'wav');
      Directory('${f.path}.part').createSync(); // the write target is a folder
      await expectLater(writeExportFile(f, [1, 2, 3]), throwsA(isA<FileSystemException>()));
      expect(f.existsSync(), isFalse);
      expect(await listExportedFiles(directory: folder), isEmpty);
    });

    test('a reserved, unwritten name is hidden from the export library', () async {
      final folder = Directory('${root.path}/out')..createSync();
      final f = await uniqueExportFile(folder, 'Pending', 'wav');
      expect(await listExportedFiles(directory: folder), isEmpty);
      await writeExportFile(f, _tone(.1));
      expect((await listExportedFiles(directory: folder)).single.name, 'Pending.wav');
      expect(File('${f.path}.part').existsSync(), isFalse);
    });
  });

  group('vocal stems', () {
    // 120 BPM: 1 bar = 2 s. A: 1 bar x2 (silent), B: 1 bar x3 with a 1 s take.
    List<Section> arrangement() => [
      Section(id: 'A', name: 'A', bars: 1, repeats: 2),
      Section(id: 'B', name: 'B', bars: 1, repeats: 3)
        ..tracks['vocal'] = TrackData(clips: [VocalClip(path: 'b.wav')]),
    ];

    test('S4: section takes land at their song position, every repeat, song length', () async {
      await take('b.wav', _tone(1));
      final stems = await exportStems(arrangement(), 120, 0, const {'vocal': 1.0}, 'S4');
      expect(stems.map((f) => f.uri.pathSegments.last), ['S4 - vocal.wav']);
      final wav = parseWav(await stems.single.readAsBytes())!;
      expect(wav.sampleRate, _sr);
      expect(wav.channels, 2);
      expect(wav.samples.length / _sr, closeTo(11.2, .01), reason: 'whole song + the shared 1.2 s tail (B3)');
      expect(_rms(wav.samples, 0, 4), 0, reason: 'A x2 is silent');
      for (final at in [4.0, 6.0, 8.0]) {
        expect(_rms(wav.samples, at + .1, at + .9), greaterThan(.3), reason: 'B repeat at $at s');
        expect(_rms(wav.samples, at + 1.05, at + 1.95), 0, reason: 'take is 1 s');
      }
    });

    test('B3: instrument and vocal stems share one start and one end', () async {
      await take('b.wav', _tone(1));
      final secs = arrangement();
      secs[0].tracks['melody'] = TrackData(
        notes: [PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4)],
      );
      final stems = await exportStems(secs, 120, 0, const {'vocal': 1.0, 'melody': .85}, 'B3');
      expect(stems.map((f) => f.uri.pathSegments.last).toSet(), {'B3 - melody.wav', 'B3 - vocal.wav'});
      final lengths = <int>{};
      for (final f in stems) {
        final b = await f.readAsBytes();
        final wav = parseWav(b)!;
        expect(wav.channels, 2);
        lengths.add(wav.samples.length);
      }
      expect(lengths, hasLength(1), reason: 'identical frame counts');
      expect(lengths.single / _sr, greaterThanOrEqualTo(10), reason: 'the whole song (plus tail)');
    });

    test('S3: the song-level take follows the Vocal lane level (no normalising)', () async {
      await take('song.wav', _tone(3));
      Future<double> peakAt(double vol) async {
        final stems = await exportStems(
          arrangement(),
          120,
          0,
          {'vocal': vol},
          'S3 $vol',
          songVocalPath: 'song.wav',
        );
        expect(stems.single.uri.pathSegments.last, 'S3 $vol - vocal (song).wav');
        final wav = parseWav(await stems.single.readAsBytes())!;
        expect(wav.samples.length / _sr, closeTo(11.2, .01), reason: 'song length + the shared tail');
        return _peak(wav.samples);
      }

      final full = await peakAt(1.0);
      final quarter = await peakAt(.25);
      expect(full, closeTo(.5, .01));
      expect(quarter / full, closeTo(.25, .01));
    });

    test('S5: a damaged song take is skipped and reported, not written as .wav', () async {
      await take('broken.wav', [1, 2, 3, 4]);
      var skipped = 0;
      final stems = await exportStems(
        arrangement(),
        120,
        0,
        const {'vocal': 1.0},
        'S5',
        songVocalPath: 'broken.wav',
        onVocalsSkipped: (n) => skipped = n,
      );
      expect(stems, isEmpty);
      expect(skipped, 1);
      final exported = Directory('${root.path}/looptap/exports');
      expect(await listExportedFiles(directory: exported), isEmpty);
    });

    test('S5: a damaged section take counts as skipped in stems and the full mix', () async {
      await take('b.wav', [1, 2, 3, 4]);
      var skipped = 0;
      final stems = await exportStems(
        arrangement(),
        120,
        0,
        const {'vocal': 1.0},
        'S5b',
        onVocalsSkipped: (n) => skipped = n,
      );
      expect(stems, isEmpty);
      expect(skipped, 1);
      final mix = await exportWavSong(arrangement(), 120, 0, const {'vocal': 1.0}, 'S5 mix');
      expect(mix.skippedVocals, 1);
    });
  });
}
