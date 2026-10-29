// Piano-roll usability (docs/specs/grid-usability.md): sticky ruler, piano
// gutter, selection and the enlarged editor, verified with real pointer
// coordinates through the shared PitchGridAxis.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/theme/tokens.dart' show loopTapTheme;
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';

const _screensOut = String.fromEnvironment('HUMTRACK_SCREENS_OUT');
String get _screensDir =>
    _screensOut.isNotEmpty
        ? _screensOut
        : (Platform.environment['HUMTRACK_SCREENS_OUT'] ?? '');

PitchNote n(
  int midi,
  num step, {
  num dur = 4,
  int? velocity,
  bool muted = false,
  bool locked = false,
  Articulation? art,
}) {
  final whole = step.floor();
  return PitchNote(
    midi: midi,
    freq: midiToFreq(midi),
    step: whole,
    dur: dur.ceil().clamp(1, 1 << 20),
    offsetSteps: (step - whole).toDouble(),
    durationSteps: dur is int ? null : dur.toDouble(),
    velocity: velocity,
    muted: muted,
    locked: locked,
    articulation: art,
  );
}

Rung _rung(int m) => Rung(
  midi: m,
  name: '${kNoteNames[m % 12]}${m ~/ 12 - 1}',
  degree: m % 12,
  freq: midiToFreq(m),
  index: m,
);

/// StepGrid like the editor mounts it (128 fixed rows, window callbacks),
/// recording every outward callback.
class _Roll extends StatefulWidget {
  const _Roll({
    super.key,
    required this.notes,
    this.steps = 128,
    this.window = false,
    this.maxOffset = 0,
    this.initialEdit = true,
  });
  final List<PitchNote> notes;
  final int steps, maxOffset;
  final bool window, initialEdit;
  @override
  State<_Roll> createState() => _RollState();
}

class _RollState extends State<_Roll> {
  late List<PitchNote> notes = List.of(widget.notes);
  final placed = <(int, int, int)>[];
  final previews = <int>[];
  final offsets = <int>[];
  int commits = 0, offset = 0;
  @override
  Widget build(BuildContext context) => StepGrid(
    ladder: [for (var m = 0; m <= 127; m++) _rung(m)],
    notes: notes,
    initialEditMode: widget.initialEdit,
    onPlace: (rung, a, b) {
      placed.add((rung.midi, a, b));
      setState(
        () =>
            notes = [
              ...notes,
              n(rung.midi, a < b ? a : b, dur: (a - b).abs() + 1),
            ],
      );
    },
    onErase: (_, _) {},
    onEdit: (before, after) {
      commits++;
      setState(() => notes = after);
      return true;
    },
    onPreview: (r) => previews.add(r.midi),
    playStep: 0,
    accent: Colors.lightGreen,
    steps: widget.steps,
    bars: (widget.steps / 16).ceil(),
    windowOffset: offset,
    maxOffset: widget.maxOffset,
    onWindowChanged:
        widget.window
            ? (o) {
              offsets.add(o);
              setState(() => offset = o);
            }
            : null,
  );
}

Future<GlobalKey<_RollState>> _mountRoll(
  WidgetTester tester,
  Size size,
  List<PitchNote> notes, {
  int steps = 128,
  bool window = false,
  int maxOffset = 0,
  bool initialEdit = true,
}) async {
  useOfflineTestFonts();
  _setWindow(tester, size);
  final key = GlobalKey<_RollState>();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: _Roll(
          key: key,
          notes: notes,
          steps: steps,
          window: window,
          maxOffset: maxOffset,
          initialEdit: initialEdit,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return key;
}

/// A real window size (MediaQuery included), 1 logical px = 1 physical px.
void _setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Rect _lane(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
Rect _viewport(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey('pitch-grid-viewport')));
ScrollController _vertical(WidgetTester tester) =>
    tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('pitch-grid-viewport')),
        )
        .controller!;
PitchGridView _view(WidgetTester tester) =>
    tester.widget<PitchGridSurface>(find.byType(PitchGridSurface)).view!;

/// Screen point of [step] on [midi]'s row through the roll's current axis
/// (independent re-derivation: lane rect + visible time range).
Offset _at(WidgetTester tester, double step, num midi) {
  final lane = _lane(tester);
  final v = _view(tester).view;
  final rowH = lane.height / 128;
  return Offset(
    lane.left + (step - v.start) / v.length * lane.width,
    lane.top + (127 - midi + .5) * rowH,
  );
}

/// Scroll the rows so [midi] sits mid-viewport.
Future<void> _showRow(WidgetTester tester, int midi) async {
  final c = _vertical(tester);
  final lane = _lane(tester);
  final vp = _viewport(tester);
  final rowH = lane.height / 128;
  final y = (127 - midi + .5) * rowH;
  c.jumpTo(
    (y - vp.height / 2).clamp(0.0, c.position.maxScrollExtent).toDouble(),
  );
  await tester.pump();
}

Future<void> _tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

// ignore: deprecated_member_use
const _keyData = KeyDataTransitMode.keyDataThenRawKeyData;

List<Map<String, dynamic>> _gridJson(WidgetTester tester) => [
  for (final x in tester.widget<StepGrid>(find.byType(StepGrid)).notes)
    x.toJson(),
];

List<Rect> _rulerLabelRects(WidgetTester tester) {
  final f = find.byWidgetPredicate(
    (w) =>
        w is Text &&
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('grid-ruler-'),
  );
  return [for (final e in f.evaluate()) tester.getRect(find.byWidget(e.widget))]
    ..sort((a, b) => a.left.compareTo(b.left));
}

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

void main() {
  tearDown(() {
    LoopPrefs.instance.resetGridLayout();
    EditScreen.debugDesktopOverride = null;
  });

  group('roll geometry', () {
    testWidgets('ruler labels never overlap and bar lines sit on the note '
        'x axis (1/2/4/8 bars, wide to narrow)', (tester) async {
      for (final bars in [1, 2, 4, 8]) {
        for (final width in [1266.0, 700.0, 420.0, 300.0]) {
          final steps = bars * 16;
          await _mountRoll(tester, Size(width, 500), const [], steps: steps);
          final lane = _lane(tester);
          final ruler = tester.getRect(
            find.byKey(const ValueKey('pitch-grid-ruler')),
          );
          // one x axis: ruler and lane share left edge and width
          expect(ruler.left, closeTo(lane.left, .01), reason: '$bars/$width');
          expect(ruler.width, closeTo(lane.width, .01));
          expect(ruler.bottom, lessThanOrEqualTo(_viewport(tester).top + .01));
          final rects = _rulerLabelRects(tester);
          expect(rects, isNotEmpty, reason: 'bars $bars width $width');
          for (var i = 0; i + 1 < rects.length; i++) {
            expect(
              rects[i].right,
              lessThanOrEqualTo(rects[i + 1].left),
              reason: 'labels overlap: bars $bars width $width',
            );
          }
          for (final r in rects) {
            expect(r.left, greaterThanOrEqualTo(ruler.left));
            expect(r.right, lessThanOrEqualTo(ruler.right + .01));
          }
          expect(find.byKey(const ValueKey('grid-ruler-bar-1')), findsOneWidget);
          for (var bar = 1; bar <= bars; bar++) {
            final f = find.byKey(ValueKey('grid-ruler-bar-$bar'));
            if (f.evaluate().isEmpty) continue; // thinned out
            expect(
              tester.getRect(f).left - 3,
              closeTo(lane.left + lane.width * (bar - 1) * 16 / steps, .01),
            );
          }
        }
      }
    });

    testWidgets('draw, move and resize land on the exact step and pitch '
        'after the gutter and ruler offsets (1266x714)', (tester) async {
      final key = await _mountRoll(tester, const Size(1266, 714), [
        n(64, 8),
      ]);
      final lane = _lane(tester);
      expect(
        lane.left,
        PitchGridAxis.gutterWidth(rail: false),
        reason: 'lane starts right after the piano gutter',
      );
      expect(
        _viewport(tester).top - PitchGridAxis.rulerHeight,
        tester.getRect(find.byKey(const ValueKey('pitch-grid-ruler'))).top,
      );
      await _showRow(tester, 62);
      await _tapKey(tester, 'note-draw');
      await tester.tapAt(_at(tester, 37.5, 60));
      await tester.pumpAndSettle();
      expect(key.currentState!.placed, [(60, 37, 37)]);
      await tester.dragFrom(
        _at(tester, 40.5, 62),
        _at(tester, 43.5, 62) - _at(tester, 40.5, 62),
      );
      await tester.pumpAndSettle();
      expect(key.currentState!.placed.last, (62, 40, 43));

      await _tapKey(tester, 'note-select');
      await _showRow(tester, 65);
      // move: grab the middle, +3 steps and +2 semitones
      await tester.dragFrom(
        _at(tester, 9.5, 64),
        _at(tester, 12.5, 66) - _at(tester, 9.5, 64),
      );
      await tester.pumpAndSettle();
      final moved = key.currentState!.notes.first;
      expect((moved.midi, moved.startSteps, moved.soundingSteps), (66, 11, 4));
      // resize: the selected note's right edge, +3 steps
      await tester.dragFrom(
        _at(tester, 14.8, 66),
        _at(tester, 17.8, 66) - _at(tester, 14.8, 66),
      );
      await tester.pumpAndSettle();
      final resized = key.currentState!.notes.first;
      expect((resized.midi, resized.startSteps, resized.soundingSteps), (
        66,
        11,
        7,
      ));
      expect(key.currentState!.previews, isNotEmpty); // grabbing auditions
    });

    testWidgets('only the right end resizes; the left end moves the note', (
      tester,
    ) async {
      final key = await _mountRoll(tester, const Size(1266, 714), [n(64, 8)]);
      await _showRow(tester, 64);
      await tester.tapAt(_at(tester, 9.5, 64)); // select
      await tester.pumpAndSettle();
      // left end (outline only, no handle): a drag moves, length unchanged
      await tester.dragFrom(
        _at(tester, 8.2, 64),
        _at(tester, 10.2, 64) - _at(tester, 8.2, 64),
      );
      await tester.pumpAndSettle();
      var note = key.currentState!.notes.single;
      expect((note.startSteps, note.soundingSteps), (10, 4));
      // right end handle: a drag resizes, start unchanged
      await tester.dragFrom(
        _at(tester, 13.8, 64),
        _at(tester, 15.8, 64) - _at(tester, 13.8, 64),
      );
      await tester.pumpAndSettle();
      note = key.currentState!.notes.single;
      expect((note.midi, note.startSteps, note.soundingSteps), (64, 10, 6));
    });

    testWidgets('the last steps of an 8-bar section are editable', (
      tester,
    ) async {
      final key = await _mountRoll(tester, const Size(1266, 714), [
        n(72, 120),
      ], initialEdit: false);
      await _showRow(tester, 72);
      await tester.tapAt(_at(tester, 127.5, 70));
      await tester.pumpAndSettle();
      expect(key.currentState!.placed, [(70, 127, 127)]);
      await _tapKey(tester, 'note-select');
      await tester.dragFrom(
        _at(tester, 121.5, 72),
        _at(tester, 127.9, 72) - _at(tester, 121.5, 72),
      );
      await tester.pumpAndSettle();
      final last = key.currentState!.notes.firstWhere((x) => x.midi == 72);
      expect(last.startSteps, 124);
      expect(last.endSteps, lessThanOrEqualTo(128));
    });

    testWidgets('area select rectangle selects exactly the notes under it, '
        'also zoomed and scrolled', (tester) async {
      final a = n(60, 4), b = n(62, 10, dur: 2), c = n(64, 30);
      final far = n(61, 100, dur: .25);
      final key = await _mountRoll(tester, const Size(1266, 714), [
        a,
        b,
        c,
        far,
      ]);
      await _showRow(tester, 62);
      await _tapKey(tester, 'note-area');
      await tester.dragFrom(
        _at(tester, 3, 63.4),
        _at(tester, 13, 59.6) - _at(tester, 3, 63.4),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pumpAndSettle();
      expect(key.currentState!.notes, [c, far]);

      // zoom 4x with the ruler corner, pan with the scroll strip
      await _tapKey(tester, 'grid-zoom-in');
      await _tapKey(tester, 'grid-zoom-in');
      expect(_view(tester).zoom, 4);
      final bar = tester.getRect(find.byKey(const ValueKey('grid-hscroll')));
      await tester.dragFrom(Offset(bar.left + 10, bar.center.dy), Offset(bar.width, 0));
      await tester.pumpAndSettle();
      expect(_view(tester).view.start, 96); // panned to the end
      // ruler follows: bar 7 starts at the lane's left edge
      expect(
        tester.getRect(find.byKey(const ValueKey('grid-ruler-bar-7'))).left - 3,
        closeTo(_lane(tester).left, .01),
      );
      await _tapKey(tester, 'note-area');
      await _showRow(tester, 61);
      await tester.dragFrom(
        _at(tester, 99, 62),
        _at(tester, 101, 60) - _at(tester, 99, 62),
      );
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(key.currentState!.notes.last.startSteps, 101);
      expect(key.currentState!.notes.last.soundingSteps, .25);
    });

    testWidgets('velocity lane shares the roll x axis (gutter, zoom, pan)', (
      tester,
    ) async {
      final a = n(60, 8, velocity: 80), b = n(64, 40, velocity: 80);
      final key = await _mountRoll(tester, const Size(1266, 714), [a, b]);
      final lane = _lane(tester);
      final vel = tester.getRect(find.byKey(const ValueKey('velocity-lane')));
      expect(vel.left, closeTo(lane.left, .01));
      expect(vel.width, closeTo(lane.width, .01));
      Future<int?> drag(PitchNote note) async {
        final v = _view(tester).view;
        final r = tester.getRect(find.byKey(const ValueKey('velocity-lane')));
        final x = r.left + (note.startSteps - v.start) / v.length * r.width;
        final y = r.bottom - 4 - (note.velocity ?? 100) / 127 * (r.height - 8);
        await tester.dragFrom(Offset(x, y), const Offset(0, -12));
        await tester.pumpAndSettle();
        return key.currentState!.notes
            .firstWhere((x) => x.midi == note.midi)
            .velocity;
      }

      expect(await drag(a), greaterThan(80));
      expect(key.currentState!.notes.last.velocity, 80);
      await _tapKey(tester, 'grid-zoom-in');
      await _tapKey(tester, 'grid-zoom-in');
      _view(tester).panTo(32);
      await tester.pumpAndSettle();
      final before = key.currentState!.notes.first.velocity;
      expect(await drag(key.currentState!.notes.last), greaterThan(80));
      expect(key.currentState!.notes.first.velocity, before);
    });

    testWidgets('piano keys preview only; key drag and wheel keep the '
        'pitch-range behaviour', (tester) async {
      final key = await _mountRoll(
        tester,
        const Size(1266, 714),
        [n(60, 0)],
        window: true,
        maxOffset: 5,
        initialEdit: false,
      );
      expect(_lane(tester).left, PitchGridAxis.gutterWidth(rail: true));
      await _showRow(tester, 60);
      final keys = tester.getRect(find.byKey(const ValueKey('pitch-grid-keys')));
      final y = _at(tester, 0, 60).dy;
      // rows aligned: the key at the note row's y is that note's pitch
      await tester.tapAt(Offset(keys.left + 30, y));
      await tester.pumpAndSettle();
      await tester.tapAt(Offset(keys.left + 10, _at(tester, 0, 61).dy));
      await tester.pumpAndSettle();
      expect(key.currentState!.previews, [60, 61]);
      expect(key.currentState!.placed, isEmpty);
      expect(key.currentState!.commits, 0);
      expect(key.currentState!.notes, hasLength(1));
      // label drag: 24 px per pitch step, clamped to 0..maxOffset
      await tester.dragFrom(keys.center, const Offset(0, 400));
      await tester.pumpAndSettle();
      // one step per 24 px, then held at the max (as before)
      final down = key.currentState!.offsets;
      expect(down.take(5), [1, 2, 3, 4, 5]);
      expect(down.skip(5), everyElement(5));
      await tester.dragFrom(keys.center, const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(key.currentState!.offsets.last, 0);
      // plain wheel = vertical row scroll by the wheel delta
      final c = _vertical(tester);
      final start = c.offset;
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      final p = _at(tester, 10, 60);
      await tester.sendEventToBinding(mouse.hover(p));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
      await tester.pump();
      expect(c.offset, start + 120);
      // Ctrl+wheel zooms around the pointer, Shift+wheel pans; rows stay
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(_view(tester).zoom, greaterThan(1));
      expect(c.offset, start + 120);
      final s0 = _view(tester).view.start;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100)));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(_view(tester).view.start, greaterThan(s0));
      expect(c.offset, start + 120);
      expect(key.currentState!.notes, hasLength(1));
    });

    testWidgets('phone-size roll: draw lands exactly, rows stay 24 px', (
      tester,
    ) async {
      final key = await _mountRoll(
        tester,
        const Size(390, 600),
        const [],
        steps: 32,
        initialEdit: false,
      );
      expect(_lane(tester).height / 128, 24);
      await _showRow(tester, 67);
      await tester.tapAt(_at(tester, 30.5, 67));
      await tester.pumpAndSettle();
      expect(key.currentState!.placed, [(67, 30, 30)]);
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
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
      }
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['playerId'];
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          }
          return null;
        },
      );
      root = await Directory.systemTemp.createTemp('humtrack_grid_ux_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopAudio.instance.debugOnPlayPitch = null;
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    Future<void> openGrid(
      WidgetTester tester,
      Size size, {
      int bars = 2,
      List<PitchNote> notes = const [],
      bool? desktop,
      int? program,
      GlobalKey? capture,
      bool imported = true,
    }) async {
      EditScreen.debugDesktopOverride = desktop;
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        // Ahem glyphs overflow unrelated fixed-width labels
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      addTearDown(() => FlutterError.onError = onError);
      _setWindow(tester, size);
      final sec = Section(id: 'A', name: 'A', bars: bars)
        ..tracks['melody'] = TrackData(notes: List.of(notes));
      if (imported) sec.tracks['melody']!.label = 'Imported MIDI';
      final song = Song(
        id: 'grid-ux',
        title: 'Roll',
        bpm: 120,
        bars: bars,
        sections: [sec],
        instruments: program == null ? null : {'melody': program},
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: ChangeNotifierProvider<LoopStore>.value(
            value: _Store(),
            child: MaterialApp(
              // the review screenshots use the app theme (real fonts)
              theme: capture == null ? null : loopTapTheme(),
              locale: const Locale('ko'),
              localizationsDelegates: L10n.localizationsDelegates,
              supportedLocales: L10n.supportedLocales,
              home: EditScreen(song: song),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (find.byType(Arrangement).evaluate().isNotEmpty) {
        tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
      } else {
        // ui-001 stage 3 (desktop edit view): arrange view, double-click the
        // track = its editor
        await editTrack(tester, 'melody');
      }
      await tester.pumpAndSettle();
      if (find.byType(StepGrid).evaluate().isEmpty) {
        tester
            .widget<GestureDetector>(
              find
                  .ancestor(
                    of: find.text('그리드'),
                    matching: find.byType(GestureDetector),
                  )
                  .first,
            )
            .onTap!();
        await tester.pumpAndSettle();
      }
      expect(find.byType(StepGrid), findsOneWidget);
    }

    double laneHeight(WidgetTester tester) => _viewport(tester).height;

    // ui-001 stage 3: on desktop the edit view replaces 편집 확대, the
    // timeline fold and the split handle (docs/specs/ui/ui-001 "3단계").
    testWidgets('note lane height: 1266x714 edit view (no 편집 확대 / fold / '
        'split on desktop), arrange view and back', (tester) async {
      await openGrid(tester, const Size(1266, 714), desktop: true);
      final edit = laneHeight(tester);
      debugPrint('[grid-ux] 1266x714 lane edit-view=$edit');
      expect(edit, greaterThanOrEqualTo(200));
      expect(find.byKey(const ValueKey('timeline-minimap')), findsOneWidget);
      expect(find.byType(Arrangement), findsNothing);
      for (final key in const ['grid-focus', 'timeline-expand', 'timeline-collapse']) {
        expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
      }
      expect(find.byType(DesktopSplitHandle), findsNothing);
      // ruler stays directly above the notes
      expect(
        tester.getRect(find.byKey(const ValueKey('pitch-grid-ruler'))).bottom,
        closeTo(_viewport(tester).top, .01),
      );
      // the arrange view gives the timeline the window (no surface)
      await tester.tap(find.byKey(const ValueKey('view-arrange')));
      await tester.pumpAndSettle();
      expect(find.byType(Arrangement), findsOneWidget);
      expect(find.byType(StepGrid), findsNothing);
      expect(find.byType(DesktopSplitHandle), findsNothing);
      await tester.tap(find.byKey(const ValueKey('view-edit')));
      await tester.pumpAndSettle();
      expect(laneHeight(tester), closeTo(edit, .01));
    });

    testWidgets('note lane height: large desktop and phone layouts', (
      tester,
    ) async {
      await openGrid(tester, const Size(1920, 1040), desktop: true);
      // ui-001 stage 3: the desktop edit view (편집 확대 is phone-only)
      final large = laneHeight(tester);
      expect(large, greaterThanOrEqualTo(200));
      expect(find.byKey(const ValueKey('grid-focus')), findsNothing);
      final largeFocus = large;
      LoopPrefs.instance.resetGridLayout();
      await tester.pumpWidget(const SizedBox());
      await openGrid(tester, const Size(390, 844), desktop: false);
      // phone: no desktop timeline chrome, the 2:3 split stays
      expect(find.byType(DesktopTimeline), findsNothing);
      expect(find.byType(DesktopSplitHandle), findsNothing);
      final phone = laneHeight(tester);
      await tester.tap(find.byKey(const ValueKey('grid-focus')));
      await tester.pumpAndSettle();
      final phoneFocus = laneHeight(tester);
      debugPrint(
        '[grid-ux] 1920x1040 lane default=$large focus=$largeFocus; '
        '390x844 phone default=$phone focus=$phoneFocus',
      );
      expect(phoneFocus, greaterThan(phone));
      expect(phoneFocus, greaterThanOrEqualTo(200));
    });

    testWidgets('editor piano key previews only (no note, no undo step)', (
      tester,
    ) async {
      await openGrid(tester, const Size(1266, 714), desktop: true);
      // ui-001 stage 3: the desktop edit view is the enlarged editor
      // (편집 확대 is phone-only now)
      final played = <int>[];
      LoopAudio.instance.debugOnPlayPitch = (ch, midi, vel, vol) {
        played.add(midi);
      };
      final vp = _viewport(tester);
      final lane = _lane(tester);
      final rowH = lane.height / 128;
      final y = vp.center.dy;
      final midi = 127 - ((y - lane.top) / rowH).floor();
      final keys = tester.getRect(
        find.byKey(const ValueKey('pitch-grid-keys')),
      );
      await tester.tapAt(Offset(keys.left + 8, y));
      await tester.pumpAndSettle();
      expect(played, [midi]);
      expect(tester.widget<StepGrid>(find.byType(StepGrid)).notes, isEmpty);
    });

    testWidgets('8-bar long MIDI: short and long selected notes move and '
        'undo/redo exactly; untouched data is preserved', (tester) async {
      final notes = <PitchNote>[
        for (var i = 0; i < 160; i++)
          n(
            48 + (i * 7) % 30,
            (i * 0.8) % 127,
            dur: i % 9 == 0 ? 0.25 : (i % 5 == 0 ? 12 : 1.5),
            velocity: 30 + (i * 13) % 97,
          ),
      ];
      final long = n(66, 64, dur: 32, velocity: 90);
      final short = n(67, 100.4, dur: .25, velocity: 50);
      await openGrid(
        tester,
        const Size(1266, 714),
        bars: 8,
        notes: [...notes, long, short],
        desktop: true,
      );
      // ui-001 stage 3: the desktop edit view is the enlarged editor
      // (편집 확대 is phone-only now)
      final before = [
        for (final x in tester.widget<StepGrid>(find.byType(StepGrid)).notes)
          x.toJson(),
      ];
      await _showRow(tester, 66);
      await tester.tapAt(_at(tester, 80, 66));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(_at(tester, 100.5, 67));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.textContaining('2개 선택'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      List<Map<String, dynamic>> now() => [
        for (final x in tester.widget<StepGrid>(find.byType(StepGrid)).notes)
          x.toJson(),
      ];
      final after = now();
      expect(after.length, before.length);
      for (var i = 0; i < before.length; i++) {
        if (i < notes.length) {
          expect(after[i], before[i], reason: 'untouched note $i');
        }
      }
      final grid = tester.widget<StepGrid>(find.byType(StepGrid)).notes;
      expect(grid[notes.length].startSteps, 65);
      expect(grid[notes.length].soundingSteps, 32);
      expect(grid[notes.length].velocity, 90);
      expect(grid.last.startSteps, closeTo(101.4, 1e-9));
      expect(grid.last.soundingSteps, .25);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).undo();
      await tester.pumpAndSettle();
      expect(now(), before);
      tester.widget<DesktopCommands>(find.byType(DesktopCommands)).redo();
      await tester.pumpAndSettle();
      expect(now(), after);
    });

    // Real key events through the focus system (not DesktopCommands.undo()
    // directly): the grid holds focus after a note click, Ctrl+Z / Ctrl+Shift+Z
    // must bubble from the grid's focus node to the editor's DesktopCommands.
    group('Ctrl/Cmd+Z from the focused guitar grid', () {
      Future<List<Map<String, dynamic>>> moveOneStep(
        WidgetTester tester,
      ) async {
        await openGrid(
          tester,
          const Size(1266, 714),
          desktop: true,
          program: 25, // steel guitar
          notes: [n(64, 0, dur: 4, velocity: 100), n(67, 8, dur: 2)],
        );
        await _showRow(tester, 64);
        await tester.tapAt(_at(tester, 1, 64));
        await tester.pumpAndSettle();
        expect(find.textContaining('1개 선택'), findsOneWidget);
        final before = _gridJson(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        final moved = _gridJson(tester);
        expect(moved, isNot(before));
        expect(
          tester.widget<StepGrid>(find.byType(StepGrid)).notes.first.startSteps,
          1,
        );
        return before;
      }

      /// Ctrl(+Shift)+Z where the Z key-down carries [logical] / [character]
      /// (an IME layout can report a non-Latin logical key for physical Z).
      Future<void> chord(
        WidgetTester tester, {
        required LogicalKeyboardKey modifier,
        bool shift = false,
        LogicalKeyboardKey? logical,
        String? character,
      }) async {
        await tester.sendKeyDownEvent(modifier);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyDownEvent(
          logical ?? LogicalKeyboardKey.keyZ,
          physicalKey: PhysicalKeyboardKey.keyZ,
          character: character,
        );
        await tester.sendKeyUpEvent(
          logical ?? LogicalKeyboardKey.keyZ,
          physicalKey: PhysicalKeyboardKey.keyZ,
        );
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(modifier);
        await tester.pumpAndSettle();
      }

      // Simulated platform key messages (Windows virtual keys / macOS key
      // codes), the editor running as that desktop platform.
      for (final (name, modifier, platform) in [
        ('Control_L', LogicalKeyboardKey.controlLeft, TargetPlatform.windows),
        ('Control_R', LogicalKeyboardKey.controlRight, TargetPlatform.windows),
        ('Control_L', LogicalKeyboardKey.controlLeft, TargetPlatform.linux),
        ('Meta_L (Cmd)', LogicalKeyboardKey.metaLeft, TargetPlatform.macOS),
      ]) {
        for (final keyData in [false, true]) {
          testWidgets('$name+Z undoes, +Shift+Z redoes '
              '(${platform.name}, ${keyData ? 'KeyData' : 'raw'} transit)', (
            tester,
          ) async {
            debugDefaultTargetPlatformOverride = platform;
            // Windows / macOS / Linux embedders send KeyData first (the
            // raw-message transit API is deprecated but still what desktop
            // delivers alongside it).
            // ignore: deprecated_member_use
            if (keyData) debugKeyEventSimulatorTransitModeOverride = _keyData;
            try {
              final before = await moveOneStep(tester);
              final moved = _gridJson(tester);
              await chord(tester, modifier: modifier);
              expect(_gridJson(tester), before, reason: 'Ctrl+Z restores');
              await chord(tester, modifier: modifier, shift: true);
              expect(_gridJson(tester), moved, reason: 'Ctrl+Shift+Z redoes');
              await tester.pumpWidget(const SizedBox());
            } finally {
              debugDefaultTargetPlatformOverride = null;
              // ignore: deprecated_member_use
              debugKeyEventSimulatorTransitModeOverride = null;
            }
          });
        }
      }

      // Non-Latin layouts: the platform key simulator only knows Latin
      // logical keys, so these KeyEvents go straight into the real dispatch
      // path (HardwareKeyboard, then the focus tree's key message handler),
      // exactly what KeyEventManager does with an embedder message.
      // A Korean (2-beolsik) layout with Hangul input on: physical Z is 'ㅋ'.
      for (final (name, logical, character) in [
        // control case: proves this dispatch path reaches DesktopCommands
        ('Latin z logical key', LogicalKeyboardKey.keyZ, null),
        ('Hangul ㅋ logical key', const LogicalKeyboardKey(0x314b), 'ㅋ'),
        (
          'Hangul ㅋ logical key, no character',
          const LogicalKeyboardKey(0x314b),
          null,
        ),
        ('IME Process logical key', LogicalKeyboardKey.process, null),
      ]) {
        testWidgets('Ctrl+Z with $name on physical Z undoes / redoes', (
          tester,
        ) async {
          final before = await moveOneStep(tester);
          final moved = _gridJson(tester);
          Future<void> send(KeyEvent e) async {
            final hw = HardwareKeyboard.instance.handleKeyEvent(e);
            // KeyEventManager's own dispatch of an embedder message
            // ignore: deprecated_member_use
            final manager = ServicesBinding.instance.keyEventManager;
            // ignore: deprecated_member_use
            final focus = manager.keyMessageHandler!(KeyMessage([e], null));
            debugPrint('[undo-key] ${e.runtimeType} ${e.logicalKey.debugName} '
                'hw=$hw focus=$focus');
            await tester.pump();
          }

          Future<void> imeChord({bool shift = false}) async {
            const ctrl = PhysicalKeyboardKey.controlLeft;
            const shiftKey = PhysicalKeyboardKey.shiftLeft;
            await send(const KeyDownEvent(
              physicalKey: ctrl,
              logicalKey: LogicalKeyboardKey.controlLeft,
              timeStamp: Duration.zero,
            ));
            if (shift) {
              await send(const KeyDownEvent(
                physicalKey: shiftKey,
                logicalKey: LogicalKeyboardKey.shiftLeft,
                timeStamp: Duration.zero,
              ));
            }
            await send(KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.keyZ,
              logicalKey: logical,
              character: character,
              timeStamp: Duration.zero,
            ));
            await send(KeyUpEvent(
              physicalKey: PhysicalKeyboardKey.keyZ,
              logicalKey: logical,
              timeStamp: Duration.zero,
            ));
            if (shift) {
              await send(const KeyUpEvent(
                physicalKey: shiftKey,
                logicalKey: LogicalKeyboardKey.shiftLeft,
                timeStamp: Duration.zero,
              ));
            }
            await send(const KeyUpEvent(
              physicalKey: ctrl,
              logicalKey: LogicalKeyboardKey.controlLeft,
              timeStamp: Duration.zero,
            ));
            await tester.pumpAndSettle();
          }

          await imeChord();
          expect(_gridJson(tester), before, reason: 'Ctrl+Z restores');
          await imeChord(shift: true);
          expect(_gridJson(tester), moved, reason: 'Ctrl+Shift+Z redoes');
        });
      }

      // A Latin layout that moves Z (AZERTY: physical W types 'z', physical
      // Z types 'w'): the typed letter decides, not the key position.
      testWidgets('AZERTY: Ctrl+typed Z undoes, Ctrl+typed W does not', (
        tester,
      ) async {
        final before = await moveOneStep(tester);
        final moved = _gridJson(tester);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyW,
          physicalKey: PhysicalKeyboardKey.keyZ,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(_gridJson(tester), moved, reason: 'typed W is not undo');
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(
          LogicalKeyboardKey.keyZ,
          physicalKey: PhysicalKeyboardKey.keyW,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(_gridJson(tester), before, reason: 'typed Z is undo');
      });
    });

    testWidgets('screenshots for review (HUMTRACK_SCREENS_OUT only)', (
      tester,
    ) async {
      if (_screensDir.isEmpty) return;
      await tester.runAsync(_loadScreenshotFonts);
      final shots = <(String, Size, bool?, bool)>[
        ('1266x714-default', const Size(1266, 714), true, false),
        ('1266x714-enlarged', const Size(1266, 714), true, true),
        ('1920x1040-default', const Size(1920, 1040), true, false),
        ('390x844-phone', const Size(390, 844), false, false),
        ('390x844-phone-enlarged', const Size(390, 844), false, true),
      ];
      for (final (name, size, desktop, focus) in shots) {
        LoopPrefs.instance.resetGridLayout();
        final capture = GlobalKey();
        await openGrid(
          tester,
          size,
          bars: 4,
          desktop: desktop,
          program: 25, // steel guitar: articulation / stroke marks show
          capture: capture,
          notes: [
            n(64, 0, dur: 4, velocity: 100),
            n(67, 4, dur: 2),
            n(69, 6, dur: .5),
            n(71, 8, dur: 4, muted: true),
            n(72, 12, dur: 4, art: const Articulation(
              kind: ArticulationKind.palmTone,
              gateMs: 250,
              velScale: .85,
            )),
            n(64, 16, dur: 8, locked: true),
            n(66, 24, dur: 1, art: const Articulation(
              kind: ArticulationKind.staccato,
              gateMs: 120,
            )),
            n(69, 28, dur: .25),
            n(71, 32, dur: 16),
            n(67, 50, dur: 6),
            n(62, 60, dur: 4),
          ],
        );
        // ui-001 stage 3: on desktop the edit view already is the enlarged
        // editor (편집 확대 is phone-only)
        if (focus && desktop != true) {
          await tester.tap(find.byKey(const ValueKey('grid-focus')));
          await tester.pumpAndSettle();
        }
        await _showRow(tester, 68);
        // select: a normal, a tiny, a muted and a long note
        await tester.tapAt(_at(tester, 1, 64));
        await tester.pumpAndSettle();
        for (final (s, m) in [(28.1, 69), (9.0, 71), (40.0, 71)]) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
          await tester.tapAt(_at(tester, s, m));
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
          await tester.pumpAndSettle();
        }
        final boundary =
            capture.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final png = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$_screensDir/grid-$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(png!.buffer.asUint8List());
          image.dispose();
        });
        debugPrint(
          '[grid-ux] screenshot $name lane=${_viewport(tester).height}',
        );
        await tester.pumpWidget(const SizedBox());
      }
    });
  });
}

/// Real glyphs for the review screenshots only (Malgun Gothic covers Korean
/// and Latin; the Material icon font from the SDK cache). Widget tests
/// otherwise keep the offline Ahem layout.
Future<void> _loadScreenshotFonts() async {
  Future<void> load(String family, List<String> paths) async {
    final loader = FontLoader(family);
    var any = false;
    for (final p in paths) {
      final f = File(p);
      if (f.existsSync()) {
        final bytes = await f.readAsBytes();
        loader.addFont(Future.value(ByteData.sublistView(bytes)));
        any = true;
      }
    }
    if (any) await loader.load();
  }

  const malgun = ['C:/Windows/Fonts/malgun.ttf', 'C:/Windows/Fonts/malgunbd.ttf'];
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? 'C:/src/flutter';
  for (final family in [
    'Roboto',
    'Inter',
    'JetBrainsMono',
    'FlutterTest',
    'Ahem',
    'monospace',
    'sans-serif',
    ..._googleFamilies,
  ]) {
    await load(family, malgun);
  }
  final pub =
      '${Platform.environment['LOCALAPPDATA']}/Pub/Cache/hosted/pub.dev';
  final symbols = Directory(pub).existsSync()
      ? [
          for (final d in Directory(pub).listSync())
            if (d.path.contains('material_symbols_icons-'))
              '${d.path}/lib/fonts/MaterialSymbolsOutlined.ttf',
        ]
      : <String>[];
  await load('packages/material_symbols_icons/MaterialSymbolsOutlined', symbols);
  await load('MaterialSymbolsOutlined', symbols);
  await load('MaterialIcons', [
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ]);
}

/// google_fonts registers `Family_variant` names.
final _googleFamilies = [
  for (final family in ['Inter', 'JetBrainsMono'])
    for (final w in [
      'regular',
      'italic',
      for (final x in [100, 200, 300, 400, 500, 600, 700, 800, 900]) ...[
        '$x',
        '${x}italic',
      ],
    ])
      '${family}_$w',
];
