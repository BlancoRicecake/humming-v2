// wav_codec — encode/parse roundtrip, chunk-walker robustness, resample,
// peaks. Pure Dart (no device, no assets).
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/wav_codec.dart';

Float32List sine(double freq, int sr, double sec, {double amp = 0.5}) {
  final n = (sr * sec).round();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amp * math.sin(2 * math.pi * freq * i / sr);
  }
  return out;
}

void main() {
  test('encode → parse roundtrip preserves samples', () {
    final src = sine(440, 44100, 0.25);
    final wav = parseWav(encodeWavMono16(src, 44100));
    expect(wav, isNotNull);
    expect(wav!.sampleRate, 44100);
    expect(wav.channels, 1);
    expect(wav.samples.length, src.length);
    for (var i = 0; i < src.length; i += 997) {
      expect(wav.samples[i], closeTo(src[i], 1 / 32000));
    }
  });

  test('parser walks past an inserted LIST chunk', () {
    final src = sine(220, 22050, 0.1);
    final plain = encodeWavMono16(src, 22050);
    // splice a LIST chunk between fmt and data
    const listBody = 'INFOIART';
    final list = BytesBuilder()
      ..add(plain.sublist(0, 36)) // RIFF..fmt chunk end
      ..add('LIST'.codeUnits)
      ..add((ByteData(4)..setUint32(0, listBody.length, Endian.little)).buffer.asUint8List())
      ..add(listBody.codeUnits)
      ..add(plain.sublist(36)); // data chunk onward
    final spliced = list.toBytes();
    // fix RIFF size field
    ByteData.sublistView(spliced).setUint32(4, spliced.length - 8, Endian.little);
    final wav = parseWav(spliced);
    expect(wav, isNotNull);
    expect(wav!.samples.length, src.length);
  });

  test('data size 0 falls back to file length (unfinalized header)', () {
    final src = sine(330, 44100, 0.05);
    final bytes = encodeWavMono16(src, 44100);
    ByteData.sublistView(bytes).setUint32(40, 0, Endian.little); // zero the data size
    final wav = parseWav(bytes);
    expect(wav, isNotNull);
    expect(wav!.samples.length, src.length);
  });

  test('garbage and non-PCM input return null', () {
    expect(parseWav(Uint8List(10)), isNull);
    expect(parseWav(Uint8List.fromList(List.filled(100, 7))), isNull);
  });

  test('resampleLinear maps length and preserves a slow ramp', () {
    final src = Float32List.fromList([for (var i = 0; i < 100; i++) i / 100]);
    final up = resampleLinear(src, 22050, 44100);
    expect(up.length, 200);
    expect(up.first, closeTo(0, 1e-6));
    expect(up[100], closeTo(0.5, 0.02));
    final same = resampleLinear(src, 44100, 44100);
    expect(identical(same, src), isTrue);
  });

  test('peaksFromPcm normalizes to 1.0 with a 0.05 floor', () {
    final pcm = Float32List(1000);
    for (var i = 500; i < 600; i++) {
      pcm[i] = 0.4; // one loud region
    }
    final peaks = peaksFromPcm(pcm, buckets: 10);
    expect(peaks.length, 10);
    expect(peaks.reduce(math.max), 1.0);
    expect(peaks.first, 0.05); // silent bucket floored
    expect(peaksFromPcm(Float32List(100)), everyElement(0.05)); // all-silent
  });

  test('stereo source parse averages the channels down to mono', () {
    const sr = 44100;
    const n = 200;
    // interleaved PCM16 stereo: L = 0.5, R = -0.25 → mono avg = 0.125
    final data = ByteData(44 + n * 4);
    void wr(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    wr(0, 'RIFF');
    data.setUint32(4, 36 + n * 4, Endian.little);
    wr(8, 'WAVE');
    wr(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 2, Endian.little); // stereo
    data.setUint32(24, sr, Endian.little);
    data.setUint32(28, sr * 4, Endian.little);
    data.setUint16(32, 4, Endian.little);
    data.setUint16(34, 16, Endian.little);
    wr(36, 'data');
    data.setUint32(40, n * 4, Endian.little);
    for (var i = 0; i < n; i++) {
      data.setInt16(44 + i * 4, (0.5 * 32767).round(), Endian.little);
      data.setInt16(44 + i * 4 + 2, (-0.25 * 32768).round(), Endian.little);
    }
    final wav = parseWav(data.buffer.asUint8List());
    expect(wav, isNotNull);
    expect(wav!.channels, 2);
    expect(wav.samples.length, n);
    expect(wav.samples.first, closeTo(0.125, 1 / 32000));
  });

  test('WAVE_FORMAT_EXTENSIBLE PCM16 parses', () {
    final src = sine(440, 44100, 0.05);
    const n40 = 40; // extensible fmt chunk: 16 base + cbSize(2) + 22 extension
    final data = ByteData(12 + 8 + n40 + 8 + src.length * 2);
    void wr(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    wr(0, 'RIFF');
    data.setUint32(4, data.lengthInBytes - 8, Endian.little);
    wr(8, 'WAVE');
    wr(12, 'fmt ');
    data.setUint32(16, n40, Endian.little);
    data.setUint16(20, 0xFFFE, Endian.little); // WAVE_FORMAT_EXTENSIBLE
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, 44100, Endian.little);
    data.setUint32(28, 44100 * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    data.setUint16(36, 22, Endian.little); // cbSize
    data.setUint16(38, 16, Endian.little); // valid bits per sample
    data.setUint32(40, 0x4, Endian.little); // channel mask (FC)
    data.setUint16(44, 1, Endian.little); // subformat GUID → KSDATAFORMAT_SUBTYPE_PCM
    wr(60, 'data');
    data.setUint32(64, src.length * 2, Endian.little);
    for (var i = 0; i < src.length; i++) {
      data.setInt16(68 + i * 2, (src[i] * 32767).round(), Endian.little);
    }
    final wav = parseWav(data.buffer.asUint8List());
    expect(wav, isNotNull);
    expect(wav!.sampleRate, 44100);
    expect(wav.samples.length, src.length);
    expect(wav.samples[100], closeTo(src[100], 1 / 32000));
  });

  test('encodeWavMono16FromStereo normalizes a >1.0 peak to ~0.94 without wrapping', () {
    final left = sine(440, 44100, 0.05, amp: 1.3);
    final right = sine(440, 44100, 0.05, amp: 1.3);
    var srcPeak = 0.0;
    for (final s in left) {
      if (s.abs() > srcPeak) srcPeak = s.abs();
    }
    final wav = parseWav(encodeWavMono16FromStereo(left, right, 44100));
    expect(wav, isNotNull);
    var peak = 0.0;
    for (final s in wav!.samples) {
      if (s.abs() > peak) peak = s.abs();
    }
    expect(peak, closeTo(0.94, 0.01));
    // no wrap: every sample is the source scaled by the same headroom gain
    final gain = 0.94 / srcPeak;
    for (var i = 0; i < left.length; i += 7) {
      expect(wav.samples[i], closeTo(left[i] * gain, 2 / 32768));
    }
  });

  test('mixVocalsInto sums pcm*gain at the scheduled offset on both channels', () {
    final left = Float32List(100);
    final right = Float32List(100);
    final pcm = Float32List.fromList(List.filled(20, 0.5));
    mixVocalsInto(left, right, [VocalMix(pcm: pcm, start: 30, len: 10, gain: 0.8)]);
    expect(left[29], 0);
    expect(left[30], closeTo(0.4, 1e-6));
    expect(right[39], closeTo(0.4, 1e-6));
    expect(left[40], 0); // len truncation honored
    expect(vocalMixEnd([VocalMix(pcm: pcm, start: 30, len: 10, gain: 1)]), 40);
  });
}
