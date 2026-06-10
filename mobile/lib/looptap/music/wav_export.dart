// LoopTap — on-device WAV / Stems render. Ported from prototype/export.jsx
// (OfflineAudioContext synth): triangle melody, saw+sub bass, synthesized
// kick/snare/hihat, swing + mixer levels baked in. Mono 44.1kHz PCM16.
//
// NOTE: this is an oscillator render (self-contained, deterministic). It is NOT
// the SF2 instrument timbre you hear during playback — there is no on-device
// offline SF2 render — so the exported audio is a faithful arrangement but a
// different tone. The heavy render runs in a background isolate via compute().
//
// Vocal is audio-only (m4a). It can't be decoded/mixed in pure Dart, so the
// full-mix WAV is the instrumental; each section's vocal recording is included
// in Stems as a separate file.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/loop_models.dart';
import 'song_util.dart';

const int _sr = 44100;

// ── synth (runs inside the isolate) ─────────────────────────────────
class _Synth {
  _Synth(this.steps, this.bpm, this.swing) {
    stepDur = 60 / bpm / 4;
    final totalSec = steps * stepDur + 0.4;
    buf = Float64List((_sr * totalSec).ceil());
  }
  final int steps, bpm;
  final double swing;
  late final double stepDur;
  late final Float64List buf;
  final math.Random _rng = math.Random(12345); // fixed seed → deterministic

  double _at(int step) => (step + (step % 2 == 1 ? swing * 0.5 : 0)) * stepDur;

  // WebAudio-style envelope: eps→gain over 8ms attack, then gain→eps over the
  // rest (exponential ramps).
  double _env(double t, double dur, double gain) {
    const eps = 0.0001, atk = 0.008;
    if (t < atk) return eps * math.pow(gain / eps, t / atk).toDouble();
    final d = dur - atk;
    if (d <= 0) return gain;
    final x = ((t - atk) / d).clamp(0.0, 1.0);
    return gain * math.pow(eps / gain, x).toDouble();
  }

  double _decay(double t, double gain, double dur) {
    const eps = 0.001;
    final x = (t / dur).clamp(0.0, 1.0);
    return gain * math.pow(eps / gain, x).toDouble();
  }

  double _hpAlpha(double fc) {
    final rc = 1 / (2 * math.pi * fc), dt = 1 / _sr;
    return rc / (rc + dt);
  }

  void pitched(double freq, int step, double dur, bool bass, double vol) {
    final n0 = (_at(step) * _sr).floor();
    final n = (dur * _sr).ceil();
    final gain = (bass ? 0.26 : 0.22) * vol;
    for (var i = 0; i < n; i++) {
      final idx = n0 + i;
      if (idx < 0 || idx >= buf.length) continue;
      final t = i / _sr;
      final frac = (freq * t) % 1.0;
      final wave = bass ? (2 * frac - 1) : (1 - 4 * (frac - 0.5).abs());
      buf[idx] += wave * _env(t, dur, gain);
      if (bass) {
        buf[idx] += math.sin(2 * math.pi * (freq / 2) * t) * _env(t, dur, gain * 0.5);
      }
    }
  }

  void drum(String kind, int step, double vol) {
    final n0 = (_at(step) * _sr).floor();
    if (kind == 'kick') {
      final n = (0.26 * _sr).ceil();
      var phase = 0.0;
      for (var i = 0; i < n; i++) {
        final idx = n0 + i;
        if (idx < 0 || idx >= buf.length) continue;
        final t = i / _sr;
        final f = t < 0.12 ? 155 * math.pow(45 / 155, t / 0.12).toDouble() : 45.0;
        phase += 2 * math.pi * f / _sr;
        buf[idx] += math.sin(phase) * _decay(t, 1.05 * vol, 0.24);
      }
    } else if (kind == 'snare') {
      final n = (0.2 * _sr).ceil();
      final alpha = _hpAlpha(1400);
      var hp = 0.0, xPrev = 0.0;
      for (var i = 0; i < n; i++) {
        final idx = n0 + i;
        if (idx < 0 || idx >= buf.length) continue;
        final t = i / _sr;
        final x = _rng.nextDouble() * 2 - 1;
        hp = alpha * (hp + x - xPrev);
        xPrev = x;
        buf[idx] += hp * _decay(t, 0.7 * vol, 0.18);
        final frac = (180 * t) % 1.0;
        buf[idx] += (1 - 4 * (frac - 0.5).abs()) * _decay(t, 0.45 * vol, 0.12);
      }
    } else {
      // hihat
      final n = (0.06 * _sr).ceil();
      final alpha = _hpAlpha(7000);
      var hp = 0.0, xPrev = 0.0;
      for (var i = 0; i < n; i++) {
        final idx = n0 + i;
        if (idx < 0 || idx >= buf.length) continue;
        final t = i / _sr;
        final x = _rng.nextDouble() * 2 - 1;
        hp = alpha * (hp + x - xPrev);
        xPrev = x;
        buf[idx] += hp * _decay(t, 0.45 * vol, 0.05);
      }
    }
  }

  Uint8List encode() {
    final len = buf.length;
    final data = ByteData(44 + len * 2);
    void wr(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    wr(0, 'RIFF');
    data.setUint32(4, 36 + len * 2, Endian.little);
    wr(8, 'WAVE');
    wr(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little); // PCM
    data.setUint16(22, 1, Endian.little); // mono
    data.setUint32(24, _sr, Endian.little);
    data.setUint32(28, _sr * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    wr(36, 'data');
    data.setUint32(40, len * 2, Endian.little);
    var off = 44;
    for (var i = 0; i < len; i++) {
      final s = (buf[i] * 0.85).clamp(-1.0, 1.0);
      data.setInt16(off, (s < 0 ? s * 0x8000 : s * 0x7fff).round(), Endian.little);
      off += 2;
    }
    return data.buffer.asUint8List();
  }
}

// ── isolate entry — args are plain serializable structures ──────────
Uint8List _renderIso(Map<String, dynamic> a) {
  final synth = _Synth(a['steps'] as int, a['bpm'] as int, (a['swing'] as num).toDouble());
  final only = (a['only'] as List?)?.cast<String>().toSet();
  final vol = (a['vol'] as Map).cast<String, double>();
  bool on(String t) => only == null || only.contains(t);
  if (on('melody')) {
    for (final e in (a['melody'] as List)) {
      final freq = (e[0] as num).toDouble(), step = e[1] as int, dur = e[2] as int;
      synth.pitched(freq, step, math.max(0.12, dur * synth.stepDur * 0.95), false, vol['melody'] ?? 0.85);
    }
  }
  if (on('bass')) {
    for (final e in (a['bass'] as List)) {
      final freq = (e[0] as num).toDouble(), step = e[1] as int, dur = e[2] as int;
      synth.pitched(freq, step, math.max(0.12, dur * synth.stepDur * 0.95), true, vol['bass'] ?? 0.85);
    }
  }
  if (on('drums')) {
    for (final e in (a['drums'] as List)) {
      synth.drum(e[0] as String, e[1] as int, vol['drums'] ?? 1.0);
    }
  }
  return synth.encode();
}

Map<String, dynamic> _args(FlatSong flat, int bpm, double swing, Map<String, double> vol, List<String>? only) => {
      'steps': flat.steps,
      'bpm': bpm,
      'swing': swing,
      'vol': vol,
      'only': only,
      'melody': [for (final n in flat.melody) [n.freq, n.step, n.dur]],
      'bass': [for (final n in flat.bass) [n.freq, n.step, n.dur]],
      'drums': [for (final n in flat.drums) [n.kind, n.step]],
    };

// ── public API ──────────────────────────────────────────────────────
Future<String> _exportPath(String title, String ext) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/looptap/exports');
  if (!await folder.exists()) await folder.create(recursive: true);
  final safe = title.trim().isEmpty ? 'loop' : title.trim().replaceAll(RegExp(r'[^\w\- ]+'), '_');
  return '${folder.path}/$safe.$ext';
}

/// Full-mix instrumental WAV (melody + bass + drums).
Future<File> exportWavSong(
  List<Section> sections,
  int bpm,
  double swing,
  Map<String, double> vol,
  String title,
) async {
  final flat = flattenSong(sections);
  final bytes = await compute(_renderIso, _args(flat, bpm, swing, vol, null));
  final f = File(await _exportPath(title, 'wav'));
  await f.writeAsBytes(bytes);
  return f;
}

/// One WAV per non-empty instrument track + each section's vocal recording.
Future<List<File>> exportStems(
  List<Section> sections,
  int bpm,
  double swing,
  Map<String, double> vol,
  String title,
) async {
  final flat = flattenSong(sections);
  final out = <File>[];
  final present = <String, bool>{
    'melody': flat.melody.isNotEmpty,
    'bass': flat.bass.isNotEmpty,
    'drums': flat.drums.isNotEmpty,
  };
  for (final t in const ['melody', 'bass', 'drums']) {
    if (present[t] != true) continue;
    final bytes = await compute(_renderIso, _args(flat, bpm, swing, vol, [t]));
    final f = File(await _exportPath('$title - $t', 'wav'));
    await f.writeAsBytes(bytes);
    out.add(f);
  }
  // vocal recordings — copied as-is (audio-only, no synth render)
  for (final sec in sections) {
    final vp = sec.tracks['vocal']?.vocalPath;
    if (vp == null) continue;
    final src = File(vp);
    if (!await src.exists()) continue;
    final ext = vp.contains('.') ? vp.substring(vp.lastIndexOf('.') + 1) : 'm4a';
    out.add(await src.copy(await _exportPath('$title - vocal ${sec.name}', ext)));
  }
  return out;
}
