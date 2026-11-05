// gt-003 exports: G0–G2 goldens unchanged with the articulation plan, the
// `.mid` rule (sounding pitch, start, gated length on the track channel),
// WAV role jobs (per-channel isolation, program before the first note,
// CC7/CC10 of the lane), same-key choke, channel-shortage fallback, the
// volume rule, and stems summing to the mix with the articulation jobs.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/pan.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';

import '../support/midi_all_events.dart';
import 'guitar_stroke_golden_test.dart' as g;

PitchNote n(
  int midi,
  int step, {
  int dur = 2,
  int? velocity,
  double offset = 0,
  double? duration,
  Articulation? art,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  velocity: velocity,
  offsetSteps: offset,
  durationSteps: duration,
  articulation: art,
);

const palm = Articulation(
  kind: ArticulationKind.palmTone,
  gateMs: 250,
  velScale: .85,
);
const harm = Articulation(kind: ArticulationKind.harmonicTone);
const stac = Articulation(kind: ArticulationKind.staccato, gateMs: 120);

Section sec(
  List<PitchNote> melody, {
  List<TrackRef> extras = const [],
  Map<String, TrackData> more = const {},
  int bars = 1,
}) {
  final s = Section(id: 'a', name: 'a', bars: bars, extras: List.of(extras))
    ..tracks['melody'] = TrackData(notes: melody);
  more.forEach((k, v) => s.tracks[k] = v);
  return s;
}

ArticulationPlan planOf(List<Section> s, Map<String, int> instruments) =>
    ArticulationPlan.build(sections: s, instruments: instruments);

String hash(Uint8List b) => sha256.convert(b).toString();

void main() {
  group('goldens', () {
    // the gt-001 golden cases, now built with an articulation plan in both
    // the `.mid` mode and the WAV track-role mode: byte-identical
    for (final role in [null, ArtRole.track]) {
      test('G0–G2 cases are byte-identical with a plan (role $role)', () {
        Uint8List build(
          List<Section> s,
          int bpm, {
          int melodyProgram = 0,
          bool strumGuitar = false,
          Map<String, double>? vol,
          Map<String, double>? pan,
          double swing = 0,
          GrooveContext? groove,
          int? seed,
          List<TrackRef> extras = const [],
          Map<String, int> extraInstruments = const {},
        }) => buildMidi(
          flattenSong(s, groove: groove, variationSeed: seed),
          bpm,
          melodyProgram: melodyProgram,
          strumGuitar: strumGuitar,
          vol: vol,
          pan: pan,
          swing: swing,
          extras: extras,
          extraInstruments: extraInstruments,
          articulations: planOf(s, {
            'melody': melodyProgram,
            ...extraInstruments,
          }),
          articulationRole: role,
        );
        final out = <String, Uint8List>{
          'plain_guitar': build([sec(g.guitarChords())], 100, melodyProgram: 25),
          'non_guitar': build([sec(g.guitarChords())], 100),
          'imported_precise_guitar': build(
            [sec(g.importedPrecise())],
            93,
            melodyProgram: 25,
          ),
          'strum_forced_wav': build(
            [sec(g.guitarChords())],
            110,
            strumGuitar: true,
            vol: const {'melody': .7, 'bass': .8, 'drums': .9},
            pan: const {'melody': -.3},
          ),
          'grooved_guitar': build(
            [sec(g.guitarChords())],
            100,
            melodyProgram: 25,
            swing: .2,
            groove: GrooveContext(
              trackGrooves: const {
                'melody': GrooveAssign(grooveId: 'builtin:laidback'),
              },
              amount: 1.0,
              swing: .2,
            ),
          ),
        };
        for (final e in out.entries) {
          expect(hash(e.value), g.kGolden[e.key], reason: e.key);
        }
        // added guitar track (the plan sees the extra)
        final extras = [const TrackRef('gtr2', 'melody')];
        final s = Section(id: 'a', name: 'a', extras: extras)
          ..tracks['gtr2'] = TrackData(notes: g.guitarChords());
        expect(
          build(
            [s],
            100,
            extras: extras,
            extraInstruments: const {'gtr2': 24},
          ),
          buildMidi(
            flattenSong([s]),
            100,
            extras: extras,
            extraInstruments: const {'gtr2': 24},
          ),
        );
      });
    }

    test('the full golden suite still matches (unchanged callers)', () {
      for (final e in g.goldenCases().entries) {
        expect(hash(e.value), g.kGolden[e.key], reason: e.key);
      }
    });
  });

  group('.mid conformance (review ⑤, r4)', () {
    test('sounding pitch, same start, gated length; palm/harmonic on their '
        'plan channel with the owner track GM program; staccato on the '
        'track channel', () {
      const bpm = 120; // 1 step = 125 ms
      final s = [
        sec([
          n(52, 0, dur: 4, art: palm),
          n(88, 4, dur: 4, art: harm),
          n(60, 8, dur: 4, art: stac),
          n(64, 12, dur: 2),
        ]),
      ];
      final plan = planOf(s, {'melody': 25});
      final read = readMidiEvents(
        buildMidi(
          flattenSong(s),
          bpm,
          melodyProgram: 25,
          articulations: plan,
        ),
      );
      final tps = read.tpq / kStepsPerBeat;
      final notes = midiNotes(read.events);
      expect(
        [for (final x in notes) (x.channel, x.key, x.on / tps, x.off / tps)],
        [
          (3, 52, 0.0, 2.0), // palm: 250 ms on its plan channel
          (4, 88, 4.0, 8.0), // harmonic: sounding pitch S (never S-24)
          (0, 60, 8.0, 8 + 120 / 125), // staccato stays on the track
          (0, 64, 12.0, 14.0),
        ],
      );
      expect(notes.first.velocity, 85, reason: 'palm velocity x0.85');
      // role channels carry the OWNER's GM program (never 28/31), set at t=0
      // before their first note
      for (final ch in [3, 4]) {
        final ev = read.events.where((e) => e.channel == ch).toList();
        expect(ev.first.kind, 0xC0);
        expect(ev.first.a, 25);
        expect(ev.first.tick, 0);
      }
      expect(
        read.events.where((e) => e.kind == 0xC0).map((e) => e.a),
        everyElement(isNot(isIn([28, 31]))),
      );
    });

    test('a normal note and a same-pitch palm note: the normal note keeps '
        'its full length (events and an actual render of the .mid)', () {
      const bpm = 120;
      List<Section> song(bool withPalm) => [
        sec([
          n(52, 0, dur: 16, velocity: 100), // 2 s
          if (withPalm) n(52, 2, dur: 4, velocity: 110, art: palm), // .25 s
        ]),
      ];
      Uint8List mid(bool withPalm) {
        final s = song(withPalm);
        return buildMidi(
          flattenSong(s),
          bpm,
          melodyProgram: 24,
          pan: const {'melody': .5},
          articulations: planOf(s, {'melody': 24}),
        );
      }

      final read = readMidiEvents(mid(true));
      final tps = read.tpq / kStepsPerBeat;
      final notes = midiNotes(read.events);
      final normal = notes.firstWhere((x) => x.channel == 0);
      expect((normal.key, normal.on / tps, normal.off / tps), (52, 0.0, 16.0));
      final pm = notes.firstWhere((x) => x.channel != 0);
      expect((pm.key, pm.on / tps, pm.off / tps), (52, 2.0, 4.0));
      // the role channel mirrors the lane pan (CC10) like its own channel
      expect(
        read.events
            .where((e) => e.channel == pm.channel && e.kind == 0xB0 && e.a == 10)
            .single
            .b,
        panToCc(.5),
      );
      // render the exported .mid itself through the GM font
      final gmPath = File('assets/sounds/GeneralUser-GS.sf2').absolute.path;
      Float32List render(bool withPalm) {
        final w = renderWavForExport({
          'sf2s': [gmPath],
          'jobs': [
            {'sf2': 0, 'midi': mid(withPalm)},
          ],
          'mix': false,
          'sampleRate': 44100,
          'tail': .2,
          'reverb': false,
        }).single;
        final bd = ByteData.sublistView(w, 44);
        return Float32List.fromList([
          for (var i = 0; i + 3 < bd.lengthInBytes; i += 4)
            bd.getInt16(i, Endian.little) / 32768,
        ]);
      }

      double rmsAt(Float32List x, double t0, double t1) {
        final a = (t0 * 44100).round(), b = (t1 * 44100).round();
        var acc = 0.0;
        for (var i = a; i < b; i++) {
          acc += x[i] * x[i];
        }
        return math.sqrt(acc / (b - a));
      }

      final plain = render(false), both = render(true);
      // after the palm note ended (0.25 s + 0.25 s gate + release): the
      // normal 52 still sounds as loud as without the palm note
      final ref = rmsAt(plain, .8, 1.4);
      expect(ref, greaterThan(1e-3));
      expect(rmsAt(both, .8, 1.4), greaterThan(ref * .9));
    });
  });

  group('WAV role jobs', () {
    const bpm = 120;
    final s = [
      sec([
        n(52, 0, dur: 4, velocity: 100, art: palm),
        n(52, 0, dur: 8, velocity: 90), // same pitch, normal, overlapping
        n(88, 4, dur: 4, velocity: 80, art: harm),
        n(60, 8, dur: 4, velocity: 70, art: stac),
      ]),
    ];
    final plan = planOf(s, {'melody': 25});
    const vol = {'melody': .6, 'bass': .8, 'melodyDec': .7, 'drums': .9};
    const pan = {'melody': -.4};
    Uint8List job(ArtRole role) => buildMidi(
      flattenSong(s),
      bpm,
      melodyProgram: 25,
      vol: vol,
      pan: pan,
      articulations: plan,
      articulationRole: role,
    );

    test('per-channel isolation: program before the first note, CC7/CC10 '
        'of the lane, nothing on track/base/drum/click channels', () {
      final mute = plan.channelFor('melody', ArtRole.muteVoice)!;
      final harmCh = plan.channelFor('melody', ArtRole.harmonicVoice)!;
      expect((mute, harmCh), (3, 4));
      for (final (role, ch, prog, key) in [
        (ArtRole.muteVoice, mute, 28, 52),
        (ArtRole.harmonicVoice, harmCh, 31, 64),
      ]) {
        final ev = readMidiEvents(job(role)).events;
        expect(ev.every((e) => e.channel == ch), isTrue, reason: '$role');
        final firstNote = ev.indexWhere((e) => e.kind == 0x90);
        final program = ev.indexWhere((e) => e.kind == 0xC0);
        expect(program, isNonNegative);
        expect(program, lessThan(firstNote));
        expect(ev[program].a, prog);
        expect(
          ev.where((e) => e.kind == 0xB0 && e.a == 7).single.b,
          (.6 * 127).round(),
        );
        expect(
          ev.where((e) => e.kind == 0xB0 && e.a == 10).single.b,
          panToCc(-.4),
        );
        expect(
          midiNotes(ev).map((x) => x.key),
          [key],
          reason: 'GM 31 plays key S-24',
        );
      }
      // the track job carries only track-role notes and never an
      // articulation channel
      final track = readMidiEvents(job(ArtRole.track)).events;
      expect(track.any((e) => e.channel == mute || e.channel == harmCh), isFalse);
      expect(
        [for (final x in midiNotes(track)) x.key],
        [52, 60],
        reason: 'normal 52 + staccato 60 stay on the track',
      );
      // the normal same-pitch note keeps its full length (no leak)
      final tps = readMidiEvents(job(ArtRole.track)).tpq / kStepsPerBeat;
      final normal52 = midiNotes(track).firstWhere((x) => x.key == 52);
      expect(normal52.off / tps, 8);
    });

    test('same key on one articulation channel: the earlier note ends at '
        'the later onset; the later keeps its full gate', () {
      // palm 250 ms gate; same pitch at 0 ms and 125 ms (one step)
      final s2 = [
        sec([
          n(52, 0, dur: 4, velocity: 100, art: palm),
          n(52, 1, dur: 4, velocity: 100, art: palm),
        ]),
      ];
      final p2 = planOf(s2, {'melody': 25});
      final read = readMidiEvents(
        buildMidi(
          flattenSong(s2),
          bpm,
          melodyProgram: 25,
          vol: vol,
          articulations: p2,
          articulationRole: ArtRole.muteVoice,
        ),
      );
      final tps = read.tpq / kStepsPerBeat;
      final notes = midiNotes(read.events);
      expect([for (final x in notes) (x.on / tps, x.off / tps)], [
        (0.0, 1.0),
        (1.0, 3.0),
      ]);
      // at the shared tick the off comes before the on
      final at = (1 * tps).round();
      final same = read.events.where((e) => e.tick == at).toList();
      expect(same.first.kind, 0x80);
      expect(same.last.kind, 0x90);
    });

    test('no channel: identical fallback in .mid, WAV track job and no '
        'role job', () {
      final extras = [
        for (var i = 0; i < 10; i++) TrackRef('x$i', 'melody'),
      ];
      final s3 = [
        sec([
          n(52, 0, dur: 4, velocity: 100, art: palm),
          n(88, 4, dur: 4, velocity: 80, art: harm),
        ], extras: extras),
      ];
      final p3 = planOf(s3, {'melody': 25});
      expect(p3.routes, isEmpty);
      expect(p3.shortRoles('melody'), [
        ArtRole.muteVoice,
        ArtRole.harmonicVoice,
      ]);
      final flat = flattenSong(s3);
      List<(int, double, double, int)> notesOf(Uint8List b) {
        final r = readMidiEvents(b);
        final tps = r.tpq / kStepsPerBeat;
        return [
          for (final x in midiNotes(r.events))
            if (x.channel == 0) (x.key, x.on / tps, x.off / tps, x.velocity),
        ];
      }

      final expected = [(52, 0.0, 4.0, 100), (88, 4.0, 8.0, 80)];
      expect(
        notesOf(
          buildMidi(flat, bpm, melodyProgram: 25, articulations: p3),
        ),
        expected,
      );
      expect(
        notesOf(
          buildMidi(
            flat,
            bpm,
            melodyProgram: 25,
            vol: vol,
            extras: extras,
            articulations: p3,
            articulationRole: ArtRole.track,
          ),
        ),
        expected,
      );
      expect(
        articulationJobs(flat, p3, 'melody', 0, (_) => Uint8List(0)),
        isEmpty,
      );
    });

    test('volume rule: the role job CC7 equals the track channel CC7 '
        '(vol 0 / .5 / 1); velocity is never pre-scaled by volume', () {
      for (final v in [0.0, .5, 1.0]) {
        final vv = {...vol, 'melody': v};
        Uint8List b(ArtRole role) => buildMidi(
          flattenSong(s),
          bpm,
          melodyProgram: 25,
          vol: vv,
          articulations: plan,
          articulationRole: role,
        );
        final track = readMidiEvents(b(ArtRole.track)).events;
        final palmJob = readMidiEvents(b(ArtRole.muteVoice)).events;
        final cc7Track =
            track.where((e) => e.kind == 0xB0 && e.a == 7 && e.channel == 0);
        final cc7Palm = palmJob.where((e) => e.kind == 0xB0 && e.a == 7);
        expect(cc7Palm.single.b, cc7Track.single.b, reason: 'vol $v');
        expect(cc7Palm.single.b, (v * 127).round());
        // velocities: track 90 (normal), palm 100 x 0.85 — no volume in them
        expect(midiNotes(palmJob).single.velocity, 85);
        expect(
          midiNotes(track).firstWhere((x) => x.key == 52).velocity,
          90,
        );
      }
    });
  });

  group('real render', () {
    final gmPath = File('assets/sounds/GeneralUser-GS.sf2').absolute.path;
    List<Float32List> decode(Uint8List wav) {
      final bd = ByteData.sublistView(wav, 44);
      final n = bd.lengthInBytes ~/ 4;
      final l = Float32List(n), r = Float32List(n);
      for (var i = 0; i < n; i++) {
        l[i] = bd.getInt16(i * 4, Endian.little) / 32768;
        r[i] = bd.getInt16(i * 4 + 2, Endian.little) / 32768;
      }
      return [l, r];
    }

    test('stems sum to the mix including the articulation jobs', () {
      const bpm = 120;
      final s = [
        sec([
          n(52, 0, dur: 8, velocity: 100),
          n(52, 4, dur: 4, velocity: 110, art: palm),
          n(88, 8, dur: 4, velocity: 90, art: harm),
        ]),
      ];
      final plan = planOf(s, {'melody': 25});
      final flat = flattenSong(s);
      const vol = {'melody': .8};
      Uint8List mid(ArtRole role) => buildMidi(
        flat,
        bpm,
        melodyProgram: 25,
        vol: vol,
        articulations: plan,
        articulationRole: role,
      );
      final jobs = <Map<String, Object>>[
        {'sf2': 0, 'midi': mid(ArtRole.track)},
        ...articulationJobs(flat, plan, 'melody', 0, mid),
      ];
      expect(jobs, hasLength(3));
      Map<String, dynamic> args(List<Map<String, Object>> j, bool mix) => {
        'sf2s': [gmPath],
        'jobs': j,
        'mix': mix,
        'sampleRate': 22050,
        'tail': .3,
        'reverb': false,
      };
      final separate = renderWavForExport(args(jobs, false));
      final grouped = renderWavForExport(args([
        for (final j in jobs) {...j, 'group': 0},
      ], false));
      expect(separate, hasLength(3));
      expect(grouped, hasLength(1));
      final parts = [for (final w in separate) decode(w)];
      final stem = decode(grouped.single);
      var maxErr = 0.0, energy = 0.0;
      for (var i = 0; i < stem[0].length; i++) {
        var sum = 0.0;
        for (final p in parts) {
          if (i < p[0].length) sum += p[0][i];
        }
        maxErr = math.max(maxErr, (stem[0][i] - sum).abs());
        energy += stem[0][i] * stem[0][i];
      }
      expect(energy, greaterThan(1));
      expect(maxErr, lessThan(4 / 32768), reason: 'grouped stem == sum');
      // the mix is the same sum, normalized: proportional to the stem
      final mixed = decode(renderWavForExport(args(jobs, true)).single);
      var dot = 0.0, mm = 0.0;
      for (var i = 0; i < math.min(mixed[0].length, stem[0].length); i++) {
        dot += mixed[0][i] * stem[0][i];
        mm += mixed[0][i] * mixed[0][i];
      }
      final corr = dot / math.sqrt(mm * energy);
      expect(corr, greaterThan(.999));
    });

    test('same-key retrigger is not truncated (real PCM)', () {
      const bpm = 120; // notes at 0 ms and 125 ms, 250 ms palm gate
      Float32List render(List<PitchNote> notes) {
        final s = [sec(notes)];
        final plan = planOf(s, {'melody': 25});
        final w = renderWavForExport({
          'sf2s': [gmPath],
          'jobs': [
            {
              'sf2': 0,
              'midi': buildMidi(
                flattenSong(s),
                bpm,
                melodyProgram: 25,
                vol: const {'melody': 1},
                articulations: plan,
                articulationRole: ArtRole.muteVoice,
              ),
            },
          ],
          'mix': false,
          'sampleRate': 44100,
          'tail': .3,
          'reverb': false,
        });
        return decode(w.single)[0];
      }

      double rmsAt(Float32List x, double t0, double t1) {
        final a = (t0 * 44100).round(), b = math.min(x.length, (t1 * 44100).round());
        var s = 0.0;
        for (var i = a; i < b; i++) {
          s += x[i] * x[i];
        }
        return math.sqrt(s / (b - a));
      }

      final both = render([
        n(64, 0, dur: 4, velocity: 110, art: palm),
        n(64, 1, dur: 4, velocity: 110, art: palm),
      ]);
      final secondOnly = render([n(64, 1, dur: 4, velocity: 110, art: palm)]);
      // 150–330 ms: the second note (125–375 ms) must still sound fully
      final r = rmsAt(both, .15, .33), ref = rmsAt(secondOnly, .15, .33);
      expect(ref, greaterThan(1e-3));
      expect(r, greaterThan(ref * .7));
    });

    test('a normal note and a same-pitch palm note are independent voices',
        () {
      const bpm = 120;
      // normal 52 on the track channel 0..2 s; palm 52 at 250 ms (250 ms)
      final s = [
        sec([
          n(52, 0, dur: 16, velocity: 100),
          n(52, 2, dur: 2, velocity: 110, art: palm),
        ]),
      ];
      final plan = planOf(s, {'melody': 24});
      Float32List render(ArtRole? only) {
        final flat = flattenSong(s);
        Uint8List mid(ArtRole role) => buildMidi(
          flat,
          bpm,
          melodyProgram: 24,
          vol: const {'melody': 1},
          articulations: plan,
          articulationRole: role,
        );
        final w = renderWavForExport({
          'sf2s': [gmPath],
          'jobs': [
            {'sf2': 0, 'midi': mid(ArtRole.track)},
            if (only == null) {'sf2': 0, 'midi': mid(ArtRole.muteVoice)},
          ],
          'mix': false,
          'sampleRate': 44100,
          'tail': .2,
          'reverb': false,
        });
        return decode(w.first)[0];
      }

      final trackOnly = render(ArtRole.track);
      final withPalm = render(null); // first stem = the track job
      // the track job's audio is unchanged by the palm job (separate render)
      var diff = 0.0;
      for (var i = 0; i < trackOnly.length; i++) {
        diff = math.max(diff, (trackOnly[i] - withPalm[i]).abs());
      }
      expect(diff, 0);
      // and the track job keeps sounding after the palm note ended
      double rms(Float32List x, double t0, double t1) {
        var acc = 0.0;
        final a = (t0 * 44100).round(), b = (t1 * 44100).round();
        for (var i = a; i < b; i++) {
          acc += x[i] * x[i];
        }
        return math.sqrt(acc / (b - a));
      }

      expect(rms(trackOnly, .6, .9), greaterThan(1e-3));
    });
  });

  test('wav_codec helper stays importable', () => expect(parseWav, isNotNull));
}
