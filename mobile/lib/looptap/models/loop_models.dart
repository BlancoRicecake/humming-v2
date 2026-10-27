// LoopTap data model — README §State management.
// Song -> sections[] -> tracks{melody,bass,drums,vocal} -> notes/clip.
// JSON round-trips to <Documents>/looptap/songs.json (single list, like the
// prototype's localStorage["looptap_songs_v1"]).
import 'dart:convert';

import '../music/groove.dart';
import '../music/guitar_tuning.dart';
import '../music/note_random.dart';
import '../music/pan.dart';
import '../music/theory.dart';

/// gt-001: direction of a converted guitar stroke. Down sweeps low → high
/// strings, up sweeps high → low.
enum StrokeDir { down, up }

/// gt-001: marks a note that an explicit guitar stroke rewrote, with the
/// stroke's parameters and the note's exact pre-conversion timing/strength
/// (null-ness included) so "revert" restores the original note exactly.
/// Immutable, so sharing it between copies is a deep copy.
class StrokeTag {
  const StrokeTag({
    required this.dir,
    required this.spreadMs,
    required this.falloff,
    required this.accent,
    required this.order,
    required this.baseDur,
    required this.baseOffsetSteps,
    this.baseVelocity,
    this.baseDurationSteps,
  });

  final StrokeDir dir;

  /// Gap between successive strings in ms (re-apply recomputes the step
  /// offsets at the song's current BPM).
  final double spreadMs;

  /// Fraction the last string is quieter than the first (0..0.4).
  final double falloff;

  /// Velocity multiplier for the whole hit (0.5..1.3).
  final double accent;

  /// String position of this note within its hit (0 = struck first).
  final int order;

  /// The note's values before conversion.
  final int baseDur;
  final double baseOffsetSteps;
  final int? baseVelocity;
  final double? baseDurationSteps;

  Map<String, dynamic> toJson() => {
    'dir': dir.name,
    'spreadMs': spreadMs,
    'falloff': falloff,
    'accent': accent,
    'order': order,
    'baseDur': baseDur,
    'baseOffsetSteps': baseOffsetSteps,
    if (baseVelocity != null) 'baseVelocity': baseVelocity,
    if (baseDurationSteps != null) 'baseDurationSteps': baseDurationSteps,
  };

  /// Null for a missing or unreadable tag (the note then loads as untagged).
  static StrokeTag? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final dir = StrokeDir.values.where((d) => d.name == j['dir']).firstOrNull;
    final dur = j['baseDur'], off = j['baseOffsetSteps'];
    if (dir == null || dur is! num || off is! num) return null;
    return StrokeTag(
      dir: dir,
      spreadMs: (j['spreadMs'] as num?)?.toDouble() ?? 28,
      falloff: (j['falloff'] as num?)?.toDouble() ?? .18,
      accent: (j['accent'] as num?)?.toDouble() ?? 1,
      order: (j['order'] as num?)?.toInt() ?? 0,
      baseDur: dur.toInt(),
      baseOffsetSteps: off.toDouble(),
      baseVelocity: (j['baseVelocity'] as num?)?.toInt().clamp(1, 127),
      baseDurationSteps: (j['baseDurationSteps'] as num?)?.toDouble(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StrokeTag &&
      other.dir == dir &&
      other.spreadMs == spreadMs &&
      other.falloff == falloff &&
      other.accent == accent &&
      other.order == order &&
      other.baseDur == baseDur &&
      other.baseOffsetSteps == baseOffsetSteps &&
      other.baseVelocity == baseVelocity &&
      other.baseDurationSteps == baseDurationSteps;

  @override
  int get hashCode => Object.hash(
    dir,
    spreadMs,
    falloff,
    accent,
    order,
    baseDur,
    baseOffsetSteps,
    baseVelocity,
    baseDurationSteps,
  );
}

/// gt-003: a guitar articulation. [staccato] shortens the note on the
/// track's own sound; [palmTone] and [harmonicTone] are labelled tone
/// approximations (GM 28 / GM 31) on a dedicated articulation channel.
enum ArticulationKind { staccato, palmTone, harmonicTone }

/// gt-003: lowest/highest sounding pitch the GM 31 harmonic tone supports
/// (engine key S − 24 in 50..86; partial-structure proxy, both engines).
const int kHarmonicToneLo = 74;
const int kHarmonicToneHi = 110;

/// gt-003: pitch range of the GM 28 palm tone — the standard guitar range,
/// render-checked at both ends (the preset's key range ends at 118; keys
/// above 88 use a different, 8 kHz sample and are not verified).
const int kPalmToneLo = 40;
const int kPalmToneHi = 86;

/// Whether an articulation of [kind] may sit on a note of pitch [midi].
bool articulationFits(ArticulationKind kind, int midi) => switch (kind) {
  ArticulationKind.staccato => true,
  ArticulationKind.palmTone => midi >= kPalmToneLo && midi <= kPalmToneHi,
  ArticulationKind.harmonicTone =>
    midi >= kHarmonicToneLo && midi <= kHarmonicToneHi,
};

/// gt-003: the articulation a note was given, snapshotted at apply time
/// (review ①): later preference changes never alter a saved note. Immutable.
class Articulation {
  const Articulation({required this.kind, this.gateMs, this.velScale = 1.0});

  final ArticulationKind kind;

  /// Gate cap in ms (the note sounds for at most this long); null = the
  /// note's own length.
  final int? gateMs;

  /// Velocity multiplier applied after the stroke velocity.
  final double velScale;

  Map<String, dynamic> toJson() => {
    'kind': kind.name,
    if (gateMs != null) 'gateMs': gateMs,
    if (velScale != 1.0) 'velScale': velScale,
  };

  /// Null for a missing, unknown or unreadable value (the note then loads
  /// as normal).
  static Articulation? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind =
        ArticulationKind.values.where((k) => k.name == raw['kind']).firstOrNull;
    if (kind == null) return null;
    final gate = raw['gateMs'], vel = raw['velScale'];
    final v = vel is num ? vel.toDouble() : 1.0;
    return Articulation(
      kind: kind,
      gateMs: gate is num && gate > 0 ? gate.toInt() : null,
      velScale: v.isFinite && v > 0 ? v.clamp(0.05, 2.0).toDouble() : 1.0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Articulation &&
      other.kind == kind &&
      other.gateMs == gateMs &&
      other.velScale == velScale;

  @override
  int get hashCode => Object.hash(kind, gateMs, velScale);

  @override
  String toString() => 'Articulation(${kind.name}, $gateMs ms, x$velScale)';
}

/// A pitched note: { midi, freq, step, dur }.
class PitchNote {
  PitchNote({
    required this.midi,
    required this.freq,
    required this.step,
    this.dur = 1,
    this.sourceMidi,
    this.confidence = 1.0,
    this.assisted = false,
    this.locked = false,
    this.velocity,
    this.offsetSteps = 0,
    this.durationSteps,
    this.muted = false,
    double chance = 1.0,
    int velocityDeviation = 0,
    this.stroke,
    int? guitarString,
    bool stringLocked = false,
    int? ringBaseDur,
    double? ringBaseDurationSteps,
    Articulation? articulation,
  }) : chance = chance.clamp(0.0, 1.0).toDouble(),
       velocityDeviation = velocityDeviation.clamp(-127, 127).toInt(),
       // gt-002: a string the pitch cannot sound on is never kept (a
       // transpose/scale snap/arpeggiate result simply becomes unassigned)
       guitarString =
           guitarString != null && guitarPlayable(guitarString, midi)
               ? guitarString
               : null,
       stringLocked =
           stringLocked &&
           guitarString != null &&
           guitarPlayable(guitarString, midi),
       ringBaseDur = ringBaseDur,
       ringBaseDurationSteps =
           ringBaseDur == null ? null : ringBaseDurationSteps,
       // gt-003: a pitch the articulation cannot sound at drops it (a pitch
       // edit that leaves the supported range makes the note normal)
       articulation =
           articulation != null && articulationFits(articulation.kind, midi)
               ? articulation
               : null;

  final int midi;
  final double freq;
  int step;
  int dur;

  /// Pitch before key/scale correction. Null for notes entered by hand or from
  /// old projects. Keeping it makes raw-vs-corrected listening reversible.
  final int? sourceMidi;

  /// Analyzer confidence in the source note, normalized to 0..1.
  final double confidence;

  /// True when the analyzer or grid mapping changed [sourceMidi].
  final bool assisted;

  /// Generation/editing tools must preserve locked notes.
  final bool locked;

  /// Null keeps the legacy pad gain. Imported MIDI keeps its 1..127 strength.
  final int? velocity;

  /// Fractional position within the sixteenth cell; never quantize on import.
  final double offsetSteps;
  final double? durationSteps;

  /// A deactivated note stays on the grid (and in saves) but never sounds:
  /// playback, exports, previews and generation inputs skip it.
  final bool muted;

  /// Probability (0..1) that the note sounds on each loop pass.
  final double chance;

  /// Per-pass velocity variation range: the sounding velocity lands in
  /// [velocity, velocity + deviation] (or below for a negative value).
  final int velocityDeviation;

  /// gt-001: set only by an explicit guitar stroke conversion (see
  /// `music/guitar_stroke.dart`). Null for every other note.
  final StrokeTag? stroke;

  /// gt-002: the guitar string (1 = high E ... 6 = low E, standard tuning)
  /// this note is played on, or null = unassigned. Always playable for
  /// [midi] (the constructor drops an impossible one). The fret is derived
  /// (`guitarFret`), never stored.
  final int? guitarString;

  /// gt-002: [guitarString] was chosen by the user (automatic assignment
  /// keeps it). Cleared together with the string.
  final bool stringLocked;

  /// gt-002: the note's exact `dur` / `durationSteps` (null kept) before a
  /// ring or string-choke conversion changed its length. Null [ringBaseDur]
  /// = no ring applied. "울림 되돌리기" restores them exactly.
  final int? ringBaseDur;
  final double? ringBaseDurationSteps;

  /// gt-003: the note's articulation snapshot, or null = normal. Render-time
  /// only: pitch, timing, velocity, stroke and ring fields are never changed
  /// by it.
  final Articulation? articulation;

  /// This note with [articulation] set exactly (null = normal); every other
  /// field kept.
  PitchNote withArticulation(Articulation? articulation) => PitchNote(
    midi: midi,
    freq: freq,
    step: step,
    dur: dur,
    sourceMidi: sourceMidi,
    confidence: confidence,
    assisted: assisted,
    locked: locked,
    velocity: velocity,
    offsetSteps: offsetSteps,
    durationSteps: durationSteps,
    muted: muted,
    chance: chance,
    velocityDeviation: velocityDeviation,
    stroke: stroke,
    guitarString: guitarString,
    stringLocked: stringLocked,
    ringBaseDur: ringBaseDur,
    ringBaseDurationSteps: ringBaseDurationSteps,
    articulation: articulation,
  );

  /// This note with its pre-ring length restored and the ring base cleared
  /// (itself when no ring is applied).
  PitchNote ringReverted() =>
      ringBaseDur == null
          ? this
          : withRing(
            dur: ringBaseDur!,
            durationSteps: ringBaseDurationSteps,
            ringBaseDur: null,
            ringBaseDurationSteps: null,
          );

  /// This note with [dur], [durationSteps] and the ring base set exactly
  /// (nulls included); every other field kept.
  PitchNote withRing({
    required int dur,
    required double? durationSteps,
    required int? ringBaseDur,
    required double? ringBaseDurationSteps,
  }) => PitchNote(
    midi: midi,
    freq: freq,
    step: step,
    dur: dur,
    sourceMidi: sourceMidi,
    confidence: confidence,
    assisted: assisted,
    locked: locked,
    velocity: velocity,
    offsetSteps: offsetSteps,
    durationSteps: durationSteps,
    muted: muted,
    chance: chance,
    velocityDeviation: velocityDeviation,
    stroke: stroke,
    guitarString: guitarString,
    stringLocked: stringLocked,
    ringBaseDur: ringBaseDur,
    ringBaseDurationSteps: ringBaseDurationSteps,
    articulation: articulation,
  );
  double get soundingSteps => durationSteps ?? dur.toDouble();
  double get startSteps => step + offsetSteps;
  double get endSteps => startSteps + soundingSteps;

  /// A short imported note can cross a cell boundary even when [dur] is 1.
  bool overlapsCell(int cell) => startSteps < cell + 1 && endSteps > cell;

  PitchNote copyWith({
    int? midi,
    double? freq,
    int? step,
    int? dur,
    int? sourceMidi,
    double? confidence,
    bool? assisted,
    bool? locked,
    int? velocity,
    double? offsetSteps,
    double? durationSteps,
    bool? muted,
    double? chance,
    int? velocityDeviation,
    StrokeTag? stroke,
    bool clearStroke = false,
    int? guitarString,
    bool? stringLocked,
    bool clearGuitarString = false,
    bool clearRing = false,
    Articulation? articulation,
    bool clearArticulation = false,
  }) => PitchNote(
    midi: midi ?? this.midi,
    freq: freq ?? this.freq,
    step: step ?? this.step,
    dur: dur ?? this.dur,
    sourceMidi: sourceMidi ?? this.sourceMidi,
    confidence: confidence ?? this.confidence,
    assisted: assisted ?? this.assisted,
    locked: locked ?? this.locked,
    velocity: velocity ?? this.velocity,
    offsetSteps: offsetSteps ?? this.offsetSteps,
    durationSteps: durationSteps ?? this.durationSteps,
    muted: muted ?? this.muted,
    chance: chance ?? this.chance,
    velocityDeviation: velocityDeviation ?? this.velocityDeviation,
    stroke: clearStroke ? null : stroke ?? this.stroke,
    guitarString:
        clearGuitarString ? null : guitarString ?? this.guitarString,
    stringLocked: !clearGuitarString && (stringLocked ?? this.stringLocked),
    ringBaseDur: clearRing ? null : ringBaseDur,
    ringBaseDurationSteps: clearRing ? null : ringBaseDurationSteps,
    articulation:
        clearArticulation ? null : articulation ?? this.articulation,
  );

  /// This note with every field kept but [velocity], [offsetSteps], [dur],
  /// [durationSteps] and [stroke] set exactly (nulls included) — `copyWith`
  /// cannot clear a nullable field.
  PitchNote withTiming({
    required int dur,
    required double offsetSteps,
    required int? velocity,
    required double? durationSteps,
    required StrokeTag? stroke,
  }) => PitchNote(
    midi: midi,
    freq: freq,
    step: step,
    dur: dur,
    sourceMidi: sourceMidi,
    confidence: confidence,
    assisted: assisted,
    locked: locked,
    velocity: velocity,
    offsetSteps: offsetSteps,
    durationSteps: durationSteps,
    muted: muted,
    chance: chance,
    velocityDeviation: velocityDeviation,
    stroke: stroke,
    guitarString: guitarString,
    stringLocked: stringLocked,
    ringBaseDur: ringBaseDur,
    ringBaseDurationSteps: ringBaseDurationSteps,
    articulation: articulation,
  );

  Map<String, dynamic> toJson() => {
    'midi': midi,
    'freq': freq,
    'step': step,
    'dur': dur,
    if (sourceMidi != null) 'sourceMidi': sourceMidi,
    if (confidence != 1.0) 'confidence': confidence,
    if (assisted) 'assisted': true,
    if (locked) 'locked': true,
    if (velocity != null) 'velocity': velocity,
    if (offsetSteps != 0) 'offsetSteps': offsetSteps,
    if (durationSteps != null) 'durationSteps': durationSteps,
    if (muted) 'muted': true,
    if (chance != 1.0) 'chance': chance,
    if (velocityDeviation != 0) 'velocityDeviation': velocityDeviation,
    if (stroke != null) 'stroke': stroke!.toJson(),
    if (guitarString != null) 'guitarString': guitarString,
    if (stringLocked) 'stringLocked': true,
    if (ringBaseDur != null) 'ringBaseDur': ringBaseDur,
    if (ringBaseDurationSteps != null)
      'ringBaseDurationSteps': ringBaseDurationSteps,
    if (articulation != null) 'articulation': articulation!.toJson(),
  };

  static PitchNote fromJson(Map<String, dynamic> j) => PitchNote(
    midi: (j['midi'] as num).toInt(),
    freq: (j['freq'] as num).toDouble(),
    step: (j['step'] as num).toInt(),
    dur: (j['dur'] as num?)?.toInt() ?? 1,
    sourceMidi: (j['sourceMidi'] as num?)?.toInt(),
    confidence: (j['confidence'] as num?)?.toDouble() ?? 1.0,
    assisted: (j['assisted'] as bool?) ?? false,
    locked: (j['locked'] as bool?) ?? false,
    velocity: (j['velocity'] as num?)?.toInt().clamp(1, 127),
    offsetSteps: (j['offsetSteps'] as num?)?.toDouble() ?? 0,
    durationSteps: (j['durationSteps'] as num?)?.toDouble(),
    muted: (j['muted'] as bool?) ?? false,
    chance: (j['chance'] as num?)?.toDouble() ?? 1.0,
    velocityDeviation: (j['velocityDeviation'] as num?)?.toInt() ?? 0,
    stroke: StrokeTag.fromJson(j['stroke']),
    guitarString: (j['guitarString'] as num?)?.toInt(),
    stringLocked: (j['stringLocked'] as bool?) ?? false,
    ringBaseDur: (j['ringBaseDur'] as num?)?.toInt(),
    ringBaseDurationSteps: (j['ringBaseDurationSteps'] as num?)?.toDouble(),
    articulation: Articulation.fromJson(j['articulation']),
  );
}

/// A drum hit: { kind:'kick'|'snare'|'hihat', step }.
class DrumNote {
  DrumNote({
    required this.kind,
    required this.step,
    this.velocity,
    this.offsetSteps = 0,
    this.durationSteps,
    this.muted = false,
    double chance = 1.0,
    int velocityDeviation = 0,
  }) : chance = chance.clamp(0.0, 1.0).toDouble(),
       velocityDeviation = velocityDeviation.clamp(-127, 127).toInt();

  final String kind;
  int step;
  final int? velocity;
  final double offsetSteps;
  final double? durationSteps;

  /// A deactivated hit stays on the grid (and in saves) but never sounds.
  final bool muted;

  /// Probability (0..1) that the hit sounds on each loop pass.
  final double chance;

  /// Per-pass velocity variation range (see [PitchNote.velocityDeviation]).
  final int velocityDeviation;
  double get startSteps => step + offsetSteps;

  DrumNote copyWith({
    String? kind,
    int? step,
    int? velocity,
    double? offsetSteps,
    double? durationSteps,
    bool? muted,
    double? chance,
    int? velocityDeviation,
  }) => DrumNote(
    kind: kind ?? this.kind,
    step: step ?? this.step,
    velocity: velocity ?? this.velocity,
    offsetSteps: offsetSteps ?? this.offsetSteps,
    durationSteps: durationSteps ?? this.durationSteps,
    muted: muted ?? this.muted,
    chance: chance ?? this.chance,
    velocityDeviation: velocityDeviation ?? this.velocityDeviation,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'step': step,
    if (velocity != null) 'velocity': velocity,
    if (offsetSteps != 0) 'offsetSteps': offsetSteps,
    if (durationSteps != null) 'durationSteps': durationSteps,
    if (muted) 'muted': true,
    if (chance != 1.0) 'chance': chance,
    if (velocityDeviation != 0) 'velocityDeviation': velocityDeviation,
  };

  static DrumNote fromJson(Map<String, dynamic> j) => DrumNote(
    kind: j['kind'] as String,
    step: (j['step'] as num).toInt(),
    velocity: (j['velocity'] as num?)?.toInt().clamp(1, 127),
    offsetSteps: (j['offsetSteps'] as num?)?.toDouble() ?? 0,
    durationSteps: (j['durationSteps'] as num?)?.toDouble(),
    muted: (j['muted'] as bool?) ?? false,
    chance: (j['chance'] as num?)?.toDouble() ?? 1.0,
    velocityDeviation: (j['velocityDeviation'] as num?)?.toInt() ?? 0,
  );
}

/// One effect in the vocal clip's reproducible chain. [type] is a stable
/// local-library or legacy server effect ID; [params] stores its render knobs.
class FxNode {
  FxNode({
    required this.type,
    Map<String, dynamic>? params,
    this.enabled = true,
  }) : params = params ?? {};

  String type;
  Map<String, dynamic> params;
  bool enabled;

  FxNode copy() => FxNode(
    type: type,
    params: Map<String, dynamic>.from(params),
    enabled: enabled,
  );

  Map<String, dynamic> toJson() => {
    'type': type,
    'params': params,
    if (!enabled) 'enabled': false,
  };

  static FxNode fromJson(Map<String, dynamic> j) => FxNode(
    type: j['type'] as String,
    params: (j['params'] as Map?)?.cast<String, dynamic>() ?? {},
    enabled: (j['enabled'] as bool?) ?? true,
  );
}

/// One placed take on the vocal lane. The recording lives at [path] (basename
/// under Documents/looptap/vocals/); edits are non-destructive — [trimStart]/
/// [trimEnd] window the source, [gain]/[fadeInMs]/[fadeOutMs] shape it, and
/// [fx] records server effects applied. [startStep] is its position on the
/// section grid. [trimEnd] == -1 means "to the end of the source".
class VocalClip {
  VocalClip({
    required this.path,
    this.origPath,
    this.fxSourcePath,
    this.startStep = 0,
    this.durSteps = -1,
    this.trimStart = 0,
    this.trimEnd = -1,
    this.gain = 1.0,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    List<FxNode>? fx,
    List<double>? peaks,
  }) : fx = fx ?? [],
       peaks = peaks ?? [];

  String path;
  String? origPath;

  /// Input to the recorded FX chain. May already contain legacy autotune;
  /// [origPath] still points to the earliest dry recording for full restoration.
  String? fxSourcePath;
  int startStep;

  /// The chunk's length on the grid in 16th steps, for arrangement display.
  /// -1 = unknown (drawn to the section end) until the editor measures the take.
  int durSteps;
  int trimStart;
  int trimEnd;
  double gain;
  int fadeInMs;
  int fadeOutMs;
  final List<FxNode> fx;
  List<double> peaks;

  VocalClip copy() => VocalClip(
    path: path,
    origPath: origPath,
    fxSourcePath: fxSourcePath,
    startStep: startStep,
    durSteps: durSteps,
    trimStart: trimStart,
    trimEnd: trimEnd,
    gain: gain,
    fadeInMs: fadeInMs,
    fadeOutMs: fadeOutMs,
    fx: fx.map((f) => f.copy()).toList(),
    peaks: List<double>.from(peaks),
  );

  Map<String, dynamic> toJson() => {
    'path': path,
    if (origPath != null) 'origPath': origPath,
    if (fxSourcePath != null) 'fxSourcePath': fxSourcePath,
    if (startStep != 0) 'startStep': startStep,
    if (durSteps != -1) 'durSteps': durSteps,
    if (trimStart != 0) 'trimStart': trimStart,
    if (trimEnd != -1) 'trimEnd': trimEnd,
    if (gain != 1.0) 'gain': gain,
    if (fadeInMs != 0) 'fadeInMs': fadeInMs,
    if (fadeOutMs != 0) 'fadeOutMs': fadeOutMs,
    if (fx.isNotEmpty) 'fx': fx.map((f) => f.toJson()).toList(),
    if (peaks.isNotEmpty) 'peaks': peaks,
  };

  static String? _basename(String? p) => p?.split('/').last.split('\\').last;

  static VocalClip fromJson(Map<String, dynamic> j) => VocalClip(
    path: _basename(j['path'] as String?) ?? '',
    origPath: _basename(j['origPath'] as String?),
    fxSourcePath: _basename(j['fxSourcePath'] as String?),
    startStep: (j['startStep'] as num?)?.toInt() ?? 0,
    durSteps: (j['durSteps'] as num?)?.toInt() ?? -1,
    trimStart: (j['trimStart'] as num?)?.toInt() ?? 0,
    trimEnd: (j['trimEnd'] as num?)?.toInt() ?? -1,
    gain: (j['gain'] as num?)?.toDouble() ?? 1.0,
    fadeInMs: (j['fadeInMs'] as num?)?.toInt() ?? 0,
    fadeOutMs: (j['fadeOutMs'] as num?)?.toInt() ?? 0,
    fx:
        (j['fx'] as List?)
            ?.map((e) => FxNode.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
    peaks: (j['peaks'] as List?)?.map((e) => (e as num).toDouble()).toList(),
  );
}

/// One track's content. Pitched/bass/drums use [notes]; vocal uses [clip].
class TrackData {
  TrackData({
    List<PitchNote>? notes,
    List<DrumNote>? drums,
    this.clip,
    this.vocalPath,
    this.vocalOrigPath,
    this.vocalAligned = false,
    this.vocalBpm,
    this.vocalBars,
    this.clips,
    this.label,
    this.drumKinds,
  }) : pitchNotes = notes ?? [],
       drumNotes = drums ?? [];

  final List<PitchNote> pitchNotes;
  final List<DrumNote> drumNotes;

  /// Imported lane labels and percussion palette, independent of base role.
  String? label;
  List<String>? drumKinds;

  /// Vocal waveform peaks (audio only — no MIDI), or null when empty.
  List<double>? clip;

  /// Recorded vocal file under Documents/looptap/vocals/ — stored as a
  /// BASENAME (resolve via LoopStorage.resolveVocal). Absolute paths from old
  /// saves are migrated in [fromJson].
  String? vocalPath;

  /// Pre-autotune original take (basename), kept for "revert to original".
  String? vocalOrigPath;

  /// True when the take was recorded via the loop-aligned modal: starts on the
  /// downbeat and is trimmed to exactly the section's loop length AT THE
  /// BPM/BARS IT WAS RECORDED ([vocalBpm]/[vocalBars]).
  bool vocalAligned;

  /// Loop context the take was recorded at. A take is only loop-length-exact
  /// for that bpm/bars combination — null on old saves (treated as unaligned).
  int? vocalBpm;
  int? vocalBars;

  /// Multi-take vocal lane (non-destructive editor). Null on legacy single-take
  /// saves — read [effectiveClips], which synthesizes one clip from the legacy
  /// [vocalPath]/[clip] so consumers don't have to special-case either shape.
  List<VocalClip>? clips;

  /// The vocal clips to render/play, resolving legacy single-take saves to a
  /// one-clip list. Empty when nothing is recorded.
  List<VocalClip> get effectiveClips {
    if (clips != null) return clips!;
    if (vocalPath != null) {
      return [
        VocalClip(
          path: vocalPath!,
          origPath: vocalOrigPath,
          startStep: 0,
          peaks: clip ?? const [],
        ),
      ];
    }
    return const [];
  }

  /// Whether the take is loop-aligned FOR the given playback context: aligned
  /// takes are exactly one loop long only at the bpm/bars they were recorded,
  /// so a later tempo/length change must fall back to unaligned playback
  /// (seek-on-wrap) or it desyncs cumulatively. Missing context → not aligned.
  bool vocalIsAligned(int bpm, int bars) =>
      vocalAligned && vocalBpm == bpm && vocalBars == bars;

  TrackData deepCopy() => TrackData(
    label: label,
    drumKinds: drumKinds == null ? null : List.of(drumKinds!),
    notes: pitchNotes.map((n) => n.copyWith()).toList(),
    drums: drumNotes.map((n) => n.copyWith()).toList(),
    clip: clip == null ? null : List<double>.from(clip!),
    vocalPath: vocalPath,
    vocalOrigPath: vocalOrigPath,
    vocalAligned: vocalAligned,
    vocalBpm: vocalBpm,
    vocalBars: vocalBars,
    clips: clips?.map((c) => c.copy()).toList(),
  );

  Map<String, dynamic> toJson() {
    // Mirror the first clip into the legacy vocalPath/clip fields so older app
    // builds (and export/playback paths that read them directly) still resolve
    // a take when a multi-clip lane is present.
    final first = (clips != null && clips!.isNotEmpty) ? clips!.first : null;
    final vp = first?.path ?? vocalPath;
    final pk = (first != null && first.peaks.isNotEmpty) ? first.peaks : clip;
    return {
      if (label != null) 'label': label,
      if (drumKinds != null) 'drumKinds': drumKinds,
      if (pitchNotes.isNotEmpty)
        'notes': pitchNotes.map((n) => n.toJson()).toList(),
      if (drumNotes.isNotEmpty)
        'drums': drumNotes.map((n) => n.toJson()).toList(),
      if (pk != null) 'clip': pk,
      if (vp != null) 'vocalPath': vp,
      if (vocalOrigPath != null) 'vocalOrigPath': vocalOrigPath,
      if (vocalAligned) 'vocalAligned': true,
      if (vocalBpm != null) 'vocalBpm': vocalBpm,
      if (vocalBars != null) 'vocalBars': vocalBars,
      if (clips != null && clips!.isNotEmpty)
        'clips': clips!.map((c) => c.toJson()).toList(),
    };
  }

  // Legacy saves stored absolute paths, which break when the iOS container
  // UUID changes — keep only the basename and resolve dynamically.
  static String? _basename(String? p) => p?.split('/').last.split('\\').last;

  static TrackData fromJson(Map<String, dynamic>? j) {
    if (j == null) return TrackData();
    return TrackData(
      label: j['label'] as String?,
      drumKinds: (j['drumKinds'] as List?)?.cast<String>(),
      notes:
          (j['notes'] as List?)
              ?.map((e) => PitchNote.fromJson(e as Map<String, dynamic>))
              .toList(),
      drums:
          (j['drums'] as List?)
              ?.map((e) => DrumNote.fromJson(e as Map<String, dynamic>))
              .toList(),
      clip: (j['clip'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      vocalPath: _basename(j['vocalPath'] as String?),
      vocalOrigPath: _basename(j['vocalOrigPath'] as String?),
      vocalAligned: (j['vocalAligned'] as bool?) ?? false,
      vocalBpm: (j['vocalBpm'] as num?)?.toInt(),
      vocalBars: (j['vocalBars'] as num?)?.toInt(),
      clips:
          (j['clips'] as List?)
              ?.map(
                (e) => VocalClip.fromJson((e as Map).cast<String, dynamic>()),
              )
              .toList(),
    );
  }
}

/// A section = an independent loop with a repeat count.
class Section {
  Section({
    required this.id,
    required this.name,
    Map<String, TrackData>? tracks,
    List<TrackRef>? extras,
    List<String>? order,
    List<String>? fillKinds,
    this.autoName = true,
    this.bars = 2,
    this.repeats = 1,
    Map<String, GrooveAssign?>? grooveOverrides,
    this.linkId,
  }) : grooveOverrides = grooveOverrides ?? {},
       tracks = tracks ?? _emptyTracks(),
       extras = extras ?? [],
       order = order ?? [],
       fillKinds =
           (fillKinds != null && fillKinds.length == kFillKindsDefault.length)
               ? List.of(fillKinds)
               : List.of(kFillKindsDefault);

  String id;
  String name;

  /// True while [name] is an auto-assigned position letter (A, B, C…). The
  /// editor re-letters auto-named sections by their position on add/move/delete;
  /// a user rename flips this false so the custom name is left alone.
  bool autoName;
  final Map<String, TrackData>
  tracks; // keyed by track id (base ids + extra ids)
  /// The 6 percussion sounds assigned to the Beat-Fill launchpad pads (kinds in
  /// kFillPalette). Per-section so each section's Fill notes match its layout.
  final List<String> fillKinds;
  // User-added track instances beyond the fixed base 6. Their TrackData lives in
  // [tracks] under the ref id; the section meta list = kTracks + these.
  final List<TrackRef> extras;
  // Explicit display order of track ids (drag-to-reorder). Display-only — channel
  // allocation is independent, so reordering never reassigns a track's channel.
  // Ids not listed here fall back to natural order (kTracks + extras) at the end;
  // empty = pure natural order.
  final List<String> order;
  int bars;
  int repeats;

  /// groove-001: per-track groove for this section only, overriding the
  /// song's track groove. A null value means "no groove here" (Swing).
  final Map<String, GrooveAssign?> grooveOverrides;

  /// AR-001 linked copy: shares [source]'s `tracks` map and `fillKinds` list
  /// (no copy), takes its `bars`; name, repeats, track list and groove
  /// overrides are this section's own.
  Section.linkedTo(
    Section source, {
    required this.id,
    required this.name,
    this.autoName = true,
    this.repeats = 1,
    List<TrackRef>? extras,
    List<String>? order,
    Map<String, GrooveAssign?>? grooveOverrides,
    String? linkId,
  }) : tracks = source.tracks,
       fillKinds = source.fillKinds,
       bars = source.bars,
       extras =
           extras ?? [for (final e in source.extras) TrackRef(e.id, e.type)],
       order = order ?? [...source.order],
       grooveOverrides = grooveOverrides ?? {},
       linkId = linkId ?? source.linkId;

  /// AR-001: sections with the same id share their content (tracks, bars,
  /// Beat-Fill pads) at runtime. Null = an independent section.
  String? linkId;

  static Map<String, TrackData> _emptyTracks() => {
    for (final t in kTracks) t.id: TrackData(),
  };

  Section deepCopy() => Section(
    id: id,
    name: name,
    tracks: tracks.map((k, v) => MapEntry(k, v.deepCopy())),
    extras: [for (final e in extras) TrackRef(e.id, e.type)],
    order: [...order],
    fillKinds: [...fillKinds],
    autoName: autoName,
    bars: bars,
    repeats: repeats,
    grooveOverrides: Map.of(grooveOverrides),
    linkId: linkId,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'tracks': tracks.map((k, v) => MapEntry(k, v.toJson())),
    'extras': [for (final e in extras) e.toJson()],
    'order': order,
    'fillKinds': fillKinds,
    if (!autoName) 'autoName': false,
    'bars': bars,
    'repeats': repeats,
    if (grooveOverrides.isNotEmpty)
      'grooveOverrides': grooveOverrides.map(
        (k, v) => MapEntry(k, v?.toJson()),
      ),
    if (linkId != null) 'linkId': linkId,
  };

  static Section fromJson(Map<String, dynamic> j) {
    final rawTracks = (j['tracks'] as Map?)?.cast<String, dynamic>() ?? {};
    final extras = [
      for (final e in (j['extras'] as List?) ?? [])
        TrackRef.fromJson((e as Map).cast<String, dynamic>()),
    ];
    // base tracks + any extra-instance tracks, all read from the saved map.
    final tracks = _emptyTracks();
    for (final e in extras) {
      tracks[e.id] = TrackData();
    }
    for (final id in tracks.keys.toList()) {
      tracks[id] = TrackData.fromJson(rawTracks[id] as Map<String, dynamic>?);
    }
    return Section(
      id: (j['id'] ?? 'sec') as String,
      name: (j['name'] ?? 'A') as String,
      tracks: tracks,
      extras: extras,
      order: [for (final o in (j['order'] as List?) ?? []) o as String],
      fillKinds: (j['fillKinds'] as List?)?.map((e) => e as String).toList(),
      autoName: (j['autoName'] as bool?) ?? true,
      bars: (j['bars'] as num?)?.toInt() ?? 2,
      repeats: (j['repeats'] as num?)?.toInt() ?? 1,
      grooveOverrides: (j['grooveOverrides'] as Map?)?.map(
        (k, v) => MapEntry(
          k as String,
          v == null
              ? null
              : GrooveAssign.fromJson((v as Map).cast<String, dynamic>()),
        ),
      ),
      linkId: j['linkId'] as String?,
    );
  }
}

/// A song / loop project.
class Song {
  Song({
    required this.id,
    required this.title,
    this.key = 'A',
    this.scale = 'minor',
    this.bpm = 92,
    this.swing = 0,
    this.bars = 2,
    Map<String, double>? vol,
    Map<String, double>? pan,
    Map<String, bool>? mutes,
    Map<String, int>? instruments,
    List<Section>? sections,
    this.updatedAt,
    List<double>? wave,
    this.songVocalPath,
    this.songVocalPeaks,
    this.songVocalBpm,
    this.songVocalBars,
    Map<String, bool>? generationLocks,
    this.variationSeed,
    List<GrooveTemplate>? grooves,
    Map<String, GrooveAssign>? trackGrooves,
    this.grooveAmount = 1.0,
  }) : grooves = grooves ?? [],
       trackGrooves = trackGrooves ?? {},
       vol =
           vol ??
           {
             for (final t in kTracks)
               t.id: t.kind == TrackKind.drums ? 1.0 : 0.85,
           },
       pan = {
         for (final e in (pan ?? const <String, double>{}).entries)
           if (clampPan(e.value) != 0) e.key: clampPan(e.value),
       },
       mutes = mutes ?? {},
       instruments =
           instruments ??
           {for (final t in kPitchedTracks) t.id: t.defaultProgram},
       sections = sections ?? [Section(id: 'A', name: 'A')],
       wave = wave ?? List<double>.filled(30, 0.12),
       generationLocks = generationLocks ?? {'melody': true};

  String id;
  String title;
  String key; // root note name
  String scale;
  int bpm;
  double swing; // 0–0.6
  int bars; // 1 | 2 | 4
  final Map<String, double> vol;

  /// mixer-001: per-track pan (track id -> p in [-1, 1], -1 = left). Centre
  /// (0) entries are never stored; missing = centre.
  final Map<String, double> pan;
  final Map<String, bool> mutes;

  /// Per-track GM program (melody/bass). Drives live playback + MIDI export.
  final Map<String, int> instruments;
  final List<Section> sections;
  DateTime? updatedAt;

  /// 30-bar waveform thumbnail for the songs grid.
  List<double> wave;

  /// Optional song-level continuous vocal take — recorded over the WHOLE song
  /// and played from step 0 during Play Song (avoids the per-section repeat
  /// conflict). Basename under Documents/looptap/vocals; null when none.
  String? songVocalPath;
  List<double>? songVocalPeaks; // display peaks
  int? songVocalBpm; // bpm at record time
  int? songVocalBars; // total song bars at record time (loop length)
  /// Track-level invariants for an arrangement model. Melody is locked by
  /// default so an AI/backing pass cannot silently replace the user's idea.
  final Map<String, bool> generationLocks;

  /// Seed for per-note chance / velocity variation in exports and Play Song.
  /// Null on songs that never re-rolled: derived from [id] instead.
  int? variationSeed;
  int get effectiveVariationSeed => variationSeed ?? fnv1a32(id);

  /// groove-001: the song's extracted / user groove templates (built-ins are
  /// referenced by id, never stored), track assignments and Amount 0..1.3.
  final List<GrooveTemplate> grooves;
  final Map<String, GrooveAssign> trackGrooves;
  double grooveAmount;

  /// Groove resolution for flatten / playback (Swing for the rest).
  GrooveContext get grooveContext => GrooveContext(
    grooves: grooves,
    trackGrooves: trackGrooves,
    amount: grooveAmount,
    swing: swing,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'key': key,
    'scale': scale,
    'bpm': bpm,
    'swing': swing,
    'bars': bars,
    'vol': vol,
    if (pan.values.any((p) => p != 0))
      'pan': {
        for (final e in pan.entries)
          if (e.value != 0) e.key: e.value,
      },
    'mutes': mutes,
    'instruments': instruments,
    'sections': sections.map((s) => s.toJson()).toList(),
    'updatedAt': updatedAt?.millisecondsSinceEpoch,
    'wave': wave,
    if (songVocalPath != null) 'songVocalPath': songVocalPath,
    if (songVocalPeaks != null) 'songVocalPeaks': songVocalPeaks,
    if (songVocalBpm != null) 'songVocalBpm': songVocalBpm,
    if (songVocalBars != null) 'songVocalBars': songVocalBars,
    'generationLocks': generationLocks,
    if (variationSeed != null) 'variationSeed': variationSeed,
    if (grooves.isNotEmpty) 'grooves': grooves.map((g) => g.toJson()).toList(),
    if (trackGrooves.isNotEmpty)
      'trackGrooves': trackGrooves.map((k, v) => MapEntry(k, v.toJson())),
    if (grooveAmount != 1.0) 'grooveAmount': grooveAmount,
  };

  static Song fromJson(Map<String, dynamic> j) => Song(
    id: (j['id'] ?? 'lt') as String,
    title: (j['title'] ?? 'Untitled loop') as String,
    key: (j['key'] ?? 'A') as String,
    // an unknown scale (older build / hand-edited file) would crash every
    // kScales[scale]! lookup downstream — normalise it here once.
    scale: kScales.containsKey(j['scale']) ? j['scale'] as String : 'minor',
    bpm: (j['bpm'] as num?)?.toInt() ?? 92,
    swing: (j['swing'] as num?)?.toDouble() ?? 0,
    bars: (j['bars'] as num?)?.toInt() ?? 2,
    vol: (j['vol'] as Map?)?.map(
      (k, v) => MapEntry(k as String, (v as num).toDouble()),
    ),
    pan: (j['pan'] as Map?)?.map(
      (k, v) => MapEntry(k as String, clampPan(v as num?)),
    ),
    mutes: (j['mutes'] as Map?)?.map(
      (k, v) => MapEntry(k as String, v as bool),
    ),
    instruments: (j['instruments'] as Map?)?.map(
      (k, v) => MapEntry(k as String, (v as num).toInt()),
    ),
    sections:
        (j['sections'] as List?)
            ?.map((e) => Section.fromJson(e as Map<String, dynamic>))
            .toList(),
    updatedAt:
        j['updatedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
              (j['updatedAt'] as num).toInt(),
            ),
    wave: (j['wave'] as List?)?.map((e) => (e as num).toDouble()).toList(),
    songVocalPath:
        (j['songVocalPath'] as String?)?.split('/').last.split('\\').last,
    songVocalPeaks:
        (j['songVocalPeaks'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList(),
    songVocalBpm: (j['songVocalBpm'] as num?)?.toInt(),
    songVocalBars: (j['songVocalBars'] as num?)?.toInt(),
    generationLocks: (j['generationLocks'] as Map?)?.map(
      (k, v) => MapEntry(k as String, v as bool),
    ),
    variationSeed: (j['variationSeed'] as num?)?.toInt(),
    grooves: [
      for (final g in (j['grooves'] as List?) ?? const [])
        GrooveTemplate.fromJson((g as Map).cast<String, dynamic>()),
    ],
    trackGrooves: (j['trackGrooves'] as Map?)?.map(
      (k, v) => MapEntry(
        k as String,
        GrooveAssign.fromJson((v as Map).cast<String, dynamic>()),
      ),
    ),
    grooveAmount:
        ((j['grooveAmount'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.3),
  );

  /// songs.json top-level schema version. v1 = a bare JSON list (never
  /// written any more, still readable); v2 = `{"v": 2, "songs": [...]}`;
  /// v3 = same envelope, notes and drum hits may carry `muted`/`chance`/
  /// `velocityDeviation`, songs a `variationSeed` and groove data
  /// (`grooves`/`trackGrooves`/`grooveAmount`, section `grooveOverrides`)
  /// and section `linkId`, and per-track `pan` (mixer-001), notes a guitar
  /// `stroke` tag (gt-001) and `guitarString`/`stringLocked`/`ringBaseDur`/
  /// `ringBaseDurationSteps` (gt-002) — all optional, so v2 files read
  /// unchanged.
  static const int kSchemaVersion = 3;

  /// The `v` of a songs.json payload, or null when it is not a readable
  /// envelope (v1 bare lists report 1).
  static int? schemaVersionOf(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return 1;
      if (decoded is Map && decoded['v'] is num) {
        return (decoded['v'] as num).toInt();
      }
    } catch (_) {}
    return null;
  }

  static String encodeList(List<Song> songs) => jsonEncode({
    'v': kSchemaVersion,
    'songs': songs.map((s) => s.toJson()).toList(),
  });

  /// The raw song entries of either file shape (v1 bare list, v2 envelope).
  /// Throws on anything else — the caller decides what "unreadable" means.
  static List<dynamic> _unwrap(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded; // v1
    if (decoded is Map) {
      final songs = decoded['songs'];
      if (songs is List) return songs; // v2+
    }
    throw const FormatException('songs.json: unrecognised top-level shape');
  }

  /// Strict decode — any malformed song fails the whole list.
  static List<Song> decodeList(String raw) =>
      _unwrap(
        raw,
      ).map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();

  /// Lenient decode — a malformed song entry is skipped (and counted) instead
  /// of taking the whole library down with it. Still throws when the file
  /// itself isn't parseable, so the caller can fall back to a backup.
  static ({List<Song> songs, int skipped}) decodeListLenient(String raw) {
    final out = <Song>[];
    var skipped = 0;
    for (final e in _unwrap(raw)) {
      try {
        out.add(Song.fromJson((e as Map).cast<String, dynamic>()));
      } catch (_) {
        skipped++;
      }
    }
    return (songs: out, skipped: skipped);
  }
}
