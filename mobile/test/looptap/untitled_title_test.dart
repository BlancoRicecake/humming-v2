// 2026-11-02: new songs are "Untitled loop 1, 2, 3…" so they can be told
// apart; a numbered default title still counts as untouched.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/state/loop_store.dart';

void main() {
  test('the next free number after the existing ones', () {
    expect(LoopStore.nextUntitledTitle(const []), 'Untitled loop 1');
    expect(LoopStore.nextUntitledTitle(const ['Untitled loop', 'Demo']), 'Untitled loop 1');
    expect(LoopStore.nextUntitledTitle(const ['Untitled loop 1', 'Untitled loop 3', 'My song 9']), 'Untitled loop 4');
    expect(LoopStore.nextUntitledTitle(const ['Untitled loop 2 (copy)']), 'Untitled loop 1');
  });

  test('default titles are recognised, renamed ones are not', () {
    for (final t in ['Untitled loop', 'Untitled loop 1', 'Untitled loop 27']) {
      expect(LoopStore.kUntitledTitle.hasMatch(t), isTrue, reason: t);
    }
    for (final t in ['Untitled loop x', 'My Untitled loop 1', 'Untitled loop 1 (copy)']) {
      expect(LoopStore.kUntitledTitle.hasMatch(t), isFalse, reason: t);
    }
  });

  test('createNew numbers new songs', () {
    final store = LoopStore();
    expect(store.createNew().title, 'Untitled loop 1');
  });
}
