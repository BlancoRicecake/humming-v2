// Announcements UI (2026-10-30): one home banner (no popup storm), the
// critical popup only on a safe home (nothing above it, app in front), once
// per run, "Got it" vs "Later", the list with read items, safe link button,
// and layouts at 320 px with large text, phone landscape and desktop.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/announcements/announcement.dart';
import 'package:humming/looptap/announcements/announcement_service.dart';
import 'package:humming/looptap/announcements/announcement_widgets.dart';
import 'package:humming/looptap/screens/songs_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:provider/provider.dart';

import '../support/announcement_fixtures.dart';
import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  @override
  bool get loaded => true;
}

void main() {
  late Directory root;
  late FakeFeed feed;
  late AnnouncementService service;
  var now = kFixtureNow;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_ann_ui_');
    LoopStorage.rootOverride = root;
    feed = FakeFeed();
    now = kFixtureNow;
    service = AnnouncementService(
      fetch: feed.call,
      platform: AnnouncementPlatform.windows,
      build: 43,
      buildKnown: true,
      now: () => now,
    );
  });
  tearDown(() async {
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 10));
    }
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> home(
    WidgetTester tester, {
    String lang = 'en',
    Size size = const Size(1000, 700),
    double text = 1.0,
  }) async {
    useOfflineTestFonts();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(textScaler: TextScaler.linear(text)),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            children: [AnnouncementHomeBanner(service: service), const Spacer()],
          ),
        ),
      ),
    );
    await settle(tester, () => feed.calls > 0 && !service.busy);
  }

  /// A refresh, waited for while frames keep running (never awaited directly:
  /// its file IO runs in the test's fake-async zone).
  Future<void> refreshed(WidgetTester tester) async {
    service.refresh(force: true);
    await settle(tester, () => !service.busy);
  }

  final critical = find.byKey(const ValueKey('ann-critical'));

  testWidgets('a critical feed received in background shows on resume even when refresh is throttled', (tester) async {
    await home(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    feed.rows = [annRow('background-outage', kind: 'critical')];
    await refreshed(tester);
    expect(critical, findsNothing);
    final calls = feed.calls;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester, () => critical.evaluate().isNotEmpty);
    expect(feed.calls, calls, reason: 'resume is within the refresh interval');
    expect(critical, findsOneWidget);
  });

  testWidgets('an expired banner disappears while home stays open offline', (tester) async {
    feed.rows = [annRow('short-lived', endsAt: now.add(const Duration(seconds: 5)))];
    await home(tester);
    expect(find.byKey(const ValueKey('ann-home-banner')), findsOneWidget);
    feed.fail = true;
    now = now.add(const Duration(seconds: 6));
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(find.byKey(const ValueKey('ann-home-banner')), findsNothing);
  });

  testWidgets('several announcements: one banner with a count, no popup for info / important', (tester) async {
    feed.rows = [annRow('a', kind: 'important'), annRow('b'), annRow('c')];
    await home(tester);
    expect(find.byKey(const ValueKey('ann-home-banner')), findsOneWidget);
    expect(find.textContaining('Important · Title a'), findsOneWidget);
    expect(find.text('See all (3)'), findsOneWidget);
    expect(critical, findsNothing);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('critical: shown once on a safe home; "Got it" stores it; not again', (tester) async {
    feed.rows = [annRow('outage', kind: 'critical', titleEn: 'Service outage'), annRow('news')];
    await home(tester);
    expect(critical, findsOneWidget);
    expect(find.text('Service outage'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('ann-critical-confirm')));
    await settle(tester, () => critical.evaluate().isEmpty);
    expect(critical, findsNothing);
    final a = service.visible.firstWhere((x) => x.id == 'outage');
    expect(service.isAcknowledged(a), isTrue);
    await refreshed(tester); // a later rebuild with the same feed
    expect(critical, findsNothing);
  });

  testWidgets('"Later" closes it without confirming, and not again in this run', (tester) async {
    feed.rows = [annRow('outage', kind: 'critical')];
    await home(tester);
    await tester.tap(find.byKey(const ValueKey('ann-critical-later')));
    await settle(tester, () => critical.evaluate().isEmpty);
    final a = service.visible.single;
    expect(service.isAcknowledged(a), isFalse);
    expect(service.isRead(a), isTrue);
    await refreshed(tester);
    expect(critical, findsNothing, reason: 'once per run');
  });

  testWidgets('nothing pops up while another screen is on top; it waits for home', (tester) async {
    feed.hold = null;
    feed.rows = [];
    await home(tester);
    // the user opens something (an editor / sheet stands in) …
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('editing'))));
    await tester.pumpAndSettle();
    // … and a critical announcement arrives meanwhile
    feed.rows = [annRow('outage', kind: 'critical')];
    await refreshed(tester);
    expect(critical, findsNothing, reason: 'never over the editor');
    nav.pop();
    await settle(tester, () => critical.evaluate().isNotEmpty);
    expect(critical, findsOneWidget, reason: 'shown back on the home screen');
  });

  testWidgets('the list keeps read items; detail scrolls; only a vetted link is a button', (tester) async {
    feed.rows = [
      annRow('safe', actionUrl: 'https://hum-track.com/status', bodyEn: 'Long text. ' * 350),
      annRow('unsafe', actionUrl: 'file:///C:/Windows'),
    ];
    await home(tester);
    await tester.tap(find.byKey(const ValueKey('ann-home-all')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ann-item-safe')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('ann-item-safe')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ann-action')), findsNothing, reason: 'below the fold');
    await tester.scrollUntilVisible(find.byKey(const ValueKey('ann-action')), 400,
        scrollable: find.descendant(of: find.byKey(const ValueKey('ann-detail')), matching: find.byType(Scrollable)).first);
    expect(find.text('Open'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ann-item-safe')), findsOneWidget, reason: 'read items stay listed');
    await tester.tap(find.byKey(const ValueKey('ann-item-unsafe')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ann-action')), findsNothing);
  });

  for (final c in [
    (const Size(320, 640), 'en', 1.5),
    (const Size(320, 640), 'ko', 2.0),
    (const Size(740, 360), 'ko', 1.3), // phone landscape
    (const Size(960, 700), 'en', 1.0),
  ]) {
    testWidgets('fits ${c.$1.width.toInt()}x${c.$1.height.toInt()} ${c.$2} x${c.$3}', (tester) async {
      final long = 'A long announcement title that goes on and on · 아주 긴 공지 제목입니다';
      feed.rows = [
        annRow('outage', kind: 'critical', titleEn: long, titleKo: long, bodyEn: 'Details. ' * 300, bodyKo: '자세한 내용. ' * 300, actionUrl: 'https://hum-track.com/s'),
        annRow('news', titleEn: long, titleKo: long),
      ];
      await home(tester, lang: c.$2, size: c.$1, text: c.$3);
      expect(critical, findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'dialog fits');
      final confirm = find.byKey(const ValueKey('ann-critical-confirm'));
      final r = tester.getRect(confirm);
      expect(r.right <= c.$1.width && r.bottom <= c.$1.height, isTrue, reason: 'confirm reachable: $r');
      await tester.tap(find.byKey(const ValueKey('ann-critical-later')));
      await settle(tester, () => critical.evaluate().isEmpty);
      expect(tester.takeException(), isNull, reason: 'banner fits');
      await tester.tap(find.byKey(const ValueKey('ann-home-link')).evaluate().isNotEmpty
          ? find.byKey(const ValueKey('ann-home-link'))
          : find.byKey(const ValueKey('ann-home-all')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'list fits');
      await tester.tap(find.byKey(const ValueKey('ann-item-outage')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'detail fits');
      await tester.scrollUntilVisible(find.byKey(const ValueKey('ann-action')), 300,
          scrollable: find.descendant(of: find.byKey(const ValueKey('ann-detail')), matching: find.byType(Scrollable)).first);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the real song list shows the banner and keeps its other notices', (tester) async {
    feed.rows = [annRow('news', kind: 'important', titleEn: 'New version notes')];
    AnnouncementService.instance = service;
    addTearDown(() => AnnouncementService.instance = AnnouncementService(fetch: () async => null));
    useOfflineTestFonts();
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: _Store(),
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const SongsScreen(),
        ),
      ),
    );
    await settle(tester, () => find.byKey(const ValueKey('ann-home-banner')).evaluate().isNotEmpty);
    expect(find.textContaining('New version notes'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
