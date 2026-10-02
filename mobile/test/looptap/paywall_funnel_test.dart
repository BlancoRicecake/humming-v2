import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/offline_fonts.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/sheets/paywall_sheet.dart';
import 'package:humming/services/product_analytics.dart';
import 'package:provider/provider.dart';

class _Sink implements ProductAnalyticsSink {
  final events = <(String, Map<String, Object>)>[];
  @override
  Future<void> track(String name, Map<String, Object> p) async =>
      events.add((name, p));
  @override
  Future<void> initialize() async {}
  @override
  Future<void> reset() async {}
  @override
  Future<void> setCollectionEnabled(bool enabled) async {}
  @override
  Future<void> setContext(Map<String, Object> context) async {}
  @override
  Future<void> setUserId(String? id) async {}
}

class _Store extends LoopStore {
  bool signedIn = true;
  int restoreCalls = 0;
  final result = Completer<RestoreOutcome>();
  @override
  bool get iapEnabled => true;
  @override
  bool get isSignedIn => signedIn;
  @override
  Future<void> loadProducts() async {}
  @override
  Future<RestoreOutcome> restorePurchases({
    Duration timeout = const Duration(seconds: 8),
  }) {
    restoreCalls++;
    return result.future;
  }
}

void main() {
  final sink = _Sink();
  setUpAll(() {
    ProductAnalytics.instance.installSinks([sink]);
  });
  Future<void> open(WidgetTester tester, _Store store) async {
    useOfflineTestFonts();
    sink.events.clear();
    await tester.binding.setSurfaceSize(const Size(900, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    addTearDown(store.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed:
                        () => showPaywallSheet(
                          context,
                          trigger: PaywallTrigger.export,
                        ),
                    child: const Text('Export'),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
  }

  testWidgets('closing without purchase records export origin once', (
    tester,
  ) async {
    await open(tester, _Store());
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    final events = sink.events.where((e) => e.$1 == ProductEvent.paywallClosed);
    expect(events, hasLength(1));
    expect(events.single.$2['outcome'], 'dismissed');
    expect(events.single.$2['entry_source'], 'export');
  });
  for (final outcome in RestoreOutcome.values) {
    testWidgets(
      'restore ${outcome.name} reports terminal result without duplicate taps',
      (tester) async {
        final store = _Store();
        await open(tester, store);
        await tester.tap(find.text('Restore purchases'));
        await tester.pump();
        await tester.tap(find.text('Restore purchases'));
        await tester.pump();
        expect(store.restoreCalls, 1);
        store.result.complete(outcome);
        await tester.pumpAndSettle();
        expect(
          sink.events.where((e) => e.$1 == ProductEvent.restoreStarted),
          hasLength(1),
        );
        expect(
          sink.events
              .singleWhere((e) => e.$1 == ProductEvent.restoreCompleted)
              .$2['outcome'],
          outcome.name,
        );
        if (outcome == RestoreOutcome.restored ||
            outcome == RestoreOutcome.alreadyActive) {
          expect(
            sink.events
                .singleWhere((e) => e.$1 == ProductEvent.paywallClosed)
                .$2['outcome'],
            'restored',
          );
        } else {
          expect(find.text('Restore purchases'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets(
    'restore exception resets busy state and is counted without raw error',
    (tester) async {
      final store = _Store();
      await open(tester, store);
      await tester.tap(find.text('Restore purchases'));
      await tester.pump();
      store.result.completeError(StateError('private-account@example.com'));
      await tester.pumpAndSettle();
      final event = sink.events.singleWhere(
        (e) => e.$1 == ProductEvent.restoreCompleted,
      );
      expect(event.$2['outcome'], 'error');
      expect(event.$2.toString(), isNot(contains('@')));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'canceling restore sign-in records cancellation without billing',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = .9;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = _Store()..signedIn = false;
      await open(tester, store);
      await tester.tap(find.text('Restore purchases'));
      // Parent paywall remains busy while the login sheet is open.
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byTooltip('Close').last);
      await tester.pumpAndSettle();
      expect(store.restoreCalls, 0);
      expect(
        sink.events
            .singleWhere((e) => e.$1 == ProductEvent.restoreCompleted)
            .$2['outcome'],
        'auth_cancelled',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
