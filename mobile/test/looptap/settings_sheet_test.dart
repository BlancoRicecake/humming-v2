// Settings sheet: every row is localized, and rows that open a screen point
// forward (chevron), not back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/theme/atoms.dart';
import 'package:humming/looptap/widgets/sheets/settings_sheet.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

Future<void> _openSettings(WidgetTester tester, String lang) async {
  useOfflineTestFonts();
  await tester.binding.setSurfaceSize(const Size(800, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final store = LoopStore();
  addTearDown(store.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<LoopStore>.value(
    value: store,
    child: MaterialApp(
      locale: Locale(lang),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showSettingsSheet(context),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Korean settings show the vocal sync row in Korean', (tester) async {
    await _openSettings(tester, 'ko');
    expect(find.text('보컬 싱크'), findsOneWidget);
    expect(find.text('Vocal sync'), findsNothing);
  });

  testWidgets('navigation rows use a forward chevron, never a back arrow',
      (tester) async {
    await _openSettings(tester, 'en');
    expect(find.text('Vocal sync'), findsOneWidget);
    expect(find.byIcon(LtIcons.chevronRight), findsWidgets);
    expect(find.byIcon(LtIcons.arrowBack), findsNothing);
  });
}
