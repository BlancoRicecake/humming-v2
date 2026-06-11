// HumTrack — on-device WAV / Stems render via dart_melty_soundfont.
//
// Unlike the old oscillator render, this plays the song's MIDI (buildMidi) back
// through the SAME TimGM6mb.sf2 used for live playback — so the exported WAV
// matches the timbre you hear in the editor (FluidSynth vs MeltySynth differ
// only subtly). buildMidi already covers all five lanes (melody/bass/melodyDec/
// drums/beatDec), so stems and the full mix include the decoration tracks too.
//
// The heavy render runs in a background isolate via compute(): the SF2 bytes are
// loaded on the main isolate (rootBundle) and passed in, since rootBundle isn't
// available inside a plain isolate.
//
// Vocal is audio-only (m4a). It can't be decoded/mixed in pure Dart, so the
// full-mix WAV is the instrumental; each section's vocal recording is included
// in Stems as a separate file.
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/loop_models.dart';
import 'instruments.dart';
import 'midi_export.dart';
import 'song_util.dart';
import 'theory.dart';

const int _sr = 44100;
const String _sfAsset = 'assets/sounds/TimGM6mb.sf2';
const String _sf808Asset = 'assets/sounds/808.sf2';
// Render past the last note-off so reverb/release tails aren't cut.
const double _tailSec = 1.2;

// ── SF2 asset bytes (loaded on the main isolate, passed into compute) ──
Future<Uint8List> _sf2Bytes() async {
  final bd = await rootBundle.load(_sfAsset);
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

Future<Uint8List> _sf808Bytes() async {
  final bd = await rootBundle.load(_sf808Asset);
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

// ── isolate render ──────────────────────────────────────────────────
// Input: a['sf2s'] = list of SoundFont blobs; a['jobs'] = list of {sf2:int(index
// into sf2s), midi:Uint8List}; a['mix'] = bool. Each job renders its MIDI through
// its own SoundFont — this is how the 808 bass lane (a second SF2) is mixed with
// the GM lanes. When mix=true the job buffers are summed into one WAV; otherwise
// one WAV per job (stems).
List<Uint8List> _renderIso(Map<String, dynamic> a) {
  final sf2s = (a['sf2s'] as List).cast<Uint8List>();
  final jobs = (a['jobs'] as List).cast<Map>();
  final sampleRate = a['sampleRate'] as int;
  final tailSec = a['tail'] as double;
  final mix = a['mix'] as bool;

  final lefts = <Float32List>[];
  final rights = <Float32List>[];
  var maxN = 0;
  for (final job in jobs) {
    final synth = Synthesizer.loadByteData(
      ByteData.sublistView(sf2s[job['sf2'] as int]),
      SynthesizerSettings(sampleRate: sampleRate, enableReverbAndChorus: true),
    );
    final midiFile = MidiFile.fromByteData(ByteData.sublistView(job['midi'] as Uint8List));
    final seq = MidiFileSequencer(synth);
    seq.play(midiFile, loop: false);

    final totalSec = midiFile.length.inMicroseconds / 1e6 + tailSec;
    final n = (totalSec * sampleRate).ceil();
    if (n > maxN) maxN = n;
    final left = Float32List(n);
    final right = Float32List(n);
    seq.render(left, right);
    lefts.add(left);
    rights.add(right);
  }

  if (!mix) {
    return [for (var i = 0; i < lefts.length; i++) _encodeWav(lefts[i], rights[i], sampleRate)];
  }
  // Sum all job buffers (different lengths possible) into one mix.
  final left = Float32List(maxN);
  final right = Float32List(maxN);
  for (var j = 0; j < lefts.length; j++) {
    final l = lefts[j], r = rights[j];
    for (var i = 0; i < l.length; i++) {
      left[i] += l[i];
      right[i] += r[i];
    }
  }
  return [_encodeWav(left, right, sampleRate)];
}

// Mono 16-bit PCM WAV from interleaved L/R float buffers.
Uint8List _encodeWav(Float32List left, Float32List right, int sr) {
  final len = left.length;
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
  data.setUint32(24, sr, Endian.little);
  data.setUint32(28, sr * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  wr(36, 'data');
  data.setUint32(40, len * 2, Endian.little);
  var off = 44;
  for (var i = 0; i < len; i++) {
    final s = ((left[i] + right[i]) * 0.5).clamp(-1.0, 1.0);
    data.setInt16(off, (s < 0 ? s * 0x8000 : s * 0x7fff).round(), Endian.little);
    off += 2;
  }
  return data.buffer.asUint8List();
}

// Debug-only: report duration + level so an export can be sanity-checked from
// logs (non-silent? right length?) without pulling the file off-device.
void _logWavStats(String tag, String path, Uint8List wav) {
  if (!kDebugMode) return;
  final samples = (wav.length - 44) ~/ 2;
  final sec = samples / _sr;
  final bd = ByteData.sublistView(wav, 44);
  var peak = 0;
  var sumSq = 0.0;
  for (var i = 0; i + 1 < bd.lengthInBytes; i += 2) {
    final s = bd.getInt16(i, Endian.little);
    final a = s.abs();
    if (a > peak) peak = a;
    sumSq += s * s.toDouble();
  }
  final rms = samples > 0 ? math.sqrt(sumSq / samples) : 0.0;
  debugPrint('[export] $tag ${path.split('/').last}: '
      '${(wav.length / 1024).toStringAsFixed(0)}KB, ${sec.toStringAsFixed(2)}s, '
      'peak=${(peak / 32768 * 100).toStringAsFixed(1)}% rms=${(rms / 32768 * 100).toStringAsFixed(1)}%');
}

// ── public API ──────────────────────────────────────────────────────
Future<String> _exportPath(String title, String ext) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/looptap/exports');
  if (!await folder.exists()) await folder.create(recursive: true);
  final safe = title.trim().isEmpty ? 'loop' : title.trim().replaceAll(RegExp(r'[^\w\- ]+'), '_');
  return '${folder.path}/$safe.$ext';
}

/// Full-mix instrumental WAV — all five lanes. When the bass uses the 808 (no GM
/// slot) the bass lane renders through 808.sf2 and the rest through the GM SF2,
/// then the two are summed so the mix matches live playback.
Future<File> exportWavSong(
  List<Section> sections,
  int bpm,
  double swing,
  Map<String, double> vol,
  String title, {
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
  List<TrackRef> extras = const [],
  Map<String, int> instruments = const {},
}) async {
  final flat = flattenSong(sections);
  final use808 = bassProgram == kProgram808;

  List<Uint8List> sf2s;
  List<Map<String, Object>> jobs;
  if (use808) {
    // rest = all GM lanes (base minus bass) + every added instance.
    final restTracks = {'melody', 'melodyDec', 'drums', 'beatDec', for (final e in extras) e.id};
    final rest = buildMidi(flat, bpm,
        melodyProgram: melodyProgram,
        bassProgram: bassProgram,
        melodyDecProgram: melodyDecProgram,
        swing: swing,
        vol: vol,
        tracks: restTracks,
        extras: extras,
        extraInstruments: instruments);
    // bassProgram 0 → selects the 808.sf2's single preset.
    final bassMidi = buildMidi(flat, bpm,
        bassProgram: 0, swing: swing, vol: vol, tracks: const {'bass'});
    sf2s = [await _sf2Bytes(), await _sf808Bytes()];
    jobs = [
      {'sf2': 0, 'midi': rest},
      {'sf2': 1, 'midi': bassMidi},
    ];
  } else {
    final midi = buildMidi(flat, bpm,
        melodyProgram: melodyProgram,
        bassProgram: bassProgram,
        melodyDecProgram: melodyDecProgram,
        swing: swing,
        vol: vol,
        extras: extras,
        extraInstruments: instruments);
    sf2s = [await _sf2Bytes()];
    jobs = [
      {'sf2': 0, 'midi': midi},
    ];
  }
  final wavs = await compute(_renderIso, {
    'sf2s': sf2s,
    'jobs': jobs,
    'mix': true,
    'sampleRate': _sr,
    'tail': _tailSec,
  });
  final f = File(await _exportPath(title, 'wav'));
  await f.writeAsBytes(wavs.first);
  _logWavStats('WAV mix', f.path, wavs.first);
  return f;
}

/// One WAV per non-empty instrument lane + each section's vocal recording.
Future<List<File>> exportStems(
  List<Section> sections,
  int bpm,
  double swing,
  Map<String, double> vol,
  String title, {
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
  List<TrackRef> extras = const [],
  Map<String, int> instruments = const {},
}) async {
  final flat = flattenSong(sections);
  final labelOf = {for (final m in sectionTrackMetas(extras)) m.id: m.label};
  // present lanes: non-empty base lanes + non-empty added instances.
  final present = <({String id, String label})>[
    if (flat.melody.isNotEmpty) (id: 'melody', label: 'melody'),
    if (flat.bass.isNotEmpty) (id: 'bass', label: 'bass'),
    if (flat.melodyDec.isNotEmpty) (id: 'melodyDec', label: 'melodyDec'),
    if (flat.drums.isNotEmpty) (id: 'drums', label: 'drums'),
    if (flat.beatDec.isNotEmpty) (id: 'beatDec', label: 'beatDec'),
    for (final e in extras)
      if ((flat.extraPitched[e.id]?.isNotEmpty ?? false) ||
          (flat.extraDrums[e.id]?.isNotEmpty ?? false))
        (id: e.id, label: labelOf[e.id] ?? e.id),
  ];
  final out = <File>[];

  if (present.isNotEmpty) {
    final use808 = bassProgram == kProgram808;
    final jobs = <Map<String, Object>>[
      for (final p in present)
        {
          'sf2': (p.id == 'bass' && use808) ? 1 : 0,
          'midi': buildMidi(flat, bpm,
              melodyProgram: melodyProgram,
              // 808 bass stem → program 0 selects the 808.sf2 preset.
              bassProgram: (p.id == 'bass' && use808) ? 0 : bassProgram,
              melodyDecProgram: melodyDecProgram,
              swing: swing,
              vol: vol,
              tracks: {p.id},
              extras: extras,
              extraInstruments: instruments),
        },
    ];
    final wavs = await compute(_renderIso, {
      'sf2s': [await _sf2Bytes(), if (use808) await _sf808Bytes()],
      'jobs': jobs,
      'mix': false,
      'sampleRate': _sr,
      'tail': _tailSec,
    });
    for (var i = 0; i < present.length; i++) {
      final f = File(await _exportPath('$title - ${present[i].label}', 'wav'));
      await f.writeAsBytes(wavs[i]);
      _logWavStats('stem ${present[i].label}', f.path, wavs[i]);
      out.add(f);
    }
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
