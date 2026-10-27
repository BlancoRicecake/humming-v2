// gt-002 guitar strings: assignment, unassignable state, ring, choke,
// revert, pitch-change validity, export identity, groove and performance.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/arpeggiate.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/pitch_clipboard.dart';
import 'package:humming/looptap/music/pitch_note_edit.dart';
import 'package:humming/looptap/music/section_links.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

PitchNote n(
  int midi,
  double start, {
  int dur = 1,
  double? duration,
  int? string,
  bool stringLocked = false,
  bool locked = false,
  bool muted = false,
  int? velocity,
}) {
  final step = start.floor();
  return PitchNote(
    midi: midi,
    freq: midiToFreq(midi),
    step: step,
    dur: dur,
    offsetSteps: start - step,
    durationSteps: duration,
    guitarString: string,
    stringLocked: stringLocked,
    locked: locked,
    muted: muted,
    velocity: velocity,
  );
}

List<Map<String, dynamic>> js(List<PitchNote> notes) => [
  for (final x in notes) x.toJson(),
];

Map<int, int?> stringsByMidi(List<PitchNote> notes) => {
  for (final x in notes) x.midi: x.guitarString,
};

/// Every MIDI event (on/off) of a single-track `buildMidi` file, in order.
List<({int tick, bool on, int pitch})> readEvents(Uint8List b) {
  var i = 22;
  var tick = 0;
  int vlq() {
    var v = 0;
    while (true) {
      final c = b[i++];
      v = (v << 7) | (c & 0x7f);
      if (c & 0x80 == 0) return v;
    }
  }

  final out = <({int tick, bool on, int pitch})>[];
  while (i < b.length) {
    tick += vlq();
    final status = b[i++];
    if (status == 0xFF) {
      i++;
      final len = vlq();
      i += len;
      continue;
    }
    final kind = status & 0xF0;
    if (kind == 0xC0 || kind == 0xD0) {
      i += 1;
      continue;
    }
    final a = b[i++], v = b[i++];
    if (kind == 0x90 || kind == 0x80) {
      out.add((tick: tick, on: kind == 0x90 && v > 0, pitch: a));
    }
  }
  return out;
}

int tpqOf(Uint8List b) => (b[12] << 8) | b[13];

Uint8List midiOf(List<PitchNote> notes, {int bars = 1, GrooveContext? groove}) {
  final s = Section(id: 's', name: 's', bars: bars)
    ..tracks['melody'] = TrackData(notes: notes);
  return buildMidi(flattenSong([s], groove: groove), 120, melodyProgram: 25);
}

void main() {
  group('tuning', () {
    test('standard tuning, string 1 = high E, frets 0..22', () {
      expect(kGuitarOpenMidi, [64, 59, 55, 50, 45, 40]);
      expect(guitarFret(6, 40), 0);
      expect(guitarFret(1, 64 + 22), 22);
      expect(guitarFret(1, 64 + 23), isNull);
      expect(guitarFret(1, 63), isNull);
      expect(guitarFret(0, 60), isNull);
      expect(guitarFret(7, 60), isNull);
    });
  });

  group('assignment', () {
    test('open E major: six distinct strings, valid span', () {
      final src = [for (final m in [40, 47, 52, 56, 59, 64]) n(m, 0, dur: 4)];
      final edit = assignStrings(src, {});
      expect(edit.unassignable, isEmpty);
      expect(stringsByMidi(edit.notes), {
        40: 6,
        47: 5,
        52: 4,
        56: 3,
        59: 2,
        64: 1,
      });
      final frets = [for (final x in edit.notes) noteFret(x)!];
      expect(frets, [0, 2, 2, 1, 0, 0]);
      expect(edit.notes.every((x) => !x.stringLocked), isTrue);
    });

    test('C shape gets the open-position C', () {
      final src = [for (final m in [48, 52, 55, 60, 64]) n(m, 0, dur: 4)];
      final edit = assignStrings(src, {});
      expect(stringsByMidi(edit.notes), {48: 5, 52: 4, 55: 3, 60: 2, 64: 1});
      expect([for (final x in edit.notes) noteFret(x)], [3, 2, 0, 1, 0]);
    });

    test('7 simultaneous notes leave 1 unassignable (not moved)', () {
      final src = [
        for (final m in [40, 45, 50, 55, 59, 64, 69]) n(m, 0, dur: 2),
      ];
      final edit = assignStrings(src, {});
      expect(edit.unassignable, hasLength(1));
      expect(edit.unassignable.values.single, UnassignableReason.tooMany);
      final assigned = edit.notes.where((x) => x.guitarString != null);
      expect(assigned, hasLength(6));
      expect({for (final x in assigned) x.guitarString}, hasLength(6));
      expect(js(edit.notes).map((j) => j['midi']), src.map((x) => x.midi));
    });

    test('out-of-range notes are unassignable and keep their pitch', () {
      final src = [n(36, 0), n(90, 1), n(60, 2)];
      final edit = assignStrings(src, {});
      expect(edit.unassignable.values.toList(), [
        UnassignableReason.outOfRange,
        UnassignableReason.outOfRange,
      ]);
      expect(edit.notes.map((x) => x.midi), [36, 90, 60]);
      expect(edit.notes[0].guitarString, isNull);
      expect(edit.notes[2].guitarString, 2);
    });

    test('stroke-staggered hit: grouped by base start, distinct strings', () {
      final chord = [for (final m in [40, 45, 50, 55, 59, 64]) n(m, 0, dur: 4)];
      final slow = applyGuitarStroke(
        chord,
        {},
        const StrokeSpec.down(spreadMs: 60),
        bpm: 120,
      ).notes;
      // actual starts .48 step apart, each string a different actual start
      expect(slow.map((x) => x.startSteps).toSet(), hasLength(6));
      final edit = assignStrings(slow, {});
      expect(edit.unassignable, isEmpty);
      expect(stringsByMidi(edit.notes), {
        40: 6,
        45: 5,
        50: 4,
        55: 3,
        59: 2,
        64: 1,
      });
      // the stroke data is untouched
      expect(
        [for (final x in edit.notes) x.stroke],
        [for (final x in slow) x.stroke],
      );
    });

    test('an overlap is not a strum: the later note avoids the sounding '
        'string', () {
      // 60 (string 2, fret 1) rings 0..8; 61 at 4 would be fret 2 on the
      // same string, so it takes string 3 (fret 6) instead
      final held = [n(60, 0, dur: 8), n(61, 4, dur: 2)];
      final a = assignStrings(held, {});
      expect(a.notes[0].guitarString, 2);
      expect(a.notes[1].guitarString, 3);
      expect(a.notes[0].endSteps, 8, reason: 'no choke needed');
      // after the first note ends, the cheaper string is free again
      final apart = [n(60, 0, dur: 4), n(61, 4, dur: 2)];
      expect(assignStrings(apart, {}).notes[1].guitarString, 2);
    });

    test('an unselected sounding note blocks its string (never cut)', () {
      final outside = n(59, 0, dur: 8, string: 2);
      // 59 can sound on strings 2..5; string 2 is held by [outside]
      final mine = n(59, 2, dur: 2);
      final edit = assignStrings([outside, mine], {mine});
      expect(identical(edit.notes[0], outside), isTrue);
      expect(edit.notes[1].guitarString, isNot(2));
      expect(edit.notes[1].guitarString, isNotNull);
      // same pitch: the selected note is cut at nothing (it is later); the
      // outside note keeps its data
      expect(edit.notes[0].endSteps, 8);
    });

    test('locked, user-chosen and muted notes', () {
      final lockedWith = n(64, 0, dur: 2, string: 2, locked: true); // fret 5
      final lockedWithout = n(52, 0, dur: 2, locked: true);
      final chosen = n(59, 0, dur: 2, string: 3, stringLocked: true); // fret 4
      final muted = n(55, 0, dur: 2, muted: true);
      final free = n(64, 0, dur: 2);
      final src = [lockedWith, lockedWithout, chosen, muted, free];
      final edit = assignStrings(src, {});
      expect(identical(edit.notes[0], lockedWith), isTrue);
      expect(identical(edit.notes[1], lockedWithout), isTrue);
      expect(identical(edit.notes[2], chosen), isTrue);
      expect(identical(edit.notes[3], muted), isTrue);
      expect(edit.unassignable[edit.notes[1]], UnassignableReason.locked);
      // the free 64 cannot use strings 2 or 3 (taken in the hit)
      expect(edit.notes[4].guitarString, 1);
    });

    test('nothing to do returns the notes themselves', () {
      final src = assignStrings([n(40, 0), n(64, 2)], {}).notes;
      final again = assignStrings(src, {});
      expect(identical(again.notes, src), isTrue);
      expect(again.unassignable, isEmpty);
    });

    test('never alters pitch, timing or note count (property, random)', () {
      final rng = math.Random(7);
      for (var trial = 0; trial < 150; trial++) {
        final src = [
          for (var i = 0; i < 1 + rng.nextInt(24); i++)
            n(
              30 + rng.nextInt(64),
              rng.nextInt(16) + (rng.nextBool() ? 0 : rng.nextInt(10) / 10),
              dur: 1 + rng.nextInt(6),
              duration: rng.nextBool() ? null : .25 + rng.nextInt(20) / 4,
              muted: rng.nextInt(10) == 0,
              locked: rng.nextInt(12) == 0,
            ),
        ];
        final sel = {
          for (final x in src)
            if (rng.nextBool()) x,
        };
        final edit = assignStrings(src, sel);
        expect(edit.notes, hasLength(src.length));
        for (var i = 0; i < src.length; i++) {
          final a = src[i], b = edit.notes[i];
          expect(b.midi, a.midi);
          expect(b.step, a.step);
          expect(b.offsetSteps, a.offsetSteps);
          expect(b.muted, a.muted);
          expect(b.velocity, a.velocity);
          // only edited notes may get shorter, and they stay restorable
          expect(b.ringReverted().soundingSteps, a.soundingSteps);
          if (b.guitarString != null) {
            expect(guitarPlayable(b.guitarString!, b.midi), isTrue);
          }
          if (!(sel.isEmpty ? true : sel.contains(a)) || a.locked) {
            expect(identical(a, b), isTrue);
          }
        }
        // no two sounding edited notes overlap on one string
        final edited = [
          for (var i = 0; i < src.length; i++)
            if (!identical(src[i], edit.notes[i]) &&
                edit.notes[i].guitarString != null &&
                !edit.notes[i].muted)
              edit.notes[i],
        ];
        for (final x in edited) {
          for (final y in edited) {
            if (identical(x, y) || x.guitarString != y.guitarString) continue;
            final overlap =
                x.startSteps < y.endSteps - 1e-9 &&
                y.startSteps < x.endSteps - 1e-9;
            expect(overlap, isFalse, reason: 'trial $trial');
          }
        }
      }
    });

    test('5,000 notes assign in under 1 s; invalid values are rejected', () {
      final rng = math.Random(1);
      final src = <PitchNote>[];
      for (var hit = 0; src.length < 5000; hit++) {
        final size = 1 + rng.nextInt(8); // some hits exceed 6 notes
        for (var k = 0; k < size && src.length < 5000; k++) {
          src.add(n(36 + rng.nextInt(56), hit * .5, dur: 1 + rng.nextInt(3)));
        }
      }
      final sw = Stopwatch()..start();
      final edit = assignStrings(src, {});
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(edit.notes, hasLength(5000));
      final bad = n(60, 0).copyWith(offsetSteps: double.nan);
      final inf = n(62, 1, duration: double.infinity);
      final e2 = assignStrings([bad, inf, n(64, 2)], {});
      expect(e2.unassignable.values.toList(), [
        UnassignableReason.invalid,
        UnassignableReason.invalid,
      ]);
      expect(e2.notes[2].guitarString, 1);
      expect(
        () => applyRing([n(64, 0)], {}, rangeEnd: double.nan),
        throwsArgumentError,
      );
      expect(() => applyRing([n(64, 0)], {}, rangeEnd: 0), throwsArgumentError);
      expect(() => setGuitarString([n(64, 0)], {}, 7), throwsArgumentError);
      expect(
        PitchNote.fromJson({
          'midi': 64,
          'freq': 329.6,
          'step': 0,
          'guitarString': 9,
          'stringLocked': true,
        }).guitarString,
        isNull,
      );
    });
  });

  group('manual override', () {
    test('only playable strings; the fret follows; conflicts refused', () {
      final a = n(64, 0, string: 1), b = n(59, 0, string: 2);
      final r = setGuitarString([a, b], {a}, 2);
      expect(r.refused, 1, reason: 'string 2 is held in the hit by b');
      expect(identical(r.notes[0], a), isTrue);
      final ok = setGuitarString([a, b], {a}, 3);
      expect(ok.refused, 0);
      expect(ok.notes[0].guitarString, 3);
      expect(ok.notes[0].stringLocked, isTrue);
      expect(noteFret(ok.notes[0]), 9);
      final low = n(41, 0);
      expect(setGuitarString([low], {low}, 1).refused, 1); // not playable
      final auto = setGuitarString(ok.notes, ok.selection, null);
      expect(auto.notes[0].stringLocked, isFalse);
      expect(auto.notes[0].guitarString, 3);
      expect(playableStringsFor([n(40, 0)]), {6});
      expect(playableStringsFor([n(64, 0), n(59, 0)]), {2, 3, 4, 5});
    });
  });

  group('pitch changes keep strings valid', () {
    final one = n(64, 0, dur: 2, string: 1, stringLocked: true);
    test('transpose, octave, scale snap, fit, arpeggiate', () {
      final down = movePitchNotes(
        [one],
        {one},
        deltaSteps: 0,
        semitones: -1,
        steps: 16,
      ).single;
      expect(down.midi, 63);
      expect(down.guitarString, isNull, reason: 'E4 string cannot sound D#4');
      expect(down.stringLocked, isFalse);
      final upOne = movePitchNotes(
        [one],
        {one},
        deltaSteps: 0,
        semitones: 1,
        steps: 16,
      ).single;
      expect(upOne.guitarString, 1);
      expect(noteFret(upOne), 1);
      final low = n(40, 0, string: 6);
      expect(
        movePitchNotes([low], {low}, deltaSteps: 0, semitones: 12, steps: 16)
            .single
            .guitarString,
        6,
      );
      expect(
        movePitchNotes([low], {low}, deltaSteps: 0, semitones: -1, steps: 16)
            .single
            .guitarString,
        isNull,
      );
      final snapped = movePitchNotesInScale(
        [one],
        {one},
        root: 'C',
        scale: 'major',
        dir: -1,
      ).single;
      expect(snapped.midi, 62);
      expect(snapped.guitarString, isNull);
      final e4 = n(64, 0, string: 1);
      final fit = fitPitchNotesToScale([e4], {e4}, 'C', 'minor');
      expect(fit.single.midi, 63);
      expect(fit.single.guitarString, isNull);
      // arpeggiate moves pitches of a chord; strings never go stale
      final chord = [
        for (final m in [52, 56, 59]) n(m, 0, dur: 4),
      ];
      final assigned = assignStrings(chord, {}).notes;
      final arp = arpeggiatePitchNotes(
        assigned,
        assigned.toSet(),
        const ArpSettings(),
        seed: 1,
        steps: 16,
      ).notes;
      for (final x in arp) {
        if (x.guitarString != null) {
          expect(guitarPlayable(x.guitarString!, x.midi), isTrue);
        }
      }
    });

    test('paste and chord stamp: kept when playable, new notes unassigned', () {
      final clip = PitchClipboard()..copy([one]);
      final pasted = clip.paste(atStep: 4, steps: 16).single;
      expect(pasted.guitarString, 1);
      expect(pasted.stringLocked, isTrue);
      final stamped = stampChordsBelow(
        [one],
        {one},
        ChordType.major,
        key: 'C',
        scale: 'major',
      );
      expect(stamped.selection, isNotEmpty);
      expect(stamped.selection.every((x) => x.guitarString == null), isTrue);
      expect(stamped.notes.first.guitarString, 1);
    });
  });

  group('ring and choke', () {
    test('different strings ring to the range end; same string chokes; '
        'unison ends at the later onset', () {
      // E-shape arpeggio on strings 6, 5, 4, 3, one step each
      final arp = [
        n(40, 0, string: 6),
        n(47, 1, string: 5),
        n(52, 2, string: 4),
        n(56, 3, string: 3),
      ];
      final ring = applyRing(arp, {}, rangeEnd: 8);
      expect([for (final x in ring.notes) x.endSteps], [8, 8, 8, 8]);
      // the same string re-plucked: cut at the second onset
      final same = [n(40, 0, string: 6), n(45, 2, string: 6)];
      final cut = applyRing(same, {}, rangeEnd: 8).notes;
      expect(cut[0].endSteps, 2);
      expect(cut[1].endSteps, 8);
      // unison on two strings: the earlier ends at the later onset
      final unison = [n(64, 0, string: 1), n(64, 2, string: 2)];
      final u = applyRing(unison, {}, rangeEnd: 8).notes;
      expect(u[0].endSteps, 2);
      expect(u[1].endSteps, 8);
      // a choke shortens a long note too
      final long = [n(40, 0, dur: 6, string: 6), n(45, 2, string: 6)];
      expect(applyRing(long, {}, rangeEnd: 8).notes[0].endSteps, 2);
      // a note longer than the range keeps its length
      final longer = [n(40, 0, dur: 12, string: 6)];
      expect(applyRing(longer, {}, rangeEnd: 8).notes[0].endSteps, 12);
    });

    test('ring end searched across the whole track; outside data unchanged',
        () {
      final mine = n(40, 0, string: 6);
      final outside = n(45, 3, string: 6); // unselected re-pluck
      final pitch = n(52, 1, string: 4);
      final samePitchOutside = n(52, 5, string: 3); // unison, unselected
      final src = [mine, outside, pitch, samePitchOutside];
      final r = applyRing(src, {mine, pitch}, rangeEnd: 16);
      expect(r.notes[0].endSteps, 3);
      expect(r.notes[2].endSteps, 5);
      expect(identical(r.notes[1], outside), isTrue);
      expect(identical(r.notes[3], samePitchOutside), isTrue);
      expect(r.selection, {r.notes[0], r.notes[2]});
    });

    test('half-open boundary, muted, locked and unassigned notes', () {
      // an onset exactly at the end is a choke: no extension past it
      final edge = [n(40, 0, dur: 2, string: 6), n(45, 2, string: 6)];
      final e = applyRing(edge, {}, rangeEnd: 8).notes;
      expect(identical(e[0], edge[0]), isTrue);
      expect(e[0].endSteps, 2);
      // a muted re-pluck neither chokes nor rings
      final mutedLater = [
        n(40, 0, string: 6),
        n(45, 2, string: 6, muted: true),
      ];
      final m = applyRing(mutedLater, {}, rangeEnd: 8).notes;
      expect(m[0].endSteps, 8);
      expect(identical(m[1], mutedLater[1]), isTrue);
      // a locked note is not extended but still chokes
      final locked = [
        n(40, 0, string: 6, locked: true),
        n(47, 1, string: 6),
        n(45, 4, string: 6, locked: true),
      ];
      final l = applyRing(locked, {}, rangeEnd: 8).notes;
      expect(identical(l[0], locked[0]), isTrue);
      expect(l[1].endSteps, 4);
      // unassigned notes keep their duration
      final free = [n(60, 0)];
      expect(identical(applyRing(free, {}, rangeEnd: 8).notes, free), isTrue);
    });

    test('revert restores exact JSON (null-ness kept); re-apply does not '
        'accumulate', () {
      final src = [
        n(40, 0, dur: 2, string: 6), // durationSteps null
        n(45, 1, dur: 1, duration: 2.0, string: 5),
        n(50, 2.25, dur: 1, duration: .5, string: 4),
      ];
      final before = js(src);
      final ring = applyRing(src, {}, rangeEnd: 8).notes;
      expect(ring.every((x) => x.ringBaseDur != null), isTrue);
      expect(ring[0].ringBaseDurationSteps, isNull);
      expect(ring[1].ringBaseDurationSteps, 2.0);
      final again = applyRing(ring, {}, rangeEnd: 8).notes;
      expect(js(again), js(ring));
      final back = revertRing(again, {}).notes;
      expect(js(back), before);
      expect(back[0].durationSteps, isNull);
      expect(back[0].dur, 2);
      // nothing to revert: the notes themselves
      expect(identical(revertRing(src, {}).notes, src), isTrue);
      // the ring base survives save/load
      final loaded = [
        for (final j in jsonDecode(jsonEncode(js(ring))) as List)
          PitchNote.fromJson(j as Map<String, dynamic>),
      ];
      expect(js(loaded), js(ring));
      expect(js(revertRing(loaded, {}).notes), before);
    });

    test('assignment chokes same-pitch overlaps restorably', () {
      final a = n(64, 0, dur: 4, string: 1, stringLocked: true);
      final b = n(64, 2, dur: 2, string: 2, stringLocked: true);
      final edit = assignStrings([a, b], {});
      expect(edit.notes[0].endSteps, 2);
      expect(edit.notes[0].ringBaseDur, 4);
      expect(js(revertRing(edit.notes, {}).notes), js([a, b]));
      // equal starts (duplicates) are never cut to nothing
      final dupA = n(64, 0, dur: 2, string: 1, stringLocked: true);
      final dupB = n(64, 0, dur: 2, string: 2, stringLocked: true);
      final d = enforceStringChoke([dupA, dupB], {});
      expect(identical(d.notes[0], dupA), isTrue);
    });

    test('a stroke-converted hit: ring from each actual start; choke on '
        'actual starts', () {
      final chord = [for (final m in [40, 45, 50, 55, 59, 64]) n(m, 0, dur: 2)];
      final stroke = applyGuitarStroke(chord, {}, const StrokeSpec.down(), bpm: 120);
      final assigned = assignStrings(stroke.notes, {}).notes;
      // next hit re-plucks the low string at 4
      final next = n(43, 4, dur: 1, string: 6, stringLocked: true);
      final ring = applyRing([...assigned, next], {}, rangeEnd: 8).notes;
      for (var i = 0; i < 6; i++) {
        expect(ring[i].startSteps, assigned[i].startSteps);
        expect(ring[i].endSteps, i == 0 ? 4 : 8, reason: '${ring[i].midi}');
        expect(ring[i].stroke, assigned[i].stroke, reason: 'tag kept');
      }
      // ring revert is exact; a stroke revert/re-apply drops the ring
      expect(js(revertRing(ring, {}).notes), js([...assigned, next]));
      final strokeBack = revertGuitarStroke(ring, {}).notes;
      expect(strokeBack.take(6).every((x) => x.ringBaseDur == null), isTrue);
      expect(
        [for (final x in strokeBack.take(6)) x.toJson()..remove('guitarString')],
        js(chord),
      );
    });

    test('ringRangeEnd: selection end or section end', () {
      final a = n(40, 0, string: 6), b = n(45, 3, dur: 2, string: 5);
      expect(ringRangeEnd([a, b], {}, 16), 16);
      expect(ringRangeEnd([a, b], {a, b}, 16), 5);
      expect(ringRangeEnd([a, b], {a}, 16), 1);
      expect(ringRangeEnd([n(40, 15, dur: 4)], {}, 16), 16);
    });
  });

  group('output identity', () {
    test('MIDI events == note data for ring/choke results (WAV uses '
        'buildMidi)', () {
      final src = [
        n(40, 0, string: 6),
        n(47, 1, string: 5),
        n(45, 3, string: 6),
        n(64, 2, string: 1),
        n(64, 5, string: 2),
      ];
      final ring = applyRing(src, {}, rangeEnd: 8).notes;
      final bytes = midiOf(ring);
      final tps = tpqOf(bytes) / kStepsPerBeat;
      final ev = readEvents(bytes);
      final ons = {
        for (final e in ev)
          if (e.on) (e.pitch, e.tick),
      };
      final offs = {
        for (final e in ev)
          if (!e.on) (e.pitch, e.tick),
      };
      expect(ons, {
        for (final x in ring) (x.midi, (x.startSteps * tps).round()),
      });
      expect(offs, {
        for (final x in ring) (x.midi, (x.endSteps * tps).round()),
      });
      // live reads the same note data: the legacy strum never applies to
      // ringed notes (explicit length), so each plays at its start/length
      expect(ring.every((x) => x.durationSteps != null), isTrue);
    });

    test('same tick: note-off before note-on for the same pitch, whatever '
        'the list order', () {
      // the later note listed first, the earlier one choked at its onset
      final later = n(64, 4, dur: 2, string: 2);
      final earlier = n(64, 0, dur: 4, string: 1);
      for (final order in [
        [later, earlier],
        [earlier, later],
      ]) {
        final ev = readEvents(midiOf(order));
        final at4 = [
          for (final e in ev)
            if (e.pitch == 64 && e.tick == ev.firstWhere((x) => x.on && x.tick > 0).tick) e.on,
        ];
        expect(at4, [false, true]);
      }
      // a zero-gap re-strike of a different pitch keeps its order
      final plain = readEvents(midiOf([n(60, 0), n(62, 1)]));
      expect([for (final e in plain) e.on], [true, false, true, false]);
    });

    test('groove: choke boundary drift is documented (actual result)', () {
      // a re-plucked string: 40 at 0 is choked at 3 by 45 (both string 6)
      final src = applyRing(
        [n(40, 0, string: 6), n(45, 3, string: 6)],
        {},
        rangeEnd: 8,
      ).notes;
      expect(src[0].endSteps, 3);
      const ctx = GrooveContext(
        trackGrooves: {'melody': GrooveAssign(grooveId: 'builtin:laidback')},
      );
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: src);
      final flat = flattenSong([s], groove: ctx).melody;
      final first = flat.firstWhere((x) => x.midi == 40);
      final second = flat.firstWhere((x) => x.midi == 45);
      final shift0 = first.startSteps - 0, shift1 = second.startSteps - 3;
      // the groove moves both onsets and keeps the lengths, so the boundary
      // moves with the first note's shift: gap/overlap = shift0 - shift1
      expect(
        first.endSteps - second.startSteps,
        closeTo(shift0 - shift1, 1e-6),
      );
      // the drift is bounded by the groove's own shifts
      expect(
        (first.endSteps - second.startSteps).abs(),
        lessThanOrEqualTo(shift0.abs() + shift1.abs() + 1e-6),
      );
      // whatever the drift, a same-pitch choke never cuts the new note
      final unison = applyRing(
        [n(64, 0, string: 1), n(64, 2, string: 2)],
        {},
        rangeEnd: 8,
      ).notes;
      final ev = readEvents(midiOf(unison, groove: ctx));
      var sounding = 0;
      for (final e in ev) {
        sounding += e.on ? 1 : -1;
        expect(sounding, inInclusiveRange(0, 1));
      }
    });

    test('section end truncates rings; a ring never passes the section', () {
      final src = [n(40, 12, string: 6)];
      final ring = applyRing(src, {}, rangeEnd: 16).notes;
      expect(ring.single.endSteps, 16);
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: ring);
      final flat = flattenSong([s, s.deepCopy()..id = 't']).melody;
      expect(flat, hasLength(2));
      expect(flat.every((x) => x.endSteps - x.startSteps <= 4 + 1e-9), isTrue);
    });
  });

  group('review regressions', () {
    test('a slow stroke crossing into the next hit (inverted onsets)', () {
      // hit A at 0: strings land at 0 .. 2.4; hit B at 1.0 starts before
      // A's late strings although A is processed first
      final a = applyGuitarStroke(
        [for (final m in [40, 45, 50, 55, 59, 64]) n(m, 0, dur: 4)],
        {},
        const StrokeSpec.down(spreadMs: 60),
        bpm: 120,
      ).notes;
      final b = n(59, 1, dur: 2);
      final edit = assignStrings([...a, b], {});
      expect(edit.unassignable, isEmpty);
      expect(stringsByMidi(edit.notes.take(6).toList()), {
        40: 6,
        45: 5,
        50: 4,
        55: 3,
        59: 2,
        64: 1,
      });
      // every string choice costs one choke; B takes the open B string and
      // is cut where A's later 59 (string 2, 1.92) is struck
      final bOut = edit.notes[6];
      expect(bOut.guitarString, 2);
      expect(bOut.endSteps, closeTo(1.92, 1e-9));
      expect(bOut.ringBaseDur, 2);
      // A's strings keep their lengths (nothing struck on them later)
      for (var i = 0; i < 6; i++) {
        expect(edit.notes[i].endSteps, closeTo(4, 1e-9));
      }
      // no two notes overlap on one string
      for (final x in edit.notes) {
        for (final y in edit.notes) {
          if (identical(x, y) || x.guitarString != y.guitarString) continue;
          expect(
            x.startSteps < y.endSteps - 1e-9 && y.startSteps < x.endSteps - 1e-9,
            isFalse,
          );
        }
      }
    });

    test('a long locked note under a later short fixed note still blocks', () {
      final long = n(59, 0, dur: 8, string: 2, locked: true);
      final short = n(60, 1, dur: 1, string: 2); // pre-existing overlap
      final mine = n(59, 4, dur: 1);
      final edit = assignStrings([long, short, mine], {mine});
      expect(identical(edit.notes[0], long), isTrue);
      expect(identical(edit.notes[1], short), isTrue);
      expect(edit.notes[2].guitarString, 3, reason: 'string 2 still rings');
    });

    test('ring cap boundaries', () {
      // ending exactly at the cap: unchanged
      final atCap = [n(40, 0, dur: 8, string: 6)];
      expect(identical(applyRing(atCap, {}, rangeEnd: 8).notes, atCap), isTrue);
      // an onset exactly at the cap (half-open): rings to the cap
      final onCap = [n(40, 0, string: 6), n(45, 8, string: 6)];
      final r = applyRing(onCap, {onCap[0]}, rangeEnd: 8).notes;
      expect(r[0].endSteps, 8);
      // an original longer than the cap is left as it is (ring never
      // shortens except for a choke) ...
      final longer = [n(40, 12, dur: 8, string: 6)];
      expect(identical(applyRing(longer, {}, rangeEnd: 16).notes, longer), isTrue);
      // ... and the section clip still truncates it at the section end
      final s = Section(id: 's', name: 's', bars: 1)
        ..tracks['melody'] = TrackData(notes: longer);
      final flat = flattenSong([s]).melody.single;
      expect(flat.endSteps, lessThanOrEqualTo(16 + 1e-9));
      final ev = readEvents(midiOf(longer));
      final tps = tpqOf(midiOf(longer)) / kStepsPerBeat;
      expect(ev.where((e) => !e.on).single.tick, lessThanOrEqualTo(16 * tps));
    });
  });

  group('stroke order follows the assigned strings', () {
    List<int> order(List<PitchNote> notes, StrokeDir dir) {
      final out = applyGuitarStroke(
        notes,
        {},
        dir == StrokeDir.down ? const StrokeSpec.down() : const StrokeSpec.up(),
        bpm: 120,
      ).notes;
      final idx = [for (var i = 0; i < out.length; i++) i]
        ..sort((a, b) => out[a].stroke!.order.compareTo(out[b].stroke!.order));
      return idx;
    }

    test('crossing: a higher pitch on a lower string', () {
      // 47 on string 6 (fret 7), 45 on string 5 (open)
      final notes = [n(47, 0, dur: 2, string: 6), n(45, 0, dur: 2, string: 5)];
      expect(order(notes, StrokeDir.down), [0, 1]); // string 6 first
      expect(order(notes, StrokeDir.up), [1, 0]); // string 5 first
      expect(strokeConversionOrder(notes, [0, 1], StrokeDir.down), [0, 1]);
      // pitch order would be the reverse
      expect(strokeOrder(notes, [0, 1], StrokeDir.down), [1, 0]);
    });

    test('same pitch on two strings', () {
      final notes = [n(64, 0, dur: 2, string: 1), n(64, 0, dur: 2, string: 2)];
      expect(order(notes, StrokeDir.down), [1, 0]);
      expect(order(notes, StrokeDir.up), [0, 1]);
    });

    test('a partly assigned hit falls back to pitch order', () {
      final notes = [n(47, 0, dur: 2, string: 6), n(45, 0, dur: 2)];
      expect(order(notes, StrokeDir.down), [1, 0]);
      expect(order(notes, StrokeDir.up), [0, 1]);
      final none = [n(47, 0, dur: 2), n(45, 0, dur: 2)];
      expect(order(none, StrokeDir.down), [1, 0]);
    });

    test('the legacy strum keeps pitch order even with strings', () {
      final notes = [n(47, 0, dur: 2, string: 6), n(45, 0, dur: 2, string: 5)];
      expect([for (final p in strumPairs(notes)) p.midi], [45, 47]);
    });
  });

  group('inheritance', () {
    late List<PitchNote> ringed;
    setUp(() {
      ringed = applyRing(
        [n(40, 0, string: 6, stringLocked: true), n(45, 2, string: 5)],
        {},
        rangeEnd: 8,
      ).notes;
      expect(ringed.every((x) => x.ringBaseDur != null), isTrue);
    });

    test('copy/paste, duplicate, sections, save/load keep the fields', () {
      final pasted = (PitchClipboard()..copy(ringed)).paste(atStep: 8, steps: 16);
      for (var i = 0; i < 2; i++) {
        final a = ringed[i].toJson()..remove('step');
        final b = pasted[i].toJson()..remove('step');
        expect(b, a);
      }
      final dup = duplicatePitchNotes(ringed, ringed.toSet(), 32);
      expect(dup.skip(2).map((x) => x.guitarString), [6, 5]);
      final s = Section(id: 'a', name: 'A', bars: 1)
        ..tracks['melody'] = TrackData(notes: ringed);
      expect(js(s.deepCopy().tracks['melody']!.pitchNotes), js(ringed));
      final linked = duplicateLinked(s, 'b');
      expect(identical(linked.tracks, s.tracks), isTrue);
      final song = Song(id: 'x', title: 'x', sections: [s, linked]);
      final loaded = Song.fromJson(
        jsonDecode(jsonEncode(song.toJson())) as Map<String, dynamic>,
      );
      for (final sec in loaded.sections) {
        expect(js(sec.tracks['melody']!.pitchNotes), js(ringed));
      }
      // untouched notes write none of the new keys
      final plain = n(60, 0).toJson();
      for (final k in [
        'guitarString',
        'stringLocked',
        'ringBaseDur',
        'ringBaseDurationSteps',
      ]) {
        expect(plain.containsKey(k), isFalse);
      }
    });

    test('split, quantize, glue keep the string and drop the ring base', () {
      final low = ringed[0];
      final split = splitPitchNotesAt(ringed, {low}, 1).notes;
      final pieces = split.where((x) => x.midi == 40).toList();
      expect(pieces, hasLength(2));
      expect(pieces.every((x) => x.guitarString == 6), isTrue);
      expect(pieces.every((x) => x.ringBaseDur == null), isTrue);
      final ringedOff = applyRing([n(40, .3, string: 6)], {}, rangeEnd: 4).notes;
      final q2 = quantizePitchNotes(
        ringedOff,
        ringedOff.toSet(),
        grid: 1,
        strength: 1,
        ends: false,
        steps: 16,
      );
      expect(q2.single.guitarString, 6);
      expect(q2.single.ringBaseDur, isNull);
      final glued = gluePitchNotes(pieces, pieces.toSet()).notes.single;
      expect(glued.guitarString, 6);
      expect(glued.ringBaseDur, isNull);
    });
  });
}
