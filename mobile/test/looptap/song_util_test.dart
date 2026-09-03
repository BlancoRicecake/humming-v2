// song_util — flattenSong drops/clamps notes outside a section's current
// length (C7: shrinking bars must not leak notes into the next section), and
// the shared export file-name sanitiser keeps non-ASCII titles while never
// overwriting an existing export (C11 / A20).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

void main() {
  group('flattenSong', () {
    test('notes at/after the section end are dropped, overhangs clamped', () {
      // section A was recorded at 2 bars (32 steps) then shrunk to 1 bar (16).
      final a = Section(id: 'A', name: 'A', bars: 1);
      a.tracks['melody'] = TrackData(notes: [
        PitchNote(midi: 60, freq: 0, step: 0, dur: 4), // fine
        PitchNote(midi: 62, freq: 0, step: 14, dur: 6), // overhang → clamp to 2
        PitchNote(midi: 64, freq: 0, step: 16, dur: 2), // out → dropped
        PitchNote(midi: 65, freq: 0, step: 24, dur: 2), // out → dropped
      ]);
      a.tracks['drums'] = TrackData(drums: [
        DrumNote(kind: 'kick', step: 0),
        DrumNote(kind: 'kick', step: 20), // out → dropped
      ]);
      final b = Section(id: 'B', name: 'B', bars: 1);
      b.tracks['melody'] = TrackData(notes: [PitchNote(midi: 67, freq: 0, step: 0, dur: 1)]);

      final flat = flattenSong([a, b]);
      expect(flat.steps, 32);
      // nothing from A lands in B's range [16, 32) except B's own note
      final inB = flat.melody.where((n) => n.step >= 16).toList();
      expect(inB.length, 1);
      expect(inB.single.midi, 67);
      final clamped = flat.melody.firstWhere((n) => n.midi == 62);
      expect(clamped.step + clamped.dur, lessThanOrEqualTo(16));
      expect(flat.drums.length, 1);
    });

    test('added tracks are filtered the same way', () {
      final a = Section(id: 'A', name: 'A', bars: 1, extras: const [TrackRef('bass_x1', 'bass')]);
      a.tracks['bass_x1'] = TrackData(notes: [
        PitchNote(midi: 40, freq: 0, step: 2, dur: 2),
        PitchNote(midi: 41, freq: 0, step: 18, dur: 2),
      ]);
      final flat = flattenSong([a]);
      expect(flat.extraPitched['bass_x1']!.map((n) => n.midi), [40]);
    });
  });

  group('exportFileName', () {
    test('keeps Korean / spaces, strips only filesystem-illegal characters', () {
      expect(exportFileName('내 노래 - A'), '내 노래 - A');
      expect(exportFileName(r'a/b\c:d*e?f"g<h>i|j'), 'abcdefghij');
      expect(exportFileName('  spaced  '), 'spaced');
      expect(exportFileName('dots...'), 'dots');
    });

    test('falls back to the song id when nothing survives', () {
      expect(exportFileName('', fallback: 'lt123'), 'lt123');
      expect(exportFileName('???', fallback: 'lt123'), 'lt123');
      expect(exportFileName('', fallback: ''), 'loop');
    });
  });

  group('uniqueExportFile', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('lt_export_'));
    tearDown(() async => dir.delete(recursive: true));

    test('appends (2), (3)… instead of overwriting', () async {
      final f1 = await uniqueExportFile(dir, '내 노래', 'wav');
      expect(f1.path.endsWith('내 노래.wav'), isTrue);
      await f1.writeAsString('x');
      final f2 = await uniqueExportFile(dir, '내 노래', 'wav');
      expect(f2.path.endsWith('내 노래 (2).wav'), isTrue);
      await f2.writeAsString('y');
      final f3 = await uniqueExportFile(dir, '내 노래', 'wav');
      expect(f3.path.endsWith('내 노래 (3).wav'), isTrue);
      expect(await f1.readAsString(), 'x'); // untouched
    });
  });

  test('stepsForBars sanity', () {
    expect(stepsForBars(2), 32);
  });
}
