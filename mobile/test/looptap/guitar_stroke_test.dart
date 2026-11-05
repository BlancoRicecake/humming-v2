// gt-001 guitar stroke conversion: pure conversion, revert, grouping,
// inheritance through existing edits, legacy-strum exclusion and export.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/arpeggiate.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/pitch_clipboard.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/section_links.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

import '../support/midi_events.dart';

PitchNote n(
  int midi,
  double start, {
  int dur = 2,
  int? velocity,
  double? duration,
  bool locked = false,
  bool muted = false,
}) {
  final step = start.floor();
  return PitchNote(
    midi: midi,
    freq: midiToFreq(midi),
    step: step,
    dur: dur,
    velocity: velocity,
    offsetSteps: start - step,
    durationSteps: duration,
    locked: locked,
    muted: muted,
  );
}

/// E major shape, deliberately unsorted.
List<PitchNote> chord([double at = 0]) => [
  n(59, at),
  n(52, at),
  n(64, at),
  n(56, at),
];

PitchNote byMidi(List<PitchNote> notes, int midi) =>
    notes.singleWhere((x) => x.midi == midi);

const down = StrokeSpec.down();
const up = StrokeSpec.up();
const bpm = 120; // 1 step = 125 ms → 28 ms = .224 step, 18 ms = .144 step

List<Map<String, dynamic>> js(List<PitchNote> notes) =>
    [for (final x in notes) x.toJson()];

void main() {
  group('conversion', () {
    test('down stroke: low→high offsets, falloff × accent, shared end', () {
      final src = chord();
      final out = applyGuitarStroke(src, {}, down, bpm: bpm).notes;
      final expected = {52: (0.0, 100), 56: (.224, 94), 59: (.448, 88), 64: (.672, 82)};
      expected.forEach((midi, e) {
        final x = byMidi(out, midi);
        expect(x.offsetSteps, closeTo(e.$1, 1e-9), reason: '$midi offset');
        expect(x.velocity, e.$2, reason: '$midi velocity');
        expect(x.endSteps, closeTo(2, 1e-9), reason: '$midi ends at chord end');
        expect(x.durationSteps, isNotNull);
        expect(x.stroke!.dir, StrokeDir.down);
      });
      expect([for (final m in [52, 56, 59, 64]) byMidi(out, m).stroke!.order], [
        0,
        1,
        2,
        3,
      ]);
      // list order and step stay; only the converted fields change
      expect([for (final x in out) x.midi], [59, 52, 64, 56]);
      expect(out.every((x) => x.step == 0 && x.dur == 2), isTrue);
    });

    test('up stroke: high→low, lighter and quicker by default', () {
      final out = applyGuitarStroke(chord(), {}, up, bpm: bpm).notes;
      final expected = {64: (0.0, 80), 59: (.144, 75), 56: (.288, 70), 52: (.432, 66)};
      expected.forEach((midi, e) {
        final x = byMidi(out, midi);
        expect(x.offsetSteps, closeTo(e.$1, 1e-9), reason: '$midi');
        expect(x.velocity, e.$2, reason: '$midi');
        expect(x.endSteps, closeTo(2, 1e-9));
        expect(x.stroke!.dir, StrokeDir.up);
      });
      // custom parameters are used as given
      final custom = applyGuitarStroke(
        chord(),
        {},
        const StrokeSpec(dir: StrokeDir.up, spreadMs: 50, falloff: 0, accent: 1.2),
        bpm: 60,
      ).notes;
      expect(byMidi(custom, 52).offsetSteps, closeTo(3 * .2, 1e-9));
      expect(custom.every((x) => x.velocity == 120), isTrue);
    });

    test('single-note hit only gets the accent; spread is clamped', () {
      final single = applyGuitarStroke([n(60, 3, dur: 1)], {}, up, bpm: bpm);
      final x = single.notes.single;
      expect(x.startSteps, 3);
      expect(x.velocity, 80);
      expect(x.durationSteps, 1);
      final short = [
        for (final m in [40, 45, 50, 55, 59, 64]) n(m, 0, dur: 1, duration: .25),
      ];
      final out = applyGuitarStroke(
        short,
        {},
        const StrokeSpec.down(spreadMs: 60),
        bpm: 200,
      ).notes;
      final last = byMidi(out, 64);
      expect(last.startSteps, lessThan(.25));
      expect(out.every((x) => x.soundingSteps >= 1 / 16 - 1e-9), isTrue);
    });

    test('re-apply does not accumulate; revert restores exact JSON', () {
      final src = [
        n(52, 0), // dur 2, durationSteps null, velocity null
        n(56, 0, dur: 1, duration: 2.0),
        n(59, .12, velocity: 90, duration: 1.7),
      ];
      final before = js(src);
      final once = applyGuitarStroke(src, {}, down, bpm: bpm).notes;
      final twice = applyGuitarStroke(once, {}, down, bpm: bpm).notes;
      expect(js(twice), js(once));
      final upAfterDown = applyGuitarStroke(once, {}, up, bpm: bpm).notes;
      expect(js(upAfterDown), js(applyGuitarStroke(src, {}, up, bpm: bpm).notes));
      final reverted = revertGuitarStroke(twice, {}).notes;
      expect(js(reverted), before);
      expect(reverted[0].durationSteps, isNull);
      expect(reverted[0].dur, 2);
      expect(reverted[1].durationSteps, 2.0);
      expect(reverted[1].dur, 1);
      expect(reverted[2].velocity, 90);
      // reverting untagged notes is a no-op
      expect(identical(revertGuitarStroke(src, {}).notes, src), isTrue);
    });

    test('duplicate same-pitch notes in one hit are both kept and converted', () {
      final a = n(60, 0), b = n(60, 0), c = n(64, 0);
      final out = applyGuitarStroke([a, b, c], {}, down, bpm: bpm).notes;
      expect(out, hasLength(3));
      expect(out.every((x) => x.stroke != null), isTrue);
      expect([for (final x in out) x.stroke!.order], [0, 1, 2]); // index-stable
      expect(out[1].startSteps, greaterThan(out[0].startSteps));
      // Both reach the export as their own note-on events. (One MIDI channel
      // cannot sound two overlapping same-pitch notes independently; only
      // the events are asserted here.)
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: out);
      final ons = readNoteOns(buildMidi(flattenSong([s]), bpm, melodyProgram: 25)).ons;
      expect(ons.where((e) => e.pitch == 60), hasLength(2));
    });

    test('locked keep their slot; muted are skipped; scope = selection or track', () {
      final locked = n(52, 0, locked: true);
      final muted = n(64, 0, muted: true);
      final src = [locked, n(56, 0), n(59, 0), muted, ...chord(4)];
      final all = applyGuitarStroke(src, {}, down, bpm: bpm).notes;
      expect(identical(all[0], locked), isTrue);
      expect(identical(all[3], muted), isTrue);
      expect(all[1].offsetSteps, closeTo(.224, 1e-9)); // slot 1 of 3
      expect(all[1].velocity, 91);
      expect(all[2].offsetSteps, closeTo(.448, 1e-9));
      expect(all.skip(4).every((x) => x.stroke != null), isTrue); // whole track
      // only the selected hit converts; the selection follows the new notes
      final edit = applyGuitarStroke(src, {src[4], src[5]}, down, bpm: bpm);
      expect(edit.notes.take(4).every((x) => x.stroke == null), isTrue);
      expect(edit.notes.skip(6).every((x) => x.stroke == null), isTrue);
      expect(edit.selection, {edit.notes[4], edit.notes[5]});
    });

    test('pattern presets assign ↓/↑ to successive hits in time order', () {
      final src = [for (final at in [12.0, 0.0, 8.0, 4.0]) ...chord(at)];
      final out =
          applyStrokePattern(src, {}, strokePatternById('downUp'), bpm: bpm).notes;
      StrokeDir dirAt(int step) =>
          out.firstWhere((x) => x.step == step).stroke!.dir;
      expect([for (final s in [0, 4, 8, 12]) dirAt(s)], [
        StrokeDir.down,
        StrokeDir.up,
        StrokeDir.down,
        StrokeDir.up,
      ]);
      final folk = applyStrokePattern(
        [for (var i = 0; i < 7; i++) ...chord(i * 2.0)],
        {},
        strokePatternById('folk'),
        bpm: bpm,
      ).notes;
      expect(
        [for (var i = 0; i < 7; i++) folk.firstWhere((x) => x.step == i * 2).stroke!.dir],
        [
          StrokeDir.down,
          StrokeDir.down,
          StrokeDir.up,
          StrokeDir.up,
          StrokeDir.down,
          StrokeDir.up,
          StrokeDir.down,
        ],
      );
      expect(strokeMark(byMidi(applyGuitarStroke(chord(), {}, down, bpm: bpm).notes, 52)), '↓');
      expect(strokeMark(byMidi(applyGuitarStroke(chord(), {}, down, bpm: bpm).notes, 56)), isNull);
    });
  });

  test('legacy strum pairs duplicate pitches by index (each keeps its note)', () {
    final a = n(60, 0, dur: 1), b = n(60, 0, dur: 3), c = n(64, 0);
    final pairs = strumPairs([a, b, c]);
    expect([for (final p in pairs) p.note], [same(a), same(b), same(c)]);
    expect([for (final p in pairs) p.delayMs], [0, 28, 56]);
    // the export now gives each duplicate its own length: 1 and 3 steps
    final s = Section(id: 's', name: 's', bars: 1)
      ..tracks['melody'] = TrackData(notes: [a, b, c]);
    final bytes = buildMidi(flattenSong([s]), bpm, melodyProgram: 25);
    expect(readNoteOns(bytes).ons.where((e) => e.pitch == 60), hasLength(2));
  });

  group('hit grouping (actual start, 0.05-step tolerance)', () {
    test('a fast monophonic line inside one cell is not strummed', () {
      final line = [n(60, 0), n(62, .3), n(64, .6), n(65, .8)];
      expect(strokeChordHits(line, line.toSet()), [
        [0],
        [1],
        [2],
        [3],
      ]);
      final out = applyGuitarStroke(line, {}, down, bpm: bpm).notes;
      for (var i = 0; i < 4; i++) {
        expect(out[i].startSteps, closeTo(line[i].startSteps, 1e-9));
        expect(out[i].stroke!.order, 0);
      }
    });

    test('a micro-offset chord is one hit; chaining is anchored', () {
      final micro = [n(52, 0), n(56, .02), n(59, .04)];
      expect(strokeChordHits(micro, micro.toSet()), [
        [0, 1, 2],
      ]);
      final chain = [n(52, 0), n(56, .04), n(59, .08)];
      expect(strokeChordHits(chain, chain.toSet()), [
        [0, 1],
        [2],
      ]);
    });

    test('re-apply groups a converted hit by its base timing', () {
      final micro = [n(52, 0), n(56, .02), n(59, .04)];
      final slow = applyGuitarStroke(
        micro,
        {},
        const StrokeSpec.down(spreadMs: 60),
        bpm: bpm,
      ).notes;
      // actual starts are now .48 step apart, base starts still one hit
      expect(strokeChordHits(slow, slow.toSet()), [
        [0, 1, 2],
      ]);
      final again = applyGuitarStroke(slow, {}, up, bpm: bpm).notes;
      expect([for (final x in again) x.stroke!.order], [2, 1, 0]);
      expect(js(again), js(applyGuitarStroke(micro, {}, up, bpm: bpm).notes));
      expect(js(revertGuitarStroke(again, {}).notes), js(micro));
    });
  });

  group('inheritance through existing edits', () {
    late List<PitchNote> converted;
    setUp(() => converted = applyGuitarStroke(chord(), {}, down, bpm: bpm).notes);

    test('quantize drops the tag; the legacy strum still never runs', () {
      final q = quantizePitchNotes(
        converted,
        converted.toSet(),
        grid: 1,
        strength: .5,
        ends: false,
        steps: 16,
      );
      // moved strings lose the tag (the on-grid first string is untouched)
      for (var i = 0; i < 4; i++) {
        expect(
          identical(q[i], converted[i]) ? converted[i].stroke : q[i].stroke,
          identical(q[i], converted[i]) ? isNotNull : isNull,
        );
      }
      expect(q.where((x) => x.stroke == null), hasLength(3));
      expect(q.every((x) => x.velocity != null && x.durationSteps != null), isTrue);
      expect(liveLegacyStrum(q, guitar: true), isNull);
      // even with every tag gone, the explicit velocity/length keep the
      // legacy predicate from matching the converted hit
      final stripped = [for (final x in q) x.copyWith(clearStroke: true)];
      expect(liveLegacyStrum(stripped, guitar: true), isNull);
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: q);
      final read = readNoteOns(buildMidi(flattenSong([s]), bpm, melodyProgram: 25));
      final tps = read.tpq / kStepsPerBeat;
      expect(
        {for (final e in read.ons) (e.pitch, e.tick, e.velocity)},
        {for (final x in q) (x.midi, (x.startSteps * tps).round(), x.velocity)},
      );
      expect(liveLegacyStrum(converted, guitar: true), isNull);
    });

    test('split/chop/legato/humanize/arpeggiate drop; glue keeps the earliest', () {
      final low = byMidi(converted, 52);
      final split = splitPitchNotesAt(converted, {low}, 1).notes;
      expect(split.where((x) => x.midi == 52).every((x) => x.stroke == null), isTrue);
      expect(chopPitchNotes(converted, {low}, parts: 2).notes.where((x) => x.midi == 52).every((x) => x.stroke == null), isTrue);
      expect(legatoPitchNotes(converted, converted.toSet(), steps: 16).every((x) => x.stroke == null), isTrue);
      final human = humanizePitchNotes(
        converted,
        converted.toSet(),
        timingSteps: 0,
        velocityRange: 20,
        seed: 3,
        steps: 16,
      );
      expect(
        [for (var i = 0; i < 4; i++) if (human[i] != converted[i]) human[i].stroke],
        everyElement(isNull),
      );
      // a tagged block chord (shared start) so the arpeggiator has work
      final block = [
        for (final x in chord()) x.copyWith(stroke: byMidi(converted, x.midi).stroke),
      ];
      final arp = arpeggiatePitchNotes(
        block,
        block.toSet(),
        const ArpSettings(),
        seed: 1,
        steps: 16,
      ).notes;
      expect(arp, isNot(same(block)));
      expect(arp.every((x) => x.stroke == null), isTrue);
      final pieces = [low, n(52, 3, dur: 1)];
      final glued = gluePitchNotes(pieces, pieces.toSet()).notes.single;
      expect(glued.stroke, low.stroke);
    });

    test('mute, transpose, octave, scale snap, duplicate, copy/paste keep it', () {
      final all = converted.toSet();
      expect(setPitchNotesMuted(converted, all, true).every((x) => x.stroke != null), isTrue);
      expect(
        movePitchNotes(converted, all, deltaSteps: 0, semitones: 12, steps: 16)
            .every((x) => x.stroke != null),
        isTrue,
      );
      expect(
        movePitchNotesInScale(converted, all, root: 'C', scale: 'major', dir: 1)
            .every((x) => x.stroke != null),
        isTrue,
      );
      final dup = duplicatePitchNotes(converted, all, 16);
      expect(dup.skip(4).map((x) => x.stroke), converted.map((x) => x.stroke));
      final clip = PitchClipboard()..copy(converted);
      final pasted = clip.paste(atStep: 8, steps: 16);
      expect(pasted.map((x) => x.stroke), converted.map((x) => x.stroke));
      for (var i = 0; i < 4; i++) {
        expect(pasted[i].startSteps - 8, closeTo(converted[i].startSteps, 1e-9));
      }
      final stamped = stampChordsBelow(
        [n(72, 0)],
        {},
        ChordType.major,
        key: 'C',
        scale: 'major',
      );
      expect(stamped.notes.every((x) => x.stroke == null), isTrue);
    });

    test('save/load, section deep copy and linked sections keep tags', () {
      final s = Section(id: 'a', name: 'A', bars: 1)
        ..tracks['melody'] = TrackData(notes: converted);
      final song = Song(id: 'x', title: 'x', sections: [s]);
      final loaded = Song.fromJson(
        jsonDecode(jsonEncode(song.toJson())) as Map<String, dynamic>,
      );
      final notes = loaded.sections.single.tracks['melody']!.pitchNotes;
      expect(js(notes), js(converted));
      expect(notes.map((x) => x.stroke), converted.map((x) => x.stroke));
      expect(
        s.deepCopy().tracks['melody']!.pitchNotes.map((x) => x.stroke),
        converted.map((x) => x.stroke),
      );
      final linked = duplicateLinked(s, 'b');
      expect(identical(linked.tracks, s.tracks), isTrue);
      expect(
        linked.tracks['melody']!.pitchNotes.map((x) => x.stroke),
        converted.map((x) => x.stroke),
      );
      // untagged notes write no key; an unreadable tag loads as untagged
      expect(n(60, 0).toJson().containsKey('stroke'), isFalse);
      expect(
        PitchNote.fromJson({'midi': 60, 'freq': 261.6, 'step': 0, 'stroke': {'dir': 'sideways'}}).stroke,
        isNull,
      );
    });
  });

  group('playback and export read the same events', () {
    test('converted hit: live (offset path) == MIDI events; WAV uses buildMidi', () {
      final out = applyStrokePattern(
        [...chord(0), ...chord(4), n(60, 9, dur: 1)],
        {},
        strokePatternById('downUp'),
        bpm: 97,
      ).notes;
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: out);
      for (final strum in [false, true]) {
        // strumGuitar = the WAV render's buildMidi call for guitar lanes
        final read = readNoteOns(
          buildMidi(flattenSong([s]), 97, melodyProgram: 25, strumGuitar: strum),
        );
        final tps = read.tpq / kStepsPerBeat;
        // live: the legacy strum never applies, every note plays at its
        // startSteps with its velocity
        for (final step in {for (final x in out) x.step}) {
          expect(
            liveLegacyStrum(out.where((x) => x.step == step).toList(), guitar: true),
            isNull,
          );
        }
        expect(
          [for (final e in read.ons) (e.pitch, e.tick, e.velocity)]..sort(_cmp3),
          [for (final x in out) (x.midi, (x.startSteps * tps).round(), x.velocity!)]
            ..sort(_cmp3),
        );
      }
    });

    test('strings past the section end are not scheduled', () {
      // 1-bar section, a chord in the last cell with a slow spread
      final out = applyGuitarStroke(
        [for (final m in [40, 45, 50, 55, 59, 64]) n(m, 15, dur: 4, duration: 4)],
        {},
        const StrokeSpec.down(spreadMs: 60),
        bpm: 240,
      ).notes;
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: out);
      final past = out.where((x) => x.startSteps >= 16).toList();
      expect(past, isNotEmpty);
      final flat = flattenSong([s]);
      expect(flat.melody, hasLength(out.length - past.length));
      expect(flat.melody.every((x) => x.endSteps <= 16 + 1e-9), isTrue);
      // live: the gate of a string past the range end is zero (not played)
      const range = PlaybackRange(0, 16);
      for (final x in past) {
        expect(range.gateSeconds(x.startSteps, 1, .1), 0);
      }
    });

    test('grooved lane: live schedule == flattened export', () {
      final out = applyGuitarStroke(
        [...chord(0), ...chord(6)],
        {},
        down,
        bpm: 97,
      ).notes;
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: out);
      const ctx = GrooveContext(
        trackGrooves: {'melody': GrooveAssign(grooveId: 'builtin:laidback')},
      );
      const sps = 60 / 97 / kStepsPerBeat;
      final live = liveGrooveSchedule(s, 97, 0, ctx);
      final flat = flattenSong([s], groove: ctx);
      final liveSec = [for (final e in live) e.seconds]..sort();
      final flatSec = [for (final x in flat.melody) x.startSteps * sps]..sort();
      expect(liveSec.length, flatSec.length);
      for (var i = 0; i < liveSec.length; i++) {
        expect(liveSec[i], closeTo(flatSec[i], .001));
      }
      expect(
        [for (final e in live) e.velocity]..sort(),
        [for (final x in flat.melody) x.velocity!]..sort(),
      );
    });
  });
}

int _cmp3((int, int, int) a, (int, int, int) b) {
  var c = a.$1.compareTo(b.$1);
  if (c != 0) return c;
  c = a.$2.compareTo(b.$2);
  return c != 0 ? c : a.$3.compareTo(b.$3);
}
