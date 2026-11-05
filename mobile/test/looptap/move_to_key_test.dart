// A guided key pick is heard (2026-11-02): the melody moves to the new key.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/theory.dart';

void main() {
  test('root change moves the short way', () {
    expect(moveToKey(60, 'C', 'major', 'D', 'major'), 62);
    expect(moveToKey(60, 'C', 'major', 'A', 'major'), 57); // -3, not +9
    expect(moveToKey(64, 'C', 'major', 'F#', 'major'), 70); // +6
  });

  test('same root, other 7-note scale: degree onto degree', () {
    expect(moveToKey(64, 'C', 'major', 'C', 'minor'), 63); // E → Eb
    expect(moveToKey(69, 'C', 'major', 'C', 'minor'), 68); // A → Ab
    expect(moveToKey(62, 'C', 'major', 'C', 'minor'), 62); // D stays
    expect(moveToKey(61, 'C', 'major', 'C', 'minor'), 61); // C# keeps +1 over C
    expect(moveToKey(76, 'C', 'major', 'C', 'minor'), 75); // octave kept
  });

  test('root and scale together; a different-size scale snaps', () {
    expect(moveToKey(64, 'C', 'major', 'A', 'minor'), 60); // E(3rd) → C
    final m = moveToKey(62, 'C', 'major', 'C', 'pentatonic');
    expect(inScale(m, 'C', 'pentatonic'), isTrue);
  });

  test('unknown key or range edge', () {
    expect(moveToKey(60, 'H', 'major', 'C', 'major'), 60);
    expect(moveToKey(127, 'C', 'major', 'F#', 'major'), 127);
  });
}
