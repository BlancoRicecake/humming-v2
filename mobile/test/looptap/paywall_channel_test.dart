// The direct-download Mac build has no store channel: the paywall must not show
// prices or purchase/restore UI, only account Pro guidance. StoreKit builds
// (iOS here) keep the full purchase flow.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/sheets/paywall_sheet.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  _Store({required this.signedIn});
  final bool signedIn;
  @override
  bool get iapEnabled => false;
  @override
  bool get isSignedIn => signedIn;
  @override
  Future<void> loadProducts() async {}
}

Future<void> _open(WidgetTester tester, _Store store) async {
  useOfflineTestFonts();
  await tester.binding.setSurfaceSize(const Size(900, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(store.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<LoopStore>.value(
    value: store,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              showPaywallSheet(context, trigger: PaywallTrigger.export),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void _expectNoStoreUi(L10n l) {
  expect(find.byKey(const ValueKey('restore-purchases')), findsNothing);
  expect(find.text(l.payRestore), findsNothing);
  expect(find.text(l.paySubscribe), findsNothing);
  expect(find.text(l.payPlanYearly), findsNothing);
  expect(find.text(l.payPlanMonthly), findsNothing);
  expect(find.text(l.payStoreUnavailable), findsNothing);
}

void main() {
  final l = lookupL10n(const Locale('en'));

  testWidgets('direct Mac build: account guidance and sign-in, no store UI',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _open(tester, _Store(signedIn: false));
      expect(find.byKey(const ValueKey('paywall-account-pro-only')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('paywall-sign-in')), findsOneWidget);
      _expectNoStoreUi(l);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('direct Mac build, signed in: guidance only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _open(tester, _Store(signedIn: true));
      expect(find.byKey(const ValueKey('paywall-account-pro-only')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('paywall-sign-in')), findsNothing);
      _expectNoStoreUi(l);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('iOS keeps the store purchase flow', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await _open(tester, _Store(signedIn: true));
      expect(find.byKey(const ValueKey('paywall-account-pro-only')),
          findsNothing);
      expect(find.byKey(const ValueKey('restore-purchases')), findsOneWidget);
      expect(find.text(l.paySubscribe), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
