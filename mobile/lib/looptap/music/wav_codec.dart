// LoopTap — pure-Dart WAV codec (no Flutter imports: usable in isolates and
// plain `flutter test`). Vocal recordings are PCM16 WAV since the opus→WAV
// switch, so parse/encode/resample/peaks all live here and are shared by the
// recorder, the export mixer, and tests.
import 'dart:typed_data';

const double _wavHeadroomPeak = 0.94;

/// Decoded mono audio. [samples] are normalized to [-1, 1].
class WavData {
  const WavData({
    required this.samples,
    required this.sampleRate,
    required this.channels,
  });
  final Float32List samples; // mono (stereo input is averaged down)
  final int sampleRate;
  final int channels; // channel count of the SOURCE file
}

/// Parse a PCM16 RIFF/WAVE file. Walks chunks (LIST/fact/etc. tolerated).
/// If the data chunk's size field is 0 or 0xFFFFFFFF (a not-yet-finalized
/// header from a streaming writer), the rest of the file is taken as data.
/// Returns null when the bytes aren't a parseable PCM16 WAV.
WavData? parseWav(Uint8List bytes) {
  if (bytes.length < 44) return null;
  final bd = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;

  int? fmtCode, channels, sampleRate, bitsPerSample;
  int dataOff = -1, dataLen = 0;
  var off = 12;
  while (off + 8 <= bytes.length) {
    final id = tag(off);
    var size = bd.getUint32(off + 4, Endian.little);
    if (id == 'fmt ') {
      if (off + 8 + 16 > bytes.length) return null;
      fmtCode = bd.getUint16(off + 8, Endian.little);
      channels = bd.getUint16(off + 10, Endian.little);
      sampleRate = bd.getUint32(off + 12, Endian.little);
      bitsPerSample = bd.getUint16(off + 22, Endian.little);
    } else if (id == 'data') {
      dataOff = off + 8;
      if (size == 0 || size == 0xFFFFFFFF || dataOff + size > bytes.length) {
        size = bytes.length - dataOff; // unfinalized header fallback
      }
      dataLen = size;
      break; // data is conventionally last; stop scanning
    }
    off += 8 + size + (size & 1); // chunks are word-aligned
  }
  // 0xFFFE = WAVE_FORMAT_EXTENSIBLE — common from OS recorders; at 16 bits
  // the sample data is plain PCM16, so treat it the same as fmtCode 1.
  if ((fmtCode != 1 && fmtCode != 0xFFFE) || bitsPerSample != 16 || dataOff < 0) {
    return null;
  }
  if (channels == null ||
      channels < 1 ||
      sampleRate == null ||
      sampleRate <= 0) {
    return null;
  }

  final frameCount = dataLen ~/ (2 * channels);
  final mono = Float32List(frameCount);
  final data = ByteData.sublistView(bytes, dataOff);
  for (var i = 0; i < frameCount; i++) {
    var acc = 0;
    for (var c = 0; c < channels; c++) {
      acc += data.getInt16((i * channels + c) * 2, Endian.little);
    }
    mono[i] = (acc / channels) / 32768.0;
  }
  return WavData(samples: mono, sampleRate: sampleRate, channels: channels);
}

/// Linear-interpolation resample (adequate for voice).
Float32List resampleLinear(Float32List src, int srcSr, int dstSr) {
  if (srcSr == dstSr || src.isEmpty) return src;
  final outLen = (src.length * dstSr / srcSr).round();
  final out = Float32List(outLen);
  final step = srcSr / dstSr;
  for (var i = 0; i < outLen; i++) {
    final pos = i * step;
    final i0 = pos.floor();
    final i1 = i0 + 1 < src.length ? i0 + 1 : src.length - 1;
    final frac = pos - i0;
    out[i] =
        src[i0 < src.length ? i0 : src.length - 1] * (1 - frac) +
        src[i1] * frac;
  }
  return out;
}

/// Mono 16-bit PCM WAV (shared with wav_export's stereo render path, which
/// averages L/R before calling the stereo variant below).
Uint8List encodeWavMono16(Float32List samples, int sr) {
  final len = samples.length;
  final data = ByteData(44 + len * 2);
  _writeWavHeader(data, len, sr);
  var off = 44;
  for (var i = 0; i < len; i++) {
    final s = samples[i].clamp(-1.0, 1.0);
    data.setInt16(
      off,
      (s < 0 ? s * 0x8000 : s * 0x7fff).round(),
      Endian.little,
    );
    off += 2;
  }
  return data.buffer.asUint8List();
}

/// Mono WAV from L/R render buffers, averaging the two (legacy _encodeWav).
Uint8List encodeWavMono16FromStereo(
  Float32List left,
  Float32List right,
  int sr,
) {
  final len = left.length;
  final data = ByteData(44 + len * 2);
  _writeWavHeader(data, len, sr);
  var peak = 0.0;
  for (var i = 0; i < len; i++) {
    final a = ((left[i] + right[i]) * 0.5).abs();
    if (a > peak) peak = a;
  }
  final gain = peak > _wavHeadroomPeak ? _wavHeadroomPeak / peak : 1.0;
  var off = 44;
  for (var i = 0; i < len; i++) {
    final s = (((left[i] + right[i]) * 0.5) * gain).clamp(-1.0, 1.0);
    data.setInt16(
      off,
      (s < 0 ? s * 0x8000 : s * 0x7fff).round(),
      Endian.little,
    );
    off += 2;
  }
  return data.buffer.asUint8List();
}

void _writeWavHeader(ByteData data, int sampleCount, int sr) {
  void wr(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  wr(0, 'RIFF');
  data.setUint32(4, 36 + sampleCount * 2, Endian.little);
  wr(8, 'WAVE');
  wr(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM
  data.setUint16(22, 1, Endian.little); // mono
  data.setUint32(24, sr, Endian.little);
  data.setUint32(28, sr * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  wr(36, 'data');
  data.setUint32(40, sampleCount * 2, Endian.little);
}

/// One scheduled vocal occurrence in a flattened-song render: [pcm] (mono,
/// render sample rate) summed into the mix at [start] for [len] samples.
class VocalMix {
  const VocalMix({
    required this.pcm,
    required this.start,
    required this.len,
    required this.gain,
  });
  final Float32List pcm;
  final int start;
  final int len; // truncated at the section-instance boundary
  final double gain;
}

/// Sum scheduled vocal clips into stereo render buffers. Adds `pcm*gain` to
/// BOTH channels so a downstream (L+R)/2 mono fold contributes exactly
/// `pcm*gain`. Buffers must already be long enough (see [vocalMixEnd]).
void mixVocalsInto(Float32List left, Float32List right, List<VocalMix> vocals) {
  for (final v in vocals) {
    final n = v.len < v.pcm.length ? v.len : v.pcm.length;
    for (var i = 0; i < n; i++) {
      final s = v.pcm[i] * v.gain;
      left[v.start + i] += s;
      right[v.start + i] += s;
    }
  }
}

/// The minimum buffer length needed to hold all [vocals].
int vocalMixEnd(List<VocalMix> vocals) {
  var end = 0;
  for (final v in vocals) {
    final n = v.len < v.pcm.length ? v.len : v.pcm.length;
    if (v.start + n > end) end = v.start + n;
  }
  return end;
}

// ── non-destructive clip edits (pure, isolate-safe) ───────────────────────
// All take/return mono Float32List in [-1,1] at the source sample rate, so they
// chain with parseWav → … → encodeWavMono16 and are unit-testable without
// Flutter. Out-of-range / inverted args are clamped to a safe no-op rather than
// throwing — callers pass sample indices derived from UI gestures.

/// Slice [start, end) samples. Bounds are clamped; start>=end → empty.
Float32List trimPcm(Float32List s, int start, int end) {
  final a = start < 0 ? 0 : (start > s.length ? s.length : start);
  final b = end < a ? a : (end > s.length ? s.length : end);
  return Float32List.sublistView(s, a, b);
}

/// Multiply every sample by [gain] (linear). Result is clamped to [-1,1] so a
/// boost never wraps on later int16 encoding.
Float32List applyGain(Float32List s, double gain) {
  final out = Float32List(s.length);
  for (var i = 0; i < s.length; i++) {
    out[i] = (s[i] * gain).clamp(-1.0, 1.0);
  }
  return out;
}

/// Fade-in over the first [fadeIn] samples and fade-out over the last [fadeOut]
/// samples, using a smoothstep curve (3t²−2t³) so the ramp eases in/out for a
/// more dramatic, musical fade than a straight line. Overlapping/oversized
/// fades are clamped to the clip length so the two ramps never cross. Returns a
/// new buffer.
Float32List fadePcm(Float32List s, int fadeIn, int fadeOut) {
  final n = s.length;
  if (n == 0) return Float32List(0);
  var fi = fadeIn < 0 ? 0 : (fadeIn > n ? n : fadeIn);
  var fo = fadeOut < 0 ? 0 : (fadeOut > n ? n : fadeOut);
  if (fi + fo > n) {
    // Split the budget proportionally so the ramps meet but don't overlap.
    final total = fi + fo;
    fi = (fi * n / total).floor();
    fo = n - fi;
  }
  double smooth(double t) => t * t * (3 - 2 * t); // smoothstep ease
  final out = Float32List.fromList(s);
  for (var i = 0; i < fi; i++) {
    out[i] *= smooth((i + 1) / fi);
  }
  for (var i = 0; i < fo; i++) {
    out[n - 1 - i] *= smooth((i + 1) / fo);
  }
  return out;
}

/// Scale so the loudest sample hits [targetPeak]. Silence (or a clip already at
/// the target) is returned unchanged. [targetPeak] is clamped to (0, 1].
Float32List normalizePcm(Float32List s, {double targetPeak = 0.99}) {
  final t = targetPeak.clamp(1e-4, 1.0);
  var peak = 0.0;
  for (final v in s) {
    final a = v.abs();
    if (a > peak) peak = a;
  }
  if (peak <= 1e-6) return s;
  return applyGain(s, t / peak);
}

/// Concatenate [parts] head-to-tail into one buffer (splice / "붙이기" base).
Float32List concatPcm(List<Float32List> parts) {
  var total = 0;
  for (final p in parts) {
    total += p.length;
  }
  final out = Float32List(total);
  var off = 0;
  for (final p in parts) {
    out.setRange(off, off + p.length, p);
    off += p.length;
  }
  return out;
}

/// Display peaks: bucketed max-abs, normalized so the loudest bucket → 1.0,
/// floored at 0.05 (what the arrangement painter expects of `clip`).
List<double> peaksFromPcm(Float32List pcm, {int buckets = 64}) {
  if (pcm.isEmpty) return List<double>.filled(buckets, 0.05);
  final out = List<double>.filled(buckets, 0.0);
  final per = pcm.length / buckets;
  for (var b = 0; b < buckets; b++) {
    final start = (b * per).floor();
    final end = (b + 1 == buckets) ? pcm.length : ((b + 1) * per).floor();
    var peak = 0.0;
    for (var i = start; i < end; i++) {
      final a = pcm[i].abs();
      if (a > peak) peak = a;
    }
    out[b] = peak;
  }
  var max = 0.0;
  for (final v in out) {
    if (v > max) max = v;
  }
  if (max > 0) {
    for (var b = 0; b < buckets; b++) {
      out[b] = (out[b] / max).clamp(0.05, 1.0);
    }
  } else {
    for (var b = 0; b < buckets; b++) {
      out[b] = 0.05;
    }
  }
  return out;
}
