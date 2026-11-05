import 'dart:io';
import 'dart:ui' show ViewFocusEvent, ViewFocusState, ViewFocusDirection;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/widgets/desktop_instrument.dart';
import 'package:humming/looptap/state/loop_prefs.dart';

void main() {
  testWidgets(
    'window blur releases notes and return resumes keys without repeats or modifier chords',
    (tester) async {
      LoopPrefs.instance.keyboardBindings.value = {};
      var hits = 0, releases = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DesktopInstrument(
              group: 'piano',
              identity: 'melody',
              labels: const ['C', 'D'],
              onDown: (_) {
                hits++;
                return () => releases++;
              },
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
      expect(hits, 1);
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.unfocused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      expect(releases, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      expect(hits, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
      tester.binding.handleViewFocusChanged(
        ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ViewFocusState.focused,
          direction: ViewFocusDirection.undefined,
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(hits, 2);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(hits, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(
        hits,
        2,
        reason: 'Disposed instruments remove their hardware handler',
      );
    },
  );
  testWidgets('a sibling modal blocks notes and closing it restores playing', (
    tester,
  ) async {
    LoopPrefs.instance.keyboardBindings.value = {};
    var hits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Builder(
                builder:
                    (context) => TextButton(
                      onPressed:
                          () => showDialog<void>(
                            context: context,
                            builder:
                                (context) => AlertDialog(
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('Close'),
                                    ),
                                  ],
                                ),
                          ),
                      child: const Text('Dialog'),
                    ),
              ),
              Expanded(
                child: DesktopInstrument(
                  group: 'piano',
                  identity: 'melody',
                  labels: const ['C'],
                  onDown: (_) {
                    hits++;
                    return () {};
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Dialog'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(hits, 0);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(hits, 1);
  });
  testWidgets('toolbar focus does not disable instrument keys or steal focus', (
    tester,
  ) async {
    LoopPrefs.instance.keyboardBindings.value = {};
    final toolbar = FocusNode();
    addTearDown(toolbar.dispose);
    var hits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextButton(
                focusNode: toolbar,
                onPressed: () {},
                child: const Text('Transport'),
              ),
              const TextField(),
              Expanded(
                child: DesktopInstrument(
                  group: 'piano',
                  identity: 'melody',
                  labels: const ['C'],
                  onDown: (_) {
                    hits++;
                    return () {};
                  },
                  child: const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(hits, 1);
    toolbar.requestFocus();
    await tester.pump();
    expect(toolbar.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(hits, 2, reason: 'A non-text toolbar must not disable playing');
    expect(
      toolbar.hasPrimaryFocus,
      isTrue,
      reason: 'Keep keyboard accessibility on the toolbar',
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(hits, 2, reason: 'Text input must never trigger the instrument');
    toolbar.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(
      hits,
      3,
      reason: 'Leaving text input must restore playing without a pad click',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('invalid mappings fall back; valid custom keys survive decoding', () {
    expect(instrumentKeys('piano', [1]), pianoKeys);
    expect(instrumentKeys('drums', List.filled(6, 0x70004)), drumKeys);
    final custom = pianoKeys.map((k) => k.usbHidUsage).toList();
    custom[0] = PhysicalKeyboardKey.keyQ.usbHidUsage;
    expect(instrumentKeys('piano', custom).first, PhysicalKeyboardKey.keyQ);
  });
  testWidgets('chords, repeats, keyup, context change and text input', (
    tester,
  ) async {
    final down = <int>[];
    final up = <int>[];
    var identity = 'melody';
    late StateSetter refresh;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, update) {
            refresh = update;
            return Scaffold(
              body: Column(
                children: [
                  const TextField(),
                  Expanded(
                    child: DesktopInstrument(
                      group: 'piano',
                      identity: identity,
                      labels: const ['C', 'D', 'E'],
                      onDown: (i) {
                        down.add(i);
                        return () => up.add(i);
                      },
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    expect(down, [0, 1]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(up, [0]);
    refresh(() => identity = 'bass');
    await tester.pump();
    expect(up, [0, 1]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyD);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(up, [0, 1, 2]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyD);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(down, [0, 1, 2]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('custom key and dialog isolation', (tester) async {
    final custom = pianoKeys.map((k) => k.usbHidUsage).toList();
    custom[0] = PhysicalKeyboardKey.keyQ.usbHidUsage;
    LoopPrefs.instance.keyboardBindings.value = {'piano': custom};
    var hits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopInstrument(
            group: 'piano',
            identity: 'a',
            labels: const ['C'],
            onDown: (_) {
              hits++;
              return () {};
            },
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    expect(hits, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    expect(hits, 1);
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    expect(hits, 1);
    expect(find.text('Instrument keys'), findsOneWidget);
    final temp =
        (await tester.runAsync(
          () => Directory.systemTemp.createTemp('humtrack-keys-'),
        ))!;
    LoopPrefs.rootOverride = temp;
    try {
      await tester.tap(find.text('1: Q'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.pump();
      expect(find.text('This key is already assigned.'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        // Finish the settings write before checking a fresh decode.
        await LoopPrefs.instance.setKeyboardBindings(
          'piano',
          LoopPrefs.instance.keyboardBindings.value['piano']!,
        );
        final saved =
            jsonDecode(
                  await File('${temp.path}/looptap/prefs.json').readAsString(),
                )
                as Map;
        expect(
          instrumentKeys(
            'piano',
            List<int>.from(saved['keyboardBindings']['piano']),
          ).first,
          PhysicalKeyboardKey.keyW,
        );
      });
    } finally {
      LoopPrefs.rootOverride = null;
      await tester.runAsync(() => temp.delete(recursive: true));
      LoopPrefs.instance.keyboardBindings.value = {};
    }
  });
}
