// Parity test: the Dart engine→app mapping (looptap/music/hum_map.dart) must
// match the Python mirror (backend/app/looptap_map.py) used by the eval harness.
// The golden file is emitted by `python tests/test_looptap_map.py` (REGEN_GOLDEN=1);
// if this test fails after an intentional mapping change, regenerate it and
// update both sides together.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/hum_map.dart';
import 'package:humming/looptap/music/theory.dart';

void main() {
  final file = File('test/looptap/fixtures/hum_map_golden.json');
  final golden = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  test('golden fixture present and versioned', () {
    expect(file.existsSync(), isTrue);
    expect(golden['version'], 1);
  });

  for (final raw in (golden['cases'] as List)) {
    final c = raw as Map<String, dynamic>;
    final spec = c['ladder_spec'] as Map<String, dynamic>;
    final label = '${spec['name']} ${spec['mode']} oct${spec['oct']}';
    final ladder = buildLadder(
        spec['name'] as String, spec['mode'] as String, spec['oct'] as int, spec['count'] as int);

    test('buildLadder $label', () {
      expect(ladder.map((r) => r.midi).toList(),
          (c['ladder_midis'] as List).cast<int>());
    });

    test('phraseOctaveShift $label', () {
      for (final oc in (c['octave_shift'] as List)) {
        final m = oc as Map<String, dynamic>;
        final midis = (m['midis'] as List).cast<int>();
        expect(phraseOctaveShift(midis, ladder), m['out'],
            reason: 'midis=$midis');
      }
    });

    test('snapToLadder $label', () {
      for (final s in (c['snap'] as List)) {
        final m = s as Map<String, dynamic>;
        expect(snapToLadder(m['midi'] as int, ladder).midi, m['out'],
            reason: 'midi=${m['midi']}');
      }
    });
  }
}
