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

// ── Guitar voicing + strum (validated in SoundLab "기타 연구소") ──────
/// Real 6-string guitar range, standard tuning: open low E (E2=40) to the
/// 24th fret of the high E (E6=88). Guitar voicings are clamped here.
const int kGuitarLo = 40; // E2
const int kGuitarHi = 88; // E6

/// A guitar-style spread voicing for chord-mode pad input. Takes the diatonic
/// root/3rd/5th and re-voices it like a strummed barre/open 6-string shape: the
/// bass root drops to the low guitar register (~E2) with the 5th, octave, 3rd,
/// 5th and high octave stacked above (the open-E / barre shape), clamped to the
/// real guitar range. Intervals stay diatonic (so e.g. vii° keeps its dim 5th).
List<int> guitarVoicing(int rootMidi, String tonic, String scale) {
  final triad = diatonicTriad(rootMidi, tonic, scale);
  final rootPc = ((triad[0] % 12) + 12) % 12;
  final thirdInterval = ((triad[1] - triad[0]) % 12 + 12) % 12; // 3 (min) or 4 (maj)
  final fifthInterval = ((triad[2] - triad[0]) % 12 + 12) % 12; // 6 / 7 / 8
  // Lowest instance of the root's pitch class at/above E2 — the 6th/5th-string
  // bass position a guitarist would fret the chord from.
  final bass = kGuitarLo + ((rootPc - kGuitarLo) % 12 + 12) % 12;
  final offsets = [0, fifthInterval, 12, 12 + thirdInterval, 12 + fifthInterval, 24];
  final out = <int>{};
  for (final o in offsets) {
    final m = bass + o;
    if (m >= kGuitarLo && m <= kGuitarHi) out.add(m);
  }
  final list = out.toList()..sort();
  return list.isEmpty ? triad : list;
}

/// A power chord (5th) for chord-mode pad input: root + perfect 5th + octave.
/// No third, so it's key/scale-agnostic (sounds the same in major or minor) —
/// exactly how a guitarist plays a power chord.
List<int> powerChord(int rootMidi) => [rootMidi, rootMidi + 7, rootMidi + 12];

/// A guitar-register power chord: drops the root to the low guitar register
/// (~E2) and stacks the 5th + octave above, clamped to the real guitar range.
/// Reuses [guitarVoicing]'s bass-position logic; only the offsets differ (the
/// root/5th/octave power-chord shape instead of the full triad voicing).
List<int> guitarPowerVoicing(int rootMidi) {
  final rootPc = ((rootMidi % 12) + 12) % 12;
  final bass = kGuitarLo + ((rootPc - kGuitarLo) % 12 + 12) % 12;
  const offsets = [0, 7, 12]; // root, perfect 5th, octave
  final out = <int>{};
  for (final o in offsets) {
    final m = bass + o;
    if (m >= kGuitarLo && m <= kGuitarHi) out.add(m);
  }
  final list = out.toList()..sort();
  return list.isEmpty ? powerChord(rootMidi) : list;
}

/// Guitar strum profile — the lab-confirmed defaults. [strumMs] is the gap
/// between successive strings; [velocityFalloff] is the fraction the
/// last-struck string is quieter than the first (humanizes the pick sweep).
class GuitarStrum {
  const GuitarStrum({this.strumMs = 28, this.velocityFalloff = 0.18, this.down = true});
  final int strumMs;
  final double velocityFalloff;
  final bool down; // true = down-stroke (low→high), false = up-stroke (high→low)
}

const GuitarStrum kGuitarStrum = GuitarStrum();

/// Per-note strum schedule for a set of simultaneous chord notes: ordered by
/// the stroke direction, each note gets an onset delay (ms) and a velocity
/// scale. Shared by live play, sequencer playback and MIDI export so the strum
/// is identical everywhere.
List<({int midi, int delayMs, double velScale})> strumPlan(
  List<int> midis, {
  GuitarStrum profile = kGuitarStrum,
}) {
  final ordered = [...midis]..sort();
  if (!profile.down) {
    final r = ordered.reversed.toList();
    ordered
      ..clear()
      ..addAll(r);
  }
  final n = ordered.length;
  return [
    for (var i = 0; i < n; i++)
      (
        midi: ordered[i],
        delayMs: i * profile.strumMs,
        velScale: 1.0 - profile.velocityFalloff * (n > 1 ? i / (n - 1) : 0.0),
      ),
  ];
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
  // Beat-fill is its own track with an independent kit, so it lives on its own
  // channel (10) rather than sharing the drums' ch9. (Live only — export renders
  // each drum lane as a separate ch9 job through its kit.)
  TrackMeta('beatDec', 'Beat Fill', LtIcons.graphicEq, LT.amber, TrackKind.drums,
      channel: 10, group: 'beat', decoration: true, drumKinds: ['shaker', 'tambourine', 'clap']),
  TrackMeta('vocal', 'Vocal', LtIcons.mic, LT.pink, TrackKind.vocal, group: 'vocal'),
];

/// Audio lane — behaves EXACTLY like the base Vocal track (records, edits, and
/// plays an audio clip via the same VocalClip model), but it is user-ADDABLE and
/// named "Audio" with a distinct violet so several can coexist for overlapping
/// takes / layered parts. Not one of the fixed base [kTracks]; added as an extra
/// instance, and picked up by vocal-kind logic (export/bounce) like any vocal.
const TrackMeta kAudioTrack = TrackMeta(
    'audio', 'Audio', LtIcons.audiotrack, Color(0xFFA78BFA), TrackKind.vocal,
    group: 'vocal');

/// The track TYPES the add-track picker offers: every base track (Vocal too —
/// it can now be instanced for layered/overlapping takes) plus the Audio lane.
List<TrackMeta> get kAddableTracks => [...kTracks, kAudioTrack];

/// Beat-fill launchpad percussion palette — the sounds a Fill pad can play.
/// Each must exist in kDrumNote (audio), _drumNote (midi_export) and kDrumSpecs
/// (drum_surface) — the three maps are a documented mirror. kick/snare/hihat are
/// main-kit only and intentionally NOT here.
const List<String> kFillPalette = [
  'clap', 'shaker', 'tambourine', 'cowbell', 'maracas', 'claves',
  'rimshot', 'woodhi', 'woodlo', 'ride', 'crash', 'triangle',
];

/// Default 6 Fill pad assignments (one per launchpad pad). Includes the legacy
/// shaker/tambourine/clap so old songs' Fill notes still land on a pad.
const List<String> kFillKindsDefault = [
  'clap', 'shaker', 'tambourine', 'cowbell', 'maracas', 'claves',
];

/// The pitched/bass tracks (melody, melody-fill, bass) — used wherever code
/// needs to iterate the instrument-bearing voices.
List<TrackMeta> get kPitchedTracks =>
    kTracks.where((t) => t.kind == TrackKind.pitched || t.kind == TrackKind.bass).toList();

TrackMeta trackById(String id) =>
    id == kAudioTrack.id ? kAudioTrack : kTracks.firstWhere((t) => t.id == id);

/// MIDI channels free after the base tracks claim 0,1,2 (melody, bass,
/// melody-fill), 9 (drums) and 15 (metronome click). Added track instances —
/// pitched AND drums — each draw a distinct channel from here so they get an
/// independent instrument/kit. (FluidSynth on Android + AVAudioUnitSampler on
/// iOS both play a bank-128 kit on any channel, so a drum instance need not be
/// on ch9.)
const List<int> kExtraPitchChannels = [3, 4, 5, 6, 7, 8, 11, 12, 13, 14];

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
    // Vocal stays nominal ch0 (audio-only, no synth voice); every other added
    // instance — pitched or drums — gets its own channel so its kit/instrument
    // is independent of the base tracks and of other instances.
    final ch = base.kind == TrackKind.vocal
        ? 0
        : (pi < kExtraPitchChannels.length ? kExtraPitchChannels[pi++] : kExtraPitchChannels.last);
    out.add(base.copyWith(id: e.id, label: '${base.label} $n', channel: ch));
  }
  return out;
}
