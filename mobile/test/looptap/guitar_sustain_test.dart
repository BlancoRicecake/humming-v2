// gt-004 "줄별 울림 유지" (pure rule): equivalence with the approved A3
// AFTER, the 5→6 / 2→3 connections, every not-connected case, protected
// notes keep byte-identical JSON, idempotence, ring revert, layers and MIDI.
// Spec: docs/specs/guitar/gt-004-stroke-sustain.md.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/guitar_sustain.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

import '../support/midi_all_events.dart';

const _em = [40, 47, 52, 55, 59, 64];
const _eps = 1e-9;

PitchNote _raw(int midi, int step, int dur) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

/// Block chords of [pitches] at each (step, dur).
List<PitchNote> _chords(List<int> pitches, List<(int, int)> hits) => [
  for (final (s, d) in hits)
    for (final m in pitches) _raw(m, s, d),
];

/// Down strokes on every hit (pitch order, 28 ms at 120 BPM).
List<PitchNote> _down(List<PitchNote> notes) =>
    applyGuitarStroke(notes, const {}, const StrokeSpec.down(), bpm: 120).notes;

String _j(PitchNote n) => jsonEncode(n.toJson());

/// Indices of the notes whose pre-stroke hit starts at [step].
List<int> _hitAt(List<PitchNote> notes, num step) => [
  for (var i = 0; i < notes.length; i++)
    if ((strokeGroupStart(notes[i]) - step).abs() < _eps) i,
];

int _r(StrokeSustainResult r, SustainReason k) => r.reasons[k] ?? 0;

/// Every note of [hit] that rings ends exactly at the same-string,
/// same-pitch onset of [next]; strings are read from [strings] (the result
/// or an assignment of it).
void _expectConnected(
  List<PitchNote> out,
  List<int> hit,
  List<int> next, {
  List<PitchNote>? strings,
}) {
  final s = strings ?? out;
  for (final i in hit) {
    final j = next.singleWhere(
      (j) => out[j].midi == out[i].midi && s[j].guitarString == s[i].guitarString,
    );
    expect(out[i].endSteps, closeTo(out[j].startSteps, 1e-9), reason: '#$i');
  }
}

void main() {
  group('A3-normal equivalence (approved AFTER)', () {
    const dir = '../artifacts/guitar-stroke-ring-20261022';
    final beforeFile = File('$dir/BEFORE-A3-normal.song.json');
    final afterFile = File('$dir/AFTER-A3-normal-ring.song.json');
    final missing = !beforeFile.existsSync() || !afterFile.existsSync();
    Song load(File f) =>
        Song.fromJson(jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
    List<PitchNote> guitar(Song s) =>
        s.sections.single.tracks['melody']!.pitchNotes;

    late List<PitchNote> before, after;
    late StrokeSustainResult r;
    setUpAll(() {
      if (missing) return;
      final b = load(beforeFile);
      before = guitar(b);
      after = guitar(load(afterFile));
      r = applyStrokeSustain(before, const {}, sectionSteps: b.bars * 16);
    });
    final skip = missing ? 'approved A3 files not found under $dir' : false;

    test('identical durations for all 288 notes (200 extended); onsets, '
        'velocities and tags unchanged', () {
      expect(before, hasLength(288));
      expect(after, hasLength(288));
      expect(r.extended, 200);
      expect(r.kept, 88);
      expect(r.reasons, {
        SustainReason.chordChange: 42,
        SustainReason.sectionEnd: 6,
        SustainReason.alreadyConnected: 40,
      });
      var lengthened = 0;
      for (var i = 0; i < 288; i++) {
        final o = r.notes[i], a = after[i], b = before[i];
        expect((o.dur, o.durationSteps), (a.dur, a.durationSteps), reason: '#$i');
        expect(
          (o.midi, o.step, o.offsetSteps, o.velocity),
          (a.midi, a.step, a.offsetSteps, a.velocity),
          reason: '#$i',
        );
        expect(o.stroke, a.stroke, reason: '#$i');
        expect(o.stroke, b.stroke, reason: '#$i');
        if (o.durationSteps != b.durationSteps) lengthened++;
        if (o.ringBaseDur != null) {
          // an extended note equals the approved AFTER note exactly
          expect(o.toJson(), a.toJson(), reason: '#$i');
        } else {
          // every other note is untouched (narrowest rule: no string)
          expect(_j(o), _j(b), reason: '#$i');
          expect(o.toJson(), a.toJson()..remove('guitarString'), reason: '#$i');
        }
      }
      expect(lengthened, 200);
    }, skip: skip);

    test('hits 5→6 and 2→3: every string ends at the next same-string, '
        'same-pitch onset', () {
      final strings = assignStrings(r.notes, const {}).notes;
      for (final (a, b) in [(12, 14), (4, 6)]) {
        final hit = _hitAt(r.notes, a), next = _hitAt(r.notes, b);
        expect(hit, hasLength(6));
        _expectConnected(r.notes, hit, next, strings: strings);
        // compared with the approved AFTER's strings as well
        _expectConnected(r.notes, hit, next, strings: after);
      }
      // the 0 ms string (E4 into the up stroke) is already connected
      final e4 = _hitAt(r.notes, 12).singleWhere((i) => r.notes[i].midi == 64);
      expect(_j(r.notes[e4]), _j(before[e4]));
    }, skip: skip);

    test('MIDI: same-key note-off before note-on; no same-pitch overlap; '
        'extended offs land on the re-strike', () {
      final sec = Section(id: 'A', name: 'A', bars: 8)
        ..tracks['melody'] = TrackData(notes: r.notes);
      final read = readMidiEvents(
        buildMidi(flattenSong([sec]), 80, melodyProgram: 25),
      );
      final notes = midiNotes(read.events);
      expect(notes, hasLength(288));
      final tps = read.tpq / kStepsPerBeat;
      final expected = [
        for (final n in r.notes)
          (
            channel: 0,
            key: n.midi,
            velocity: n.velocity!,
            on: (n.step * tps + n.offsetSteps * tps).round(),
            off:
                (n.step * tps + n.offsetSteps * tps + n.soundingSteps * tps)
                    .round(),
          ),
      ]..sort((x, y) => x.on != y.on ? x.on.compareTo(y.on) : x.key - y.key);
      expect(notes, expected);
      // same tick, same key: the first off precedes the first on
      final firstOn = <(int, int), int>{}, firstOff = <(int, int), int>{};
      for (var i = 0; i < read.events.length; i++) {
        final e = read.events[i];
        if (e.kind == 0x90 && e.b > 0) firstOn.putIfAbsent((e.tick, e.a), () => i);
        if (e.kind == 0x80 || (e.kind == 0x90 && e.b == 0)) {
          firstOff.putIfAbsent((e.tick, e.a), () => i);
        }
      }
      var pairs = 0;
      for (final e in firstOn.entries) {
        final off = firstOff[e.key];
        if (off == null) continue;
        pairs++;
        expect(off, lessThan(e.value), reason: '${e.key}');
      }
      expect(pairs, greaterThanOrEqualTo(200));
      final byKey = <int, List<({int on, int off})>>{};
      for (final x in notes) {
        (byKey[x.key] ??= []).add((on: x.on, off: x.off));
      }
      for (final list in byKey.values) {
        for (var k = 0; k + 1 < list.length; k++) {
          expect(list[k + 1].on, greaterThanOrEqualTo(list[k].off));
        }
      }
    }, skip: skip);
  });

  group('connection', () {
    test('a repeated stroked chord rings to the re-strike', () {
      final src = _down(_chords(_em, [(0, 4), (4, 4)]));
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(r.extended, 5);
      expect(r.reasons, {
        SustainReason.alreadyConnected: 1, // E2: struck first, ends at 4
        SustainReason.sectionEnd: 6,
      });
      _expectConnected(r.notes, _hitAt(r.notes, 0), _hitAt(r.notes, 4),
          strings: assignStrings(src, const {}).notes);
      for (var i = 0; i < src.length; i++) {
        expect(
          (r.notes[i].step, r.notes[i].offsetSteps, r.notes[i].velocity),
          (src[i].step, src[i].offsetSteps, src[i].velocity),
        );
        expect(r.notes[i].stroke, src[i].stroke);
        expect(r.notes[i].endSteps, greaterThanOrEqualTo(src[i].endSteps));
      }
      expect(r.summary(ko: true), '연장 5 · 그대로 7 (섹션 끝 6, 이미 연결됨 1)');
    });

    test('already-long notes are neither extended nor shortened; re-apply is '
        'idempotent', () {
      final assigned =
          assignStrings(_down(_chords(_em, [(0, 4), (4, 4)])), const {}).notes;
      final g3 = _hitAt(assigned, 0).singleWhere((i) => assigned[i].midi == 55);
      final src = [...assigned];
      src[g3] = src[g3].copyWith(durationSteps: 7.0); // past the re-strike
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(_j(r.notes[g3]), _j(src[g3]));
      expect(r.extended, 4);
      expect(_r(r, SustainReason.alreadyConnected), 2);
      final again = applyStrokeSustain(r.notes, const {}, sectionSteps: 16);
      expect(identical(again.notes, r.notes), isTrue);
      expect(again.extended, 0);
      expect(_r(again, SustainReason.alreadyConnected), 6);
    });

    test('울림 되돌리기 restores the exact JSON; stroke and strings kept', () {
      final assigned =
          assignStrings(_down(_chords(_em, [(0, 4), (4, 4)])), const {}).notes;
      final r = applyStrokeSustain(assigned, const {}, sectionSteps: 16);
      expect(r.extended, 5);
      expect(r.stringsAssigned, 0, reason: 'strings were already there');
      final back = revertRing(r.notes, const {}).notes;
      expect([for (final n in back) _j(n)], [for (final n in assigned) _j(n)]);
    });

    test('auto strings are written only to the extended notes', () {
      final src = _down(_chords(_em, [(0, 4), (4, 4)]));
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(r.stringsAssigned, 5);
      for (var i = 0; i < src.length; i++) {
        if (r.notes[i].ringBaseDur != null) {
          expect(r.notes[i].guitarString, isNotNull);
          expect(r.notes[i].stringLocked, isFalse);
        } else {
          expect(_j(r.notes[i]), _j(src[i]), reason: '#$i');
        }
      }
    });
  });

  group('not connected', () {
    test('chord change: the same pitch is in the next chord, voicing differs',
        () {
      // E2 B2 E3 G3 B3 E4 -> E2 B2 E3 G3 B3 (E2..B3 repeat, E4 dropped)
      final src = _down([
        ..._chords(_em, [(0, 4)]),
        ..._chords(_em.take(5).toList(), [(4, 4)]),
      ]);
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(r.extended, 0);
      expect(identical(r.notes, src), isTrue);
      expect(_r(r, SustainReason.chordChange), 6);
    });

    test('voicing change of the same chord (C, different inversion)', () {
      final src = _down([
        ..._chords([48, 52, 55, 60, 64], [(0, 4)]),
        ..._chords([52, 55, 60, 64, 67], [(4, 4)]),
      ]);
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(r.extended, 0);
      expect(_r(r, SustainReason.chordChange), 5);
    });

    test('rest gap', () {
      final src = _down(_chords(_em, [(0, 2), (4, 4)]));
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(r.extended, 0);
      expect(_r(r, SustainReason.rest), 6);
    });

    test('one string cut short on purpose stays cut; its neighbours ring', () {
      final raw = _chords(_em, [(0, 4), (4, 4)]);
      raw[5] = _raw(64, 0, 2); // E4 of the first hit ends at 2
      final src = _down(raw);
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(_r(r, SustainReason.rest), 1);
      expect(_j(r.notes[5]), _j(src[5]));
      expect(r.extended, 4); // E2 is already connected
      for (final i in [1, 2, 3, 4]) {
        expect(r.notes[i].endSteps, greaterThan(src[i].endSteps));
      }
    });

    test('section end (no next hit, or the next hit past the section)', () {
      final src = _down(_chords(_em, [(0, 4), (16, 4)]));
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(r.extended, 0);
      expect(_r(r, SustainReason.sectionEnd), 12);
    });

    test('partial selection of a hit is refused; outside notes stay '
        'byte-identical', () {
      final src = _down(_chords(_em, [(0, 4), (4, 4), (8, 4)]));
      // hit 0 fully, hit 1 only its lower three strings
      final sel = {for (final i in [0, 1, 2, 3, 4, 5, 6, 7, 8]) src[i]};
      final r = applyStrokeSustain(src, sel, sectionSteps: 16);
      expect(r.extended, 0);
      expect(_r(r, SustainReason.partialSelection), 9);
      // the whole of hits 0 and 1: hit 0 rings, hit 1 stops at the boundary,
      // hit 2 (outside) is considered but never written
      final both = {for (var i = 0; i < 12; i++) src[i]};
      final r2 = applyStrokeSustain(src, both, sectionSteps: 16);
      expect(r2.extended, 5);
      expect(_r(r2, SustainReason.selectionBoundary), 6);
      for (var i = 6; i < 18; i++) {
        expect(_j(r2.notes[i]), _j(src[i]), reason: '#$i');
      }
      expect(r2.selection, {for (var i = 0; i < 12; i++) r2.notes[i]});
    });

    test('a split selection never bridges the gap', () {
      final src = _down(_chords(_em, [(0, 4), (4, 4), (8, 4), (12, 4)]));
      final sel = {
        for (var i = 0; i < 6; i++) src[i],
        for (var i = 12; i < 18; i++) src[i],
      };
      final r = applyStrokeSustain(src, sel, sectionSteps: 16);
      expect(r.extended, 0);
      expect(identical(r.notes, src), isTrue);
      expect(_r(r, SustainReason.selectionBoundary), 12);
    });

    test('untagged chords, untagged destination and mixed hits', () {
      // never converted
      final plain = _chords(_em, [(0, 4), (4, 4)]);
      final r0 = applyStrokeSustain(plain, const {}, sectionSteps: 16);
      expect(r0.extended, 0);
      expect(_r(r0, SustainReason.noStroke), 12);
      // stroked hit -> untagged legacy chord
      final dest = [..._down(_chords(_em, [(0, 4)])), ..._chords(_em, [(4, 4)])];
      final r1 = applyStrokeSustain(dest, const {}, sectionSteps: 16);
      expect(r1.extended, 0);
      expect(_r(r1, SustainReason.noStroke), 12);
      // a mixed hit (one string untagged) as A and as B
      final stroked = _down(_chords(_em, [(0, 4), (4, 4), (8, 4)]));
      for (final at in [0, 6]) {
        final mixed = [...stroked];
        final untagged = at + 3; // G3
        mixed[untagged] = _raw(55, mixed[untagged].step, 4);
        final r = applyStrokeSustain(mixed, const {}, sectionSteps: 16);
        // the mixed hit refuses every pair it is part of (as A and as B)
        final protected = at == 0 ? 6 : 18;
        for (var i = 0; i < protected; i++) {
          expect(_j(r.notes[i]), _j(mixed[i]), reason: 'with #$untagged: #$i');
        }
        // mixed hit 0: hit 1 -> hit 2 still connects; mixed hit 1: nothing
        expect(r.extended, at == 0 ? 5 : 0);
        expect(_r(r, SustainReason.noStroke), at == 0 ? 6 : 12);
      }
    });

    test('an arpeggio (one note per hit) never connects', () {
      final src = _down([
        for (var k = 0; k < 8; k++) _raw([40, 47, 52, 55][k % 4], k, 1),
      ]);
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(r.extended, 0);
      expect(_r(r, SustainReason.chordChange), 7);
      expect(_r(r, SustainReason.sectionEnd), 1);
    });

    test('articulated, muted and locked notes: protected JSON, neighbours '
        'extend where the rule allows', () {
      final src = _down(_chords(_em, [(0, 4), (4, 4), (8, 4), (12, 4)]));
      final art = [...src];
      // hit 1 G3 staccato: pairs 0->1 and 1->2 refused, 2->3 rings
      art[9] = art[9].withArticulation(newArticulation(ArticulationKind.staccato));
      final ra = applyStrokeSustain(art, const {}, sectionSteps: 16);
      for (var i = 0; i < 12; i++) {
        expect(_j(ra.notes[i]), _j(art[i]), reason: '#$i');
      }
      expect(ra.extended, 5);
      expect(_r(ra, SustainReason.articulation), 12);
      expect(ra.notes[9].articulation?.kind, ArticulationKind.staccato);

      // muted B3 in hit 1: hit 0 -> 1 and 1 -> 2 differ; 2 -> 3 rings
      final mut = [...src];
      mut[10] = mut[10].copyWith(muted: true);
      final rm = applyStrokeSustain(mut, const {}, sectionSteps: 16);
      for (var i = 0; i < 12; i++) {
        expect(_j(rm.notes[i]), _j(mut[i]), reason: '#$i');
      }
      expect(_r(rm, SustainReason.lockedMuted), 1);
      expect(rm.extended, 5);

      // locked D3 in hit 0: kept (no string written), the others ring
      final lock = [...src];
      lock[2] = lock[2].copyWith(locked: true);
      final rl = applyStrokeSustain(lock, const {}, sectionSteps: 16);
      expect(_j(rl.notes[2]), _j(lock[2]));
      expect(_r(rl, SustainReason.lockedMuted), 1);
      expect(rl.extended, 4 + 5 + 5);
    });

    test('a manually chosen string in the next hit (another string) is not '
        'joined; the user string is never changed', () {
      final src = [..._down(_chords(_em, [(0, 4), (4, 4)]))];
      src[11] = src[11].copyWith(guitarString: 2, stringLocked: true); // B E4
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(_j(r.notes[5]), _j(src[5]));
      expect(_j(r.notes[11]), _j(src[11]));
      // E4 has no string-1 partner; the next hit's B3 then finds no free
      // string, so B3 is not joined either (strings decide, not pitches)
      expect(_r(r, SustainReason.chordChange), 1);
      expect(_r(r, SustainReason.noString), 1);
      expect(r.extended, 3);
      expect(r.notes[11].guitarString, 2);
      expect(r.notes[11].stringLocked, isTrue);
    });

    test('unison: a same-pitch onset before the target is a conflict', () {
      final src = _down(_chords([64, 64], [(0, 4), (4, 4)]));
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      // the first string would run over the second string's E4 of the next
      // hit (same pitch, one MIDI channel): refused, nothing is written
      expect(r.extended, 0);
      expect(identical(r.notes, src), isTrue);
      // the first E4 would be cut by its unison partner when assigned (no
      // leak: refused), the second meets the next hit's first E4 first
      expect(r.reasons, {
        SustainReason.noString: 1,
        SustainReason.conflict: 1,
        SustainReason.sectionEnd: 2,
      });
    });

    test('an assignment choke never leaks into lengths', () {
      final src = [..._down(_chords(_em, [(0, 4), (4, 4)]))];
      // B3 of hit 0 runs past the re-strike: assigning it would cut it
      src[4] = src[4].copyWith(durationSteps: 6.0);
      final r = applyStrokeSustain(src, const {}, sectionSteps: 16);
      expect(_j(r.notes[4]), _j(src[4]));
      expect(_r(r, SustainReason.noString), 1);
      expect(r.extended, 4);
      for (var i = 6; i < 12; i++) {
        expect(_j(r.notes[i]), _j(src[i]), reason: 'targets keep JSON #$i');
      }
    });
  });
}
