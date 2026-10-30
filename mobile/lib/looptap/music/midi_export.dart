// LoopTap — Standard MIDI File (format 0) export. Ported from export.jsx
// buildMidi: piano ch1, fingered bass ch2 (prog 33), drums GM ch10. The whole
// song is flattened (sections × repeats) onto one timeline.
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/loop_models.dart';
import 'groove.dart';
import 'guitar_articulation.dart';
import 'guitar_stroke.dart';
import 'instruments.dart';
import 'pan.dart';
import 'song_util.dart';
import 'soundfont_catalog.dart';
import 'theory.dart';
import 'percussion.dart';

// MIRROR of kDrumNote (loop_audio.dart) — keep in sync. See [drum_mirror_test].
const Map<String, int> _drumNote = {
  'kick': 36,
  'snare': 38,
  'hihat': 42,
  'shaker': 82,
  'tambourine': 54,
  'clap': 39,
  'cowbell': 56,
  'maracas': 70,
  'claves': 75,
  'rimshot': 37,
  'woodhi': 76,
  'woodlo': 77,
  'ride': 51,
  'crash': 57,
  'triangle': 81,
};

/// The drum kinds this exporter knows — exposed so a mirror test can assert it
/// matches kDrumNote (loop_audio.dart).
Set<String> get midiDrumKinds => _drumNote.keys.toSet();

class _Ev {
  _Ev(this.t, this.data, {this.release = false});
  final int t;
  final List<int> data;

  /// A note-off that ends a note started at an earlier tick (never the off
  /// of a zero-length note, which must stay after its own on).
  final bool release;
}

/// gt-002: within one tick, a release (note-off of an earlier note) of a
/// channel+pitch goes before a note-on of the same channel+pitch, so a
/// same-string choke or a re-struck pitch never has its new note cut by the
/// old note's off. Ticks without such a pair keep their order exactly.
List<_Ev> _releaseBeforeOn(List<_Ev> sorted) {
  int? keyOf(_Ev e) =>
      e.data.length == 3 && e.data[0] & 0xF0 == 0x90
          ? (e.data[0] & 0x0F) << 8 | e.data[1]
          : null;
  int? offKey(_Ev e) =>
      e.release ? (e.data[0] & 0x0F) << 8 | e.data[1] : null;
  final out = <_Ev>[];
  var i = 0;
  while (i < sorted.length) {
    var j = i;
    while (j < sorted.length && sorted[j].t == sorted[i].t) {
      j++;
    }
    final run = sorted.sublist(i, j);
    i = j;
    final seenOn = <int>{};
    var conflict = false;
    for (final e in run) {
      final on = keyOf(e), off = offKey(e);
      if (on != null) seenOn.add(on);
      if (off != null && seenOn.contains(off)) conflict = true;
    }
    if (!conflict) {
      out.addAll(run);
      continue;
    }
    final moved = <int>{};
    for (var k = 0; k < run.length; k++) {
      if (moved.contains(k)) continue;
      final on = keyOf(run[k]);
      if (on != null) {
        for (var q = k + 1; q < run.length; q++) {
          if (!moved.contains(q) && offKey(run[q]) == on) {
            out.add(run[q]);
            moved.add(q);
          }
        }
      }
      out.add(run[k]);
    }
  }
  return out;
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
/// (exportMidiSong) is byte-identical to before. [pan] (mixer-001) adds a
/// per-channel CC10 at t=0: on EVERY channel when rendering audio ([vol] set),
/// otherwise only where p != 0 — so an all-centre `.mid` stays byte-identical.
/// ch9 carries pan['drums'] (all drum lanes share it in a plain `.mid`).
///
/// gt-003: [articulations] routes articulated guitar notes (null = ignore
/// them, the pre-G3 output). With [articulationRole] null every note is
/// written on its track channel at its sounding pitch with the articulation
/// gate and velocity (the `.mid`; the GM 28/31 timbre is not encoded).
/// [ArtRole.track] writes only the notes that stay on the track channel (a
/// lane's audio render); a voice role writes only that role's notes on its
/// articulation channel (program, CC7 and CC10 of the lane first) and none
/// of the track channels' set-up, so it never touches them.
Uint8List buildMidi(
  FlatSong flat,
  int bpm, {
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
  int drumProgram = 0,
  double swing = 0,
  Set<String>? tracks,
  Map<String, double>? vol,
  List<TrackRef> extras = const [],
  Map<String, int> extraInstruments = const {},
  bool strumGuitar = false,
  Map<String, double>? pan,
  ArticulationPlan? articulations,
  ArtRole? articulationRole,
}) {
  final voiceJob =
      articulationRole != null && articulationRole != ArtRole.track;
  final articulated =
      articulations != null &&
      articulations.hasArticulations &&
      [
        ...flat.melody,
        ...flat.bass,
        ...flat.melodyDec,
        ...flat.extraPitched.values.expand((n) => n),
      ].any((n) => n.articulation != null);
  final precise =
      articulated ||
      [
        ...flat.melody,
        ...flat.bass,
        ...flat.melodyDec,
        ...flat.extraPitched.values.expand((n) => n),
      ].any((n) => n.durationSteps != null || n.offsetSteps != 0) ||
      [
        ...flat.drums,
        ...flat.beatDec,
        ...flat.extraDrums.values.expand((n) => n),
      ].any((n) => n.durationSteps != null || n.offsetSteps != 0);
  final tpq = precise ? 9600 : 96;
  final tps = tpq / kStepsPerBeat;
  // ms → ticks for guitar strum offsets (tpq ticks per quarter at this bpm).
  double msToTicks(int ms) => ms * tpq * bpm / 60000.0;
  final evs = <_Ev>[];
  final mpq = (60000000 / bpm).round();
  // A Standard MIDI File can only carry GM programs (0–127); the 808 sentinel
  // (and any out-of-range value) falls back to the nearest GM voice.
  int gm(int p) => p > 127 ? kProgram808MidiFallback : p;
  evs.add(
    _Ev(0, [
      0xFF,
      0x51,
      0x03,
      (mpq >> 16) & 0xff,
      (mpq >> 8) & 0xff,
      mpq & 0xff,
    ]),
  );
  if (!voiceJob) {
    evs.add(_Ev(0, [0xC0, gm(melodyProgram) & 0x7f])); // ch0 melody instrument
    evs.add(_Ev(0, [0xC1, gm(bassProgram) & 0x7f])); // ch1 bass instrument
    evs.add(
      _Ev(0, [0xC2, gm(melodyDecProgram) & 0x7f]),
    ); // ch2 melody-fill instrument
  }
  // ch9 drum kit (GM bank-128 program). Skip program 0 (Standard, the default) so
  // the plain .mid export stays byte-identical when no kit is chosen.
  if (!voiceJob && drumProgram > 0 && drumProgram <= 127) {
    evs.add(_Ev(0, [0xC9, drumProgram & 0x7f]));
  }

  // Per-channel volume (CC7) from the mixer — only when rendering audio.
  if (vol != null && !voiceJob) {
    int cc(double? v) =>
        ((v ?? 0.85).clamp(0.0, 1.0) * 127).round().clamp(0, 127);
    evs.add(_Ev(0, [0xB0, 0x07, cc(vol['melody'])])); // ch0
    evs.add(_Ev(0, [0xB1, 0x07, cc(vol['bass'])])); // ch1
    evs.add(_Ev(0, [0xB2, 0x07, cc(vol['melodyDec'] ?? vol['melody'])])); // ch2
    evs.add(
      _Ev(0, [0xB9, 0x07, cc(vol['drums'])]),
    ); // ch9 (drums + beat-fill share)
  }

  // Per-channel pan (CC10) — every channel when rendering, else only p != 0.
  void addPan(int ch, String id) {
    if (pan == null || voiceJob) return;
    final p = clampPan(pan[id]);
    if (vol == null && p == 0) return;
    evs.add(_Ev(0, [0xB0 | ch, 0x0A, panToCc(p)]));
  }

  addPan(0, 'melody');
  addPan(1, 'bass');
  addPan(2, 'melodyDec');
  addPan(9, 'drums');

  // Swing-aware step→tick: odd steps nudged later by swing*0.5 of a step.
  // Self-timed (grooved) lanes already carry their timing (groove-001).
  double onTick(int step, String lane) =>
      (step +
          (step.isOdd && !flat.selfTimed.contains(lane) ? swing * 0.5 : 0)) *
      tps;
  bool want(String t) => tracks == null || tracks.contains(t);

  void emit(int ch, int midi, double on, num dur, int vel) {
    final a = on.round(), b = (on + dur * tps).round();
    evs.add(_Ev(a, [0x90 | ch, midi, vel]));
    evs.add(_Ev(b, [0x80 | ch, midi, 0], release: b > a));
  }

  // gt-003: one pitched note through the shared realize step. Without a
  // plan it is exactly [emit]. A voice job's set-up (program, CC7 = the
  // lane's volume exactly as its track channel gets it, CC10 = its pan) goes
  // on the articulation channel once, at t=0, before its first note.
  final voiceSetUp = <int>{};
  // the GM program of the lane addPitched is writing (r4 .mid set-up)
  var laneProgram = 0;
  final voiceNotes = <({int ch, int key, double on, double off, int vel})>[];
  void emitNote(
    PitchNote n,
    String lane,
    int ch,
    int midi,
    double on,
    num dur,
    int vel,
  ) {
    if (articulations == null) {
      if (!voiceJob) emit(ch, midi, on, dur, vel);
      return;
    }
    final ev = realizeArticulation(
      n,
      articulations.contextFor(lane, bpm),
      velocity: vel,
      gateSteps: dur.toDouble(),
      soundingMidi: midi,
    );
    final v = ev.velocity ?? vel;
    // the role channel's set-up, once, at t=0 before its first note: the
    // program, the lane's volume (CC7, audio renders only) and pan (CC10,
    // same rule as the lane's own channel)
    void setUp(int ach, int program) {
      if (!voiceSetUp.add(ach)) return;
      evs.add(_Ev(0, [0xC0 | ach, program & 0x7f]));
      if (vol != null) {
        final cc = ((vol[lane] ?? 0.85).clamp(0.0, 1.0) * 127)
            .round()
            .clamp(0, 127);
        evs.add(_Ev(0, [0xB0 | ach, 0x07, cc]));
      }
      if (pan != null) {
        final p = clampPan(pan[lane]);
        if (vol != null || p != 0) {
          evs.add(_Ev(0, [0xB0 | ach, 0x0A, panToCc(p)]));
        }
      }
    }

    if (articulationRole == null) {
      // .mid: sounding pitch and articulation gate. A palm/harmonic note
      // whose role has a plan channel goes on that channel (r4) with the
      // OWNER track's GM program, so it never cuts an overlapping normal
      // note of the same pitch; staccato and fallbacks stay on the track.
      if (ev.channel == null) {
        emit(ch, ev.soundingMidi, on, ev.gateSteps, v);
        return;
      }
      setUp(ev.channel!, gm(laneProgram));
      voiceNotes.add((
        ch: ev.channel!,
        key: ev.soundingMidi,
        on: on,
        off: on + ev.gateSteps * tps,
        vel: v,
      ));
      return;
    }
    if (ev.role != articulationRole) return;
    if (ev.role == ArtRole.track) {
      emit(ch, ev.key, on, ev.gateSteps, v);
      return;
    }
    final ach = ev.channel!;
    setUp(ach, ev.program!);
    voiceNotes.add((
      ch: ach,
      key: ev.key,
      on: on,
      off: on + ev.gateSteps * tps,
      vel: v,
    ));
  }

  // [program] decides guitar (strum); [strumGuitar] forces it on (used by the
  // WAV exporter's dynamic-soundfont guitar lanes, whose program arg is the
  // SF2's internal preset, not a GM guitar number).
  void addPitched(List<PitchNote> notes, int ch, int program, String lane) {
    laneProgram = program;
    if (!(strumGuitar || isGuitarProgram(program))) {
      for (final n in notes) {
        emitNote(
          n,
          lane,
          ch,
          n.midi,
          onTick(n.step, lane) + n.offsetSteps * tps,
          n.soundingSteps,
          n.velocity ?? 100,
        );
      }
      return;
    }
    // Guitar: strum simultaneous notes — order by pitch, offset each string a
    // few ms and soften it, matching live + sequencer playback.
    final byStep = <int, List<PitchNote>>{};
    for (final n in notes) {
      (byStep[n.step] ??= <PitchNote>[]).add(n);
    }
    for (final group in byStep.values) {
      if (group.length < 2 ||
          group.any(
            (n) =>
                n.velocity != null ||
                n.offsetSteps != 0 ||
                n.durationSteps != null ||
                n.stroke != null ||
                n.articulation != null,
          )) {
        // Match live playback per step: precise edits must not change the
        // strumming or strengths of untouched chords elsewhere in the lane.
        for (final n in group) {
          emitNote(
            n,
            lane,
            ch,
            n.midi,
            onTick(n.step, lane) + n.offsetSteps * tps,
            n.soundingSteps,
            n.velocity ?? 100,
          );
        }
        continue;
      }
      // index-stable pairing (gt-001): duplicate pitches keep their own note
      for (final s in strumPairs(group)) {
        final n = s.note;
        emitNote(
          n,
          lane,
          ch,
          s.midi,
          onTick(n.step, lane) + msToTicks(s.delayMs),
          n.dur,
          (100 * s.velScale).round().clamp(1, 127),
        );
      }
    }
  }

  if (want('melody')) addPitched(flat.melody, 0, melodyProgram, 'melody');
  if (want('bass')) addPitched(flat.bass, 1, bassProgram, 'bass');
  if (want('melodyDec')) {
    addPitched(flat.melodyDec, 2, melodyDecProgram, 'melodyDec');
  }

  // both percussion tracks (main drums + beat-fill) → GM ch9
  void addDrums(List<DrumNote> notes, String lane) {
    if (voiceJob) return;
    for (final n in notes) {
      final pitch = percussionMidi(n.kind);
      if (pitch == null) continue;
      final on = onTick(n.step, lane) + n.offsetSteps * tps;
      evs.add(
        _Ev(on.round(), [0x99, pitch, n.velocity ?? 100]),
      ); // ch9 (GM drums)
      evs.add(
        _Ev((on + (n.durationSteps ?? 1) * tps).round(), [0x89, pitch, 0]),
      );
    }
  }

  if (want('drums')) addDrums(flat.drums, 'drums');
  if (want('beatDec')) addDrums(flat.beatDec, 'beatDec');

  // added track instances — each on its allocated channel (pitched) or ch9 (drums).
  if (extras.isNotEmpty) {
    final metas = sectionTrackMetas(extras);
    final chOf = {for (final mt in metas) mt.id: mt.channel};
    int cc(double? v) =>
        ((v ?? 0.85).clamp(0.0, 1.0) * 127).round().clamp(0, 127);
    for (final ref in extras) {
      if (!want(ref.id)) continue;
      final base = trackById(ref.type);
      if (base.kind == TrackKind.drums) {
        addDrums(flat.extraDrums[ref.id] ?? const [], ref.id);
      } else {
        final ch = chOf[ref.id] ?? 0;
        final prog = extraInstruments[ref.id] ?? base.defaultProgram;
        if (!voiceJob) {
          evs.add(_Ev(0, [0xC0 | ch, gm(prog) & 0x7f]));
          if (vol != null) {
            evs.add(_Ev(0, [0xB0 | ch, 0x07, cc(vol[ref.id])]));
          }
        }
        addPan(ch, ref.id);
        addPitched(flat.extraPitched[ref.id] ?? const [], ch, prog, ref.id);
      }
    }
  }

  // gt-003: articulation voices. One channel cannot sound one key twice, so
  // a same-key note on the same articulation channel ends the earlier one
  // at its onset (G2 rule); the off-before-on order of equal ticks follows
  // from the release flag below.
  if (voiceNotes.isNotEmpty) {
    final byKey = <int, List<int>>{};
    for (var i = 0; i < voiceNotes.length; i++) {
      final v = voiceNotes[i];
      (byKey[v.ch << 8 | v.key] ??= <int>[]).add(i);
    }
    final off = [for (final v in voiceNotes) v.off];
    for (final idx in byKey.values) {
      idx.sort((x, y) {
        final c = voiceNotes[x].on.compareTo(voiceNotes[y].on);
        return c != 0 ? c : x.compareTo(y);
      });
      for (var k = 0; k + 1 < idx.length; k++) {
        final next = voiceNotes[idx[k + 1]].on;
        if (next < off[idx[k]]) off[idx[k]] = next;
      }
    }
    for (var i = 0; i < voiceNotes.length; i++) {
      final v = voiceNotes[i];
      final a = v.on.round(), b = off[i].round();
      evs.add(_Ev(a, [0x90 | v.ch, v.key, v.vel]));
      evs.add(_Ev(b, [0x80 | v.ch, v.key, 0], release: b > a));
    }
  }

  // stable sort by time (preserve insertion order for equal times)
  final indexed = [for (var i = 0; i < evs.length; i++) (i, evs[i])];
  indexed.sort((a, b) {
    final c = a.$2.t.compareTo(b.$2.t);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final sorted = _releaseBeforeOn([for (final e in indexed) e.$2]);
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
  final trk = [
    0x4D,
    0x54,
    0x72,
    0x6B,
    (len >> 24) & 255,
    (len >> 16) & 255,
    (len >> 8) & 255,
    len & 255,
    ...body,
  ];
  final head = [
    0x4D,
    0x54,
    0x68,
    0x64,
    0,
    0,
    0,
    6,
    0,
    0,
    0,
    1,
    (tpq >> 8) & 255,
    tpq & 255,
  ];
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
  String fallbackName = 'loop',
  int? variationSeed,
  bool includeAllNotes = false,
  GrooveContext? groove,
  Map<String, double> pan = const {},
  ArticulationPlan? articulations,
}) async {
  // One fixed variation of chance/velocity variation (same as WAV/stems), or
  // every non-muted note as written when [includeAllNotes] is set. The .mid
  // has never carried Swing, so grooved lanes bake only their grooves.
  final flat = flattenSong(
    sections,
    variationSeed: includeAllNotes ? null : variationSeed,
    groove:
        groove == null
            ? null
            : GrooveContext(
              grooves: groove.grooves,
              trackGrooves: groove.trackGrooves,
              amount: groove.amount,
            ),
  );
  // A .mid can't carry a custom soundfont — fall back to the nearest GM voice:
  // hip-hop kit → its GM kit; runtime-catalog slots → the entry's midi_fallback.
  int gmOf(int p) =>
      isDynamicSlot(p) ? SoundfontCatalog.instance.midiFallback(p) : p;
  final gmKit =
      drumProgram == kProgramHipHopKit
          ? kProgramHipHopKitMidiFallback
          : gmOf(drumProgram);
  final gmInstruments = {
    for (final e in instruments.entries) e.key: gmOf(e.value),
  };
  final bytes = buildMidi(
    flat,
    bpm,
    melodyProgram: gmOf(melodyProgram),
    bassProgram: gmOf(bassProgram),
    melodyDecProgram: gmOf(melodyDecProgram),
    drumProgram: gmKit,
    extras: extras,
    extraInstruments: gmInstruments,
    pan: pan,
    // gt-003: sounding pitch + articulation gate on the track channel
    articulations:
        articulations ??
        ArticulationPlan.build(sections: sections, instruments: instruments),
  );
  final folder = await exportsFolder(); // created + backup-excluded (C18)
  // shared sanitiser (C11): non-ASCII titles survive; never overwrite (A20).
  final file = await uniqueExportFile(
    folder,
    exportFileName(title, fallback: fallbackName),
    'mid',
  );
  await writeExportFile(file, bytes);
  if (kDebugMode) {
    final hdrOk =
        bytes.length > 14 &&
        bytes[0] == 0x4D &&
        bytes[1] == 0x54 &&
        bytes[2] == 0x68 &&
        bytes[3] == 0x64;
    final eotOk =
        bytes.length > 3 &&
        bytes[bytes.length - 3] == 0xFF &&
        bytes[bytes.length - 2] == 0x2F;
    debugPrint(
      '[export] MIDI ${file.path.split('/').last}: ${bytes.length}B '
      'hdrOK=$hdrOk eotOK=$eotOk steps=${flat.steps} bpm=$bpm',
    );
  }
  return file;
}
