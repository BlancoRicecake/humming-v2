import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';
import 'package:humming/looptap/music/beginner_backing.dart';

void main() {
  testWidgets('first step records; converted step listens and saves', (
    tester,
  ) async {
    var recorded = 0, listened = 0, saved = 0, edited = 0;
    Future<void> show(bool hasNotes) => tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: GuidedHumPanel(
            hasNotes: hasNotes,
            playing: false,
            saved: false,
            onBack: () {},
            onRecord: () => recorded++,
            onListen: () => listened++,
            onSave: () => saved++,
            onInstrument: () {},
            onEdit: () => edited++,
          ),
        ),
      ),
    );
    await show(false);
    await tester.pumpAndSettle();
    expect(find.text('내 곡 저장'), findsNothing);
    await tester.tap(find.text('멜로디 녹음하기'));
    expect(recorded, 1);
    await show(true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 곡 듣기'));
    await tester.tap(find.text('내 곡 저장'));
    await tester.tap(find.text('직접 편집하기'));
    expect([listened, saved, edited], [1, 1, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('converted melody exposes lock, A/B preview and review', (
    tester,
  ) async {
    var raw = 0, corrected = 0, reviewed = 0;
    await tester.binding.setSurfaceSize(const Size(850, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: GuidedHumPanel(
            hasNotes: true,
            playing: false,
            saved: false,
            onBack: () {},
            onRecord: () {},
            onListen: () {},
            onSave: () {},
            onInstrument: () {},
            onEdit: () {},
            lowConfidenceCount: 2,
            melodyLocked: true,
            onPreviewOriginal: () => raw++,
            onPreviewCorrected: () => corrected++,
            onReviewMelody: () => reviewed++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('내 멜로디 잠금'), findsOneWidget);
    for (final label in ['원음정 듣기', '보정음정 듣기', '확인이 필요한 음 2개']) {
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
    }
    expect([raw, corrected, reviewed], [1, 1, 1]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'beginner can complete record, backing, preview, apply and save',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(850, 400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final actions = <String>[];
      var hasNotes = false;
      var saved = false;
      BackingStyle? backing;
      var preview = -1;
      var applied = -1;

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder:
                  (context, setState) => GuidedHumPanel(
                    hasNotes: hasNotes,
                    playing: false,
                    saved: saved,
                    backingStyle: backing,
                    previewCandidate: preview < 0 ? null : preview,
                    appliedCandidate: applied < 0 ? null : applied,
                    onBack: () {},
                    onRecord: () {
                      actions.add('record');
                      setState(() => hasNotes = true);
                    },
                    onListen: () => actions.add('listen'),
                    onInstrument: () {},
                    onSave: () {
                      actions.add('save');
                      setState(() => saved = true);
                    },
                    onEdit: () {},
                    onBacking: (style) {
                      actions.add('backing:${style.name}');
                      setState(() => backing = style);
                    },
                    onPreviewBacking: (candidate) {
                      actions.add('preview:$candidate');
                      setState(() => preview = candidate);
                    },
                    onApplyBacking: (candidate) {
                      actions.add('apply:$candidate');
                      setState(() => applied = candidate);
                    },
                  ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('멜로디 녹음하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('신나게'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('A'));
      await tester.tap(find.byTooltip('미리듣기').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('적용').first);
    await tester.ensureVisible(find.text('내 곡 저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 곡 저장'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 곡 듣기'));

      expect(actions, [
        'record',
        'backing:drive',
        'preview:0',
        'apply:0',
        'save',
        'listen',
      ]);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final lang in ['ko', 'en']) {
    testWidgets(
      '$lang landscape keeps transport visible and backing actionable',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(850, 400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        BackingStyle? chosen;
        var previewed = -1;
        var applied = -1;
        var samples = 0;
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(lang),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: Scaffold(
              body: GuidedHumPanel(
                hasNotes: true,
                playing: false,
                saved: true,
                onBack: () {},
                onRecord: () {},
                onListen: () {},
                onInstrument: () {},
                onSave: () {},
                onEdit: () {},
                onSample: () => samples++,
                onBacking: (s) => chosen = s,
                onPreviewBacking: (i) => previewed = i,
                onApplyBacking: (i) => applied = i,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(lang == 'ko' ? '신나게' : 'Drive'));
        expect(chosen, BackingStyle.drive);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(lang),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: Scaffold(
              body: GuidedHumPanel(
                hasNotes: true,
                playing: false,
                saved: true,
                onBack: () {},
                onRecord: () {},
                onListen: () {},
                onInstrument: () {},
                onSave: () {},
                onEdit: () {},
                onSample: () => samples++,
                backingStyle: BackingStyle.drive,
                onBacking: (s) => chosen = s,
                onPreviewBacking: (i) => previewed = i,
                onApplyBacking: (i) => applied = i,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('A'));
        await tester.tap(
          find.byTooltip(lang == 'ko' ? '미리듣기' : 'Preview').first,
        );
        await tester.tap(find.text(lang == 'ko' ? '적용' : 'Apply').first);
        expect([previewed, applied], [0, 0]);
        await tester.ensureVisible(
          find.text(lang == 'ko' ? '내 소리 추가하기' : 'Add sounds'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(lang == 'ko' ? '내 소리 추가하기' : 'Add sounds'));
        expect(samples, 1);
        expect(
          find.text(lang == 'ko' ? '내 곡 저장' : 'Save my song').hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
