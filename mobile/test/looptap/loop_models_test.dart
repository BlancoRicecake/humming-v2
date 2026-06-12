// loop_models — TrackData/Section JSON round-trips: legacy saves without the
// vocal-context fields load with safe defaults, absolute vocal paths migrate
// to basenames, and vocalIsAligned only trusts a matching recorded context.
// Pure Dart (no device, no assets).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';

void main() {
  test('old-format JSON without vocal context loads with safe defaults', () {
    final t = TrackData.fromJson({
      'vocalPath': 'take.wav',
      'vocalAligned': true,
    });
    expect(t.vocalPath, 'take.wav');
    expect(t.vocalAligned, isTrue);
    expect(t.vocalBpm, isNull);
    expect(t.vocalBars, isNull);
    // missing recorded context → never trust native-loop alignment
    expect(t.vocalIsAligned(92, 2), isFalse);
  });

  test('absolute vocalPath migrates to basename', () {
    final t = TrackData.fromJson({
      'vocalPath': '/var/mobile/Containers/Data/Documents/looptap/vocals/lt1_A_5.wav',
      'vocalOrigPath': r'C:\Users\x\Documents\looptap\vocals\lt1_A_4.wav',
    });
    expect(t.vocalPath, 'lt1_A_5.wav');
    expect(t.vocalOrigPath, 'lt1_A_4.wav');
  });

  test('vocalBpm/vocalBars round-trip through JSON', () {
    final t = TrackData(
      vocalPath: 'take.wav',
      vocalAligned: true,
      vocalBpm: 104,
      vocalBars: 4,
    );
    final r = TrackData.fromJson(
      jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
    );
    expect(r.vocalAligned, isTrue);
    expect(r.vocalBpm, 104);
    expect(r.vocalBars, 4);
    expect(r.vocalIsAligned(104, 4), isTrue);
  });

  test('vocalIsAligned requires aligned flag AND matching bpm/bars', () {
    final t = TrackData(
      vocalPath: 'take.wav',
      vocalAligned: true,
      vocalBpm: 92,
      vocalBars: 2,
    );
    expect(t.vocalIsAligned(92, 2), isTrue);
    expect(t.vocalIsAligned(93, 2), isFalse); // bpm changed since recording
    expect(t.vocalIsAligned(92, 4), isFalse); // bars changed since recording
    t.vocalAligned = false;
    expect(t.vocalIsAligned(92, 2), isFalse); // unaligned take never loops natively
  });

  test('Section JSON round-trip preserves vocal track fields', () {
    final s = Section(id: 'sec1', name: 'A', bars: 2, repeats: 3);
    s.tracks['vocal'] = TrackData(
      vocalPath: 'v.wav',
      vocalAligned: true,
      vocalBpm: 120,
      vocalBars: 2,
    );
    final r = Section.fromJson(
      jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
    );
    final v = r.tracks['vocal']!;
    expect(v.vocalPath, 'v.wav');
    expect(v.vocalIsAligned(120, 2), isTrue);
    expect(v.vocalIsAligned(121, 2), isFalse);
    expect(r.bars, 2);
    expect(r.repeats, 3);
  });

  test('deepCopy carries the vocal context', () {
    final t = TrackData(
      vocalPath: 'v.wav',
      vocalAligned: true,
      vocalBpm: 88,
      vocalBars: 1,
    );
    final c = t.deepCopy();
    expect(c.vocalIsAligned(88, 1), isTrue);
    expect(c.vocalBpm, 88);
    expect(c.vocalBars, 1);
  });
}
