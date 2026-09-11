import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/widgets/policy_notice.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('lt_notice_');
    LoopPrefs.rootOverride = root;
    LoopPrefs.instance.acknowledgedPolicyNotice.value = null;
  });

  tearDown(() async {
    LoopPrefs.rootOverride = null;
    LoopPrefs.instance.acknowledgedPolicyNotice.value = null;
    final resolved = await root.resolveSymbolicLinks();
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    if (!resolved.startsWith('$temp${Platform.pathSeparator}lt_notice_')) {
      throw StateError('Unexpected test cleanup path');
    }
    await root.delete(recursive: true);
  });

  Widget app(String locale) => MaterialApp(
    theme: ThemeData.dark(),
    locale: Locale(locale),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Scaffold(
      body: Column(
        children: [
          const PolicyNoticeBanner(),
          Builder(
            builder:
                (context) => TextButton(
                  onPressed: () => showPolicyNotice(context),
                  child: const Text('Reopen notice'),
                ),
          ),
        ],
      ),
    ),
  );

  for (final locale in ['ko', 'en']) {
    testWidgets(
      '$locale notice fits landscape, closes without acknowledgement, persists read state',
      (tester) async {
        tester.view.physicalSize = const Size(640, 360);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(app(locale));
        await tester.pumpAndSettle();
        final l = await L10n.delegate.load(Locale(locale));
        expect(find.text(l.policyNoticeRead), findsOneWidget);

        await tester.tap(find.text(l.policyNoticeRead));
        await tester.pumpAndSettle();
        expect(find.text(l.policyNoticeBody), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.text(l.close));
        await tester.pumpAndSettle();
        expect(find.text(l.policyNoticeRead), findsOneWidget);

        await tester.tap(find.text(l.policyNoticeRead));
        await tester.pumpAndSettle();
        // All three bundled documents remain available, including offline.
        expect(find.text(l.termsTitle), findsOneWidget);
        expect(find.text(l.privacyTitle), findsOneWidget);
        expect(find.text(l.refundScreenTitle), findsOneWidget);
        await tester.runAsync(() async {
          await tester.tap(find.text(l.policyNoticeAcknowledge));
          // Wait for the preference write initiated by the button.
          for (var i = 0; i < 50; i++) {
            final file = File('${root.path}/looptap/prefs.json');
            if (await file.exists()) {
              try {
                final saved = jsonDecode(await file.readAsString()) as Map;
                if (saved['acknowledgedPolicyNotice'] == policyNoticeId) return;
              } on FormatException {
                /* write still in flight */
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          fail('Notice acknowledgement was not saved');
        });
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text(l.policyNoticeRead), findsNothing);
        await tester.tap(find.text('Reopen notice'));
        await tester.pumpAndSettle();
        expect(find.text(l.policyNoticeBody), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
