// 코드(다이아토닉 트라이어드) 변환 검증.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/music/chords.dart';
import 'package:humming/models/models.dart';

void main() {
  test('diatonic triads in C major', () {
    expect(buildDiatonicTriad(60, 'C', 'major'), [60, 64, 67]); // C → C E G
    expect(buildDiatonicTriad(62, 'C', 'major'), [62, 65, 69]); // D → D F A
    expect(buildDiatonicTriad(67, 'C', 'major'), [67, 71, 74]); // G → G B D
  });

  test('expandChords triples pitched notes, leaves percussive', () {
    Note mk(int p, String kind) => Note.fromJson({
          'start': 0, 'end': 0.5, 'duration': 0.5, 'pitch': p, 'pitch_raw': p.toDouble(),
          'pitch_hz': 0, 'velocity': 90, 'confidence': 0.8, 'voiced_ratio': 1.0, 'kind': kind,
          'pitch_original': p, 'assisted': false, 'candidates': [p], 'source': 'raw',
          'in_key': true, 'correction_cents': 0,
        });
    final key = DetectedKey(tonic: 'C', scale: 'major');
    final out = expandChords([mk(60, 'pitched')], key, true);
    expect(out.length, 3); // C E G
    expect(out.map((n) => n.pitch).toList(), [60, 64, 67]);

    final drums = expandChords([mk(38, 'percussive')], key, true);
    expect(drums.length, 1); // percussive 그대로
  });
}
