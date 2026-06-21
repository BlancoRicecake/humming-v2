// Offline A/B SoundFont audition through dart_melty_soundfont — the SAME
// engine the app's WAV export uses (wav_export.dart _renderIso). Renders one
// short phrase per instrument through two SF2 banks so you can listen and
// decide whether to swap the app's GM bank:
//
//   timgm — assets/sounds/TimGM6mb.sf2 (current app bank)
//   gugs  — GeneralUser GS v2.0.3 (candidate; leans on FluidSynth-style
//           modulators, so this checks it still sounds right on melty)
//
// Run from mobile/:  dart run tool/sf2_ab_melty.dart
//
// The phrases are the backend's audition phrases (backend/app/render.py
// _DEMO_MELODIC / _DEMO_DRUM): C-major arpeggio + held triad for melodic
// presets, kick/snare/hat pattern for bank-128 kits, velocity 100, 0.7 s tail.
// The render path mirrors the app's export exactly: build a format-0 SMF the
// way midi_export.dart buildMidi does (program change at t0; drum kits as a
// program change on ch9, which melty maps to bank 128), then
// Synthesizer.loadByteData + MidiFileSequencer.render at 44.1 kHz with
// reverb/chorus enabled — so what you hear here is what an export sounds like.
//
// Output: C:\Users\jlion\Documents\Humtrack\sf2_ab\melty\<bankId>\
//   mel<NNN> <label>.wav / kit<NNN> <label>.wav   (stereo PCM16, 44.1 kHz)
// — the naming matches the FluidSynth-side renders so files pair up.
//
// Per render it prints peak/RMS; a near-silent file (peak < 1%) is the
// melty-incompatibility signal we're hunting. It also enumerates each SF2's
// presets and flags requested (bank, program) pairs that are MISSING — melty
// silently falls back to another preset in that case, which would make the
// A/B lie.
// ignore_for_file: avoid_print  (CLI tool — print IS the output)
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';

const int _sr = 44100; // matches wav_export.dart
const double _tailSec = 0.7;
const String _outRoot = r'C:\Users\jlion\Documents\Humtrack\sf2_ab\melty';

final Map<String, String> _banks = {
  'timgm': r'C:\Users\jlion\Documents\Humtrack\Humming V2\mobile\assets\sounds\TimGM6mb.sf2',
  'gugs': r'C:\Users\jlion\Downloads\GeneralUser_GS_v2.0.3--doc_r6\GeneralUser-GS\GeneralUser-GS.sf2',
};

// ── audition phrases (ported from backend/app/render.py lines 143–151) ──
// (start sec, dur sec, midi pitch), velocity 100.
const List<(double, double, int)> _demoMelodic = [
  (0.00, 0.28, 60), (0.30, 0.28, 64), (0.60, 0.28, 67),
  (0.90, 0.80, 72),
  (0.90, 0.80, 60), (0.90, 0.80, 64), (0.90, 0.80, 67), // held triad
];
const List<(double, double, int)> _demoDrum = [
  // GM drum map: 36 kick, 38 snare, 42 hat
  (0.00, 0.20, 36), (0.25, 0.15, 42), (0.50, 0.20, 38), (0.75, 0.15, 42),
  (1.00, 0.20, 36), (1.25, 0.15, 42), (1.50, 0.20, 38), (1.75, 0.15, 42),
];

// ── programs to audition ──
const List<(int, String)> _melodic = [
  (0, 'Grand Piano'), (4, 'Electric Piano'), (16, 'Drawbar Organ'),
  (24, 'Nylon Guitar'), (25, 'Steel Guitar'), (33, 'Fingered Bass'),
  (38, 'Synth Bass 1'), (48, 'String Ensemble'), (52, 'Choir Aahs'),
  (56, 'Trumpet'), (73, 'Flute'), (80, 'Square Lead'), (81, 'Saw Lead'),
  (88, 'New Age Pad'), (89, 'Warm Pad'),
];
const List<(int, String)> _kits = [
  (0, 'Standard'), (8, 'Room'), (16, 'Power'), (24, 'Electronic'),
  (25, 'TR-808'), (32, 'Jazz'), (40, 'Brush'), (48, 'Orchestra'),
];

// ── format-0 SMF builder (mirrors midi_export.dart buildMidi encoding) ──
// tpq=1000 at 60 BPM → 1 tick = 1 ms, so the phrase seconds are exact.
const int _tpq = 1000;

List<int> _vlq(int n) {
  final b = [n & 0x7f];
  n >>= 7;
  while (n > 0) {
    b.insert(0, (n & 0x7f) | 0x80);
    n >>= 7;
  }
  return b;
}

Uint8List _buildPhraseMidi(int program, {required bool drum}) {
  final evs = <(int, List<int>)>[];
  const mpq = 1000000; // 60 BPM
  evs.add((0, [0xFF, 0x51, 0x03, (mpq >> 16) & 0xff, (mpq >> 8) & 0xff, mpq & 0xff]));
  if (drum) {
    // ch9 kit select — melty maps ch9 program changes to bank 128, same as the
    // app's kit handling. buildMidi skips program 0 (Standard, the ch9
    // default); mirror that so the A/B uses the exact export message stream.
    if (program > 0 && program <= 127) evs.add((0, [0xC9, program & 0x7f]));
  } else {
    evs.add((0, [0xC0, program & 0x7f])); // ch0, bank 0
  }
  final ch = drum ? 9 : 0;
  int t(double sec) => (sec * _tpq).round();
  for (final (start, dur, pitch) in drum ? _demoDrum : _demoMelodic) {
    evs.add((t(start), [0x90 | ch, pitch, 100]));
    evs.add((t(start + dur), [0x80 | ch, pitch, 0]));
  }
  // stable sort by time (note-ons before note-offs at equal times is already
  // guaranteed by insertion order per note; preserve insertion order overall)
  final indexed = [for (var i = 0; i < evs.length; i++) (i, evs[i])];
  indexed.sort((a, b) {
    final c = a.$2.$1.compareTo(b.$2.$1);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final sorted = [for (final e in indexed) e.$2];
  sorted.add((sorted.last.$1, [0xFF, 0x2F, 0x00])); // EOT at last event

  final body = <int>[];
  var prev = 0;
  for (final (tick, data) in sorted) {
    body.addAll(_vlq(tick - prev));
    body.addAll(data);
    prev = tick;
  }
  final len = body.length;
  return Uint8List.fromList([
    0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, (_tpq >> 8) & 255, _tpq & 255,
    0x4D, 0x54, 0x72, 0x6B, (len >> 24) & 255, (len >> 16) & 255, (len >> 8) & 255, len & 255,
    ...body,
  ]);
}

// ── render one phrase exactly like wav_export.dart _renderIso ──
({Float32List left, Float32List right}) _render(Uint8List sf2, Uint8List midi) {
  final synth = Synthesizer.loadByteData(
    ByteData.sublistView(sf2),
    SynthesizerSettings(sampleRate: _sr, enableReverbAndChorus: true),
  );
  final midiFile = MidiFile.fromByteData(ByteData.sublistView(midi));
  final seq = MidiFileSequencer(synth);
  seq.play(midiFile, loop: false);
  final n = ((midiFile.length.inMicroseconds / 1e6 + _tailSec) * _sr).ceil();
  final left = Float32List(n), right = Float32List(n);
  seq.render(left, right);
  return (left: left, right: right);
}

// ── stereo PCM16 WAV writer (wav_codec's encoder mono-folds + normalizes;
// for A/B listening we keep raw stereo levels, just clamped) ──
Uint8List _encodeWavStereo16(Float32List left, Float32List right) {
  final n = left.length;
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
  data.setUint32(24, _sr, Endian.little);
  data.setUint32(28, _sr * 4, Endian.little); // byte rate
  data.setUint16(32, 4, Endian.little); // block align
  data.setUint16(34, 16, Endian.little);
  wr(36, 'data');
  data.setUint32(40, n * 4, Endian.little);
  var off = 44;
  int pcm(double v) {
    final s = v.clamp(-1.0, 1.0);
    return (s < 0 ? s * 0x8000 : s * 0x7fff).round();
  }

  for (var i = 0; i < n; i++) {
    data.setInt16(off, pcm(left[i]), Endian.little);
    data.setInt16(off + 2, pcm(right[i]), Endian.little);
    off += 4;
  }
  return data.buffer.asUint8List();
}

({double peak, double rms}) _stats(Float32List left, Float32List right) {
  var peak = 0.0, sumSq = 0.0;
  for (var i = 0; i < left.length; i++) {
    final al = left[i].abs(), ar = right[i].abs();
    if (al > peak) peak = al;
    if (ar > peak) peak = ar;
    sumSq += left[i] * left[i] + right[i] * right[i];
  }
  return (peak: peak, rms: math.sqrt(sumSq / (left.length * 2)));
}

String _pct(double v) => '${(v * 100).toStringAsFixed(1)}%';

void main() {
  final sw = Stopwatch()..start();
  final jobs = <(String kind, int bank, int program, String label)>[
    for (final (p, label) in _melodic) ('mel', 0, p, label),
    for (final (p, label) in _kits) ('kit', 128, p, label),
  ];

  // results[bankId][file stem] = (peak, missing)
  final peaks = <String, Map<String, double>>{};
  final missing = <String, Set<String>>{};

  for (final entry in _banks.entries) {
    final bankId = entry.key;
    final sf2Path = entry.value;
    final sf2 = File(sf2Path).readAsBytesSync();
    print('\n── $bankId: $sf2Path (${(sf2.length / 1024 / 1024).toStringAsFixed(1)} MB) ──');

    // preset inventory → flag requested (bank, program) pairs melty can't find
    // (it silently falls back to another preset, which would skew the A/B).
    // SoundFont itself isn't in the package's umbrella export; reach the parsed
    // presets through a Synthesizer, same parse path the renders use.
    final inventory = Synthesizer.loadByteData(
      ByteData.sublistView(sf2),
      SynthesizerSettings(sampleRate: _sr, enableReverbAndChorus: true),
    ).soundFont.presets;
    final have = {for (final p in inventory) (p.bankNumber << 16) | p.patchNumber};
    print('presets in file: ${inventory.length}');
    peaks[bankId] = {};
    missing[bankId] = {};
    for (final (kind, bank, program, label) in jobs) {
      if (!have.contains((bank << 16) | program)) {
        final stem = '$kind${program.toString().padLeft(3, '0')} $label';
        missing[bankId]!.add(stem);
        print('  MISSING preset bank $bank prog $program ($label) — render will be a fallback voice');
      }
    }

    final outDir = Directory('$_outRoot\\$bankId')..createSync(recursive: true);
    for (final (kind, bank, program, label) in jobs) {
      final stem = '$kind${program.toString().padLeft(3, '0')} $label';
      final midi = _buildPhraseMidi(program, drum: bank == 128);
      final r = _render(sf2, midi);
      final s = _stats(r.left, r.right);
      peaks[bankId]![stem] = s.peak;
      final file = File('${outDir.path}\\$stem.wav');
      file.writeAsBytesSync(_encodeWavStereo16(r.left, r.right));
      final flag = s.peak < 0.01 ? '  << NEAR-SILENT' : '';
      print('  $stem.wav  peak=${_pct(s.peak)} rms=${_pct(s.rms)}$flag');
    }
  }

  // ── summary table ──
  print('\n── summary (peak %) ──');
  print('${'program'.padRight(24)}${'timgm'.padRight(10)}${'gugs'.padRight(10)}flags');
  var problems = 0;
  for (final (kind, _, program, label) in jobs) {
    final stem = '$kind${program.toString().padLeft(3, '0')} $label';
    final flags = <String>[];
    for (final bankId in _banks.keys) {
      if (missing[bankId]!.contains(stem)) flags.add('$bankId:MISSING');
      if ((peaks[bankId]![stem] ?? 0) < 0.01) flags.add('$bankId:SILENT');
    }
    if (flags.isNotEmpty) problems++;
    print('${stem.padRight(24)}'
        '${_pct(peaks['timgm']![stem] ?? 0).padRight(10)}'
        '${_pct(peaks['gugs']![stem] ?? 0).padRight(10)}'
        '${flags.join(' ')}');
  }
  print('\n${jobs.length} phrases × ${_banks.length} banks rendered to $_outRoot '
      'in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)}s — '
      '${problems == 0 ? 'no missing/silent presets' : '$problems program(s) flagged'}.');
}
