// G3 design probe (not a regression test): renders GM31/GM28/GM24 and the
// FreePats nylon through MeltySynth (the desktop/iOS engine) and writes raw
// float32 PCM so the same Python analysis used for FluidSynth can compare the
// two engines. Skipped unless HUMTRACK_PROBE_OUT is set.
import 'dart:io';

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final out = Platform.environment['HUMTRACK_PROBE_OUT'];
  test(
    'render articulation probe PCM with MeltySynth',
    () {
      const sr = 44100;
      final fonts = {
        'gm': 'assets/sounds/GeneralUser-GS.sf2',
        'nylon': 'assets/sounds/reference/freepats_nylon.sf2',
      };
      final jobs = <(String, String, int, int, int)>[
        for (final k in [36, 40, 45, 50, 52, 55, 57, 59, 62, 64, 67, 69, 72, 76, 79, 83, 86])
          ('gm31', 'gm', 31, k, 100),
        for (final k in [45, 52, 59])
          for (final v in [110, 80, 50]) ...[
            ('nylon', 'nylon', 0, k, v),
            ('gm24', 'gm', 24, k, v),
            ('gm28', 'gm', 28, k, v),
          ],
      ];
      final synths = {
        for (final e in fonts.entries)
          e.key: File(e.value).readAsBytesSync(),
      };
      for (final (name, font, prog, key, vel) in jobs) {
        final s = Synthesizer.loadByteData(
          ByteData.sublistView(synths[font]!),
          SynthesizerSettings(sampleRate: sr),
        );
        s.processMidiMessage(channel: 0, command: 0xc0, data1: prog, data2: 0);
        s.noteOn(channel: 0, key: key, velocity: vel);
        final l = Float32List((sr * 1.2).round()), r = Float32List(l.length);
        s.render(l, r);
        final mono = Float32List(l.length);
        for (var i = 0; i < l.length; i++) {
          mono[i] = (l[i] + r[i]) / 2;
        }
        File('$out/melty_${name}_k${key}_v$vel.f32')
            .writeAsBytesSync(mono.buffer.asUint8List());
      }
    },
    skip: out == null ? 'set HUMTRACK_PROBE_OUT to render probe PCM' : false,
  );
}
