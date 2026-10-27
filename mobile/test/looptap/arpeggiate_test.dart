// harmony-002: Arpeggiate. docs/specs/harmony/hm-002-arpeggiate.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/arpeggiate.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/widgets/desktop_instrument.dart';

import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

PitchNote n(int midi, int start, int end, {int? velocity, double chance = 1}) =>
    PitchNote(
      midi: midi,
      freq: midiToFreq(midi),
      step: start,
      dur: end - start,
      velocity: velocity,
      chance: chance,
    );

List<PitchNote> chord({int end = 4}) => [
  n(60, 0, end),
  n(64, 0, end),
  n(67, 0, end),
];

PitchNoteEdit arp(
  List<PitchNote> notes, {
  ArpStyle style = ArpStyle.up,
  QuantizeGrid grid = QuantizeGrid.sixteenth,
  double gate = 1,
  int octaves = 1,
  bool keep = false,
  int seed = 1,
  Set<PitchNote>? selected,
}) => arpeggiatePitchNotes(
  notes,
  selected ?? notes.toSet(),
  ArpSettings(
    style: style,
    grid: grid,
    gate: gate,
    octaves: octaves,
    keepOriginalMuted: keep,
  ),
  seed: seed,
  steps: 32,
);

List<(int, double, double)> spans(Iterable<PitchNote> l) => [
  for (final x in l) (x.midi, x.startSteps, x.endSteps),
];

void main() {
  test('Up, 1/16', () {
    expect(spans(arp(chord()).notes), [
      (60, 0.0, 1.0),
      (64, 1.0, 2.0),
      (67, 2.0, 3.0),
      (60, 3.0, 4.0),
    ]);
  });

  test('Down, 1/8', () {
    expect(spans(arp(chord(), style: ArpStyle.down, grid: QuantizeGrid.eighth).notes), [
      (67, 0.0, 2.0),
      (64, 2.0, 4.0),
    ]);
  });

  test('Up-Down over 8 steps', () {
    expect(
      arp(chord(end: 8), style: ArpStyle.upDown).notes.map((x) => x.midi),
      [60, 64, 67, 64, 60, 64, 67, 64],
    );
  });

  test('Octaves 2', () {
    expect(
      arp(chord(end: 8), octaves: 2).notes.map((x) => x.midi),
      [60, 64, 67, 72, 76, 79, 60, 64],
    );
  });

  test('Gate 50% and 200%', () {
    expect(spans(arp(chord(), grid: QuantizeGrid.eighth, gate: .5).notes), [
      (60, 0.0, 1.0),
      (64, 2.0, 3.0),
    ]);
    expect(spans(arp(chord(), gate: 2).notes), [
      (60, 0.0, 2.0),
      (64, 1.0, 3.0),
      (67, 2.0, 4.0),
      (60, 3.0, 4.0),
    ]);
  });

  test('1/16T keeps exact fractional starts', () {
    final out = arp(chord(), grid: QuantizeGrid.sixteenthTriplet).notes;
    for (var i = 0; i < out.length; i++) {
      expect(out[i].startSteps, closeTo(i * 2 / 3, 1e-9));
    }
    expect(out[1].offsetSteps, closeTo(2 / 3, 1e-9));
    expect(out.length, 6);
  });

  test('run notes inherit from their source pitch (octave copies too)', () {
    final notes = [
      n(60, 0, 8),
      n(64, 0, 8, velocity: 40, chance: .5),
      n(67, 0, 8),
    ];
    final out = arp(notes, octaves: 2).notes;
    for (final x in out.where((x) => x.midi == 64 || x.midi == 76)) {
      expect((x.velocity, x.chance), (40, .5));
    }
    expect(out.where((x) => x.midi == 76), isNotEmpty);
    expect(out.where((x) => x.midi == 60).every((x) => x.velocity == null), isTrue);
  });

  test('Random: seeded, no repeat inside a round or across rounds', () {
    final long = [n(60, 0, 32), n(64, 0, 32), n(67, 0, 32), n(71, 0, 32)];
    List<int> run(int seed) => [
      for (final x in arp(
        long,
        style: ArpStyle.random,
        grid: QuantizeGrid.thirtySecond,
        seed: seed,
      ).notes)
        x.midi,
    ];
    expect(run(9), run(9));
    // 63 seeds x 16 rounds of |P| = 4: over 1000 rounds
    var inRound = 0, boundary = 0;
    for (var seed = 0; seed < 63; seed++) {
      final m = run(seed); // 64 notes = 16 rounds per seed
      for (var r = 0; r + 4 <= m.length; r += 4) {
        if (m.sublist(r, r + 4).toSet().length != 4) inRound++;
        if (r > 0 && m[r] == m[r - 1]) boundary++;
      }
    }
    expect((inRound, boundary), (0, 0));
  });

  test('keep the chord muted', () {
    final edit = arp(chord(), keep: true), out = edit.notes;
    expect(out.length, 7);
    expect(out.take(3).every((x) => x.muted), isTrue);
    expect(out.skip(3).every((x) => !x.muted), isTrue);
    expect(edit.selection, out.skip(3).toSet());
  });

  test('single note, locked and muted notes', () {
    final one = [n(60, 0, 4)];
    expect(arp(one).notes, same(one));
    final locked = n(72, 0, 4).copyWith(locked: true);
    final muted = n(48, 0, 4).copyWith(muted: true);
    final notes = [...chord(), locked, muted];
    final edit = arp(notes), out = edit.notes;
    expect(out, contains(same(locked)));
    expect(out, contains(same(muted)));
    expect(out.where((x) => x.midi == 72 || x.midi == 48), hasLength(2));
    // a second run over the arpeggio finds no chords
    final again = arp(out, selected: edit.selection);
    expect(again.notes, same(out));
  });

  testWidgets('one command = one edit, the run is selected; Ctrl+Shift+A '
      'reaches the grid under the desktop piano', (tester) async {
    useOfflineTestFonts();
    final p = LoopPrefs.instance;
    p.keyboardBindings.value = {};
    p.arpStyle.value = 'up';
    p.arpGrid.value = 'sixteenth';
    p.arpGate.value = 100;
    p.arpOctaves.value = 1;
    p.arpKeepOriginal.value = false;
    final played = <int>[];
    final key = GlobalKey<GridHarnessState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 720,
              height: 420,
              child: DesktopInstrument(
                group: 'piano',
                identity: 'melody',
                capturePointerFocus: false,
                labels: const ['C', 'D', 'E', 'F', 'G', 'A', 'B'],
                onDown: (i) {
                  played.add(i);
                  return () {};
                },
                child: GridHarness(key: key, notes: chord(), high: 67),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(gridPoint(tester, 7.5, 61, high: 67)); // focus
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA); // select all
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA); // arpeggiate
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(state.notes.map((x) => x.midi), [60, 64, 67, 60]);
    expect(find.text('4 selected'), findsOneWidget);
    expect(played, isEmpty);
    // the inspector button does the same (and reports "nothing to do" now)
    await tapGridButton(tester, 'note-arpeggiate');
    expect(state.commits, 1);
  });
}
