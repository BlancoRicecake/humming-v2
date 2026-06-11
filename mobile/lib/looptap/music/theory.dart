// LoopTap music theory + transport constants — ported 1:1 from prototype/engine.jsx.
// In-key ladders so you can't play a wrong note; 16th-note grid transport math.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/atoms.dart';
import '../theme/tokens.dart';

const List<String> kNoteNames = [
  'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B',
];

class ScaleDef {
  const ScaleDef(this.label, this.steps);
  final String label;
  final List<int> steps;
}

/// pentatonic = minor pentatonic — "can't-miss" default.
const Map<String, ScaleDef> kScales = {
  'minor': ScaleDef('minor', [0, 2, 3, 5, 7, 8, 10]),
  'major': ScaleDef('major', [0, 2, 4, 5, 7, 9, 11]),
  'pentatonic': ScaleDef('penta', [0, 3, 5, 7, 10]),
  'dorian': ScaleDef('dorian', [0, 2, 3, 5, 7, 9, 10]),
};

double midiToFreq(int m) => 440 * math.pow(2, (m - 69) / 12).toDouble();

/// Root note name -> midi of that note in octave [oct] (C4 = 60).
int rootMidi(String name, int oct) => 12 * (oct + 1) + kNoteNames.indexOf(name);

/// A single rung of an in-key ladder.
class Rung {
  const Rung({
    required this.midi,
    required this.name,
    required this.degree,
    required this.freq,
    required this.index,
  });

  final int midi;
  final String name;
  final int degree;
  final double freq;
  final int index;
}

/// Build an in-key ladder of [count] ascending scale degrees from root/oct.
List<Rung> buildLadder(String name, String mode, int oct, int count) {
  final steps = (kScales[mode] ?? kScales['minor']!).steps;
  final base = rootMidi(name, oct);
  final out = <Rung>[];
  for (var i = 0; i < count; i++) {
    final deg = i % steps.length;
    final octShift = i ~/ steps.length;
    final midi = base + steps[deg] + 12 * octShift;
    out.add(Rung(
      midi: midi,
      name: kNoteNames[midi % 12],
      degree: deg,
      freq: midiToFreq(midi),
      index: i,
    ));
  }
  return out;
}

/// Root + in-key 3rd + 5th (a diatonic triad) for chord-mode pad input.
/// Ported from the legacy lib/music/chords.dart: builds the song's scale as a
/// pitch-class set, walks a local ladder around [rootMidi], and takes scale
/// degrees i, i+2, i+4. Falls back to a major triad if the key/scale is unknown.
List<int> diatonicTriad(int rootMidi, String tonic, String scale) {
  final rootPc = kNoteNames.indexOf(tonic);
  final steps = kScales[scale]?.steps;
  if (rootPc < 0 || steps == null) {
    return [rootMidi, rootMidi + 4, rootMidi + 7];
  }
  final pcSet = steps.map((iv) => (rootPc + iv) % 12).toSet();
  final ladder = <int>[];
  for (var m = rootMidi - 12; m <= rootMidi + 24; m++) {
    if (pcSet.contains(((m % 12) + 12) % 12)) ladder.add(m);
  }
  final i = ladder.indexWhere((m) => m >= rootMidi);
  if (i < 0) return [rootMidi, rootMidi + 4, rootMidi + 7];
  final root = ladder[i];
  final third = (i + 2 < ladder.length) ? ladder[i + 2] : root + 4;
  final fifth = (i + 4 < ladder.length) ? ladder[i + 4] : root + 7;
  return [root, third, fifth];
}

// ── Transport constants (16th grid) ─────────────────────────────────
const int kBeatsPerBar = 4;
const int kStepsPerBeat = 4;
int stepsForBars(int bars) => bars * kBeatsPerBar * kStepsPerBeat;

/// Track kinds.
enum TrackKind { pitched, bass, drums, vocal }

class TrackMeta {
  const TrackMeta(
    this.id,
    this.label,
    this.icon,
    this.color,
    this.kind, {
    this.channel = 0,
    this.defaultProgram = 0,
    this.group = '',
    this.decoration = false,
    this.drumKinds,
  });
  final String id;
  final String label;
  final IconData icon;
  final Color color;
  final TrackKind kind;

  /// MIDI channel for live playback + export. Pitched tracks get distinct
  /// channels (melody 0, bass 1, melody-fill 2); percussion tracks share ch9.
  final int channel;

  /// Default GM program (pitched tracks only; percussion ignores it).
  final int defaultProgram;

  /// Layer group — main + decoration tracks of the same group are paired
  /// ('melody' | 'bass' | 'beat' | 'vocal').
  final String group;

  /// A decoration ("꾸밈") layer rather than a main track.
  final bool decoration;

  /// Percussion kinds for drum tracks (drives the drum surface + note map).
  final List<String>? drumKinds;

  TrackMeta copyWith({String? id, String? label, int? channel}) => TrackMeta(
        id ?? this.id,
        label ?? this.label,
        icon,
        color,
        kind,
        channel: channel ?? this.channel,
        defaultProgram: defaultProgram,
        group: group,
        decoration: decoration,
        drumKinds: drumKinds,
      );
}

/// An added track instance: a unique [id] plus the base track [type] it copies
/// (one of the kTracks ids). The fixed base tracks aren't TrackRefs — only the
/// user-added extras are.
class TrackRef {
  const TrackRef(this.id, this.type);
  final String id;
  final String type;

  Map<String, dynamic> toJson() => {'id': id, 'type': type};
  static TrackRef fromJson(Map<String, dynamic> j) =>
      TrackRef(j['id'] as String, j['type'] as String);
}

/// Six tracks: main + decoration layers. Order = arrangement strip order
/// (decoration rows sit right under their main row). `kTracks` is the single
/// source of truth — data/audio/export/UI all iterate it instead of hardcoding
/// the track ids.
const List<TrackMeta> kTracks = [
  TrackMeta('melody', 'Melody', LtIcons.piano, LT.lime, TrackKind.pitched,
      channel: 0, defaultProgram: 0, group: 'melody'),
  TrackMeta('melodyDec', 'Melody Fill', LtIcons.piano, LT.lime, TrackKind.pitched,
      channel: 2, defaultProgram: 48, group: 'melody', decoration: true),
  TrackMeta('bass', 'Bass', LtIcons.audiotrack, LT.blue, TrackKind.bass,
      channel: 1, defaultProgram: 33, group: 'bass'),
  TrackMeta('drums', 'Drums', LtIcons.graphicEq, LT.amber, TrackKind.drums,
      channel: 9, group: 'beat', drumKinds: ['hihat', 'snare', 'kick']),
  TrackMeta('beatDec', 'Beat Fill', LtIcons.graphicEq, LT.amber, TrackKind.drums,
      channel: 9, group: 'beat', decoration: true, drumKinds: ['shaker', 'tambourine', 'clap']),
  TrackMeta('vocal', 'Vocal', LtIcons.mic, LT.pink, TrackKind.vocal, group: 'vocal'),
];

/// The pitched/bass tracks (melody, melody-fill, bass) — used wherever code
/// needs to iterate the instrument-bearing voices.
List<TrackMeta> get kPitchedTracks =>
    kTracks.where((t) => t.kind == TrackKind.pitched || t.kind == TrackKind.bass).toList();

TrackMeta trackById(String id) => kTracks.firstWhere((t) => t.id == id);

/// Pitched MIDI channels still free after the base tracks claim 0,1,2 (melody,
/// bass, melody-fill) and 9 (drums). Added pitched instances draw from here so
/// each gets its own instrument; drum instances all share ch9.
const List<int> kExtraPitchChannels = [3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15];

/// The full ordered track-meta list for a section: the fixed base tracks
/// (kTracks, channels unchanged) followed by [extras], each given an allocated
/// channel and a numbered label (e.g. "Melody 2"). The base case (no extras) is
/// exactly kTracks, so existing songs/playback/export are unchanged.
List<TrackMeta> sectionTrackMetas(List<TrackRef> extras) {
  final out = <TrackMeta>[...kTracks];
  if (extras.isEmpty) return out;
  final perType = <String, int>{for (final t in kTracks) t.id: 1};
  var pi = 0;
  for (final e in extras) {
    final base = trackById(e.type);
    final n = perType[e.type] = (perType[e.type] ?? 1) + 1;
    final ch = base.kind == TrackKind.drums
        ? 9
        : base.kind == TrackKind.vocal
            ? 0
            : (pi < kExtraPitchChannels.length ? kExtraPitchChannels[pi++] : kExtraPitchChannels.last);
    out.add(base.copyWith(id: e.id, label: '${base.label} $n', channel: ch));
  }
  return out;
}
