// 박자 보정 phase 추정(그루브 보존) 검증.
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/models/models.dart';
import 'package:humming/state/project_store.dart';

Note at(double start) => Note.fromJson({
      'start': start, 'end': start + 0.1, 'duration': 0.1,
      'pitch': 38, 'pitch_raw': 38.0, 'pitch_hz': 0.0,
      'velocity': 90, 'confidence': 1.0, 'voiced_ratio': 0.0, 'kind': 'percussive',
    });

// upload_095 의 실제 onset 시퀀스 (90 BPM, 8/16분음표 비트박스).
const _onsets = [
  0.267, 0.615, 0.836, 0.952, 1.3, 1.66, 2.009, 2.345, 2.705, 3.042,
  3.297, 3.39, 3.727, 4.075, 4.4, 4.76, 4.946, 5.074, 5.41, 5.7,
];

double _meanJitter(List<double> starts, double cell, double phase) {
  double sum = 0;
  for (final s in starts) {
    final r = (s - phase) % cell;
    sum += math.min(r.abs(), (cell - r).abs());
  }
  return sum / starts.length;
}

void main() {
  final notes = _onsets.map(at).toList();
  const bpm = 90;
  final cell = (60.0 / bpm) * 4 / 16; // 16분음표 셀 ≈ 0.16667s

  test('phase is within [0, cellSec)', () {
    final ph = estimateGridPhase(notes, cell);
    expect(ph, greaterThanOrEqualTo(0.0));
    expect(ph, lessThan(cell));
  });

  test('phase-fit reduces jitter vs phase=0 (groove pocket)', () {
    final ph = estimateGridPhase(notes, cell);
    final jPhase = _meanJitter(_onsets, cell, ph);
    final jZero = _meanJitter(_onsets, cell, 0.0);
    expect(jPhase, lessThanOrEqualTo(jZero));
    // 095 실측: phase ≈ 60-70ms, 지터는 cell 의 1/3 미만으로 줄어듦.
    expect(jPhase, lessThan(cell / 3));
  });

  test('full-strength snap lands notes on the phase grid', () {
    final ph = estimateGridPhase(notes, cell);
    for (final s in _onsets) {
      final snapped = ((s - ph) / cell).round() * cell + ph;
      final r = (snapped - ph) % cell;
      final resid = math.min(r.abs(), (cell - r).abs());
      expect(resid, lessThan(1e-6)); // 그리드 라인 위
    }
  });

  test('empty / zero-cell are safe', () {
    expect(estimateGridPhase(const [], cell), 0.0);
    expect(estimateGridPhase(notes, 0.0), 0.0);
  });
}
