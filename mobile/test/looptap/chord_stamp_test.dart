// harmony-001: chord stamp (top-down under selected notes, bottom-up at the
// click). docs/specs/harmony/hm-001-chord-stamp.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/widgets/desktop_instrument.dart';

import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

PitchNote note(int midi, double start, double end) {
  final step = start.floor();
  return PitchNote(
    midi: midi,
    freq: midiToFreq(midi),
    step: step,
    dur: (end - start).ceil(),
    offsetSteps: start - step,
    durationSteps: end - start == (end - start).roundToDouble() &&
            start == step
        ? null
        : end - start,
  );
}

/// The pad chord logic as it was before the refactor (regression oracle).
List<int> legacyPadChord(
  int root, {
  required bool melody,
  required bool chordOn,
  required bool powerOn,
  required bool guitar,
  required String key,
  required String scale,
}) {
  if (!melody) return [root];
  if (powerOn) return guitar ? guitarPowerVoicing(root) : powerChord(root);
  if (!chordOn) return [root];
  return guitar
      ? guitarVoicing(root, key, scale)
      : diatonicTriad(root, key, scale);
}

void main() {
  setUp(() {
    LoopPrefs.instance.chordType.value = 'diatonic3';
    LoopPrefs.instance.chordInversion.value = 0;
  });

  group('chordMidis', () {
    test('diatonic triads in C major, including an off-scale root', () {
      List<int> c(int r) =>
          chordMidis(ChordType.diatonic3, r, key: 'C', scale: 'major');
      expect(c(60), [60, 64, 67]);
      expect(c(62), [62, 65, 69]);
      expect(c(61), [62, 65, 69]);
      expect(
        chordMidis(ChordType.diatonic7, 60, key: 'C', scale: 'major'),
        [60, 64, 67, 71],
      );
    });

    test('A minor triad and its inversions', () {
      List<int> a(int inv) => chordMidis(
        ChordType.diatonic3,
        57,
        key: 'A',
        scale: 'minor',
        inversion: inv,
      );
      expect(a(0), [57, 60, 64]);
      expect(a(1), [60, 64, 69]);
      expect(a(2), [64, 69, 72]);
    });

    test('fixed kinds ignore the scale', () {
      expect(
        chordMidis(ChordType.major, 60, key: 'C', scale: 'minor'),
        [60, 64, 67],
      );
    });

    test('pad chords are unchanged by the refactor', () {
      var cases = 0;
      for (final melody in [true, false]) {
        for (final chordOn in [true, false]) {
          for (final powerOn in [true, false]) {
            for (final guitar in [true, false]) {
              for (final scale in kScales.keys) {
                for (final key in ['C', 'A', 'F#']) {
                  for (var root = 36; root <= 96; root++) {
                    expect(
                      padChordMidis(
                        root,
                        melodyGroup: melody,
                        chordOn: chordOn,
                        powerOn: powerOn,
                        guitar: guitar,
                        key: key,
                        scale: scale,
                      ),
                      legacyPadChord(
                        root,
                        melody: melody,
                        chordOn: chordOn,
                        powerOn: powerOn,
                        guitar: guitar,
                        key: key,
                        scale: scale,
                      ),
                    );
                    cases++;
                  }
                }
              }
            }
          }
        }
      }
      expect(cases, greaterThan(12));
    });

    test('chromatic disables Diatonic (Major instead), pentatonic → minor', () {
      expect(effectiveChordType(ChordType.diatonic3, 'chromatic'), ChordType.major);
      expect(effectiveChordType(ChordType.diatonic7, null), ChordType.major);
      expect(effectiveChordType(ChordType.sus4, 'chromatic'), ChordType.sus4);
      expect(effectiveChordType(ChordType.diatonic3, 'major'), ChordType.diatonic3);
      expect(chordScaleFor('pentatonic'), 'minor');
      expect(chordScaleFor('chromatic'), isNull);
    });
  });

  group('stampChordsBelow', () {
    PitchNoteEdit below(List<PitchNote> notes, Set<PitchNote> sel) =>
        stampChordsBelow(
          notes,
          sel,
          ChordType.diatonic3,
          key: 'C',
          scale: 'major',
        );

    test('C major: G4 picks I, F4 picks IV (close voicing below)', () {
      final g = note(67, 0, 4);
      final r = below([g], {g});
      expect(r.notes.skip(1).map((n) => n.midi), [60, 64]);
      expect(r.notes.skip(1).every((n) => n.startSteps == 0), isTrue);
      expect(r.notes.skip(1).every((n) => n.endSteps == 4), isTrue);
      expect(r.notes.first, same(g));
      expect(r.selection, r.notes.skip(1).toSet());
      final f = note(65, 0, 4);
      expect(below([f], {f}).notes.skip(1).map((n) => n.midi), [57, 60]);
    });

    test('members inherit expression, provenance is reset', () {
      final m = PitchNote(
        midi: 67,
        freq: midiToFreq(67),
        step: 1,
        dur: 4,
        offsetSteps: .25,
        durationSteps: 3.5,
        velocity: 90,
        chance: .5,
        sourceMidi: 66,
        assisted: true,
        confidence: .4,
        locked: true,
      );
      final added = below([m], {m}).selection;
      expect(added, hasLength(2));
      for (final n in added) {
        expect(n.velocity, 90);
        expect(n.offsetSteps, .25);
        expect(n.durationSteps, 3.5);
        expect(n.chance, .5);
        expect(n.sourceMidi, isNull);
        expect(n.assisted, isFalse);
        expect(n.confidence, 1.0);
        expect(n.locked, isFalse);
      }
    });

    test('a same-start group uses its highest note; existing pitches skip', () {
      final c = note(60, 0, 2), g = note(67, 0, 2);
      final r = below([c, g], {c, g});
      expect(r.notes.skip(2).map((n) => n.midi), [64]);
    });

    test('nothing to add returns the input itself', () {
      final notes = [note(60, 0, 2), note(64, 0, 2), note(67, 0, 2)];
      final r = below(notes, {notes.last});
      expect(r.notes, same(notes));
    });
  });

  group('StepGrid', () {
    testWidgets('chord stamp mode: one click = one chord, one commit', (
      tester,
    ) async {
      final key = await mountGrid(
        tester,
        [],
        low: 59,
        high: 66,
        scaleRoot: 'C',
        scaleName: 'major',
      );
      await tapGridButton(tester, 'grid-chord-stamp');
      await tester.tapAt(gridPoint(tester, 2.5, 60, low: 59, high: 66));
      await tester.pumpAndSettle();
      final state = key.currentState!;
      expect(state.commits, 1);
      expect(state.placed, isEmpty);
      expect(state.notes.map((n) => n.midi), [60, 64, 67]);
      expect(state.notes.every((n) => n.step == 2), isTrue);
      // the new chord is the selection
      await tapGridButton(tester, 'note-select');
      expect(find.text('3 selected'), findsOneWidget);
    });

    testWidgets('chromatic song: Diatonic chips disabled', (tester) async {
      await mountGrid(tester, [], scaleRoot: 'C', scaleName: 'chromatic');
      final button = find.byKey(const ValueKey('grid-chord-stamp'));
      await tester.ensureVisible(button);
      await tester.longPress(button);
      await tester.pumpAndSettle();
      final diatonic = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('chord-type-diatonic3')),
      );
      expect(diatonic.onSelected, isNull);
      final major = tester.widget<ChoiceChip>(
        find.byKey(const ValueKey('chord-type-major')),
      );
      expect(major.selected, isTrue);
    });

    testWidgets('C, Shift+C, Ctrl+Shift+C reach the grid under the piano', (
      tester,
    ) async {
      useOfflineTestFonts();
      LoopPrefs.instance.keyboardBindings.value = {};
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
                  child: GridHarness(
                    key: key,
                    notes: [note(67, 0, 4)],
                    low: 60,
                    high: 67,
                    scaleRoot: 'C',
                    scaleName: 'major',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final state = key.currentState!;
      await tester.tapAt(gridPoint(tester, 1, 67, low: 60, high: 67));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.pump();
      expect(state.commits, 1);
      expect(state.notes.map((n) => n.midi), [67, 60, 64]);
      // Shift+C: kind picker
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('chord-type-major')), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      // Ctrl+Shift+C: chord stamp mode, then click an empty cell
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.tapAt(gridPoint(tester, 6.5, 62, low: 60, high: 67));
      await tester.pumpAndSettle();
      expect(state.commits, 2);
      expect(state.notes.skip(3).map((n) => n.midi), [62, 65, 69]);
      expect(played, isEmpty);
    });
  });
}
