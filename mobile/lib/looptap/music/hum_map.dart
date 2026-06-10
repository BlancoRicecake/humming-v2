// LoopTap — engine→app note mapping helpers (pure functions).
//
// Extracted from edit_screen.dart so they can be unit-tested in isolation and
// kept in parity with the Python mirror (backend/app/looptap_map.py). The eval
// harness (backend/eval_looptap.py) reproduces these exact transforms to measure
// engine→app accuracy on HumTrans, so the two MUST stay in sync — the parity
// test (test/looptap/hum_map_parity_test.dart) checks this against a golden file
// emitted by backend/tests/test_looptap_map.py.
//
// Behaviour is identical to the original private methods; no UI change.
import 'theory.dart';

/// Whole-octave shift centering a hummed phrase on the ladder's range. A phrase
/// sung an octave high/low shifts as a unit, preserving contour, instead of
/// clamping to the top/bottom rung.
int phraseOctaveShift(Iterable<int> midis, List<Rung> ladder) {
  final list = midis.toList()..sort();
  if (list.isEmpty) return 0;
  final median = list[list.length ~/ 2];
  final center = (ladder.first.midi + ladder.last.midi) ~/ 2;
  return ((center - median) / 12).round() * 12;
}

/// Fold [midi] into the ladder's octave range, then snap to the nearest in-key
/// rung (ties resolve to the lower index).
Rung snapToLadder(int midi, List<Rung> ladder) {
  final lo = ladder.first.midi, hi = ladder.last.midi;
  var m = midi;
  while (m < lo - 6) {
    m += 12;
  }
  while (m > hi + 6) {
    m -= 12;
  }
  var best = ladder.first;
  var bestD = 9999;
  for (final r in ladder) {
    final d = (r.midi - m).abs();
    if (d < bestD) {
      bestD = d;
      best = r;
    }
  }
  return best;
}

/// Map an engine note's GM drum value / name to a LoopTap kit kind.
String? drumKind(int? drum, String? drumName, int pitch) {
  final name = (drumName ?? '').toLowerCase();
  if (name.contains('kick')) return 'kick';
  if (name.contains('snare')) return 'snare';
  if (name.contains('hat')) return 'hihat';
  switch (drum ?? pitch) {
    case 36:
      return 'kick';
    case 38:
    case 40:
      return 'snare';
    case 42:
    case 44:
    case 46:
      return 'hihat';
  }
  return null;
}
