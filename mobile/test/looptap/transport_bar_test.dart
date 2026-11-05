import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/widgets/transport_bar.dart';

import '../support/offline_fonts.dart';

Widget _host({required ValueChanged<int> onBpm, bool showBar = true}) {
  return MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    // Ahem (test font) glyphs are a full em wide; shrink text so the fixed
    // 58px BPM readout doesn't report a layout overflow.
    builder:
        (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
    home: Scaffold(
      body:
          showBar
              ? TransportBar(
                playing: false,
                recording: false,
                onPlay: () {},
                onStop: () {},
                onRec: () {},
                bpm: 120,
                onBpm: onBpm,
                metro: false,
                onMetro: (_) {},
                countIn: false,
                onCountIn: (_) {},
                onClear: () {},
                swing: 0,
                onSwing: (_) {},
                bars: 2,
                onBars: (_) {},
              )
              : const SizedBox(),
    ),
  );
}

void main() {
  setUpAll(useOfflineTestFonts);

  testWidgets('a second finger on +/- cannot orphan the hold auto-repeat', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final steps = <int>[];
    await tester.pumpWidget(_host(onBpm: steps.add));
    await tester.pumpAndSettle();

    final plus = tester.getCenter(find.text('+'));
    final g1 = await tester.startGesture(plus, pointer: 1);
    expect(steps, [121]);
    final g2 = await tester.startGesture(plus, pointer: 2);
    expect(steps, [121], reason: 'extra finger is ignored while held');
    await tester.pump(const Duration(seconds: 1)); // auto-repeat running
    expect(steps.length, greaterThan(1));
    await g2.up(); // the non-owning finger does not end the hold
    await g1.up();
    final afterRelease = steps.length;
    await tester.pump(const Duration(seconds: 5));
    expect(
      steps.length,
      afterRelease,
      reason: 'no orphaned timer keeps stepping after release',
    );
  });

  testWidgets('direct BPM entry applies the typed value', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final steps = <int>[];
    await tester.pumpWidget(_host(onBpm: steps.add));
    await tester.pumpAndSettle();

    await tester.tap(find.text('120'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '150');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(steps, [150]);
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
