import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/screens/songs_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/theme/tokens.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';
import 'package:humming/looptap/widgets/sheets/instrument_sheet.dart';
import 'package:humming/looptap/widgets/sheets/settings_sheet.dart';
import 'package:humming/looptap/widgets/transport_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/desktop_section_band.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  @override
  bool get loaded => true;
  @override
  Future<void> upsert(Song song) async {}
  @override
  Future<void> sweepVocals() async {}
}

void main() {
  late Directory root;
  late _Store store;
  setUp(() async {
    useOfflineTestFonts();
    root = await Directory.systemTemp.createTemp('humtrack_uiux_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    store = _Store();
    EditScreen.debugDesktopOverride = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
  });
  tearDown(() async {
    EditScreen.debugDesktopOverride = null;
    store.dispose();
    LoopStorage.rootOverride = null;
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    final resolved = await root.resolveSymbolicLinks();
    if (!resolved.startsWith(
      '$parent${Platform.pathSeparator}humtrack_uiux_',
    )) {
      throw StateError('Unexpected test cleanup path');
    }
    await root.delete(recursive: true);
  });

  Future<void> host(
    WidgetTester tester,
    Widget child,
    String lang,
    double scale,
    Size size,
  ) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          theme: loopTapTheme(platform: TargetPlatform.android),
          locale: Locale(lang),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          builder:
              (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
          home: Scaffold(body: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop Tab traverses buttons and Space activates the focused control',
    (tester) async {
      var actions = 0;
      var plays = 0;
      await host(
        tester,
        DesktopCommands(
          enabled: true,
          play: () => plays++,
          record: () {},
          save: () {},
          undo: () {},
          redo: () {},
          child: Column(
            children: [
              TextButton(
                onPressed: () => actions++,
                child: const Text('Action'),
              ),
              TextButton(onPressed: () {}, child: const Text('Next')),
            ],
          ),
        ),
        'en',
        1,
        const Size(1280, 720),
      );
      Focus.of(tester.element(find.text('Action'))).requestFocus();
      await tester.pump();
      final before = FocusManager.instance.primaryFocus;
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      expect(actions, 1);
      expect(plays, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, isNot(same(before)));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(FocusManager.instance.primaryFocus, same(before));
    },
  );

  testWidgets(
    'desktop section band supports keyboard menu, rename and 28px targets',
    (tester) async {
      var menus = 0;
      await host(
        tester,
        Align(
          alignment: Alignment.topCenter,
          child: DesktopSectionBand(
            sections: [Section(id: 'keyboard-section', name: 'Verse')],
            activeIdx: 0,
            songMode: false,
            onSwitch: (_) {},
            onAdd: () {},
            onRename: (_, _) {},
            onRepeats: (_, _) {},
            onMenu: (_) => menus++,
            onPlaySong: () {},
          ),
        ),
        'en',
        2,
        const Size(1280, 720),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('desktop-section-band')))
            .height,
        28,
      );
      Focus.of(tester.element(find.text('Verse'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
      expect(menus, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f10);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(menus, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.f2);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final lang in ['ko', 'en']) {
    for (final scale in [1.0, 1.5, 2.0]) {
      for (final size in [const Size(320, 640), const Size(844, 390)]) {
        testWidgets(
          'guided $lang ${scale}x $size keeps choices and retake reachable',
          (tester) async {
            for (final ready in [false, true]) {
              await host(
                tester,
                GuidedHumPanel(
                  hasNotes: ready,
                  hasMelody: true,
                  playing: false,
                  onBack: () {},
                  onRecord: () {},
                  onListen: () {},
                  onInstrument: () {},
                  onEdit: () {},
                  onKey: () {},
                  onPlayTake: () {},
                  onRecordVocal: () {},
                  onSample: () {},
                  instrumentName: 'Grand piano',
                  keyLabel: 'C major',
                ),
                lang,
                scale,
                size,
              );
              expect(tester.takeException(), isNull);
              final action = find.byKey(
                ValueKey(ready ? 'guided-retake' : 'guided-choice-hum'),
              );
              final target =
                  ready
                      ? action
                      : find
                          .descendant(of: action, matching: find.byType(Text))
                          .first;
              await tester.ensureVisible(target);
              await tester.pumpAndSettle();
              expect(target.hitTestable(), findsOneWidget);
              expect(tester.takeException(), isNull);
              if (ready) {
                expect(
                  find.byKey(const ValueKey('guided-make-song')).hitTestable(),
                  findsOneWidget,
                );
              }
            }
          },
        );
      }

      testWidgets(
        'transport $lang ${scale}x has named 48px actions and keyboard activation',
        (tester) async {
          var calls = 0;
          final semantics = tester.ensureSemantics();
          try {
            Widget bar({bool active = false}) => TransportBar(
              playing: active,
              recording: active,
              onPlay: () => calls++,
              onStop: () {},
              onRec: () {},
              bpm: 120,
              onBpm: (_) {},
              metro: false,
              onMetro: (_) {},
              countIn: false,
              onCountIn: (_) {},
              onClear: () {},
              swing: 0,
              onSwing: (_) {},
              bars: 2,
              onBars: (_) {},
              onLoop: () {},
            );
            await host(tester, bar(), lang, scale, const Size(320, 640));
            final play = find.byKey(const ValueKey('transport-play'));
            final record = find.byKey(const ValueKey('transport-record'));
            for (final action in [play, record]) {
              final rect = tester.getRect(action);
              expect(rect.width, greaterThanOrEqualTo(48));
              expect(rect.height, greaterThanOrEqualTo(48));
              final data = tester.getSemantics(action).getSemanticsData();
              expect(data.flagsCollection.isButton, isTrue);
              expect(data.label, isNotEmpty);
            }
            final context = tester.element(
              find.descendant(of: play, matching: find.byType(Icon)).first,
            );
            Focus.of(context).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            expect(calls, 1);
            await host(
              tester,
              bar(active: true),
              lang,
              scale,
              const Size(320, 640),
            );
            expect(
              tester.getSemantics(play).getSemanticsData().label,
              lang == 'ko' ? '일시정지' : 'Pause',
            );
            expect(
              tester
                  .getSemantics(record)
                  .getSemanticsData()
                  .flagsCollection
                  .isToggled,
              Tristate.isTrue,
            );
            expect(
              tester.getSemantics(record).getSemanticsData().label,
              lang == 'ko' ? '녹음 종료' : 'Stop recording',
            );
            final settings = find.byKey(const ValueKey('transport-settings'));
            expect(
              tester.getSemantics(settings).getSemanticsData().label,
              contains(lang == 'ko' ? '재생 설정' : 'Playback settings'),
            );
            await tester.tap(settings);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.ensureVisible(
              find.byKey(const ValueKey('transport-loop-options')),
            );
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            semantics.dispose();
          }
        },
      );

      testWidgets('settings and instruments $lang ${scale}x stay scrollable', (
        tester,
      ) async {
        await host(
          tester,
          Builder(
            builder:
                (context) => Column(
                  children: [
                    TextButton(
                      onPressed: () => showSettingsSheet(context),
                      child: const Text('settings'),
                    ),
                    TextButton(
                      onPressed:
                          () => showInstrumentSheet(
                            context,
                            trackId: 'melody',
                            trackLabel: 'Melody',
                            currentProgram: 0,
                            onPick: (_) {},
                          ),
                      child: const Text('instruments'),
                    ),
                  ],
                ),
          ),
          lang,
          scale,
          const Size(320, 640),
        );
        await tester.tap(find.text('settings'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-open-backup')),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        Navigator.of(
          tester.element(find.byKey(const ValueKey('settings-open-backup'))),
        ).pop();
        await tester.pumpAndSettle();
        await tester.tap(find.text('instruments'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      testWidgets(
        'home and phone editor $lang ${scale}x preserve enlarged text and save access',
        (tester) async {
          await host(
            tester,
            const SongsScreen(),
            lang,
            scale,
            const Size(844, 390),
          );
          expect(tester.takeException(), isNull);
          await host(
            tester,
            EditScreen(song: store.createNew()),
            lang,
            scale,
            const Size(844, 390),
          );
          expect(tester.takeException(), isNull);
          final title = find.byKey(const ValueKey('phone-song-title'));
          expect(
            MediaQuery.textScalerOf(tester.element(title)).scale(14),
            14 * scale,
          );
          final more = find.byKey(const ValueKey('phone-editor-more'));
          if (more.evaluate().isNotEmpty) {
            await tester.tap(more);
            await tester.pumpAndSettle();
          }
          final saveLabel = lang == 'ko' ? '저장' : 'Save';
          expect(
            find.text(saveLabel).evaluate().isNotEmpty ||
                find.byTooltip(saveLabel).evaluate().isNotEmpty,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
