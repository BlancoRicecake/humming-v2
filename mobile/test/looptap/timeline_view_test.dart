import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/timeline_view.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/timeline_ruler.dart';
import '../support/offline_fonts.dart';

void main() {
  test(
    'projection retains song time for fractional notes and clamped seeks',
    () {
      const view = TimelineView(64, 128);
      expect(view.fraction(64), 0);
      expect(view.fraction(128), 1);
      expect(view.stepAt(view.fraction(67.225)), closeTo(67.225, 1e-10));
      expect(view.stepAt(-1), 64);
      expect(view.stepAt(2), 128);
    },
  );

  testWidgets(
    'loop fit keeps labels fixed and aligns bars, playhead and seeking',
    (tester) async {
      useOfflineTestFonts();
      await tester.binding.setSurfaceSize(const Size(1100, 380));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final section = Section(id: 'A', name: 'A', bars: 8);
      section.tracks['melody']!
        ..label = 'Tenor Sax · 4'
        ..pitchNotes.add(
          PitchNote(
            midi: 66,
            freq: 369.99,
            step: 67,
            dur: 3,
            velocity: 67,
            offsetSteps: .225,
            durationSteps: 2.258,
          ),
        );
      final before = section.toJson();
      final head = ValueNotifier(67.2);
      addTearDown(head.dispose);
      var labelWidth = 220.0;
      var loop = const PlaybackRange(64, 128);
      double? sought;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return DesktopTimeline(
                  steps: 128,
                  loopRange: loop,
                  labelWidth: labelWidth,
                  builder:
                      (view) => Arrangement(
                        section: section,
                        tracks: [trackById('melody')],
                        instrumentNames: const {'melody': 'Tenor Sax'},
                        view: view,
                        labelWidth: labelWidth,
                        onLabelWidthChanged:
                            (w) => setState(() => labelWidth = w),
                        activeId: 'melody',
                        mutes: const {},
                        onSelect: (_) {},
                        onToggleMute: (_) {},
                        onToggleSolo: (_) {},
                        playStep: head,
                        steps: 128,
                        ranges: const {},
                        loopRange: loop,
                        onSeek: (s) => sought = s,
                      ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      final label = find.byKey(const ValueKey('track-label-melody'));
      final labelBefore = tester.getRect(label);
      expect(find.text('Tenor Sax · 4'), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline-bar-1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('timeline-fit-loop')));
      await tester.pumpAndSettle();
      Arrangement arrangement() =>
          tester.widget<Arrangement>(find.byType(Arrangement));
      expect(arrangement().visible.start, closeTo(64, 1e-10));
      expect(arrangement().visible.end, closeTo(128, 1e-10));
      expect(tester.getRect(label), labelBefore);
      expect(find.byKey(const ValueKey('timeline-bar-1')), findsNothing);
      expect(find.byKey(const ValueKey('timeline-bar-5')), findsOneWidget);
      expect(find.byKey(const ValueKey('timeline-bar-8')), findsOneWidget);
      final ruler = tester.getRect(find.byType(TimelineRuler));
      final line = tester.getTopLeft(
        find.byKey(const ValueKey('timeline-playhead')),
      );
      expect(line.dx, closeTo(ruler.left + ruler.width * 3.2 / 64, .01));
      await tester.tapAt(ruler.center);
      expect(sought, closeTo(96, .01));
      // The labels remain fixed while the underlying musical time is panned.
      final scroller = tester.widget<SingleChildScrollView>(
        find.byKey(const ValueKey('timeline-scroll')),
      );
      scroller.controller!.jumpTo(0);
      await tester.pump();
      expect(arrangement().visible.start, 0);
      expect(tester.getRect(label), labelBefore);
      await tester.tap(find.byKey(const ValueKey('timeline-fit-loop')));
      await tester.pumpAndSettle();
      // A changed repeat range stays fitted without moving any MIDI notes.
      rebuild(() => loop = const PlaybackRange(16, 48));
      await tester.pumpAndSettle();
      expect(arrangement().visible.start, closeTo(16, .01));
      expect(arrangement().visible.end, closeTo(48, .01));
      await tester.binding.setSurfaceSize(const Size(1000, 380));
      await tester.pumpAndSettle();
      expect(arrangement().visible.start, closeTo(16, .01));
      expect(arrangement().visible.end, closeTo(48, .01));
      await tester.drag(
        find.byKey(const ValueKey('track-label-resize')),
        const Offset(60, 0),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(label).width, greaterThanOrEqualTo(260));
      expect(arrangement().visible.start, closeTo(16, .01));
      expect(arrangement().visible.end, closeTo(48, .01));
      await tester.tap(find.byKey(const ValueKey('timeline-fit-all')));
      await tester.pumpAndSettle();
      expect(arrangement().visible.start, 0);
      expect(arrangement().visible.end, 128);
      expect(section.toJson(), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('audio clip dragging uses song steps inside a zoomed viewport', (
    tester,
  ) async {
    useOfflineTestFonts();
    await tester.binding.setSurfaceSize(const Size(1000, 260));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final section = Section(id: 'A', name: 'A', bars: 8);
    section.tracks['vocal']!.clips = [
      VocalClip(path: 'take.wav', startStep: 68, durSteps: 8),
    ];
    final head = ValueNotifier(64.0);
    addTearDown(head.dispose);
    int? moved;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: Arrangement(
            section: section,
            tracks: [trackById('vocal')],
            view: const TimelineView(64, 96),
            activeId: 'vocal',
            mutes: const {},
            onSelect: (_) {},
            onToggleMute: (_) {},
            playStep: head,
            steps: 128,
            ranges: const {},
            onMoveClip: (_, __, step) => moved = step,
          ),
        ),
      ),
    );
    final ruler = tester.getRect(find.byType(TimelineRuler));
    // Grab the middle of the clip at song step 72 and move by four steps.
    final gesture = await tester.startGesture(
      Offset(ruler.left + ruler.width * 8 / 32, ruler.bottom + 22),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(Offset(ruler.width * 4 / 32, 0));
    await tester.pump();
    await gesture.up();
    expect(moved, 72);
    expect(section.tracks['vocal']!.clips!.single.startStep, 68);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
