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

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/loop_models.dart';
import 'midi_export.dart';
import 'song_util.dart';

const int _sr = 44100;
const String _sfAsset = 'assets/sounds/TimGM6mb.sf2';
// Render past the last note-off so reverb/release tails aren't cut.
const double _tailSec = 1.2;

// ── SF2 asset bytes (loaded on the main isolate, passed into compute) ──
Future<Uint8List> _sf2Bytes() async {
  final bd = await rootBundle.load(_sfAsset);
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

// ── isolate render: SF2 bytes + one or more MIDI byte-blobs → WAV bytes ──
// Loads the SoundFont once and renders each MIDI through MidiFileSequencer.
List<Uint8List> _renderIso(Map<String, dynamic> a) {
  final sf2 = ByteData.sublistView(a['sf2'] as Uint8List);
  final midis = (a['midis'] as List).cast<Uint8List>();
  final sampleRate = a['sampleRate'] as int;
  final tailSec = a['tail'] as double;

  final out = <Uint8List>[];
  for (final m in midis) {
    final synth = Synthesizer.loadByteData(
      sf2,
      SynthesizerSettings(sampleRate: sampleRate, enableReverbAndChorus: true),
    );
    final midiFile = MidiFile.fromByteData(ByteData.sublistView(m));
    final seq = MidiFileSequencer(synth);
    seq.play(midiFile, loop: false);

    final totalSec = midiFile.length.inMicroseconds / 1e6 + tailSec;
    final n = (totalSec * sampleRate).ceil();
    final left = Float32List(n);
    final right = Float32List(n);
    seq.render(left, right);

    out.add(_encodeWav(left, right, sampleRate));
  }
  return out;
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

// ── public API ──────────────────────────────────────────────────────
Future<String> _exportPath(String title, String ext) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/looptap/exports');
  if (!await folder.exists()) await folder.create(recursive: true);
  final safe = title.trim().isEmpty ? 'loop' : title.trim().replaceAll(RegExp(r'[^\w\- ]+'), '_');
  return '${folder.path}/$safe.$ext';
}

/// Full-mix instrumental WAV — all five lanes through the SF2.
Future<File> exportWavSong(
  List<Section> sections,
  int bpm,
  double swing,
  Map<String, double> vol,
  String title, {
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
}) async {
  final flat = flattenSong(sections);
  final midi = buildMidi(flat, bpm,
      melodyProgram: melodyProgram,
      bassProgram: bassProgram,
      melodyDecProgram: melodyDecProgram,
      swing: swing,
      vol: vol);
  final wavs = await compute(_renderIso, {
    'sf2': await _sf2Bytes(),
    'midis': <Uint8List>[midi],
    'sampleRate': _sr,
    'tail': _tailSec,
  });
  final f = File(await _exportPath(title, 'wav'));
  await f.writeAsBytes(wavs.first);
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
}) async {
  final flat = flattenSong(sections);
  final present = <String>[
    if (flat.melody.isNotEmpty) 'melody',
    if (flat.bass.isNotEmpty) 'bass',
    if (flat.melodyDec.isNotEmpty) 'melodyDec',
    if (flat.drums.isNotEmpty) 'drums',
    if (flat.beatDec.isNotEmpty) 'beatDec',
  ];
  final out = <File>[];

  if (present.isNotEmpty) {
    final midis = [
      for (final t in present)
        buildMidi(flat, bpm,
            melodyProgram: melodyProgram,
            bassProgram: bassProgram,
            melodyDecProgram: melodyDecProgram,
            swing: swing,
            vol: vol,
            tracks: {t}),
    ];
    final wavs = await compute(_renderIso, {
      'sf2': await _sf2Bytes(),
      'midis': midis,
      'sampleRate': _sr,
      'tail': _tailSec,
    });
    for (var i = 0; i < present.length; i++) {
      final f = File(await _exportPath('$title - ${present[i]}', 'wav'));
      await f.writeAsBytes(wavs[i]);
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
