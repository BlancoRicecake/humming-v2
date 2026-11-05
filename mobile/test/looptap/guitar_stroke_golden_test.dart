// gt-001 golden: songs and imported precise MIDI WITHOUT stroke tags must keep
// byte-identical .mid output and the same live legacy-strum decisions as the
// code before guitar stroke conversion existed. The hashes below were
// captured from the pre-change build (2026-10-22) before any gt-001 edit.
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

PitchNote _n(
  int midi,
  int step, {
  int dur = 1,
  int? velocity,
  double offset = 0,
  double? duration,
  double chance = 1,
  int deviation = 0,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  velocity: velocity,
  offsetSteps: offset,
  durationSteps: duration,
  chance: chance,
  velocityDeviation: deviation,
);

/// Untouched GM-guitar chords (no duplicate pitches) plus a single note.
List<PitchNote> guitarChords() => [
  for (final m in [52, 56, 59, 64]) _n(m, 0, dur: 2),
  for (final m in [64, 45, 57, 52, 60]) _n(m, 4, dur: 3), // unsorted input
  for (final m in [55, 59, 62]) _n(m, 8, dur: 2),
  _n(60, 12, dur: 1),
  for (final m in [48, 55, 60, 64, 67]) _n(m, 14, dur: 2),
];

/// The shape `midi_import` writes: explicit velocity, offset, duration.
List<PitchNote> importedPrecise() => [
  _n(52, 0, velocity: 96, offset: .12, duration: 1.7, dur: 2),
  _n(56, 0, velocity: 90, offset: .2, duration: 1.6, dur: 2),
  _n(59, 0, velocity: 84, offset: .31, duration: 1.4, dur: 2),
  _n(45, 4, velocity: 110, duration: 2.5, dur: 3),
  _n(57, 4, velocity: 70, offset: .05, duration: 2.4, dur: 3),
  _n(60, 9, velocity: 64, offset: .5, duration: .25, dur: 1),
];

Section _sec(
  String id, {
  List<PitchNote>? melody,
  List<PitchNote>? bass,
  int bars = 1,
  int repeats = 1,
  List<TrackRef>? extras,
  Map<String, TrackData>? extraTracks,
}) {
  final s = Section(id: id, name: id, bars: bars, repeats: repeats, extras: extras);
  if (melody != null) s.tracks['melody'] = TrackData(notes: melody);
  if (bass != null) s.tracks['bass'] = TrackData(notes: bass);
  extraTracks?.forEach((k, v) => s.tracks[k] = v);
  return s;
}

String _hash(Uint8List b) => sha256.convert(b).toString();

/// Every golden case: name → the .mid bytes the current code builds.
Map<String, Uint8List> goldenCases() {
  final out = <String, Uint8List>{};
  out['plain_guitar'] = buildMidi(
    flattenSong([_sec('a', melody: guitarChords())]),
    100,
    melodyProgram: 25,
  );
  out['non_guitar'] = buildMidi(
    flattenSong([_sec('a', melody: guitarChords())]),
    100,
  );
  out['imported_precise_guitar'] = buildMidi(
    flattenSong([_sec('a', melody: importedPrecise())]),
    93,
    melodyProgram: 25,
  );
  out['mixed_edit'] = buildMidi(
    flattenSong([
      _sec(
        'a',
        melody: [
          ...guitarChords(),
          _n(50, 6, velocity: 77),
          _n(57, 6),
        ],
        bass: [_n(40, 0, dur: 4), _n(43, 8, dur: 4)],
      ),
    ]),
    120,
    melodyProgram: 27,
  );
  out['strum_forced_wav'] = buildMidi(
    flattenSong([_sec('a', melody: guitarChords())]),
    110,
    strumGuitar: true,
    vol: const {'melody': .7, 'bass': .8, 'drums': .9},
    pan: const {'melody': -.3},
  );
  final ctx = GrooveContext(
    trackGrooves: const {'melody': GrooveAssign(grooveId: 'builtin:laidback')},
    amount: 1.0,
    swing: .2,
  );
  out['grooved_guitar'] = buildMidi(
    flattenSong([_sec('a', melody: guitarChords())], groove: ctx),
    100,
    melodyProgram: 25,
    swing: .2,
  );
  out['extras_guitar'] = buildMidi(
    flattenSong([
      _sec(
        'a',
        extras: const [TrackRef('gtr2', 'melody')],
        extraTracks: {'gtr2': TrackData(notes: guitarChords())},
      ),
    ]),
    100,
    extras: const [TrackRef('gtr2', 'melody')],
    extraInstruments: const {'gtr2': 24},
  );
  out['swing_variation_sections'] = buildMidi(
    flattenSong([
      _sec(
        'a',
        melody: [
          ...guitarChords(),
          _n(62, 10, chance: .5),
          _n(65, 11, deviation: 20, velocity: 80),
        ],
        repeats: 2,
      ),
      _sec('b', melody: importedPrecise(), bars: 2),
    ], variationSeed: 1234),
    100,
    melodyProgram: 25,
    swing: .3,
  );
  return out;
}

const Map<String, String> kGolden = {
  'plain_guitar':
      '8c98258a72b13e429ab1d5090df2d5a2461381e1fccdaa3332a6d7bdffa81373',
  'non_guitar':
      'f1c760da049b36ef71f4b02063b06822bd057b950a269e1849322ccb15c030b5',
  'imported_precise_guitar':
      '1b9d2099f336de89377f4e1d0276771035597dc29838689ae8dc53040e5591d5',
  'mixed_edit':
      'ba56e3612e7441707e3c1d1fdabb14577e9397d6d65c6f9eb80576da8005e108',
  'strum_forced_wav':
      'e81221b01611e9b197592fc6ddc2968ce5f5cba05b847055e7af2a00bcb1b746',
  'grooved_guitar':
      '038990656df1650102d665f8026b9a96b79deb6bbaa5727c24bbdaf68e151b7e',
  'extras_guitar':
      '2cecf5a95a86bbfa55694b0f873d38bebed2cc61052f99021ba6168afde014e2',
  'swing_variation_sections':
      '9dfc134803125ba8596b203859b218c6c9fab496319efe23486b44bcba4e8868',
};

/// Frozen copy of the pre-change live legacy-strum decision in
/// `EditScreen._trigger` (guitar branch). Used as the reference the new
/// shared helper must match for chords without duplicate pitches.
List<({PitchNote note, int midi, int delayMs, double velScale})>?
frozenLegacyLive(
  List<PitchNote> due, {
  required bool guitar,
  int Function(PitchNote n)? midiOf,
}) {
  int previewMidi(PitchNote n) => midiOf?.call(n) ?? n.midi;
  if (guitar &&
      due.length > 1 &&
      due.every(
        (n) =>
            n.velocity == null &&
            n.velocityDeviation == 0 &&
            n.offsetSteps == 0 &&
            n.durationSteps == null,
      )) {
    final byMidi = {for (final n in due) previewMidi(n): n};
    return [
      for (final s in strumPlan([for (final n in due) previewMidi(n)]))
        (
          note: byMidi[s.midi]!,
          midi: s.midi,
          delayMs: s.delayMs,
          velScale: s.velScale,
        ),
    ];
  }
  return null;
}

void main() {
  test('pre-change .mid bytes are unchanged (sha256 per case)', () {
    final cases = goldenCases();
    final got = {for (final e in cases.entries) e.key: _hash(e.value)};
    expect(got, kGolden);
  });

  test('live legacy strum decisions match the frozen pre-change code', () {
    final cases = <List<PitchNote>>[
      guitarChords().where((n) => n.step == 0).toList(),
      guitarChords().where((n) => n.step == 4).toList(), // unsorted input
      guitarChords().where((n) => n.step == 8).toList(),
      guitarChords().where((n) => n.step == 12).toList(), // single note
      [_n(40, 0), _n(47, 0)],
      [_n(52, 0, velocity: 90), _n(56, 0)], // edited → no strum
      [_n(52, 0, offset: .1), _n(56, 0)],
      [_n(52, 0, duration: 1.5), _n(56, 0)],
      [_n(52, 0, deviation: 5), _n(56, 0)],
      importedPrecise().where((n) => n.step == 0).toList(),
      [],
    ];
    int raw(PitchNote n) => n.midi - 12; // the raw-melody preview mapping
    for (final due in cases) {
      for (final guitar in [true, false]) {
        for (final midiOf in <int Function(PitchNote)?>[null, raw]) {
          final old = frozenLegacyLive(due, guitar: guitar, midiOf: midiOf);
          final now = liveLegacyStrum(due, guitar: guitar, midiOf: midiOf);
          expect(now == null, old == null, reason: '$due $guitar');
          if (old == null) continue;
          expect(now!.length, old.length);
          for (var i = 0; i < old.length; i++) {
            expect(identical(now[i].note, old[i].note), isTrue);
            expect(now[i].midi, old[i].midi);
            expect(now[i].delayMs, old[i].delayMs);
            expect(now[i].velScale, old[i].velScale);
          }
        }
      }
    }
    expect(
      liveLegacyStrum(guitarChords().where((n) => n.step == 0).toList(), guitar: true),
      isNotNull,
      reason: 'the fixture really exercises the legacy strum',
    );
  });

  test('untagged notes serialize exactly as before (no stroke key)', () {
    for (final n in [...guitarChords(), ...importedPrecise()]) {
      final j = n.toJson();
      expect(j.containsKey('stroke'), isFalse);
      expect(PitchNote.fromJson(j).toJson(), j);
    }
  });
}
