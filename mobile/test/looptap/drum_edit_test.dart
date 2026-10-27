// drums-001: drum hit selection, velocity editing and batch-1 tools on drums.
// docs/specs/drums/dr-001-drum-selection-velocity.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/drum_note_edit.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/note_random.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/state/loop_prefs.dart';

import '../support/drum_grid_harness.dart';

DrumNote hit(
  String kind,
  int step, {
  int? velocity,
  double offset = 0,
  double chance = 1,
  int deviation = 0,
  bool muted = false,
}) => DrumNote(
  kind: kind,
  step: step,
  velocity: velocity,
  offsetSteps: offset,
  chance: chance,
  velocityDeviation: deviation,
  muted: muted,
);

String flatSig(FlatSong f) => [
  for (final l in [f.drums, f.beatDec, ...f.extraDrums.values])
    [for (final n in l) n.toJson()],
].toString();

Section drumSection() {
  final s = Section(id: 'A', name: 'A', repeats: 4);
  s.tracks['drums'] = TrackData(
    drums: [
      for (var i = 0; i < 8; i++)
        hit('hihat', i * 2, chance: .5, velocity: 80, deviation: 20),
      hit('kick', 0),
      hit('snare', 4, muted: true),
    ],
  );
  return s;
}

void main() {
  group('model', () {
    test('JSON: defaults write no new keys, values round-trip', () {
      final plain = hit('kick', 0).toJson();
      expect(plain.keys.toSet(), {'kind', 'step'});
      final j =
          hit('kick', 2, muted: true, chance: .25, deviation: -10).toJson();
      expect(j['muted'], true);
      expect(j['chance'], .25);
      expect(j['velocityDeviation'], -10);
      final back = DrumNote.fromJson(j);
      expect(back.muted, isTrue);
      expect(back.chance, .25);
      expect(back.velocityDeviation, -10);
      // a v2 hit (no new keys) loads with defaults
      final old = DrumNote.fromJson({'kind': 'snare', 'step': 3});
      expect((old.muted, old.chance, old.velocityDeviation), (false, 1.0, 0));
      // through a whole song file
      final song = Song(id: 's', title: 't');
      song.sections.first.tracks['drums'] = TrackData(drums: [back]);
      final again =
          Song.decodeList(Song.encodeList([song]))
              .single
              .sections
              .first
              .tracks['drums']!
              .drumNotes
              .single;
      expect(again.toJson(), j);
    });

    test('copyWith(kind:) keeps velocity, offset and chance', () {
      final n = hit('shaker', 3, velocity: 50, offset: .2, chance: .4);
      final c = n.copyWith(kind: 'clap');
      expect(c.kind, 'clap');
      expect((c.step, c.velocity, c.offsetSteps, c.chance), (3, 50, .2, .4));
    });

    test('Fill pad sound swap keeps strength and micro timing', () {
      final kept = hit('kick', 1);
      final notes = [hit('shaker', 3, velocity: 50, offset: .2), kept];
      final out = remapDrumKind(notes, 'shaker', 'clap');
      expect(out.first.kind, 'clap');
      expect(
        (out.first.step, out.first.velocity, out.first.offsetSteps),
        (3, 50, .2),
      );
      expect(out[1], same(kept));
    });
  });

  group('edits', () {
    test('quantize 1/16: 100% and 50%, no-op identical', () {
      final a = hit('kick', 2, offset: .3);
      final full = quantizeDrumNotes(
        [a],
        {a},
        grid: 1,
        strength: 1,
        steps: 16,
      );
      expect((full.single.step, full.single.offsetSteps), (2, 0.0));
      final b = hit('kick', 2, offset: .4);
      final half = quantizeDrumNotes(
        [b],
        {b},
        grid: 1,
        strength: .5,
        steps: 16,
      );
      expect(half.single.step, 2);
      expect(half.single.offsetSteps, closeTo(.2, 1e-9));
      final on = [hit('kick', 2)];
      expect(
        quantizeDrumNotes(on, on.toSet(), grid: 1, strength: 1, steps: 16),
        same(on),
      );
    });

    test('humanize: deterministic, no-op identical, null velocity', () {
      final notes = [hit('kick', 0), hit('snare', 4), hit('hihat', 4)];
      List<String> run(int seed) => [
        for (final n in humanizeDrumNotes(
          notes,
          notes.toSet(),
          timingSteps: .3,
          velocityRange: 20,
          seed: seed,
          steps: 16,
        ))
          '${n.startSteps}/${n.velocity}',
      ];
      expect(run(5), run(5));
      expect(
        humanizeDrumNotes(
          notes,
          notes.toSet(),
          timingSteps: 0,
          velocityRange: 0,
          seed: 5,
          steps: 16,
        ),
        same(notes),
      );
      final vel = humanizeDrumNotes(
        notes,
        notes.toSet(),
        timingSteps: 0,
        velocityRange: 30,
        seed: 9,
        steps: 16,
      );
      for (var i = 0; i < notes.length; i++) {
        if (identical(vel[i], notes[i])) continue; // dv rounded to 0
        expect(vel[i].velocity, isNotNull);
        expect(vel[i].velocity, isNot(100));
      }
      expect(vel.any((n) => n.velocity != null), isTrue);
    });

    test('shift velocities like shiftPitchVelocities', () {
      List<int?> shift(List<DrumNote> l, int d) => [
        for (final n in shiftDrumVelocities(l, l.toSet(), d)) n.velocity,
      ];
      expect(shift([hit('kick', 0, velocity: 40), hit('kick', 1, velocity: 60)], 30), [70, 90]);
      expect(shift([hit('kick', 0, velocity: 100), hit('kick', 1, velocity: 120)], 30), [127, 127]);
      expect(shift([hit('kick', 0)], 30), [127]);
    });

    test('mute toggles the selection as a whole', () {
      final m = hit('kick', 0, muted: true), a = hit('kick', 1);
      final both = setDrumNotesMuted([m, a], {m, a}, true);
      expect(both.every((n) => n.muted), isTrue);
      expect(both.first, same(m));
      final back = setDrumNotesMuted(both, both.toSet(), false);
      expect(back.every((n) => !n.muted), isTrue);
    });

    test('move stops the group at the section edges', () {
      final a = hit('kick', 0), b = hit('kick', 14, offset: .5);
      final right = moveDrumNotes([a, b], {a, b}, deltaSteps: 4, steps: 16);
      expect(right.map((n) => n.startSteps), [.5, 15.0]);
      final pair = [a, b];
      // the first hit is already at 0, so the group cannot move left
      expect(moveDrumNotes(pair, {a, b}, deltaSteps: -1, steps: 16), same(pair));
      expect(moveDrumNotes([a], {a}, deltaSteps: -1, steps: 16).single, same(a));
      final fine = moveDrumNotes([a], {a}, deltaSteps: .25, steps: 16);
      expect((fine.single.step, fine.single.offsetSteps), (0, .25));
    });
  });

  group('realizeDrumNote', () {
    List<DrumNote?> rolls(DrumNote n) => [
      for (var p = 0; p < 500; p++)
        realizeDrumNote(n, seed: 7, sectionId: 'A', trackId: 'drums', pass: p),
    ];

    test('chance 0 never sounds; chance 1 passes the hit through', () {
      expect(rolls(hit('kick', 0, chance: 0)).every((n) => n == null), isTrue);
      final plain = hit('kick', 0, velocity: 77);
      expect(rolls(plain).every((n) => identical(n, plain)), isTrue);
    });

    test('same key same result, kind is part of the key', () {
      String sig(List<DrumNote?> l) => [for (final n in l) n?.velocity].join();
      final k = hit('kick', 2, chance: .5, velocity: 70, deviation: 30);
      expect(sig(rolls(k)), sig(rolls(k)));
      expect(sig(rolls(k.copyWith(kind: 'snare'))), isNot(sig(rolls(k))));
    });
  });

  group('flattenSong', () {
    test('muted hits are dropped; a fixed seed is reproducible', () {
      final plain = flattenSong([drumSection()]);
      expect(plain.drums.where((n) => n.kind == 'snare'), isEmpty);
      expect(plain.drums.length, 4 * 9);
      final a = flattenSong([drumSection()], variationSeed: 3);
      final b = flattenSong([drumSection()], variationSeed: 3);
      expect(flatSig(a), flatSig(b));
      expect(buildMidi(a, 120), buildMidi(b, 120));
      expect(a.drums.where((n) => n.kind == 'hihat').length, lessThan(32));
      expect(
        a.drums.every((n) => n.chance == 1 && n.velocityDeviation == 0),
        isTrue,
      );
    });
  });

  test('playback: muted and chance-0 hits never reach playDrum', () {
    final played = <(String, int?)>[]; // fake audio
    final notes = [
      hit('kick', 0, velocity: 90),
      hit('snare', 0, muted: true),
      hit('hihat', 0, chance: 0),
      hit('clap', 1),
    ];
    for (var pass = 0; pass < 20; pass++) {
      for (final h in soundingDrumHits(
        notes,
        0,
        seed: 1,
        sectionId: 'A',
        trackId: 'drums',
        pass: pass,
      )) {
        played.add((h.note.kind, h.played.velocity));
      }
    }
    expect(played.toSet(), {('kick', 90)});
    expect(played.length, 20);
  });

  group('DrumGrid', () {
    testWidgets('draw mode tap toggles through onToggle', (tester) async {
      final key = await mountDrums(tester, [], selectMode: false);
      await tester.tapAt(drumPoint(tester, 3.5, 2));
      await tester.pump();
      expect(key.currentState!.toggled, [('kick', 3)]);
      expect(key.currentState!.commits, 0);
    });

    testWidgets('select: tap one, drag a box, Delete commits once', (
      tester,
    ) async {
      final notes = [
        hit('hihat', 1),
        hit('snare', 2),
        hit('kick', 3),
        hit('kick', 3), // stacked twin
        hit('kick', 12),
      ];
      final key = await mountDrums(tester, notes);
      await tester.tapAt(drumPoint(tester, 1.5, 0));
      await tester.pump();
      expect(find.text('1 SELECTED'), findsOneWidget);
      // box from empty space over rows 0..2, steps 0..5
      await tester.dragFrom(
        drumPoint(tester, 0.2, 0) - const Offset(0, 10),
        drumPoint(tester, 5.5, 2) - drumPoint(tester, 0.2, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('4 SELECTED'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      final state = key.currentState!;
      expect(state.commits, 1);
      expect(state.notes, [same(notes[4])]);
      // Undo restores the exact objects
      state.undoLast();
      await tester.pump();
      expect(state.notes, notes);
    });

    testWidgets('velocity lane drag = one edit, one undo', (tester) async {
      final a = hit('kick', 2, velocity: 60), b = hit('kick', 6, velocity: 80);
      final key = await mountDrums(tester, [a, b]);
      // select both kick hits, then drag one bar up
      await tester.tapAt(drumPoint(tester, 2.5, 2));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tapAt(drumPoint(tester, 6.5, 2));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      final lane = tester.getRect(
        find.byKey(const ValueKey('drum-velocity-lane')),
      );
      final g = await tester.startGesture(
        Offset(lane.left + lane.width * 2.5 / 16, lane.center.dy),
      );
      for (var i = 0; i < 3; i++) {
        await g.moveBy(const Offset(0, -2));
        await tester.pump();
      }
      await g.up();
      await tester.pump();
      final state = key.currentState!;
      expect(state.commits, 1);
      final d = state.notes[0].velocity! - 60;
      expect(d, greaterThan(0));
      expect(state.notes[1].velocity, 80 + d);
      state.undoLast();
      await tester.pump();
      expect(state.notes, [same(a), same(b)]);
    });

    testWidgets('every shortcut reaches the grid under a DesktopInstrument', (
      tester,
    ) async {
      LoopPrefs.instance.quantizeGrid.value = 'sixteenth';
      LoopPrefs.instance.quantizeStrength.value = 100;
      LoopPrefs.instance.humanizeTiming.value = .3;
      LoopPrefs.instance.humanizeVelocity.value = 20;
      final instrument = <int>[];
      final key = await mountDrums(
        tester,
        [hit('kick', 2, velocity: 60, offset: .3), hit('snare', 8)],
        selectMode: false,
        instrument: true,
        instrumentHits: instrument,
      );
      final state = key.currentState!;
      Future<void> press(
        LogicalKeyboardKey k, {
        bool ctrl = false,
        bool shift = false,
      }) async {
        if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(k);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      // focus the grid by its row label (no toggle)
      await tester.tap(find.byKey(const ValueKey('drum-row-kick')));
      await tester.pump();
      await press(LogicalKeyboardKey.keyB, ctrl: true); // → select mode
      expect(find.byKey(const ValueKey('drum-velocity-lane')), findsOneWidget);
      await press(LogicalKeyboardKey.keyA, ctrl: true);
      expect(find.text('2 SELECTED'), findsOneWidget);
      await press(LogicalKeyboardKey.escape);
      expect(find.text('2 SELECTED'), findsNothing);
      await press(LogicalKeyboardKey.keyA, ctrl: true);
      await press(LogicalKeyboardKey.keyU, ctrl: true); // quantize
      expect(state.notes.first.offsetSteps, 0);
      await press(LogicalKeyboardKey.arrowRight);
      expect(state.notes.map((n) => n.step), [3, 9]);
      await press(LogicalKeyboardKey.arrowLeft, shift: true);
      expect(state.notes.first.startSteps, 2.75);
      await press(LogicalKeyboardKey.arrowUp);
      expect(state.notes.first.velocity, 65);
      await press(LogicalKeyboardKey.arrowDown, shift: true);
      expect(state.notes.first.velocity, 45);
      await press(LogicalKeyboardKey.keyM);
      expect(state.notes.every((n) => n.muted), isTrue);
      await tester.tap(find.byKey(const ValueKey('drum-lane-chance')));
      await tester.pump();
      await press(LogicalKeyboardKey.arrowDown, ctrl: true);
      expect(state.notes.every((n) => n.chance == .9), isTrue);
      final before = state.commits;
      await press(LogicalKeyboardKey.keyH, ctrl: true, shift: true);
      expect(state.commits, before + 1); // humanize applied
      await press(LogicalKeyboardKey.delete);
      expect(state.notes, isEmpty);
      await press(LogicalKeyboardKey.keyB, ctrl: true); // → draw mode
      expect(find.byKey(const ValueKey('drum-velocity-lane')), findsNothing);
      // none of these keys played the drum pads
      expect(instrument, isEmpty);
      // ...while a plain drum key still does
      await tester.sendKeyEvent(LogicalKeyboardKey.keyD);
      expect(instrument, [0]);
    });
  });
}
