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
}
