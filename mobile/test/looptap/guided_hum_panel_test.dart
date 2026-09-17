import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';

void main() {
  testWidgets('first step records; converted step listens and saves', (tester) async {
    var recorded = 0, listened = 0, saved = 0, edited = 0;
    Future<void> show(bool hasNotes) => tester.pumpWidget(MaterialApp(
      locale: const Locale('ko'), localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: GuidedHumPanel(hasNotes: hasNotes, playing: false,
        saved: false, onBack: () {}, onRecord: () => recorded++,
        onListen: () => listened++, onSave: () => saved++,
        onInstrument: () {}, onEdit: () => edited++))));
    await show(false); await tester.pumpAndSettle();
    expect(find.text('내 곡 저장'), findsNothing);
    await tester.tap(find.text('멜로디 녹음하기'));
    expect(recorded, 1);
    await show(true); await tester.pumpAndSettle();
    await tester.tap(find.text('내 멜로디 듣기'));
    await tester.tap(find.text('내 곡 저장'));
    await tester.tap(find.text('직접 편집하기'));
    expect([listened, saved, edited], [1, 1, 1]);
    expect(tester.takeException(), isNull);
  });
}
