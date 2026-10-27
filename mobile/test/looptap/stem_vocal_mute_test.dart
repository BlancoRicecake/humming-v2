// Stem export honours a muted Vocal lane for the song-level take (it used to be
// written even at vol 0 while the full mix dropped it), and the live-preview
// vocal bounce limits a summed peak instead of hard-clipping it.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt_stems_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    final pcm = Float32List.fromList(
      List.generate(4410, (i) => 0.5 * math.sin(i / 10)),
    );
    await File(
      '${root.path}/looptap/vocals/song_take.wav',
    ).writeAsBytes(encodeWavMono16(pcm, 44100));
  });

  tearDown(() async {
    LoopStorage.rootOverride = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  // Only the vocal can produce a stem: every instrument lane is silent/empty.
  Map<String, double> vol(double vocal) => {
    'melody': 0,
    'bass': 0,
    'melodyDec': 0,
    'drums': 0,
    'beatDec': 0,
    'vocal': vocal,
  };

  List<Section> sections() => [Section(id: 'a', name: 'A')];

  test('muted Vocal lane: no song-vocal stem', () async {
    final files = await exportStems(
      sections(),
      120,
      0,
      vol(0),
      'Muted',
      songVocalPath: 'song_take.wav',
    );
    expect(files.where((f) => f.path.contains('vocal')), isEmpty);
  });

  test('audible Vocal lane: song-vocal stem is exported', () async {
    final files = await exportStems(
      sections(),
      120,
      0,
      vol(0.8),
      'Audible',
      songVocalPath: 'song_take.wav',
    );
    expect(files.where((f) => f.path.contains('vocal (song)')), hasLength(1));
  });

  test('preview bounce encoder limits a hot summed lane to the headroom', () {
    final hot = Float32List.fromList(
      List.generate(1000, (i) => 1.6 * math.sin(i / 7)),
    );
    final wav = parseWav(encodeWavMono16FromStereo(hot, hot, 44100))!;
    var peak = 0.0;
    var clipped = 0;
    for (final s in wav.samples) {
      peak = math.max(peak, s.abs());
      if (s.abs() >= 0.999) clipped++;
    }
    expect(peak, closeTo(0.94, 0.01));
    expect(clipped, 0);
    // a quiet lane passes through unchanged (no upward normalization)
    final quiet = Float32List.fromList(List.filled(10, 0.25));
    final q = parseWav(encodeWavMono16FromStereo(quiet, quiet, 44100))!;
    expect(q.samples.first, closeTo(0.25, 1e-3));
  });
}
