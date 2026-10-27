// mixer-001 (track pan): pan law, CC10 in MIDI, stereo WAV mix/stems, vocal
// balance law, model round-trip.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/pan.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/music/wav_export.dart';

/// Index of [pattern] in [bytes], or -1.
int _find(List<int> bytes, List<int> pattern) {
  for (var i = 0; i + pattern.length <= bytes.length; i++) {
    var ok = true;
    for (var k = 0; k < pattern.length; k++) {
      if (bytes[i + k] != pattern[k]) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// Every CC10 (channel, value) in a buildMidi track, with its absolute tick.
List<({int ch, int value, int tick})> _panEvents(Uint8List midi) {
  final out = <({int ch, int value, int tick})>[];
  var i = 22; // header (14) + 'MTrk' + length
  var t = 0;
  int vlq() {
    var v = 0;
    while (true) {
      final b = midi[i++];
      v = (v << 7) | (b & 0x7f);
      if (b & 0x80 == 0) return v;
    }
  }

  while (i < midi.length) {
    t += vlq();
    final st = midi[i];
    if (st == 0xFF) {
      i += 2;
      final len = vlq();
      i += len;
      continue;
    }
    final hi = st & 0xF0;
    final n = (hi == 0xC0 || hi == 0xD0) ? 1 : 2;
    if (hi == 0xB0 && midi[i + 1] == 0x0A) {
      out.add((ch: st & 0x0F, value: midi[i + 2], tick: t));
    }
    i += 1 + n;
  }
  return out;
}

({Float32List left, Float32List right}) _stereo(Uint8List wav) {
  final bd = ByteData.sublistView(wav);
  expect(bd.getUint16(22, Endian.little), 2);
  final frames = bd.getUint32(40, Endian.little) ~/ 4;
  final l = Float32List(frames), r = Float32List(frames);
  for (var i = 0; i < frames; i++) {
    l[i] = bd.getInt16(44 + i * 4, Endian.little) / 32768.0;
    r[i] = bd.getInt16(46 + i * 4, Endian.little) / 32768.0;
  }
  return (left: l, right: r);
}

double _rms(Float32List x) {
  var s = 0.0;
  for (final v in x) {
    s += v * v;
  }
  return x.isEmpty ? 0 : math.sqrt(s / x.length);
}

void main() {
  group('pan law', () {
    test('cc mapping: -1/-0.5/0/0.5/1 -> 0/32/64/96/127', () {
      expect([for (final p in [-1.0, -0.5, 0.0, 0.5, 1.0]) panToCc(p)],
          [0, 32, 64, 96, 127]);
      expect(panToCc(-3), 0);
      expect(panToCc(3), 127);
    });

    test('readout: L23 / C / R40', () {
      expect(panLabel(-0.23), 'L23');
      expect(panLabel(0), 'C');
      expect(panLabel(0.004), 'C');
      expect(panLabel(0.4), 'R40');
      expect(panLabel(-1), 'L100');
    });

    test('balance law gL = min(1, 1-p), gR = min(1, 1+p)', () {
      expect(panBalance(0), (left: 1.0, right: 1.0));
      expect(panBalance(-1), (left: 1.0, right: 0.0));
      expect(panBalance(1), (left: 0.0, right: 1.0));
      expect(panBalance(0.25), (left: 0.75, right: 1.0));
    });
  });

  group('MIDI CC10', () {
    final flat = FlatSong(
      [PitchNote(midi: 60, freq: 0, step: 0, dur: 4)],
      [PitchNote(midi: 40, freq: 0, step: 0, dur: 4)],
      [DrumNote(kind: 'kick', step: 0)],
      16,
      beatDec: [DrumNote(kind: 'clap', step: 4)],
    );

    test('pan {melody: -1} puts B0 0A 00 on ch0 at t=0', () {
      final midi = buildMidi(flat, 100, pan: {'melody': -1});
      final ev = _panEvents(midi);
      expect(ev, [(ch: 0, value: 0, tick: 0)]); // plain .mid: only p != 0
      expect(_find(midi, [0x00, 0xB0, 0x0A, 0x00]), greaterThan(0));
    });

    test('all-centre plain .mid is byte-identical to the pre-pan output', () {
      final before = buildMidi(flat, 100, drumProgram: 8);
      expect(buildMidi(flat, 100, drumProgram: 8, pan: const {}), before);
      expect(
        buildMidi(flat, 100, drumProgram: 8, pan: const {'bass': 0.0}),
        before,
      );
    });

    test('render MIDI carries CC10 on every channel', () {
      final midi = buildMidi(flat, 100,
          vol: const {}, pan: const {'bass': 0.5, 'drums': -1});
      final byCh = {for (final e in _panEvents(midi)) e.ch: e.value};
      expect(byCh, {0: 64, 1: 96, 2: 64, 9: 0});
      expect(_panEvents(midi).every((e) => e.tick == 0), isTrue);
    });

    test('per-lane drum render: Beat-Fill ch9 CC10 = its own pan', () {
      const pan = {'beatDec': 0.5};
      final fill = buildMidi(flat, 100,
          vol: const {}, tracks: const {'beatDec'}, pan: laneDrumPan(pan, 'beatDec'));
      expect(
        _panEvents(fill).where((e) => e.ch == 9).single.value,
        96,
      );
      final base = buildMidi(flat, 100,
          vol: const {}, tracks: const {'drums'}, pan: laneDrumPan(pan, 'drums'));
      expect(_panEvents(base).where((e) => e.ch == 9).single.value, 64);
    });

    test('added pitched track gets CC10 on its allocated channel', () {
      final f = FlatSong(const [], const [], const [], 16, extraPitched: {
        'melody_x1': [PitchNote(midi: 62, freq: 0, step: 0)],
      });
      final midi = buildMidi(f, 100,
          extras: [TrackRef('melody_x1', 'melody')],
          pan: const {'melody_x1': 1});
      expect(_panEvents(midi).single, (ch: 3, value: 127, tick: 0));
    });
  });

  group('stereo WAV', () {
    test('encodeWavStereo16 header: channels 2, blockAlign 4, byteRate sr*4', () {
      const sr = 22050;
      final l = Float32List.fromList([0.5, -0.5, 0.25]);
      final r = Float32List.fromList([0.0, 0.1, -0.25]);
      final wav = encodeWavStereo16(l, r, sr, limit: false);
      final bd = ByteData.sublistView(wav);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(bd.getUint32(4, Endian.little), 36 + 3 * 4);
      expect(bd.getUint16(20, Endian.little), 1);
      expect(bd.getUint16(22, Endian.little), 2);
      expect(bd.getUint32(24, Endian.little), sr);
      expect(bd.getUint32(28, Endian.little), sr * 4);
      expect(bd.getUint16(32, Endian.little), 4);
      expect(bd.getUint16(34, Endian.little), 16);
      expect(bd.getUint32(40, Endian.little), 3 * 4);
      expect(wav.length, 44 + 12);
      final s = _stereo(wav);
      expect(s.left[0], closeTo(0.5, 1e-4));
      expect(s.right[1], closeTo(0.1, 1e-4));
      expect(s.right[2], closeTo(-0.25, 1e-4));
      // existing reader still decodes it (mono average)
      expect(parseWav(wav)!.channels, 2);
    });

    test('peak = max(|L|, |R|): normalize and the headroom limiter', () {
      final l = Float32List.fromList([0.1, 0.2]);
      final r = Float32List.fromList([0.0, -0.4]);
      final n = _stereo(encodeWavStereo16(l, r, 44100, normalize: true));
      expect(n.right[1], closeTo(-0.94, 1e-3));
      expect(n.left[1], closeTo(0.47, 1e-3)); // one gain for both sides
      final hot = _stereo(encodeWavStereo16(
          Float32List.fromList([2.0]), Float32List.fromList([1.0]), 44100));
      expect(hot.left[0], closeTo(0.94, 1e-3));
      expect(hot.right[0], closeTo(0.47, 1e-3));
      final quiet = _stereo(encodeWavStereo16(
          Float32List.fromList([0.3]), Float32List.fromList([0.2]), 44100));
      expect(quiet.left[0], closeTo(0.3, 1e-3)); // stems: no upward boost
    });

    test('vocal balance law: p=-1 -> right silent, left = mono value', () {
      final pcm = Float32List.fromList([0.5, -0.25, 0.125]);
      Float32List mono() {
        final l = Float32List(6), r = Float32List(6);
        mixVocalsInto(l, r, [VocalMix(pcm: pcm, start: 2, len: 3, gain: 0.8)]);
        return l;
      }

      final l = Float32List(6), r = Float32List(6);
      mixVocalsInto(
          l, r, [VocalMix(pcm: pcm, start: 2, len: 3, gain: 0.8, pan: -1)]);
      expect(r.every((v) => v == 0), isTrue);
      expect(l, mono());
      // centre: L = R = the old value on each side, bit for bit
      final cl = Float32List(6), cr = Float32List(6);
      mixVocalsInto(cl, cr, [VocalMix(pcm: pcm, start: 2, len: 3, gain: 0.8)]);
      expect(cl, cr);
      expect(cl[2], Float32List.fromList([pcm[0] * 0.8])[0]);
    });

    test('bounceVocalClipsStereo pans each clip; centre equals the mono lane', () {
      final src = Float32List.fromList(List.filled(100, 0.5));
      final clips = [
        VocalClip(path: 'a.wav', startStep: 0),
        VocalClip(path: 'b.wav', startStep: 4),
      ];
      final sources = {
        'a.wav': (pcm: src, sampleRate: 44100),
        'b.wav': (pcm: src, sampleRate: 44100),
      };
      final mono = bounceVocalClips(clips, 1, 120, sources);
      final centre = bounceVocalClipsStereo(clips, 1, 120, sources);
      expect(centre.left, mono);
      expect(centre.right, mono);
      final panned =
          bounceVocalClipsStereo(clips, 1, 120, sources, pans: [-1, 0.5]);
      final bStart = (4 * 60 / 120 / 4 * 44100).round();
      expect(panned.right[0], 0); // clip a hard left
      expect(panned.left[0], 0.5);
      expect(panned.left[bStart], closeTo(0.25, 1e-6)); // clip b at R50
      expect(panned.right[bStart], 0.5);
    });

    test('scheduleVocalMixes carries each lane pan; render applies it', () {
      final s = Section(id: 'A', name: 'A', bars: 1);
      s.tracks['vocal'] = TrackData(clips: [VocalClip(path: 'v.wav')]);
      final centred = scheduleVocalMixes([s], 120, 1, {'v.wav'});
      expect(centred.single.containsKey('pan'), isFalse);
      final panned = scheduleVocalMixes([s], 120, 1, {'v.wav'},
          lanePan: const {'vocal': 0.3});
      expect(panned.single['pan'], 0.3);
    });

    test('song-take stem is stereo with the balance law', () {
      final pcm = Float32List.fromList([0.5, -0.5, 0.25]);
      final stem = _stereo(songVocalStemWav(encodeWavMono16(pcm, 32000), 1));
      expect(stem.left.every((v) => v == 0), isTrue);
      expect(stem.right[0], closeTo(0.5, 1e-4));
      expect(
        ByteData.sublistView(songVocalStemWav(encodeWavMono16(pcm, 32000), 0))
            .getUint32(24, Endian.little),
        32000,
      );
    });
  });

  group('render (MeltySynth)', () {
    final gm = File('assets/sounds/GeneralUser-GS.sf2').absolute.path;
    final one = FlatSong(
      [PitchNote(midi: 72, freq: 0, step: 0, dur: 8)],
      [PitchNote(midi: 40, freq: 0, step: 4, dur: 8)],
      const [],
      16,
    );

    List<Uint8List> render(List<Uint8List> midis,
            {required bool mix, bool reverb = true}) =>
        renderWavForExport({
          'sf2s': [gm],
          'jobs': [for (final m in midis) {'sf2': 0, 'midi': m}],
          'sampleRate': 44100,
          'tail': 0.5,
          'mix': mix,
          'reverb': reverb,
        });

    test('melody hard left (p=-1, dry): right RMS < 10% of left', () {
      // GM 73 (flute) is a mono-sample voice, so CC10 alone places it.
      final midi = buildMidi(one, 100,
          melodyProgram: 73,
          vol: const {'melody': 0.85},
          tracks: const {'melody'},
          pan: const {'melody': -1});
      final s = _stereo(render([midi], mix: true, reverb: false).single);
      final l = _rms(s.left), r = _rms(s.right);
      expect(l, greaterThan(0.01));
      expect(r, lessThan(l * 0.1));
    });

    test('centred dry voice renders L == R (same as the old mono fold)', () {
      final midi = buildMidi(one, 100,
          melodyProgram: 73,
          vol: const {'melody': 0.85},
          tracks: const {'melody'},
          pan: const {});
      final s = _stereo(render([midi], mix: true, reverb: false).single);
      var maxDiff = 0;
      for (var i = 0; i < s.left.length; i++) {
        maxDiff = math.max(maxDiff, ((s.left[i] - s.right[i]) * 32768).abs().round());
      }
      expect(_rms(s.left), greaterThan(0.01));
      // a few LSB at most (the synth's centre gains are cos/sin(pi/4) in
      // float) — inaudible, i.e. the same sound as the old (L+R)/2 fold.
      expect(maxDiff, lessThanOrEqualTo(4));
    });

    test('stereo stems sum to the stereo mix (up to its normalize gain)', () {
      const pan = {'melody': -0.7, 'bass': 0.6};
      const vol = {'melody': 0.3, 'bass': 0.3};
      final mel = buildMidi(one, 100,
          vol: vol, tracks: const {'melody'}, pan: pan);
      final bass = buildMidi(one, 100,
          vol: vol, tracks: const {'bass'}, pan: pan);
      final stems = [
        for (final w in render([mel, bass], mix: false)) _stereo(w),
      ];
      final mix = _stereo(render([mel, bass], mix: true).single);
      final n = mix.left.length;
      final sumL = Float32List(n), sumR = Float32List(n);
      var peak = 0.0;
      for (final st in stems) {
        expect(st.left.length, lessThanOrEqualTo(n));
        for (var i = 0; i < st.left.length; i++) {
          sumL[i] += st.left[i];
          sumR[i] += st.right[i];
        }
      }
      for (var i = 0; i < n; i++) {
        peak = math.max(peak, math.max(sumL[i].abs(), sumR[i].abs()));
      }
      expect(peak, lessThan(0.94)); // stems weren't limited
      final g = 0.94 / peak;
      var maxErr = 0.0;
      for (var i = 0; i < n; i++) {
        maxErr = math.max(maxErr, (mix.left[i] - sumL[i] * g).abs());
        maxErr = math.max(maxErr, (mix.right[i] - sumR[i] * g).abs());
      }
      // Only Int16 rounding separates them: each stem's 0.5 LSB scaled by the
      // mix gain, plus the mix's own rounding.
      expect(maxErr, lessThan((stems.length * g + 2) / 32768));
      // the pans are audible in the stems: melody leans left, bass right
      expect(_rms(stems[0].left), greaterThan(_rms(stems[0].right)));
      expect(_rms(stems[1].right), greaterThan(_rms(stems[1].left)));
    });
  });

  group('Song.pan persistence', () {
    test('all centre -> no pan key; round-trip; clamp', () {
      final s = Song(id: 's', title: 't', pan: {'melody': 0.0});
      expect(s.toJson().containsKey('pan'), isFalse);
      expect(Song(id: 's', title: 't').toJson().containsKey('pan'), isFalse);

      final b = Song(id: 's', title: 't', pan: {'bass': 0.3});
      final back = Song.fromJson(b.toJson());
      expect(back.pan, {'bass': 0.3});
      expect(Song.decodeList(Song.encodeList([b])).single.pan, {'bass': 0.3});

      final j = Song(id: 's', title: 't').toJson()
        ..['pan'] = {'drums': 2.0, 'vocal': -5, 'bass': 0};
      expect(Song.fromJson(j).pan, {'drums': 1.0, 'vocal': -1.0});
    });

    test('songs saved before pan load centred', () {
      final j = Song(id: 'old', title: 'old').toJson()..remove('pan');
      expect(Song.fromJson(j).pan, isEmpty);
    });
  });
}
