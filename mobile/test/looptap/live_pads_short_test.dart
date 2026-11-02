// Phone landscape with a small pad area (device, 2026-11-02): the note pads
// were ~30 px tall and every label overflowed by ~4 px. A short pad keeps the
// note name only and never overflows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/surfaces/live_pads.dart';

import '../support/offline_fonts.dart';

void main() {
  for (final h in [24.0, 30.0, 40.0, 60.0, 120.0]) {
    testWidgets('pads ${h.toInt()} px tall: no overflow', (tester) async {
      useOfflineTestFonts();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 760,
                height: h,
                child: NotePads(
                  ladder: buildLadder('C', 'minor', 4, 14),
                  visibleCount: 9,
                  offset: 0,
                  litMidis: const {},
                  accent: Colors.lime,
                  onDown: (_) {},
                  onUp: (_) {},
                  onSlideStart: (_) {},
                  onOffsetChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('C'), findsWidgets);
      // the degree line only where there is room for it
      expect(find.text(L10n.of(tester.element(find.byType(NotePads))).ltPadsDegree(1)),
          h >= 48 ? findsWidgets : findsNothing);
    });
  }
}
