// gt-003: the partial-structure fit used for the GM 28 / GM 31 regression
// (a Dart port of the method in the G3 design analysis). It is a PROXY for
// the sounding pitch, not a confirmed perceived pitch: it measures how much
// of the spectral energy (40 Hz..8 kHz) lies within ±35 cents of integer
// multiples of a candidate fundamental.
import 'dart:math' as math;

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';

const int kFitSampleRate = 44100;

double midiHz(num m) => 440 * math.pow(2, (m - 69) / 12).toDouble();

/// In-place iterative radix-2 complex FFT ([re].length must be a power of 2).
void fftInPlace(Float64List re, Float64List im) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i], ti = im[i];
      re[i] = re[j];
      im[i] = im[j];
      re[j] = tr;
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = -2 * math.pi / len;
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var k = 0; k < len ~/ 2; k++) {
        final a = i + k, b = a + len ~/ 2;
        final xr = re[b] * cr - im[b] * ci, xi = re[b] * ci + im[b] * cr;
        re[b] = re[a] - xr;
        im[b] = im[a] - xi;
        re[a] += xr;
        im[a] += xi;
        final nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}

/// Power spectrum of [pcm] between [t0] and [t1] seconds (Hann window,
/// zero-padded to 65536 points). Returns (freqs, power) for bins 0..n/2.
({Float64List freq, Float64List power}) powerSpectrum(
  Float32List pcm,
  double t0,
  double t1,
) {
  const n = 1 << 16;
  final a = (t0 * kFitSampleRate).toInt(), b = (t1 * kFitSampleRate).toInt();
  final len = b - a;
  final re = Float64List(n), im = Float64List(n);
  for (var i = 0; i < len && i < n; i++) {
    final w = .5 - .5 * math.cos(2 * math.pi * i / (len - 1));
    re[i] = pcm[a + i] * w;
  }
  fftInPlace(re, im);
  final freq = Float64List(n ~/ 2 + 1), power = Float64List(n ~/ 2 + 1);
  for (var k = 0; k <= n ~/ 2; k++) {
    freq[k] = k * kFitSampleRate / n;
    power[k] = re[k] * re[k] + im[k] * im[k];
  }
  return (freq: freq, power: power);
}

/// Fraction of the 40 Hz..8 kHz energy within ±35 cents of the integer
/// multiples of [f0].
double structureFit(({Float64List freq, Float64List power}) s, double f0) {
  var tot = 0.0, hit = 0.0;
  for (var k = 0; k < s.freq.length; k++) {
    final f = s.freq[k];
    if (f <= 40 || f >= 8000) continue;
    final p = s.power[k];
    tot += p;
    final m = (f / f0).roundToDouble();
    if (m < 1) continue;
    final cents = 1200 * math.log(f / (m * f0)) / math.ln2;
    if (cents.abs() < 35) hit += p;
  }
  return tot == 0 ? 0 : hit / tot;
}

/// Mono MeltySynth render of one note (program [program], bank 0) from the
/// font bytes [sf2], [seconds] long — the same set-up as the design probe.
Float32List renderMono(
  Uint8List sf2,
  int program,
  int key, {
  int velocity = 100,
  double seconds = 1.2,
}) {
  final s = Synthesizer.loadByteData(
    ByteData.sublistView(sf2),
    SynthesizerSettings(sampleRate: kFitSampleRate),
  );
  s.processMidiMessage(channel: 0, command: 0xc0, data1: program, data2: 0);
  s.noteOn(channel: 0, key: key, velocity: velocity);
  final l = Float32List((kFitSampleRate * seconds).round());
  final r = Float32List(l.length);
  s.render(l, r);
  final mono = Float32List(l.length);
  for (var i = 0; i < l.length; i++) {
    mono[i] = (l[i] + r[i]) / 2;
  }
  return mono;
}

double rms(Float32List pcm, double t0, double t1) {
  final a = (t0 * kFitSampleRate).toInt();
  final b = math.min(pcm.length, (t1 * kFitSampleRate).toInt());
  var s = 0.0;
  for (var i = a; i < b; i++) {
    s += pcm[i] * pcm[i];
  }
  return b > a ? math.sqrt(s / (b - a)) : 0;
}
