import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/widgets/audition_bar.dart';

void main() {
  test(
    'multiple Solo lanes, bypass, and explicit mutes remain independent',
    () {
      final mutes = {'bass': true, 'melody': false};
      final solos = {'bass', 'melody'};
      expect(trackIsAudible('melody', mutes, solos), isTrue);
      expect(trackIsAudible('drums', mutes, solos), isFalse);
      expect(trackIsAudible('bass', mutes, solos), isFalse);
      expect(trackIsAudible('drums', mutes, solos, bypassSolo: true), isTrue);
      expect(trackIsAudible('bass', mutes, solos, bypassSolo: true), isFalse);
      solos.clear();
      expect(trackIsAudible('drums', mutes, solos), isTrue);
      expect(mutes, {'bass': true, 'melody': false});
    },
  );

  test('nonzero loop wraps exact and fractional steps without drift', () {
    const range = PlaybackRange(32, 48);
    expect(range.position(32), 32);
    expect(range.position(47.875), 47.875);
    expect(range.position(48), 32);
    expect(range.position(48.375), 32.375);
    expect(range.position(32 + 16 * 10000 + .3), closeTo(32.3, 1e-10));
    expect(range.contains(48), isFalse);
    expect(range.bounded(16).start, 15);
    expect(range.bounded(16).end, 16);
  });

  test('gate retains expressive timing and cuts exactly at the range end', () {
    const range = PlaybackRange(16, 32);
    expect(range.gateSeconds(20.3, .41, .125), .41);
    expect(range.gateSeconds(31.75, 2, .125), .03125);
    expect(range.gateSeconds(32, 2, .125), 0);
    expect(range.gateSeconds(15.9, 2, .125), 0);
  });

  test(
    'range start chases sustained chords, without retriggering new attacks',
    () {
      final held = PitchNote(
        midi: 60,
        freq: 261.63,
        step: 30,
        dur: 8,
        offsetSteps: .3,
        durationSteps: 7.4,
        velocity: 47,
      );
      final atStart = PitchNote(midi: 64, freq: 329.63, step: 32, dur: 2);
      final finished = PitchNote(midi: 67, freq: 392, step: 28, dur: 4);
      final gates =
          chasedPitchGates(
            [held, atStart, finished],
            const PlaybackRange(32, 36),
            32.1,
            before: 32,
          ).toList();
      expect(gates, hasLength(1));
      expect(gates.single.note, same(held));
      expect(gates.single.steps, closeTo(3.9, 1e-10));
      expect(held.velocity, 47);
      expect(held.startSteps, closeTo(30.3, 1e-10));
      expect(held.durationSteps, 7.4);
      expect(
        chasedPitchGates([held], const PlaybackRange(32, 36), 36),
        isEmpty,
      );
    },
  );

  testWidgets(
    'bar selection makes an inclusive range and fits a narrow phone',
    (tester) async {
      PlaybackRange range = const PlaybackRange(0, 128);
      await tester.binding.setSurfaceSize(const Size(360, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var enabled = true;
      var compare = 0;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return AuditionBar(
                  bars: 8,
                  range: range,
                  looping: true,
                  soloCount: 2,
                  bypassSolo: false,
                  enabled: enabled,
                  onLoop: () {},
                  onRange: (r) => setState(() => range = r),
                  onRestart: () {},
                  onClearSolo: () {},
                  onCompare: () => compare++,
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('loop-start-bar')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('3').last);
      await tester.pumpAndSettle();
      expect(range.start, 32);
      await tester.ensureVisible(find.byKey(const ValueKey('loop-end-bar')));
      await tester.tap(find.byKey(const ValueKey('loop-end-bar')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('4').last);
      await tester.pumpAndSettle();
      expect(range.end, 64);
      final compareButton = find.byKey(const ValueKey('audition-compare'));
      await tester.ensureVisible(compareButton);
      await tester.tap(compareButton);
      expect(compare, 1);
      rebuild(() => enabled = false);
      await tester.pump();
      expect(tester.widget<TextButton>(compareButton).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
