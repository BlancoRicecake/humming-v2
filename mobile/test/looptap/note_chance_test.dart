// piano-roll-007: note chance and velocity variation.
// docs/specs/piano-roll/pr-007-note-chance-velocity-random.md
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/note_random.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

import '../support/step_grid_harness.dart';

PitchNote at(
  int midi,
  int step, {
  double chance = 1,
  int deviation = 0,
  int? velocity,
  bool muted = false,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: 1,
  chance: chance,
  velocityDeviation: deviation,
  velocity: velocity,
  muted: muted,
);

List<PitchNote?> rolls(PitchNote n, {int seed = 7, int passes = 1000}) => [
  for (var p = 0; p < passes; p++)
    realizePitchNote(n, seed: seed, sectionId: 'A', trackId: 'melody', pass: p),
];

String flatSig(FlatSong f) => [
  for (final l in [f.melody, f.bass, ...f.extraPitched.values])
    [for (final n in l) n.toJson()],
].toString();

Section chanceSection() {
  final s = Section(id: 'A', name: 'A', repeats: 4);
  s.tracks['melody'] = TrackData(
    notes: [for (var i = 0; i < 8; i++) at(60 + i, i * 2, chance: .5)],
  );
  s.tracks['bass'] = TrackData(
    notes: [
      for (var i = 0; i < 4; i++)
        at(36 + i, i * 4, chance: .5, velocity: 80, deviation: 20),
    ],
  );
  return s;
}

void main() {
  test('chance 1 and no variation always sound unchanged', () {
    final out = rolls(at(60, 0));
    expect(out.every((n) => n != null && n.velocity == null), isTrue);
  });

  test('chance 0 and muted notes never sound', () {
    expect(rolls(at(60, 0, chance: 0)).every((n) => n == null), isTrue);
    expect(rolls(at(60, 0, muted: true)).every((n) => n == null), isTrue);
  });

  test('chance 0.5 sounds about half the passes', () {
    final hits = rolls(at(60, 0, chance: .5)).whereType<PitchNote>().length;
    expect(hits, inInclusiveRange(450, 550));
  });

  test('velocity variation spans the range in its direction', () {
    final up =
        rolls(at(60, 0, velocity: 60, deviation: 20))
            .map((n) => n!.velocity!)
            .toList();
    expect(up.every((v) => v >= 60 && v <= 80), isTrue);
    expect(up.reduce((a, b) => a < b ? a : b), lessThanOrEqualTo(62));
    expect(up.reduce((a, b) => a > b ? a : b), greaterThanOrEqualTo(78));
    final down = rolls(at(60, 0, velocity: 60, deviation: -20));
    expect(down.every((n) => n!.velocity! >= 40 && n.velocity! <= 60), isTrue);
  });

  test('variation is clamped to 127', () {
    final out = rolls(at(60, 0, velocity: 120, deviation: 20));
    expect(out.map((n) => n!.velocity!).reduce((a, b) => a > b ? a : b), 127);
  });

  test('rolls are deterministic and independent of other notes', () {
    final n = at(64, 3, chance: .5, velocity: 70, deviation: -30);
    String sig(List<PitchNote?> l) => [for (final x in l) x?.velocity].join();
    expect(sig(rolls(n)), sig(rolls(n)));
    // the roll is keyed by content, not list position: notes around it
    // (flattened in another order) do not change it
    final s1 = Section(id: 'A', name: 'A', repeats: 3);
    s1.tracks['melody'] = TrackData(notes: [n]);
    final s2 = Section(id: 'A', name: 'A', repeats: 3);
    s2.tracks['melody'] = TrackData(
      notes: [at(60, 0, chance: .5), at(62, 8, chance: .3), n],
    );
    List<int?> mine(FlatSong f) => [
      for (final x in f.melody)
        if (x.midi == 64) x.velocity,
    ];
    expect(
      mine(flattenSong([s2], variationSeed: 11)),
      mine(flattenSong([s1], variationSeed: 11)),
    );
  });

  test('chance and variation round-trip through JSON with defaults', () {
    final plain = at(60, 0).toJson();
    expect(plain.containsKey('chance'), isFalse);
    expect(plain.containsKey('velocityDeviation'), isFalse);
    final j = at(60, 0, chance: .25, deviation: -12).toJson();
    expect(j['chance'], .25);
    expect(j['velocityDeviation'], -12);
    final back = PitchNote.fromJson(j);
    expect(back.chance, .25);
    expect(back.velocityDeviation, -12);
    final old = PitchNote.fromJson(plain);
    expect(old.chance, 1.0);
    expect(old.velocityDeviation, 0);
    expect(PitchNote.fromJson({...plain, 'chance': 3}).chance, 1.0);
    // song seed: only stored when set, else derived from the id
    final song = Song(id: 'song-1', title: 't');
    expect(song.toJson().containsKey('variationSeed'), isFalse);
    expect(song.effectiveVariationSeed, fnv1a32('song-1'));
    song.variationSeed = 99;
    expect(Song.fromJson(song.toJson()).variationSeed, 99);
  });

  test('flattenSong with a seed is reproducible (FlatSong and MIDI bytes)', () {
    final a = flattenSong([chanceSection()], variationSeed: 7);
    final b = flattenSong([chanceSection()], variationSeed: 7);
    expect(flatSig(a), flatSig(b));
    expect(buildMidi(a, 120), buildMidi(b, 120));
    // a real variation: some notes were dropped across the 4 repeats
    expect(a.melody.length, lessThan(32));
    expect(a.melody.length, greaterThan(0));
    // baked notes are final: no further chance/variation
    expect(a.melody.every((n) => n.chance == 1), isTrue);
    expect(a.bass.every((n) => n.velocityDeviation == 0), isTrue);
    expect(
      flatSig(flattenSong([chanceSection()], variationSeed: 8)),
      isNot(flatSig(a)),
    );
  });

  test('flattenSong without a seed keeps every non-muted note', () {
    final s = chanceSection();
    s.tracks['melody']!.pitchNotes.add(at(72, 15, muted: true));
    final flat = flattenSong([s]);
    expect(flat.melody.length, 32);
    expect(flat.bass.length, 16);
  });

  test('stems and mix use the same variation', () {
    Set<(int, int, int)> ons(Uint8List bytes) => {
      for (final l in MidiReference.parse(bytes).lanes)
        for (final n in l.notes) (n.pitch, n.tick, n.velocity),
    };
    // exportWavSong and exportStems each flatten with the song seed
    final mix = flattenSong([chanceSection()], variationSeed: 7);
    final stemFlat = flattenSong([chanceSection()], variationSeed: 7);
    expect(flatSig(stemFlat), flatSig(mix));
    final full = ons(buildMidi(mix, 120));
    final stems = {
      ...ons(buildMidi(stemFlat, 120, tracks: {'melody'})),
      ...ons(buildMidi(stemFlat, 120, tracks: {'bass'})),
    };
    expect(stems, full);
  });

  test('chance setters skip locked notes and no-ops', () {
    final a = at(60, 0), l = at(62, 1).copyWith(locked: true);
    final notes = [a, l];
    final set = setPitchChance(notes, {a, l}, .5);
    expect(set[0].chance, .5);
    expect(set[1], same(l));
    expect(setPitchChance(set, {set[0]}, .5), same(set));
    final up = shiftPitchChance(set, {set[0]}, .1);
    expect(up[0].chance, closeTo(.6, 1e-9));
    final dev = setPitchVelocityDeviation(notes, {a}, -20);
    expect(dev[0].velocityDeviation, -20);
    expect(setPitchVelocityDeviation(dev, {dev[0]}, -20), same(dev));
  });

  testWidgets('chance lane: Ctrl+Down lowers chance by 10%', (tester) async {
    final key = await mountGrid(tester, [at(60, 1, chance: .5)]);
    await tester.tap(find.byKey(const ValueKey('velocity-lane-chance')));
    await tester.pump();
    await tester.tapAt(gridPoint(tester, 1.5, 60));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final state = key.currentState!;
    expect(state.commits, 1);
    expect(state.notes.single.chance, closeTo(.4, 1e-9));
  });
}
