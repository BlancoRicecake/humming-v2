// mixer-001: the Pan slider in the mixer (readout, double-tap / Alt+click
// reset) and the editor's undo/redo of a pan drag and a reset.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/sheets/mixer_sheet.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

void main() {
  group('mixer sheet', () {
    late Map<String, double> pan;
    late List<String> resets;
    late List<(String, double)> moves;

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 460,
              child: MixerSheet(
                tracks: kTracks.take(3).toList(),
                vol: const {},
                mutes: const {},
                onVol: (_, _) {},
                onToggleMute: (_) {},
                pan: pan,
                onPan: (id, p) {
                  moves.add((id, p));
                  pan[id] = p;
                },
                onPanReset: (id) {
                  resets.add(id);
                  pan.remove(id);
                },
              ),
            ),
          ),
        ),
      );
    }

    String label(WidgetTester tester, String id) =>
        tester
            .widget<Text>(find.byKey(ValueKey('mixer-pan-label-$id')))
            .data!;

    setUp(() {
      useOfflineTestFonts();
      pan = {'melody': 0.4, 'bass': -0.23};
      resets = [];
      moves = [];
    });

    testWidgets('readout shows L/C/R and double-tap resets to C', (
      tester,
    ) async {
      await pump(tester);
      expect(label(tester, 'melody'), 'R40');
      expect(label(tester, 'bass'), 'L23');
      expect(label(tester, 'melodyDec'), 'C');
      final knob = find.byKey(const ValueKey('mixer-pan-melody'));
      await tester.tap(knob);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(knob);
      await tester.pumpAndSettle();
      expect(resets, ['melody']);
      expect(moves, isEmpty); // the slider didn't jump on the way
      expect(label(tester, 'melody'), 'C');
    });

    testWidgets('dragging pans live; left = negative', (tester) async {
      await pump(tester);
      await tester.drag(
        find.byKey(const ValueKey('mixer-pan-melodyDec')),
        const Offset(-60, 0),
      );
      await tester.pumpAndSettle();
      expect(moves, isNotEmpty);
      expect(moves.every((m) => m.$1 == 'melodyDec'), isTrue);
      expect(moves.last.$2, lessThan(0));
      expect(label(tester, 'melodyDec'), startsWith('L'));
    });

    testWidgets('Alt+click resets without moving the knob', (tester) async {
      await pump(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.tap(find.byKey(const ValueKey('mixer-pan-bass')));
      await tester.pump(const Duration(milliseconds: 400)); // no double-tap
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(resets, ['bass']);
      expect(moves, isEmpty);
      expect(label(tester, 'bass'), 'C');
    });
  });

  group('editor', () {
    late Directory root;
    setUp(() async {
      useOfflineTestFonts();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'xyz.luan/audioplayers',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
      }
      root = await Directory.systemTemp.createTemp('humtrack_pan_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    testWidgets('one pan drag = one undo; reset = one undo; redo re-applies', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      final store = _Store();
      final song = Song(id: 'p', title: 'Pan', pan: {'drums': -0.5});
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: song),
          ),
        ),
      );
      await tester.pumpAndSettle();
      DesktopCommands commands() =>
          tester.widget<DesktopCommands>(find.byType(DesktopCommands));
      Future<Map<String, double>> saved() async {
        await tester.runAsync(() async => commands().save());
        await tester.pump();
        return store.lastSaved!.pan;
      }

      expect(await saved(), {'drums': -0.5});
      await tester.tap(find.byTooltip('Mixer'));
      await tester.pumpAndSettle();
      final melody = find.byKey(const ValueKey('mixer-pan-melody'));
      final gesture = await tester.startGesture(tester.getCenter(melody));
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      await gesture.up();
      await tester.pumpAndSettle();
      final dragged = (await saved())['melody'];
      expect(dragged, isNotNull);
      expect(dragged!, greaterThan(0));
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('mixer-pan-label-melody')))
            .data,
        'R${(dragged * 100).round()}',
      );

      commands().undo(); // the whole drag is one step
      await tester.pump();
      expect(await saved(), {'drums': -0.5});
      commands().redo();
      await tester.pump();
      expect((await saved())['melody'], dragged);

      // reset drums to C with a double-tap, then undo it in one step
      final drums = find.byKey(const ValueKey('mixer-pan-drums'));
      await tester.ensureVisible(drums);
      await tester.pumpAndSettle();
      await tester.tap(drums);
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(drums);
      await tester.pumpAndSettle();
      expect((await saved()).containsKey('drums'), isFalse);
      commands().undo();
      await tester.pump();
      expect(await saved(), {'melody': dragged, 'drums': -0.5});

      await tester.pumpWidget(const SizedBox.shrink());
      FlutterError.onError = onError;
    });
  });
}
