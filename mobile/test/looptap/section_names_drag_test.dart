// 2026-11-02: duplicates keep their section's name with " #2"; a long press
// drags a section chip to a new position (names follow on the drop), and a
// long press let go in place still opens the section menu.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/section_names.dart';
import 'package:humming/looptap/widgets/section_bar.dart';

import '../support/offline_fonts.dart';

Section _s(String id, {String? family, bool auto = true, String name = '?'}) =>
    Section(id: id, name: name, autoName: auto, family: family);

List<String> _names(List<Section> l) => [for (final s in l) s.name];

void main() {
  group('relabelSections', () {
    test('no copies: A, B, C as before; a custom name keeps its letter skipped', () {
      final l = [_s('a'), _s('b', auto: false, name: 'Verse'), _s('c')];
      relabelSections(l);
      expect(_names(l), ['A', 'Verse', 'C']);
    });

    test('copies read A, A #2, A #3 in song order, wherever they sit', () {
      final l = [_s('a', family: 'a'), _s('a2', family: 'a'), _s('b'), _s('a3', family: 'a')];
      relabelSections(l);
      expect(_names(l), ['A', 'A #2', 'B', 'A #3']);
      // a copy moved first takes the plain name
      l.insert(0, l.removeAt(3));
      relabelSections(l);
      expect(_names(l), ['A', 'A #2', 'A #3', 'B']);
    });

    test('a custom-named family: Verse, Verse #2; a lone "Take #2" is left alone', () {
      final l = [
        _s('v', family: 'v', auto: false, name: 'Verse'),
        _s('v2', family: 'v', auto: false, name: 'Verse #2'),
        _s('t', auto: false, name: 'Take #2'),
      ];
      l.insert(0, l.removeAt(1)); // the copy goes first
      relabelSections(l);
      expect(_names(l), ['Verse', 'Verse #2', 'Take #2']);
    });

    test('the family is saved with the song', () {
      final s = Section(id: 'x', name: 'A #2', family: 'a');
      expect(Section.fromJson(s.toJson()).family, 'a');
      expect(Section.fromJson(Section(id: 'y', name: 'B').toJson()).family, isNull);
      expect(s.deepCopy().family, 'a');
    });
  });

  group('SectionBar drag', () {
    Future<(List<(int, int)>, List<int>)> mount(WidgetTester tester) async {
      useOfflineTestFonts();
      final moves = <(int, int)>[];
      final menus = <int>[];
      final sections = [_s('a'), _s('b'), _s('c')];
      relabelSections(sections);
      await tester.binding.setSurfaceSize(const Size(600, 120));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: SectionBar(
              sections: sections,
              activeIdx: 0,
              songMode: false,
              onSwitch: (_) {},
              onAdd: () {},
              onRename: (_, _) {},
              onRepeats: (_, _) {},
              onDelete: (_) {},
              onLongPress: menus.add,
              onPlaySong: () {},
              onMove: (from, to) => moves.add((from, to)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (moves, menus);
    }

    testWidgets('long-press and drag moves a section; the others slide aside', (tester) async {
      final (moves, menus) = await mount(tester);
      final c = tester.getCenter(find.text('C'));
      final a = tester.getCenter(find.text('A').first);
      final g = await tester.startGesture(c);
      await tester.pump(const Duration(milliseconds: 600)); // long press
      await g.moveTo(Offset(a.dx - 10, c.dy));
      await tester.pump(const Duration(milliseconds: 50));
      for (var x = a.dx - 40; x > 0; x -= 20) {
        await g.moveTo(Offset(x, c.dy));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(milliseconds: 100));
      // mid-drag: B moved right to make room (the slide animation)
      final bMid = tester.getCenter(find.text('B')).dx;
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getCenter(find.text('B')).dx, greaterThan(bMid - 1));
      await g.up();
      await tester.pumpAndSettle();
      expect(moves, [(2, 0)]);
      expect(menus, isEmpty, reason: 'a drag is not a menu');
    });

    testWidgets('long-press let go in place opens the menu', (tester) async {
      final (moves, menus) = await mount(tester);
      final g = await tester.startGesture(tester.getCenter(find.text('B')));
      await tester.pump(const Duration(milliseconds: 600));
      await g.up();
      await tester.pumpAndSettle();
      expect(moves, isEmpty);
      expect(menus, [1]);
    });
  });
}
