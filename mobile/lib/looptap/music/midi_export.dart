// LoopTap — Standard MIDI File (format 0) export. Ported from export.jsx
// buildMidi: piano ch1, fingered bass ch2 (prog 33), drums GM ch10. The whole
// song is flattened (sections × repeats) onto one timeline.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/loop_models.dart';
import 'instruments.dart';
import 'song_util.dart';
import 'soundfont_catalog.dart';
import 'theory.dart';

const Map<String, int> _drumNote = {
  'kick': 36,
  'snare': 38,
  'hihat': 42,
  'shaker': 82,
  'tambourine': 54,
  'clap': 39,
};

class _Ev {
  _Ev(this.t, this.data);
  final int t;
  final List<int> data;
}

List<int> _vlq(int n) {
  final b = [n & 0x7f];
  n >>= 7;
  while (n > 0) {
    b.insert(0, (n & 0x7f) | 0x80);
    n >>= 7;
  }
  return b;
}

/// [swing] shifts odd steps later by `swing*0.5` of a step (groove match with
/// live playback). [tracks] limits which lanes are emitted (null = all) — used
/// for per-stem rendering. [vol] sets per-channel CC7 volume from the mixer
/// (null = no CC7). All three default to no-op, so the plain `.mid` export
/// (exportMidiSong) is byte-identical to before.
Uint8List buildMidi(FlatSong flat, int bpm,
    {int melodyProgram = 0,
    int bassProgram = 33,
    int melodyDecProgram = 48,
    int drumProgram = 0,
    double swing = 0,
    Set<String>? tracks,
    Map<String, double>? vol,
    List<TrackRef> extras = const [],
    Map<String, int> extraInstruments = const {}}) {
  const tpq = 96;
  final tps = tpq / kStepsPerBeat;
  final evs = <_Ev>[];
  final mpq = (60000000 / bpm).round();
  // A Standard MIDI File can only carry GM programs (0–127); the 808 sentinel
  // (and any out-of-range value) falls back to the nearest GM voice.
  int gm(int p) => p > 127 ? kProgram808MidiFallback : p;
  evs.add(_Ev(0, [0xFF, 0x51, 0x03, (mpq >> 16) & 0xff, (mpq >> 8) & 0xff, mpq & 0xff]));
  evs.add(_Ev(0, [0xC0, gm(melodyProgram) & 0x7f])); // ch0 melody instrument
  evs.add(_Ev(0, [0xC1, gm(bassProgram) & 0x7f])); // ch1 bass instrument
  evs.add(_Ev(0, [0xC2, gm(melodyDecProgram) & 0x7f])); // ch2 melody-fill instrument
  // ch9 drum kit (GM bank-128 program). Skip program 0 (Standard, the default) so
  // the plain .mid export stays byte-identical when no kit is chosen.
  if (drumProgram > 0 && drumProgram <= 127) {
    evs.add(_Ev(0, [0xC9, drumProgram & 0x7f]));
  }

  // Per-channel volume (CC7) from the mixer — only when rendering audio.
  if (vol != null) {
    int cc(double? v) => ((v ?? 0.85).clamp(0.0, 1.0) * 127).round().clamp(0, 127);
    evs.add(_Ev(0, [0xB0, 0x07, cc(vol['melody'])])); // ch0
    evs.add(_Ev(0, [0xB1, 0x07, cc(vol['bass'])])); // ch1
    evs.add(_Ev(0, [0xB2, 0x07, cc(vol['melodyDec'] ?? vol['melody'])])); // ch2
    evs.add(_Ev(0, [0xB9, 0x07, cc(vol['drums'])])); // ch9 (drums + beat-fill share)
  }

  // Swing-aware step→tick: odd steps nudged later by swing*0.5 of a step.
  double onTick(int step) => (step + (step.isOdd ? swing * 0.5 : 0)) * tps;
  bool want(String t) => tracks == null || tracks.contains(t);

  void addPitched(List<PitchNote> notes, int ch) {
    for (final n in notes) {
      final on = onTick(n.step);
      evs.add(_Ev(on.round(), [0x90 | ch, n.midi, 100]));
      evs.add(_Ev((on + n.dur * tps).round(), [0x80 | ch, n.midi, 0]));
    }
  }

  if (want('melody')) addPitched(flat.melody, 0);
  if (want('bass')) addPitched(flat.bass, 1);
  if (want('melodyDec')) addPitched(flat.melodyDec, 2);

  // both percussion tracks (main drums + beat-fill) → GM ch9
  void addDrums(List<DrumNote> notes) {
    for (final n in notes) {
      final pitch = _drumNote[n.kind];
      if (pitch == null) continue;
      final on = onTick(n.step);
      evs.add(_Ev(on.round(), [0x99, pitch, 100])); // ch9 (GM drums)
      evs.add(_Ev((on + tps).round(), [0x89, pitch, 0]));
    }
  }

  if (want('drums')) addDrums(flat.drums);
  if (want('beatDec')) addDrums(flat.beatDec);

  // added track instances — each on its allocated channel (pitched) or ch9 (drums).
  if (extras.isNotEmpty) {
    final metas = sectionTrackMetas(extras);
    final chOf = {for (final mt in metas) mt.id: mt.channel};
    int cc(double? v) => ((v ?? 0.85).clamp(0.0, 1.0) * 127).round().clamp(0, 127);
    for (final ref in extras) {
      if (!want(ref.id)) continue;
      final base = trackById(ref.type);
      if (base.kind == TrackKind.drums) {
        addDrums(flat.extraDrums[ref.id] ?? const []);
      } else {
        final ch = chOf[ref.id] ?? 0;
        final prog = extraInstruments[ref.id] ?? base.defaultProgram;
        evs.add(_Ev(0, [0xC0 | ch, gm(prog) & 0x7f]));
        if (vol != null) evs.add(_Ev(0, [0xB0 | ch, 0x07, cc(vol[ref.id])]));
        addPitched(flat.extraPitched[ref.id] ?? const [], ch);
      }
    }
  }

  // stable sort by time (preserve insertion order for equal times)
  final indexed = [for (var i = 0; i < evs.length; i++) (i, evs[i])];
  indexed.sort((a, b) {
    final c = a.$2.t.compareTo(b.$2.t);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final sorted = [for (final e in indexed) e.$2];
  // End of track at the loop end, but never before the last event — a note held
  // past the loop boundary would otherwise make the EOT delta negative (corrupt
  // VLQ / wrong length). Take the later of the two.
  final loopEnd = (flat.steps * tps).round();
  final lastEv = sorted.isEmpty ? 0 : sorted.last.t;
  sorted.add(_Ev(loopEnd < lastEv ? lastEv : loopEnd, [0xFF, 0x2F, 0x00]));

  final body = <int>[];
  var prev = 0;
  for (final e in sorted) {
    body.addAll(_vlq(e.t - prev));
    body.addAll(e.data);
    prev = e.t;
  }
  final len = body.length;
  final trk = [0x4D, 0x54, 0x72, 0x6B, (len >> 24) & 255, (len >> 16) & 255, (len >> 8) & 255, len & 255, ...body];
  final head = [0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, (tpq >> 8) & 255, tpq & 255];
  return Uint8List.fromList([...head, ...trk]);
}

/// Write the song's MIDI to Documents/looptap/exports/[title].mid and return
/// the file. (Share-sheet integration is a follow-up once share_plus resolves —
/// it's a project dep but absent from this checkout's package_config.)
Future<File> exportMidiSong(
  List<Section> sections,
  int bpm,
  String title, {
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
  int drumProgram = 0,
  List<TrackRef> extras = const [],
  Map<String, int> instruments = const {},
}) async {
  final flat = flattenSong(sections);
  // A .mid can't carry a custom soundfont — fall back to the nearest GM voice:
  // hip-hop kit → its GM kit; runtime-catalog slots → the entry's midi_fallback.
  int gmOf(int p) => isDynamicSlot(p) ? SoundfontCatalog.instance.midiFallback(p) : p;
  final gmKit = drumProgram == kProgramHipHopKit
      ? kProgramHipHopKitMidiFallback
      : gmOf(drumProgram);
  final gmInstruments = {for (final e in instruments.entries) e.key: gmOf(e.value)};
  final bytes = buildMidi(flat, bpm,
      melodyProgram: gmOf(melodyProgram),
      bassProgram: gmOf(bassProgram),
      melodyDecProgram: gmOf(melodyDecProgram),
      drumProgram: gmKit,
      extras: extras,
      extraInstruments: gmInstruments);
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/looptap/exports');
  if (!await folder.exists()) await folder.create(recursive: true);
  final safe = title.trim().isEmpty ? 'loop' : title.trim().replaceAll(RegExp(r'[^\w\-]+'), '_');
  final file = File('${folder.path}/$safe.mid');
  await file.writeAsBytes(bytes);
  if (kDebugMode) {
    final hdrOk = bytes.length > 14 &&
        bytes[0] == 0x4D && bytes[1] == 0x54 && bytes[2] == 0x68 && bytes[3] == 0x64;
    final eotOk = bytes.length > 3 &&
        bytes[bytes.length - 3] == 0xFF && bytes[bytes.length - 2] == 0x2F;
    debugPrint('[export] MIDI ${file.path.split('/').last}: ${bytes.length}B '
        'hdrOK=$hdrOk eotOK=$eotOk steps=${flat.steps} bpm=$bpm');
  }
  return file;
}
