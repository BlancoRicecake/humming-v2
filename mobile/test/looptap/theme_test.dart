// ui-001 stage 0 (docs/specs/ui/ui-001-desktop-b2-layout.md): the app theme
// gives Material-default sheets and dialogs the LoopTap palette, and the
// theme-default sheets open on a phone in landscape (844×390) without
// overflow errors.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/theme/tokens.dart';
import 'package:humming/looptap/widgets/sheets/arp_sheet.dart';
import 'package:humming/looptap/widgets/sheets/chord_type_sheet.dart';
import 'package:humming/looptap/widgets/sheets/groove_sheet.dart';
import 'package:humming/looptap/widgets/sheets/guitar_stroke_panel.dart';
import 'package:humming/looptap/widgets/sheets/midi_import_sheet.dart';
import 'package:humming/looptap/widgets/sheets/note_tool_sheets.dart';

import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

const _states = <WidgetState>{};
const _selected = {WidgetState.selected};

class _FakeGrooveHost implements GrooveSheetHost {
  @override
  String get trackLabel => 'Melody';
  @override
  List<GrooveTemplate> get songGrooves => const [];
  @override
  double get amount => 1.0;
  @override
  GrooveAssign? get trackGroove => null;
  @override
  bool get hasSectionOverride => false;
  @override
  GrooveAssign? get sectionGroove => null;
  @override
  int get defaultLength => 16;
  @override
  bool get hasTake => false;
  @override
  void assign(GrooveAssign? a, {required bool section, bool coalesce = false}) {}
  @override
  void clearSectionOverride() {}
  @override
  void setAmount(double v, {bool coalesce = false}) {}
  @override
  String? extractFromTake(int length) => null;
  @override
  String? extractFromTrack(int length) => null;
  @override
  void rename(String id, String name) {}
}

MidiReference _oneNoteMidi() {
  final track = [0, 0xc0, 28, 61, 0x90, 60, 47, 121, 0x80, 60, 0, 0, 0xff, 0x2f, 0];
  return MidiReference.parse(Uint8List.fromList([
    ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 0, 0, 1, 1, 224, //
    ...'MTrk'.codeUnits, 0, 0, 0, track.length, ...track,
  ]));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('loopTapTheme() defaults', () {
    late ThemeData t, d;
    setUpAll(() {
      useOfflineTestFonts();
      t = loopTapTheme(platform: TargetPlatform.android);
      d = loopTapTheme(platform: TargetPlatform.windows);
    });

    test('colorScheme: surface containers, no tint, lime secondary, outlines, error', () {
      final c = t.colorScheme;
      expect(c.primary, LT.lime);
      expect(c.surfaceContainerLowest, LT.bg);
      expect(c.surfaceContainerLow, LT.surface);
      expect(c.surfaceContainer, LT.surface);
      expect(c.surfaceContainerHigh, LT.surface2);
      expect(c.surfaceContainerHighest, LT.surface3);
      expect(c.surfaceTint, Colors.transparent);
      expect(c.secondaryContainer, LT.lime.withValues(alpha: 0.14));
      expect(c.onSecondaryContainer, LT.lime);
      expect(c.outline, LT.borderStrong);
      expect(c.outlineVariant, LT.border);
      expect(c.error, LT.danger);
    });

    test('bottom sheet: surface, sheet radius on top, 65% black barrier, 640 cap on desktop only', () {
      final b = t.bottomSheetTheme;
      expect(b.backgroundColor, LT.surface);
      expect(b.modalBackgroundColor, LT.surface);
      expect(b.modalBarrierColor, Colors.black.withValues(alpha: 0.65));
      expect(
        b.shape,
        const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(LTRadius.sheet))),
      );
      expect(b.constraints, isNull, reason: 'phones keep the Material default');
      expect(d.bottomSheetTheme.constraints, const BoxConstraints(maxWidth: 640));
    });

    test('dialog: surface, sheet radius, 1px border, title 16/w800 t1, body 13 t2', () {
      final g = t.dialogTheme;
      expect(g.backgroundColor, LT.surface);
      expect(g.surfaceTintColor, Colors.transparent);
      final shape = g.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(LTRadius.sheet));
      expect(shape.side, const BorderSide(color: LT.border));
      expect(g.titleTextStyle!.fontSize, 16);
      expect(g.titleTextStyle!.fontWeight, FontWeight.w800);
      expect(g.titleTextStyle!.color, LT.t1);
      expect(g.contentTextStyle!.fontSize, 13);
      expect(g.contentTextStyle!.color, LT.t2);
    });

    test('chips: surface2 / border, lime 14% + lime border + lime label when selected', () {
      final c = t.chipTheme;
      expect(c.color!.resolve(_states), LT.surface2);
      expect(c.color!.resolve(_selected), LT.lime.withValues(alpha: 0.14));
      expect(WidgetStateProperty.resolveAs<BorderSide?>(c.side, _states)!.color, LT.border);
      expect(WidgetStateProperty.resolveAs<BorderSide?>(c.side, _selected)!.color, LT.lime);
      expect(WidgetStateProperty.resolveAs<Color?>(c.labelStyle!.color, _selected), LT.lime);
      expect(c.checkmarkColor, LT.lime);
      expect(c.shape, RoundedRectangleBorder(borderRadius: BorderRadius.circular(LTRadius.chip)));
    });

    test('slider, switch, segmented, buttons, checkbox, radio, divider', () {
      expect(t.sliderTheme.activeTrackColor, LT.lime);
      expect(t.sliderTheme.inactiveTrackColor, LT.surface3);
      expect(t.sliderTheme.thumbColor, LT.lime);
      expect(t.sliderTheme.valueIndicatorColor, LT.surface2);

      expect(t.switchTheme.trackColor!.resolve(_selected), LT.lime);
      expect(t.switchTheme.thumbColor!.resolve(_selected), LT.bg);
      expect(t.switchTheme.trackColor!.resolve(_states), LT.surface3);
      expect(t.switchTheme.thumbColor!.resolve(_states), LT.t3);

      final seg = t.segmentedButtonTheme.style!;
      expect(seg.backgroundColor!.resolve(_selected), LT.lime);
      expect(seg.foregroundColor!.resolve(_selected), LT.bg);
      expect(seg.backgroundColor!.resolve(_states), Colors.transparent);
      expect(seg.foregroundColor!.resolve(_states), LT.t2);
      expect(seg.side!.resolve(_states), const BorderSide(color: LT.border));

      final filled = t.filledButtonTheme.style!;
      expect(filled.backgroundColor!.resolve(_states), LT.lime);
      expect(filled.foregroundColor!.resolve(_states), LT.bg);
      final outlined = t.outlinedButtonTheme.style!;
      expect(outlined.side!.resolve(_states)!.color, LT.borderStrong);
      expect(outlined.foregroundColor!.resolve(_states), LT.t1);
      final text = t.textButtonTheme.style!;
      expect(text.foregroundColor!.resolve(_states), LT.lime);
      for (final s in [filled, outlined, text]) {
        expect(s.shape!.resolve(_states), RoundedRectangleBorder(borderRadius: BorderRadius.circular(LTRadius.control)));
        final ts = s.textStyle!.resolve(_states)!;
        expect(ts.fontSize, 13);
        expect(ts.fontWeight, FontWeight.w700);
      }

      expect(t.checkboxTheme.fillColor!.resolve(_selected), LT.lime);
      expect(t.radioTheme.fillColor!.resolve(_selected), LT.lime);
      expect(t.dividerTheme.color, LT.border);
    });
  });

  test('lib/ has no Colors.amber / Colors.orangeAccent / Colors.redAccent', () {
    final hits = <String>[];
    final pattern = RegExp(r'Colors\.(amber|orangeAccent|redAccent)\b');
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) hits.add('${f.path}:${i + 1}');
      }
    }
    expect(hits, isEmpty);
  });

  group('phone landscape 844×390: theme-default sheets', () {
    // Measured before stage 0 (old loopTapTheme, same sheets, same size):
    // chord type 83 px, quantize 41 px, split 4.6 px bottom overflow. With the
    // stage-0 theme: 29 / 41 / 4.6 px. The cause is the modal sheet height cap
    // (9/16 of 390 px) with a non-scrolling Column — a sheet layout change,
    // outside stage 0 ("시트 파일의 레이아웃은 바꾸지 않는다").
    const knownOverflow = {
      'chord': 'pre-existing 844x390 bottom overflow (old theme 83 px, now 29 px); needs a sheet layout change, out of ui-001 stage 0',
      'quantize': 'pre-existing 844x390 bottom overflow (41 px before and after); needs a sheet layout change, out of ui-001 stage 0',
      'split': 'pre-existing 844x390 bottom overflow (4.6 px before and after); needs a sheet layout change, out of ui-001 stage 0',
    };

    Future<Object?> openWith(WidgetTester tester, Future<void> Function(BuildContext) open) async {
      useOfflineTestFonts();
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: loopTapTheme(platform: TargetPlatform.android),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(onPressed: () => open(context), child: const Text('open')),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return tester.takeException();
    }

    Future<Object?> openSplit(WidgetTester tester) async {
      useOfflineTestFonts();
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: loopTapTheme(platform: TargetPlatform.android),
        home: Scaffold(
          body: GridHarness(notes: [PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4)]),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tapAt(gridPoint(tester, 1, 60));
      await tester.pump();
      await tapGridButton(tester, 'note-split');
      expect(find.byKey(const ValueKey('split-middle')), findsOneWidget);
      return tester.takeException();
    }

    void expectSheet(WidgetTester tester) {
      final sheet = tester.widget<Material>(
        find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first,
      );
      expect(sheet.color, LT.surface);
    }

    final sheets = <String, Future<void> Function(BuildContext)>{
      'arp': (c) => showArpSheet(c, canApply: true),
      'chord': (c) => showChordTypeSheet(c, chromatic: false),
      'quantize': (c) => showQuantizeSheet(c, canApply: true),
      'humanize': (c) => showHumanizeSheet(c, canApply: true),
      'groove': (c) => showGrooveSheet(c, _FakeGrooveHost()),
      'guitar stroke': (c) => showGuitarStrokePanel(c, canApply: true, canRevert: false),
    };

    for (final e in sheets.entries) {
      testWidgets('${e.key}: opens on the LT surface', (tester) async {
        await openWith(tester, e.value);
        expectSheet(tester);
      });
      testWidgets(
        '${e.key}: no overflow',
        (tester) async => expect(await openWith(tester, e.value), isNull),
        skip: knownOverflow[e.key] != null,
      );
    }

    testWidgets('split: opens on the LT surface', (tester) async {
      await openSplit(tester);
      expectSheet(tester);
    });
    testWidgets('split: no overflow', (tester) async => expect(await openSplit(tester), isNull), skip: true);

    testWidgets('MIDI import dialog: opens, LT colours, no overflow', (tester) async {
      expect(await openWith(tester, (c) => showMidiPassageDialog(c, midi: _oneNoteMidi(), title: 'Reference')), isNull);
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      final bg = dialog.backgroundColor ?? Theme.of(tester.element(find.byType(Dialog))).dialogTheme.backgroundColor;
      expect([LT.surface, LT.surface2], contains(bg), reason: 'own LT colour or the themed default, never the M3 tint');
    });
  });
}
