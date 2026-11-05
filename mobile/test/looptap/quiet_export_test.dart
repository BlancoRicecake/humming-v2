import 'dart:io';
import 'dart:typed_data';
import 'package:dart_melty_soundfont/soundfont_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';

void main() {
  test('quiet drum mix survives render cutoff; zero stays silent', () {
    final flat = FlatSong(const [], const [],
        [DrumNote(kind: 'hihat', step: 0)], 32);
    final previous = SoundFontMath.nonAudible;
    for (final volume in [0.006957697201017667, 0.0, 1.0]) {
      final midi = buildMidi(flat, 92,
          tracks: const {'drums'}, vol: {'drums': volume});
      final wav = renderWavForExport({
        'sf2s': [File('assets/sounds/GeneralUser-GS.sf2').absolute.path],
        'jobs': [{'sf2': 0, 'midi': midi}],
        'sampleRate': 44100, 'tail': 1.2, 'mix': true,
      }).single;
      // the mix is stereo (mixer-001): the peak is over both channels
      expect(parseWav(wav)!.channels, 2);
      final pcm = ByteData.sublistView(wav, 44);
      final samples = [
        for (var i = 0; i + 1 < pcm.lengthInBytes; i += 2)
          pcm.getInt16(i, Endian.little) / 32768.0,
      ];
      final peak = samples.fold<double>(0, (p, v) => v.abs() > p ? v.abs() : p);
      expect(peak, volume == 0 ? equals(0) : greaterThan(0.9));
      expect(SoundFontMath.nonAudible, previous);
    }
  });
}
