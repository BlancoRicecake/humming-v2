// gt-003 guitar articulations: data model, apply/revert, inheritance, range
// refusal, natural-harmonic info, the shared realize step and the per-song
// channel plan. Pure (no audio).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/pitch_clipboard.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/theory.dart';

PitchNote note(int midi, int step, {int dur = 2, int? velocity}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  velocity: velocity,
);

const palm = Articulation(
  kind: ArticulationKind.palmTone,
  gateMs: 250,
  velScale: .85,
);
const harm = Articulation(kind: ArticulationKind.harmonicTone);
const stac = Articulation(kind: ArticulationKind.staccato, gateMs: 120);

String js(Object o) => jsonEncode(o);

/// A guitar song (melody on GM 25) with [notes] and [extras] added tracks.
Song guitarSong(List<PitchNote> notes, {int extras = 0, int program = 25}) {
  final sec = Section(
    id: 'A',
    name: 'A',
    extras: [for (var i = 0; i < extras; i++) TrackRef('melody_x$i', 'melody')],
  )..tracks['melody'] = TrackData(notes: notes);
  return Song(
    id: 's',
    title: 's',
    sections: [sec],
    instruments: {'melody': program},
  );
}

void main() {
  group('data model', () {
    test('JSON round trip is exact; the field is written only when set', () {
      final n = note(76, 0);
      expect(n.toJson().containsKey('articulation'), isFalse);
      for (final a in [palm, harm, stac]) {
        final t = n.withArticulation(a);
        final back = PitchNote.fromJson(
          jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
        );
        expect(back.articulation, a);
        expect(js(back.toJson()), js(t.toJson()));
      }
      // harmonic stores no gate / scale (defaults are not written)
      expect(n.withArticulation(harm).toJson()['articulation'], {
        'kind': 'harmonicTone',
      });
    });

    test('unknown kinds and garbage load as normal; old songs load', () {
      for (final raw in [
        {'kind': 'pinch'},
        'palmTone',
        42,
        {'gateMs': 100},
      ]) {
        final j = {...note(60, 0).toJson(), 'articulation': raw};
        expect(PitchNote.fromJson(j).articulation, isNull, reason: '$raw');
      }
      final old = PitchNote.fromJson(note(60, 0).toJson());
      expect(old.articulation, isNull);
    });

    test('a pitch outside the kind range drops it (constructor rule)', () {
      expect(note(73, 0).withArticulation(harm).articulation, isNull);
      expect(note(111, 0).withArticulation(harm).articulation, isNull);
      expect(note(74, 0).withArticulation(harm).articulation, harm);
      expect(note(110, 0).withArticulation(harm).articulation, harm);
      expect(note(39, 0).withArticulation(palm).articulation, isNull);
      expect(note(87, 0).withArticulation(palm).articulation, isNull);
      expect(note(40, 0).withArticulation(palm).articulation, palm);
      expect(note(86, 0).withArticulation(palm).articulation, palm);
      expect(note(20, 0).withArticulation(stac).articulation, stac);
    });
  });

  group('apply', () {
    test('apply then 일반으로 restores the exact JSON (G1/G2 data kept)', () {
      // a stroke-converted, string-assigned, ringing hit, then a later
      // manual velocity edit
      var notes =
          applyGuitarStroke(
            [note(52, 0, dur: 4), note(56, 0, dur: 4), note(59, 0, dur: 4)],
            {},
            const StrokeSpec.down(spreadMs: 30),
            bpm: 100,
          ).notes;
      notes = assignStrings(notes, {}).notes;
      notes = applyRing(notes, {}, rangeEnd: 16).notes;
      notes = setPitchVelocity(notes, {notes.first}, 90);
      final before = js([for (final n in notes) n.toJson()]);
      for (final kind in ArticulationKind.values) {
        final a = applyArticulation(notes, {}, newArticulation(kind));
        // only the articulation field changed
        for (var i = 0; i < notes.length; i++) {
          final m = Map.of(a.notes[i].toJson())..remove('articulation');
          expect(js(m), js(notes[i].toJson()));
        }
        final back = applyArticulation(a.notes, {}, null);
        expect(js([for (final n in back.notes) n.toJson()]), before);
      }
    });

    test('switching kinds keeps G1/G2 data and later manual edits', () {
      var notes = assignStrings(
        applyGuitarStroke(
          [note(52, 0, dur: 4), note(59, 0, dur: 4), note(64, 0, dur: 4)],
          {},
          const StrokeSpec.down(),
          bpm: 120,
        ).notes,
        {},
      ).notes;
      notes = applyArticulation(notes, {}, stac).notes;
      notes = setPitchVelocity(notes, {notes[1]}, 77); // manual edit
      final reference = [
        for (final n in notes) js((Map.of(n.toJson())..remove('articulation'))),
      ];
      for (final v in [palm, stac, palm, null, stac, null]) {
        notes = applyArticulation(notes, {}, v).notes;
        expect([
          for (final n in notes)
            js((Map.of(n.toJson())..remove('articulation'))),
        ], reference);
      }
      expect(notes.every((n) => n.articulation == null), isTrue);
      expect(notes[1].velocity, 77);
      // the velocity edit dropped that note's stroke tag (gt-001 rule); the
      // others keep theirs
      expect([notes[0], notes[2]].every((n) => n.stroke != null), isTrue);
    });

    test('scope: selection, nothing selected = whole track, locked skipped, '
        'muted tagged; repeated applies are idempotent', () {
      final locked = PitchNote(midi: 52, freq: 1, step: 4, locked: true);
      final muted = PitchNote(midi: 55, freq: 1, step: 8, muted: true);
      final a = note(50, 0), b = note(57, 2);
      final notes = [a, b, locked, muted];
      final sel = applyArticulation(notes, {b}, palm);
      expect(sel.applied, 1);
      expect([for (final n in sel.notes) n.articulation], [
        null,
        palm,
        null,
        null,
      ]);
      expect(sel.selection.single.articulation, palm);
      final all = applyArticulation(notes, {}, palm);
      expect(all.applied, 3);
      expect(all.notes[2].articulation, isNull, reason: 'locked');
      expect(all.notes[3].articulation, palm, reason: 'muted is tagged');
      final again = applyArticulation(all.notes, {}, palm);
      expect(identical(again.notes, all.notes), isTrue);
      expect(again.applied, 3);
    });

    test('harmonic outside 74..110 is refused, pitch unchanged, counted', () {
      final notes = [note(52, 0), note(74, 0), note(110, 2), note(111, 4)];
      final e = applyArticulation(notes, {}, harm);
      expect(e.applied, 2);
      expect(e.outOfRange, 2);
      expect([for (final n in e.notes) n.midi], [52, 74, 110, 111]);
      expect([for (final n in e.notes) n.articulation], [
        null,
        harm,
        harm,
        null,
      ]);
      final p = applyArticulation([note(39, 0), note(40, 0), note(86, 0), note(87, 0)], {}, palm);
      expect((p.applied, p.outOfRange), (2, 2));
    });

    test('no free channel refuses the whole apply and counts it', () {
      final notes = [note(76, 0), note(80, 2)];
      final e = applyArticulation(
        notes,
        {},
        harm,
        channelFor: (role, tentative) => null,
      );
      expect(identical(e.notes, notes), isTrue);
      expect((e.applied, e.outOfRange, e.noChannel), (0, 0, 2));
      // a channel available: applied
      final ok = applyArticulation(
        notes,
        {},
        harm,
        channelFor: (role, tentative) {
          expect(role, ArtRole.harmonicVoice);
          expect(tentative.every((n) => n.articulation == harm), isTrue);
          return 3;
        },
      );
      expect(ok.applied, 2);
    });
  });

  group('inheritance', () {
    final base = [note(76, 0, dur: 4).withArticulation(harm)];

    test('copy/paste, duplicate, save/load and section copy keep it', () {
      final clip = PitchClipboard()..copy(base);
      expect(clip.paste(atStep: 8, steps: 16).single.articulation, harm);
      expect(
        duplicatePitchNotes(base, base.toSet(), 16).last.articulation,
        harm,
      );
      final song = guitarSong(List.of(base));
      final loaded = Song.fromJson(
        jsonDecode(jsonEncode(song.toJson())) as Map<String, dynamic>,
      );
      expect(
        loaded.sections.single.tracks['melody']!.pitchNotes.single.articulation,
        harm,
      );
      final copy = song.sections.single.deepCopy();
      expect(copy.tracks['melody']!.pitchNotes.single.articulation, harm);
    });

    test('split/chop parts inherit; glue takes the earliest part', () {
      final split = splitPitchNotesAt(base, base.toSet(), 2);
      expect(split.notes.map((n) => n.articulation), [harm, harm]);
      final chop = chopPitchNotes(base, base.toSet(), parts: 4);
      expect(chop.notes.every((n) => n.articulation == harm), isTrue);
      final parts = [
        note(76, 0).withArticulation(stac),
        note(76, 2).withArticulation(harm),
      ];
      final glued = gluePitchNotes(parts, parts.toSet());
      expect(glued.notes.single.articulation, stac);
    });

    test('timing edits and stroke apply/revert keep it', () {
      final moved = movePitchNotes(
        base,
        base.toSet(),
        deltaSteps: 1.5,
        semitones: 0,
        steps: 16,
      );
      expect(moved.single.articulation, harm);
      expect(
        resizePitchNotes(base, base.toSet(), deltaSteps: 1, steps: 16)
            .single
            .articulation,
        harm,
      );
      final hit = [
        note(76, 0).withArticulation(harm),
        note(79, 0).withArticulation(harm),
      ];
      final stroked = applyGuitarStroke(
        hit,
        {},
        const StrokeSpec.down(),
        bpm: 120,
      ).notes;
      expect(stroked.every((n) => n.articulation == harm), isTrue);
      final reverted = revertGuitarStroke(stroked, {}).notes;
      expect(reverted.every((n) => n.articulation == harm), isTrue);
    });

    test('a pitch edit out of range clears it; in range keeps it', () {
      final up = movePitchNotes(
        base,
        base.toSet(),
        deltaSteps: 0,
        semitones: 2,
        steps: 16,
      );
      expect(up.single.articulation, harm);
      final down = movePitchNotes(
        base,
        base.toSet(),
        deltaSteps: 0,
        semitones: -3,
        steps: 16,
      );
      expect(down.single.midi, 73);
      expect(down.single.articulation, isNull);
    });

    test('paint never merges articulated notes into a plain one', () {
      final notes = [
        note(60, 0, dur: 1).withArticulation(stac),
        note(60, 2, dur: 1),
        note(60, 4, dur: 1).withArticulation(stac),
      ];
      final painted = paintPitchSpan(notes, note(60, 0, dur: 6));
      expect(
        painted.where((n) => n.articulation == stac).length,
        2,
        reason: 'both articulated notes kept',
      );
    });
  });

  group('natural-harmonic info (display only)', () {
    test('valid string positions and invalid / unknown cases', () {
      // string 1 (E4 64): 76 = +12 at fret 12 → node fret 12
      final n76 = PitchNote(midi: 76, freq: 1, step: 0, guitarString: 1);
      expect(naturalHarmonicPosition(n76), (string: 1, fret: 12));
      // string 2 (B3 59): 78 = +19 → node fret 7
      final n78 = PitchNote(midi: 78, freq: 1, step: 0, guitarString: 2);
      expect(naturalHarmonicPosition(n78), (string: 2, fret: 7));
      // string 1, 77 = +13: not a natural harmonic
      final n77 = PitchNote(midi: 77, freq: 1, step: 0, guitarString: 1);
      expect(naturalHarmonicPosition(n77), isNull);
      // no G2 string: unknown
      expect(naturalHarmonicPosition(note(76, 0)), isNull);
      // an unplayable stored string is dropped by the model, so unknown
      final bad = PitchNote(midi: 110, freq: 1, step: 0, guitarString: 6);
      expect(bad.guitarString, isNull);
      expect(naturalHarmonicPosition(bad), isNull);
    });

    test('grid markers', () {
      expect(articulationMark(note(60, 0).withArticulation(stac)), 's');
      expect(articulationMark(note(60, 0).withArticulation(palm)), 'PM');
      expect(articulationMark(note(80, 0).withArticulation(harm)), '◇');
      expect(articulationMark(note(60, 0)), isNull);
    });
  });

  group('realize', () {
    const ctx = ArticulationContext(
      guitar: true,
      bpm: 120,
      muteChannel: 3,
      harmonicChannel: 4,
    );
    // at 120 BPM one step = 125 ms
    test('staccato: track channel, gate capped at 120 ms, velocity kept', () {
      final e = realizeArticulation(
        note(60, 0, velocity: 90).withArticulation(stac),
        ctx,
        velocity: 90,
        gateSteps: 2,
      );
      expect(e.role, ArtRole.track);
      expect(e.channel, isNull);
      expect((e.key, e.velocity), (60, 90));
      expect(e.gateSteps, closeTo(120 / 125, 1e-9));
      // a gate already shorter than the cap stays (ring capped, never grown)
      final short = realizeArticulation(
        note(60, 0).withArticulation(stac),
        ctx,
        velocity: null,
        gateSteps: .5,
      );
      expect(short.gateSteps, .5);
      expect(short.velocity, isNull);
    });

    test('palm: GM 28 on its channel, same key, velocity x0.85, 250 ms', () {
      final e = realizeArticulation(
        note(52, 0).withArticulation(palm),
        ctx,
        velocity: 100,
        gateSteps: 4,
      );
      expect((e.role, e.channel, e.program), (ArtRole.muteVoice, 3, 28));
      expect((e.key, e.soundingMidi, e.velocity), (52, 52, 85));
      expect(e.gateSteps, closeTo(2, 1e-9));
      // a null (legacy pad) velocity scales from 100
      expect(
        realizeArticulation(
          note(52, 0).withArticulation(palm),
          ctx,
          velocity: null,
          gateSteps: 4,
        ).velocity,
        85,
      );
    });

    test('harmonic: GM 31 key S-24, sounding pitch S, gate unchanged', () {
      final e = realizeArticulation(
        note(88, 0).withArticulation(harm),
        ctx,
        velocity: 70,
        gateSteps: 3,
      );
      expect((e.role, e.channel, e.program), (ArtRole.harmonicVoice, 4, 31));
      expect((e.key, e.soundingMidi, e.velocity), (64, 88, 70));
      expect(e.gateSteps, 3);
    });

    test('sounding-pitch override: support is decided on that pitch', () {
      final h = note(88, 0).withArticulation(harm);
      final inRange = realizeArticulation(
        h,
        ctx,
        velocity: 80,
        gateSteps: 2,
        soundingMidi: 76,
      );
      expect((inRange.role, inRange.key), (ArtRole.harmonicVoice, 52));
      final out = realizeArticulation(
        h,
        ctx,
        velocity: 80,
        gateSteps: 2,
        soundingMidi: 70,
      );
      expect((out.role, out.key, out.gateSteps), (ArtRole.track, 70, 2));
      final p = note(60, 0).withArticulation(palm);
      final pOut = realizeArticulation(
        p,
        ctx,
        velocity: 80,
        gateSteps: 4,
        soundingMidi: 90,
      );
      expect((pOut.role, pOut.key, pOut.velocity, pOut.gateSteps), (
        ArtRole.track,
        90,
        80,
        4.0,
      ));
      final pIn = realizeArticulation(
        p,
        ctx,
        velocity: 80,
        gateSteps: 4,
        soundingMidi: 45,
      );
      expect((pIn.role, pIn.key), (ArtRole.muteVoice, 45));
    });

    test('no channel / not a guitar: exactly normal', () {
      const noCh = ArticulationContext(guitar: true, bpm: 120);
      for (final a in [palm, harm]) {
        final e = realizeArticulation(
          note(80, 0).withArticulation(a),
          noCh,
          velocity: 99,
          gateSteps: 3,
        );
        expect((e.role, e.key, e.velocity, e.gateSteps, e.channel), (
          ArtRole.track,
          80,
          99,
          3.0,
          null,
        ));
      }
      final notGuitar = realizeArticulation(
        note(60, 0).withArticulation(stac),
        ArticulationContext.none,
        velocity: 99,
        gateSteps: 3,
      );
      expect(notGuitar.gateSteps, 3);
    });
  });

  group('plan', () {
    test('deterministic channels; base, drum, click and track channels '
        'never taken', () {
      final song = guitarSong(
        [note(52, 0).withArticulation(palm), note(80, 2).withArticulation(harm)],
        extras: 2, // added tracks take 3 and 4
      );
      final plan = ArticulationPlan.of(song);
      expect(plan.channelFor('melody', ArtRole.muteVoice), 5);
      expect(plan.channelFor('melody', ArtRole.harmonicVoice), 6);
      expect(ArticulationPlan.of(song), plan);
      for (final r in plan.routes) {
        expect(kArticulationReservedChannels.contains(r.channel), isFalse);
        expect({3, 4}.contains(r.channel), isFalse);
      }
      // staccato only: no channel at all
      final s2 = guitarSong([note(52, 0).withArticulation(stac)]);
      expect(ArticulationPlan.of(s2).routes, isEmpty);
      expect(ArticulationPlan.of(s2).hasArticulations, isTrue);
    });

    test('pool full: the role gets no channel and the badge roles list it', () {
      final song = guitarSong(
        [note(52, 0).withArticulation(palm), note(80, 2).withArticulation(harm)],
        extras: 9, // one pool channel left
      );
      final plan = ArticulationPlan.of(song);
      expect(plan.channelFor('melody', ArtRole.muteVoice), 14);
      expect(plan.channelFor('melody', ArtRole.harmonicVoice), isNull);
      expect(plan.shortRoles('melody'), [ArtRole.harmonicVoice]);
      // the harmonic notes then render as normal
      final e = realizeArticulation(
        note(80, 2).withArticulation(harm),
        plan.contextFor('melody', 120),
        velocity: 90,
        gateSteps: 2,
      );
      expect((e.role, e.key), (ArtRole.track, 80));
    });

    test('a non-guitar track gets no channel and renders normal', () {
      final song = guitarSong([
        note(52, 0).withArticulation(palm),
      ], program: 0);
      final plan = ArticulationPlan.of(song);
      expect(plan.isGuitar('melody'), isFalse);
      expect(plan.routes, isEmpty);
      // the data is kept
      expect(
        song.sections.single.tracks['melody']!.pitchNotes.single.articulation,
        palm,
      );
    });
  });
}
