// Validates the 808 WAV-export render path without a device: build the bass-only
// MIDI the way exportWavSong does for the 808 (bassProgram 0, tracks:{'bass'}),
// render it through 808.sf2, and assert it's non-silent. Also renders a melody
// lane through TimGM6mb so we know the GM path still works alongside.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';

const _sr = 44100;

({double peak, double rms, double sec}) _render(Uint8List sf2, Uint8List midi) {
  final synth = Synthesizer.loadByteData(
    ByteData.sublistView(sf2),
    SynthesizerSettings(sampleRate: _sr, enableReverbAndChorus: true),
  );
  final mf = MidiFile.fromByteData(ByteData.sublistView(midi));
  final seq = MidiFileSequencer(synth);
  seq.play(mf, loop: false);
  final n = ((mf.length.inMicroseconds / 1e6 + 1.2) * _sr).ceil();
  final l = Float32List(n), r = Float32List(n);
  seq.render(l, r);
  var peak = 0.0, sumSq = 0.0;
  for (var i = 0; i < n; i++) {
    final a = l[i].abs();
    if (a > peak) peak = a;
    sumSq += l[i] * l[i];
  }
  return (peak: peak, rms: math.sqrt(sumSq / n), sec: n / _sr);
}

void main() {
  final flat = FlatSong(
    [PitchNote(midi: 60, freq: 0, step: 0, dur: 8)],
    [
      PitchNote(midi: 40, freq: 0, step: 0, dur: 8),
      PitchNote(midi: 43, freq: 0, step: 16, dur: 8),
    ],
    const [],
    32,
  );

  test('808 bass lane renders non-silent through 808.sf2', () {
    final sf808 = File('assets/sounds/808.sf2').readAsBytesSync();
    final midi = buildMidi(flat, 90, bassProgram: 0, tracks: const {'bass'});
    final b = _render(sf808, midi);
    // ignore: avoid_print
    print('[808] bass: ${b.sec.toStringAsFixed(2)}s peak=${(b.peak * 100).toStringAsFixed(1)}% '
        'rms=${(b.rms * 100).toStringAsFixed(1)}%');
    expect(b.peak, greaterThan(0.02), reason: '808 bass should be audible');
    expect(b.sec, greaterThan(1.0));
  });

  test('melody lane still renders through TimGM6mb', () {
    final timgm = File('assets/sounds/TimGM6mb.sf2').readAsBytesSync();
    final midi = buildMidi(flat, 90, tracks: const {'melody'});
    final m = _render(timgm, midi);
    // ignore: avoid_print
    print('[808] melody/GM: ${m.sec.toStringAsFixed(2)}s peak=${(m.peak * 100).toStringAsFixed(1)}% '
        'rms=${(m.rms * 100).toStringAsFixed(1)}%');
    expect(m.peak, greaterThan(0.02));
  });

  test('added instance emits on its own channel and renders', () {
    const exId = 'melody_x1';
    final exFlat = FlatSong(const [], const [], const [], 32,
        extraPitched: {
          exId: [PitchNote(midi: 64, freq: 0, step: 0, dur: 8)]
        });
    final midi = buildMidi(exFlat, 90,
        extras: const [TrackRef(exId, 'melody')], extraInstruments: const {exId: 24});
    final timgm = File('assets/sounds/TimGM6mb.sf2').readAsBytesSync();
    final r = _render(timgm, midi);
    // ignore: avoid_print
    print('[808] extra instance: ${r.sec.toStringAsFixed(2)}s peak=${(r.peak * 100).toStringAsFixed(1)}%');
    expect(r.peak, greaterThan(0.02), reason: 'added instance should render audibly');
  });
}
