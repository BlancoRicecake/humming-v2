import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/widgets/sheets/song_plan_sheet.dart';

void main() {
  testWidgets('song plan exposes section and generation lock controls', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(700, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var selected = -1;
    var duplicated = -1;
    var moved = (0, 0);
    var repeated = (0, 0);
    var locked = ('', false);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SongPlanSheet(
              sections: [
                Section(id: 'a', name: 'Intro'),
                Section(id: 'b', name: 'Hook'),
              ],
              activeIndex: 0,
              locks: const {'melody': true},
              onSelect: (i) => selected = i,
              onDuplicate: (i) => duplicated = i,
              onMove: (i, direction) => moved = (i, direction),
              onRepeats: (i, repeats) => repeated = (i, repeats),
              onLock: (track, value) => locked = (track, value),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hook'));
    await tester.tap(find.byTooltip('복제').first);
    await tester.tap(find.byTooltip('오른쪽으로 이동').first);
    await tester.tap(find.text('베이스'));
    expect(selected, 1);
    expect(duplicated, 0);
    expect(moved, (0, 1));
    expect(repeated, (0, 0));
    expect(locked, ('bass', true));
    expect(tester.takeException(), isNull);
  });
}
