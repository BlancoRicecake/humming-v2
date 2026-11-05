// Mono offline effects for recorded clips. No network or new dependencies.
import 'dart:math' as math;
import 'dart:typed_data';

import 'vocal_fx_catalog.dart';
import 'wav_codec.dart';

bool isLocalVocalEffect(String type) =>
    localVocalEffects.any((effect) => effect.type == type);

double _param(
  Map<String, dynamic> p,
  String key,
  double fallback,
  double min,
  double max,
) {
  final value = p[key];
  final low = math.min(min, max);
  return value is num && value.isFinite
      ? value.toDouble().clamp(low, max)
      : fallback.clamp(low, max);
}

/// Isolate-compatible message: audio, type and params are all transferable.
Uint8List renderLocalVocalFx(Map<String, dynamic> message) {
  final bytes = message['audio'] as Uint8List;
  final type = message['type'] as String;
  final params = (message['params'] as Map).cast<String, dynamic>();
  if (!isLocalVocalEffect(type)) throw ArgumentError('Unknown local vocal FX');
  final audio = parseWav(bytes);
  if (audio == null || audio.samples.isEmpty) {
    throw const FormatException('Invalid vocal WAV');
  }
  final mix = _param(params, 'mix', 1, 0, 1);
  if (mix == 0) return bytes;
  final source = audio.samples;
  final sr = audio.sampleRate;
  final wet = switch (type) {
    'gate' => _gate(source, sr, params),
    'deess' => _deess(source, sr, params),
    'saturation' => _saturate(source, params),
    'telephone' => _telephone(source, sr, params),
    'lofi' => _lofi(source, sr, params),
    'chorus' || 'doubler' || 'flanger' => _modDelay(source, sr, params, type),
    'tremolo' || 'robot' => _modulate(source, sr, params, type),
    _ => throw ArgumentError('Unknown local vocal FX'),
  };
  final out = Float32List(source.length);
  var peak = 0.0;
  for (var i = 0; i < out.length; i++) {
    final v = source[i] * (1 - mix) + wet[i] * mix;
    if (!v.isFinite) throw const FormatException('Non-finite effect output');
    out[i] = v;
    peak = math.max(peak, v.abs());
  }
  // Only attenuate hot signals. Never auto-boost silence or low-level noise.
  if (peak > .98) {
    final gain = .98 / peak;
    for (var i = 0; i < out.length; i++) {
      out[i] *= gain;
    }
  }
  return encodeWavMono16(out, sr);
}

double _smoothCoefficient(double ms, int sr) => math.exp(-1 / (ms * .001 * sr));

Float32List _gate(Float32List y, int sr, Map<String, dynamic> p) {
  final threshold = math.pow(10, _param(p, 'threshold', -42, -70, -12) / 20);
  final attack = _smoothCoefficient(3, sr),
      release = _smoothCoefficient(60, sr);
  final detectRelease = _smoothCoefficient(25, sr);
  var envelope = 0.0, gain = 0.0;
  final out = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    envelope = math.max(y[i].abs(), envelope * detectRelease);
    final target = (envelope / threshold).clamp(0.0, 1.0);
    final softened = target * target;
    final coef = softened > gain ? attack : release;
    gain = coef * gain + (1 - coef) * softened;
    out[i] = y[i] * gain;
  }
  return out;
}

/// Dynamic high-band attenuation, rather than permanently dulling all vocals.
Float32List _deess(Float32List y, int sr, Map<String, dynamic> p) {
  final low = _filter(y, sr, math.min(4500, sr * .35), highpass: false);
  final threshold = math.pow(10, _param(p, 'threshold', -28, -60, -6) / 20);
  final reduction = _param(p, 'reduction', .7, 0, .95);
  final atk = _smoothCoefficient(2, sr), rel = _smoothCoefficient(55, sr);
  var env = 0.0;
  final out = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    final high = y[i] - low[i];
    final coef = high.abs() > env ? atk : rel;
    env = coef * env + (1 - coef) * high.abs();
    final amount = env <= threshold ? 0.0 : (1 - threshold / env) * reduction;
    out[i] = y[i] - high * amount;
  }
  return out;
}

Float32List _saturate(Float32List y, Map<String, dynamic> p) {
  final drive = _param(p, 'drive', 2, 1, 12);
  final out = Float32List(y.length);
  // Smooth odd-symmetric soft clipping, finite even for extreme inputs.
  for (var i = 0; i < y.length; i++) {
    final x = (y[i] * drive).clamp(-12.0, 12.0);
    final e = math.exp(2 * x);
    out[i] = (e - 1) / (e + 1) / math.sqrt(drive);
  }
  return out;
}

Float32List _telephone(Float32List y, int sr, Map<String, dynamic> p) {
  final low = _param(p, 'low', 350, 60, sr * .35);
  final high = _param(p, 'high', 3200, low + 20, sr * .45);
  return _filter(
    _filter(y, sr, low, highpass: true),
    sr,
    high,
    highpass: false,
  );
}

// RBJ Butterworth low/high-pass, transposed direct form II.
Float32List _filter(
  Float32List y,
  int sr,
  double freq, {
  required bool highpass,
}) {
  final w = 2 * math.pi * freq.clamp(10, sr * .45) / sr;
  final c = math.cos(w), alpha = math.sin(w) / math.sqrt(2);
  final a0 = 1 + alpha, a1 = -2 * c / a0, a2 = (1 - alpha) / a0;
  final b0 = (highpass ? (1 + c) : (1 - c)) / 2 / a0;
  final b1 = (highpass ? -(1 + c) : (1 - c)) / a0;
  final b2 = b0;
  var z1 = 0.0, z2 = 0.0;
  final out = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    final v = b0 * y[i] + z1;
    z1 = b1 * y[i] - a1 * v + z2;
    z2 = b2 * y[i] - a2 * v;
    out[i] = v;
  }
  return out;
}

Float32List _lofi(Float32List y, int sr, Map<String, dynamic> p) {
  final bits = _param(p, 'bits', 8, 3, 16).round();
  final rate = _param(p, 'rate', 8000, 1000, sr.toDouble());
  final levels = math.pow(2, bits - 1).toDouble();
  var phase = 1.0, held = 0.0;
  final out = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    if (phase >= 1) {
      held = (y[i] * levels).round() / levels;
      phase -= 1;
    }
    out[i] = held;
    phase += rate / sr;
  }
  return out;
}

double _sample(Float32List y, double index) {
  if (index < 0 || index >= y.length) return 0;
  final a = index.floor(), b = math.min(a + 1, y.length - 1);
  final f = index - a;
  return y[a] * (1 - f) + y[b] * f;
}

Float32List _modDelay(
  Float32List y,
  int sr,
  Map<String, dynamic> p,
  String type,
) {
  final flange = type == 'flanger', doubleVoice = type == 'doubler';
  final base = flange ? 2.5 : (doubleVoice ? 24.0 : 18.0);
  final depth = _param(p, 'depth', flange ? 1.6 : 3, .1, flange ? 2.0 : 8.0);
  final rate = _param(p, 'rate', doubleVoice ? .23 : .8, .05, 5);
  final wet = _param(p, 'wet', .4, 0, 1);
  final out = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    final phase = 2 * math.pi * rate * i / sr;
    final a = _sample(y, i - (base + depth * math.sin(phase)) * sr / 1000);
    final b =
        flange
            ? a
            : _sample(
              y,
              i -
                  (base * 1.31 + depth * math.sin(phase * 1.17 + 1.9)) *
                      sr /
                      1000,
            );
    out[i] = y[i] * (1 - wet) + (a + b) * .5 * wet;
  }
  return out;
}

Float32List _modulate(
  Float32List y,
  int sr,
  Map<String, dynamic> p,
  String type,
) {
  final robot = type == 'robot';
  final rate = _param(
    p,
    'rate',
    robot ? 65 : 4,
    robot ? 20 : .1,
    robot ? 600 : 20,
  );
  final depth = _param(p, robot ? 'wet' : 'depth', robot ? .8 : .65, 0, 1);
  final out = Float32List(y.length);
  for (var i = 0; i < y.length; i++) {
    final wave = math.cos(2 * math.pi * rate * i / sr);
    final modulation = robot ? wave : .5 * (1 + wave);
    out[i] = y[i] * ((1 - depth) + depth * modulation);
  }
  return out;
}
