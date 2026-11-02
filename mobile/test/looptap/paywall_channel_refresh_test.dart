// 2026-11-03 integration: the paywall / account sheet keep develop's store
// channel split (hasStorePurchases) and add the server Pro check where there
// is no store. Run twice — plain, and with
// --dart-define=HUMTRACK_MAC_APP_STORE=true — so both Mac channels are seen.
//   no store (Windows, Linux, Mac direct): account-Pro text; signed out →
//     sign in; signed in → "Check account Pro status" (one request at a time)
//   store (Android, iOS, Mac App Store): restore + plans, no server check
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/app.dart' show rootMessengerKey;
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/sheets/account_sheet.dart';
import 'package:humming/looptap/widgets/sheets/paywall_sheet.dart';
import 'package:humming/services/iap_types.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  _Store({required this.signedIn});
  final bool signedIn;
  int refreshes = 0;
  Completer<bool>? pending;

  @override
  bool get iapEnabled => false;
  @override
  bool get isSignedIn => signedIn;
  @override
  Map<String, String>? get user =>
      signedIn ? const {'name': 'Tester', 'email': 't@example.com', 'provider': 'google'} : null;
  @override
  Future<void> loadProducts() async {}
  @override
  Future<bool> refreshSubscription() {
    refreshes++;
    return (pending = Completer<bool>()).future;
  }
}

Future<void> _pump(WidgetTester tester, _Store store, void Function(BuildContext) open) async {
  useOfflineTestFonts();
  await tester.binding.setSurfaceSize(const Size(900, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(store.dispose);
  await tester.pumpWidget(ChangeNotifierProvider<LoopStore>.value(
    value: store,
    child: MaterialApp(
      scaffoldMessengerKey: rootMessengerKey, // the sheets' messages
      locale: const Locale('en'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(onPressed: () => open(context), child: const Text('open')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Future<void> _paywall(WidgetTester tester, _Store store) =>
    _pump(tester, store, (c) => showPaywallSheet(c, trigger: PaywallTrigger.export));

const _restore = ValueKey('restore-purchases');
const _refresh = ValueKey('desktop-refresh-pro');
const _proOnly = ValueKey('paywall-account-pro-only');
const _signIn = ValueKey('paywall-sign-in');

void main() {
  final l = lookupL10n(const Locale('en'));

  test('channel rule: Mac App Store keeps the store, Mac direct has none', () {
    expect(hasStorePurchases(TargetPlatform.macOS, macAppStore: true), isTrue);
    expect(hasStorePurchases(TargetPlatform.macOS, macAppStore: false), isFalse);
    expect(hasStorePurchases(TargetPlatform.windows), isFalse);
    expect(hasStorePurchases(TargetPlatform.linux), isFalse);
    expect(hasStorePurchases(TargetPlatform.android), isTrue);
    expect(hasStorePurchases(TargetPlatform.iOS), isTrue);
  });

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ]) {
    final store = hasStorePurchases(platform);
    final name = platform == TargetPlatform.macOS
        ? 'macOS (${kMacAppStoreBuild ? 'Mac App Store' : 'direct'} build)'
        : platform.name;

    testWidgets('$name paywall, signed in: ${store ? 'restore + plans' : 'server Pro check'}',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final s = _Store(signedIn: true);
        await _paywall(tester, s);
        if (store) {
          expect(find.byKey(_restore), findsOneWidget);
          expect(find.text(l.paySubscribe), findsOneWidget);
          expect(find.byKey(_refresh), findsNothing);
          expect(find.byKey(_proOnly), findsNothing);
        } else {
          expect(find.byKey(_proOnly), findsOneWidget);
          expect(find.byKey(_restore), findsNothing);
          expect(find.text(l.paySubscribe), findsNothing);
          expect(find.byKey(_signIn), findsNothing);
          // one server request at a time; the result is reported
          await tester.tap(find.byKey(_refresh));
          await tester.pump();
          await tester.tap(find.byKey(_refresh), warnIfMissed: false);
          await tester.pump();
          expect(s.refreshes, 1, reason: 'a second tap while busy sends nothing');
          s.pending!.complete(true);
          await tester.pumpAndSettle();
          expect(find.text(l.payRestoreEmpty), findsOneWidget, reason: 'not Pro yet: says so');
          await tester.tap(find.byKey(_refresh));
          await tester.pump();
          expect(s.refreshes, 2, reason: 'usable again afterwards');
          s.pending!.complete(false);
          await tester.pumpAndSettle();
          expect(find.text(l.payRestoreError), findsOneWidget);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('$name paywall, signed out', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await _paywall(tester, _Store(signedIn: false));
        expect(find.byKey(_refresh), findsNothing);
        if (store) {
          expect(find.byKey(_restore), findsOneWidget);
        } else {
          expect(find.byKey(_signIn), findsOneWidget);
          expect(find.byKey(_restore), findsNothing);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('$name account sheet: ${store ? 'restore purchases' : 'check account Pro'}',
        (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await _pump(tester, _Store(signedIn: true), showAccountSheet);
        expect(find.text(l.payRestore), store ? findsOneWidget : findsNothing);
        expect(find.text(l.payDesktopRefresh), store ? findsNothing : findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
