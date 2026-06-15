// Vocal-into-mix export: schedule walk over sections×repeats + summing into
// render buffers. Pure Dart — synthesizes the vocal as a sine instead of
// touching files or the SF2 render. The schedule references takes by NAME
// (decode happens in the render isolate); mixVocalsInto truncates to the
// decoded take's length.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';

double rms(Float32List buf, int start, int end) {
  var sum = 0.0;
  for (var i = start; i < end; i++) {
    sum += buf[i] * buf[i];
  }
  return math.sqrt(sum / (end - start));
}

void main() {
  const sr = 44100;
  const bpm = 120;
  final spStep = 60 / bpm / kStepsPerBeat * sr; // 5512.5 samples per 16th

  Section sec(String id, {int bars = 2, int repeats = 1, String? vocal}) {
    final s = Section(id: id, name: id, bars: bars, repeats: repeats);
    if (vocal != null) s.tracks['vocal'] = TrackData(vocalPath: vocal);
    return s;
  }

  test('vocal schedules at every repeat of its section, after prior sections', () {
    final secSteps = stepsForBars(2); // 32
    final loopSamples = (secSteps * spStep).round();
    // vocal exactly one loop long, constant 0.5
    final pcm = Float32List.fromList(List.filled(loopSamples, 0.5));
    final sections = [
      sec('A', bars: 2), // no vocal
      sec('B', bars: 2, repeats: 2, vocal: 'take.wav'),
    ];
    final jobs = scheduleVocalMixes(sections, bpm, 0.8, {'take.wav'});
    expect(jobs.length, 2);
    expect(jobs[0]['name'], 'take.wav');
    expect(jobs[0]['start'], (secSteps * spStep).round());
    expect(jobs[1]['start'], (2 * secSteps * spStep).round());
    expect(jobs[0]['len'], loopSamples);
    expect(jobs[0]['gain'], 0.8);

    // sum into buffers and check energy lands only in the scheduled windows
    final vocals = [
      for (final j in jobs)
        VocalMix(
          pcm: pcm,
          start: j['start'] as int,
          len: j['len'] as int,
          gain: j['gain'] as double,
        ),
    ];
    final n = vocalMixEnd(vocals);
    final left = Float32List(n), right = Float32List(n);
    mixVocalsInto(left, right, vocals);
    final aEnd = (secSteps * spStep).round();
    expect(rms(left, 0, aEnd), 0); // section A silent
    expect(rms(left, aEnd, aEnd + 1000), closeTo(0.4, 1e-5)); // B repeat 1
    final bRep2 = (2 * secSteps * spStep).round();
    expect(rms(left, bRep2, bRep2 + 1000), closeTo(0.4, 1e-5)); // B repeat 2
  });

  test('scheduled len is the section boundary (overlong takes truncate there)', () {
    final secSteps = stepsForBars(1); // 16
    final loopSamples = (secSteps * spStep).round();
    final jobs = scheduleVocalMixes([sec('A', bars: 1, vocal: 'v.wav')], bpm, 1.0, {'v.wav'});
    expect(jobs.single['len'], loopSamples);
    // a 3×-too-long decode is clipped at the boundary by the summer
    final pcm = Float32List.fromList(List.filled(loopSamples * 3, 0.5));
    final mix = [VocalMix(pcm: pcm, start: 0, len: loopSamples, gain: 1)];
    expect(vocalMixEnd(mix), loopSamples);
  });

  test('zero gain or unloaded take schedules nothing', () {
    expect(scheduleVocalMixes([sec('A', vocal: 'v.wav')], bpm, 0, {'v.wav'}), isEmpty);
    expect(scheduleVocalMixes([sec('A', vocal: 'v.wav')], bpm, 1, {}), isEmpty);
  });

  group('multi-clip', () {
    test('each clip schedules at its own startStep with combined gain', () {
      final s = Section(id: 'A', name: 'A', bars: 2); // 32 steps
      s.tracks['vocal'] = TrackData(clips: [
        VocalClip(path: 'a.wav', startStep: 0, gain: 0.5),
        VocalClip(path: 'b.wav', startStep: 16, gain: 1.0),
      ]);
      final jobs = scheduleVocalMixes([s], bpm, 0.8, {'a.wav', 'b.wav'});
      expect(jobs.length, 2);
      expect(jobs[0]['name'], 'a.wav');
      expect(jobs[0]['start'], 0);
      expect(jobs[0]['gain'], closeTo(0.8 * 0.5, 1e-9));
      expect(jobs[1]['name'], 'b.wav');
      expect(jobs[1]['start'], (16 * spStep).round());
      expect(jobs[1]['len'], (16 * spStep).round()); // room left after step 16
      expect(jobs[1]['gain'], closeTo(0.8, 1e-9));
    });

    test('a clip starting past the section boundary is dropped', () {
      final s = Section(id: 'A', name: 'A', bars: 1); // 16 steps
      s.tracks['vocal'] = TrackData(clips: [
        VocalClip(path: 'a.wav', startStep: 20), // beyond 16 → out of loop
      ]);
      expect(scheduleVocalMixes([s], bpm, 1.0, {'a.wav'}), isEmpty);
    });

    test('legacy single take schedules identically to a step-0 clip', () {
      final legacy = scheduleVocalMixes([sec('A', bars: 2, vocal: 'v.wav')], bpm, 0.7, {'v.wav'});
      final s = Section(id: 'A', name: 'A', bars: 2);
      s.tracks['vocal'] = TrackData(clips: [VocalClip(path: 'v.wav')]);
      final explicit = scheduleVocalMixes([s], bpm, 0.7, {'v.wav'});
      expect(legacy.single['start'], explicit.single['start']);
      expect(legacy.single['len'], explicit.single['len']);
      expect(legacy.single['gain'], explicit.single['gain']);
    });

    test('three sequential chunks each sound at their own startStep', () {
      // each take is 0.05 s (2205 samples) of constant 1.0
      final src = Float32List.fromList(List.filled(2205, 1.0));
      final clips = [
        VocalClip(path: 'a.wav', startStep: 0),
        VocalClip(path: 'a.wav', startStep: 8),
        VocalClip(path: 'a.wav', startStep: 16),
      ];
      final lane = bounceVocalClips(clips, 2, bpm, {'a.wav': (pcm: src, sampleRate: sr)});
      for (final step in [0, 8, 16]) {
        final at = (step * spStep).round();
        expect(lane[at], closeTo(1.0, 1e-5), reason: 'audible at step $step');
        // silent in the gap a little before the next chunk's start
        final gap = at + 3000;
        if (gap < lane.length) expect(lane[gap], 0, reason: 'silent gap after step $step');
      }
    });

    test('minLen pads the lane to the loop length for gapless looping', () {
      final src = Float32List.fromList(List.filled(2205, 0.5));
      final pad = (stepsForBars(2) * spStep).round();
      final lane = bounceVocalClips(
          [VocalClip(path: 'a.wav', startStep: 0)], 2, bpm, {'a.wav': (pcm: src, sampleRate: sr)},
          minLen: pad);
      expect(lane.length, pad); // padded out to one full loop
      expect(lane[2205 + 100], 0); // silence after the short take
    });

    test('bounceVocalClips trims, places, and gains clips into one lane', () {
      // 0.1s of constant 1.0 at 44100
      final src = Float32List.fromList(List.filled(4410, 1.0));
      final clips = [
        VocalClip(path: 'a.wav', startStep: 0, gain: 0.5),
        VocalClip(path: 'b.wav', startStep: 8, trimStart: 0, trimEnd: 2205), // half length
      ];
      final lane = bounceVocalClips(clips, 1, bpm, {
        'a.wav': (pcm: src, sampleRate: sr),
        'b.wav': (pcm: src, sampleRate: sr),
      });
      // clip A at 0 with gain 0.5 → ~0.5
      expect(lane[0], closeTo(0.5, 1e-5));
      // gap between A (ends at 4410) and B is silent
      expect(lane[10000], 0);
      // clip B starts at step 8, gain 1.0
      final bStart = (8 * spStep).round();
      expect(lane[bStart], closeTo(1.0, 1e-5));
      // B was trimmed to 2205 source samples → the lane ends right after it
      expect(lane.length, bStart + 2205);
    });
  });
}
