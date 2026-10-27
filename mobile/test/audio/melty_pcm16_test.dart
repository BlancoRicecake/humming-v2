import 'package:flutter_test/flutter_test.dart';
import 'package:humming/audio/melty_synth_backend.dart';

void main() {
  test('non-finite samples render as silence instead of throwing', () {
    expect(MeltyEngine.pcm16(double.nan), 0);
    expect(MeltyEngine.pcm16(double.infinity), 0);
    expect(MeltyEngine.pcm16(double.negativeInfinity), 0);
  });

  test('finite samples keep the tanh soft-limit mapping', () {
    expect(MeltyEngine.pcm16(0), 0);
    expect(MeltyEngine.pcm16(10), 32767);
    expect(MeltyEngine.pcm16(-10), -32768);
    final small = MeltyEngine.pcm16(0.01);
    expect(small, closeTo(0.01 * 32767, 2));
  });
}
