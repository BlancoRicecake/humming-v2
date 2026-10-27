// gt-003 guitar articulations: 짧게 (staccato), 팜뮤트 근사 (GM 28 palm
// tone) and 하모닉스 근사 (GM 31 harmonic tone).
//
// The note stores only an immutable `Articulation` snapshot; everything
// else is decided at render time by [realizeArticulation], the one function
// live playback, audition, the `.mid` export and the WAV/stem render share.
// [ArticulationPlan] decides once per song which articulation channel each
// (track, role) gets; the same plan drives every output, so a role without a
// channel renders as normal everywhere.
import 'dart:math' as math;

import '../models/loop_models.dart';
import 'guitar_tuning.dart';
import 'instruments.dart';
import 'theory.dart';

/// GM programs of the two tone approximations (bank 0 of the GM font).
const int kPalmToneProgram = 28;
const int kHarmonicToneProgram = 31;

/// The harmonic tone sounds S when GM 31 plays key S − 24 (partial-structure
/// proxy over keys 50..86; not a confirmed perceived pitch).
const int kHarmonicKeyOffset = 24;

/// Factory defaults for new applies (LoopPrefs holds the user's values).
const int kStaccatoGateMs = 120;
const int kPalmGateMs = 250;
const double kPalmVelScale = .85;

/// Where an articulated note sounds: on the track's own channel, or on the
/// track's palm-tone / harmonic-tone articulation channel.
enum ArtRole { track, muteVoice, harmonicVoice }

/// The articulation-channel role [kind] needs (null = the track channel).
ArtRole? artRoleOf(ArticulationKind? kind) => switch (kind) {
  ArticulationKind.palmTone => ArtRole.muteVoice,
  ArticulationKind.harmonicTone => ArtRole.harmonicVoice,
  _ => null,
};

/// The GM program an articulation role plays (null for the track role).
int? artProgramOf(ArtRole role) => switch (role) {
  ArtRole.muteVoice => kPalmToneProgram,
  ArtRole.harmonicVoice => kHarmonicToneProgram,
  ArtRole.track => null,
};

/// The snapshot a new apply of [kind] stores, from the given defaults.
Articulation newArticulation(
  ArticulationKind kind, {
  int staccatoMs = kStaccatoGateMs,
  int palmMs = kPalmGateMs,
  double palmVelScale = kPalmVelScale,
}) => switch (kind) {
  ArticulationKind.staccato => Articulation(kind: kind, gateMs: staccatoMs),
  ArticulationKind.palmTone => Articulation(
    kind: kind,
    gateMs: palmMs,
    velScale: palmVelScale,
  ),
  ArticulationKind.harmonicTone => Articulation(kind: kind),
};

/// What one track's notes may use while rendering: whether the track is a
/// guitar (articulations only apply there), its articulation channels from
/// the plan, and the tempo for the ms gates.
class ArticulationContext {
  const ArticulationContext({
    required this.guitar,
    required this.bpm,
    this.muteChannel,
    this.harmonicChannel,
  });

  /// No articulations: every note renders as normal.
  static const none = ArticulationContext(guitar: false, bpm: 120);

  final bool guitar;
  final num bpm;
  final int? muteChannel, harmonicChannel;

  int? channelFor(ArtRole role) => switch (role) {
    ArtRole.muteVoice => muteChannel,
    ArtRole.harmonicVoice => harmonicChannel,
    ArtRole.track => null,
  };

  /// [ms] as sixteenth steps at [bpm].
  double msToSteps(int ms) => ms / 1000 * bpm / 60 * kStepsPerBeat;
}

/// One realized note: the engine [key] on [channel] (null = the track's own
/// channel) with [velocity] (null keeps the legacy gain rule) and the gate
/// in steps. [soundingMidi] is the pitch the listener hears and the pitch a
/// `.mid` stores.
class ArticulationEvent {
  const ArticulationEvent({
    required this.role,
    required this.key,
    required this.soundingMidi,
    required this.velocity,
    required this.gateSteps,
    this.channel,
  });

  final ArtRole role;
  final int key, soundingMidi;
  final int? velocity;
  final double gateSteps;
  final int? channel;

  int? get program => artProgramOf(role);

  @override
  String toString() =>
      'ArticulationEvent(${role.name}, key $key, sounds $soundingMidi, '
      'vel $velocity, gate $gateSteps, ch $channel)';
}

/// gt-003: what [note] plays. [velocity] and [gateSteps] are the values the
/// path would use for a normal note (after the stroke offset/velocity and
/// any range clipping); [soundingMidi] overrides the pitch (raw-pitch
/// preview), else the note's own. The articulation's gate caps the gate
/// (it also caps a G2 ring) and its velocity scale applies last. A role
/// without a channel, a sounding pitch outside the kind's supported range
/// (checked on [soundingMidi] when given; never clamped) or a non-guitar
/// track renders the note exactly as normal.
ArticulationEvent realizeArticulation(
  PitchNote note,
  ArticulationContext ctx, {
  required int? velocity,
  required double gateSteps,
  int? soundingMidi,
}) {
  final sound = soundingMidi ?? note.midi;
  final normal = ArticulationEvent(
    role: ArtRole.track,
    key: sound,
    soundingMidi: sound,
    velocity: velocity,
    gateSteps: gateSteps,
  );
  final a = note.articulation;
  // the support range is checked on the pitch this render actually sounds
  if (a == null || !ctx.guitar || !articulationFits(a.kind, sound)) {
    return normal;
  }
  final role = artRoleOf(a.kind);
  final channel = role == null ? null : ctx.channelFor(role);
  if (role != null && channel == null) return normal;
  final gate =
      a.gateMs == null
          ? gateSteps
          : math.min(gateSteps, ctx.msToSteps(a.gateMs!));
  final vel =
      a.velScale == 1.0
          ? velocity
          : ((velocity ?? 100) * a.velScale).round().clamp(1, 127);
  final key =
      role == ArtRole.harmonicVoice ? sound - kHarmonicKeyOffset : sound;
  return ArticulationEvent(
    role: role ?? ArtRole.track,
    key: key.clamp(0, 127),
    soundingMidi: sound,
    velocity: vel,
    gateSteps: gate,
    channel: channel,
  );
}

/// The channels no articulation may take: base tracks (melody 0, bass 1,
/// melody-fill 2), drums 9, Beat-Fill 10 and the metronome 15.
const Set<int> kArticulationReservedChannels = {0, 1, 2, 9, 10, 15};

/// gt-003 routing for a whole song (review ③): for every (track, role)
/// whose notes need an articulation channel, the channel it gets — or none
/// when the free pool ran out. Deterministic: tracks in song order (base
/// tracks, then added ones), palm before harmonic, channels in
/// [kExtraPitchChannels] order, skipping every channel a track uses.
class ArticulationPlan {
  ArticulationPlan._(this._guitar, this._articulated, this._channels);

  /// A plan without guitar tracks: everything renders as normal.
  static final ArticulationPlan empty = ArticulationPlan._(
    const {},
    const {},
    const {},
  );

  final Set<String> _guitar;
  final Set<String> _articulated;
  final Map<(String, ArtRole), int?> _channels;

  /// The plan for [song] (its sections and instruments).
  static ArticulationPlan of(Song song) =>
      build(sections: song.sections, instruments: song.instruments);

  /// The plan for [sections] played with [instruments] (track id → program;
  /// a missing id uses the track type's default program).
  static ArticulationPlan build({
    required Iterable<Section> sections,
    required Map<String, int> instruments,
  }) {
    final used = <int>{...kArticulationReservedChannels};
    final order = <TrackMeta>[];
    final seen = <String>{};
    for (final s in sections) {
      for (final m in sectionTrackMetas(s.extras)) {
        if (m.kind == TrackKind.vocal) continue;
        used.add(m.channel);
        if (seen.add(m.id)) order.add(m);
      }
    }
    final guitar = <String>{};
    final articulated = <String>{};
    final requests = <(String, ArtRole)>[];
    for (final m in order) {
      if (m.kind != TrackKind.pitched && m.kind != TrackKind.bass) continue;
      if (!isGuitarProgram(instruments[m.id] ?? m.defaultProgram)) continue;
      guitar.add(m.id);
      var palm = false, harmonic = false;
      for (final s in sections) {
        for (final n in s.tracks[m.id]?.pitchNotes ?? const <PitchNote>[]) {
          final a = n.articulation;
          if (a == null) continue;
          articulated.add(m.id);
          if (a.kind == ArticulationKind.palmTone) palm = true;
          if (a.kind == ArticulationKind.harmonicTone) harmonic = true;
        }
      }
      if (palm) requests.add((m.id, ArtRole.muteVoice));
      if (harmonic) requests.add((m.id, ArtRole.harmonicVoice));
    }
    final free = [
      for (final ch in kExtraPitchChannels)
        if (!used.contains(ch)) ch,
    ];
    final channels = <(String, ArtRole), int?>{};
    for (var i = 0; i < requests.length; i++) {
      channels[requests[i]] = i < free.length ? free[i] : null;
    }
    return ArticulationPlan._(guitar, articulated, channels);
  }

  /// Whether [trackId] plays a guitar (articulations apply only there).
  bool isGuitar(String trackId) => _guitar.contains(trackId);

  /// Whether any guitar track holds an articulated note.
  bool get hasArticulations => _articulated.isNotEmpty;

  /// Whether [trackId] needs [role] at all.
  bool requests(String trackId, ArtRole role) =>
      _channels.containsKey((trackId, role));

  /// The articulation channel of ([trackId], [role]), or null (not needed,
  /// or no channel left: those notes render as normal everywhere).
  int? channelFor(String trackId, ArtRole role) => _channels[(trackId, role)];

  /// The roles [trackId] needs but could not get a channel for ("채널 부족").
  List<ArtRole> shortRoles(String trackId) => [
    for (final e in _channels.entries)
      if (e.key.$1 == trackId && e.value == null) e.key.$2,
  ];

  /// Every (track, role) with a channel, in plan order.
  List<({String trackId, ArtRole role, int channel})> get routes => [
    for (final e in _channels.entries)
      if (e.value != null)
        (trackId: e.key.$1, role: e.key.$2, channel: e.value!),
  ];

  /// The articulation channels [trackId] owns.
  List<int> channelsOf(String trackId) => [
    for (final r in routes)
      if (r.trackId == trackId) r.channel,
  ];

  /// The render context for [trackId] at [bpm].
  ArticulationContext contextFor(String trackId, num bpm) =>
      ArticulationContext(
        guitar: isGuitar(trackId),
        bpm: bpm,
        muteChannel: channelFor(trackId, ArtRole.muteVoice),
        harmonicChannel: channelFor(trackId, ArtRole.harmonicVoice),
      );

  @override
  bool operator ==(Object other) =>
      other is ArticulationPlan &&
      _guitar.length == other._guitar.length &&
      _guitar.containsAll(other._guitar) &&
      _articulated.length == other._articulated.length &&
      _articulated.containsAll(other._articulated) &&
      _channels.length == other._channels.length &&
      _channels.entries.every(
        (e) =>
            other._channels.containsKey(e.key) &&
            other._channels[e.key] == e.value,
      );

  @override
  int get hashCode => Object.hash(_guitar.length, _channels.length);

  @override
  String toString() => 'ArticulationPlan($_channels)';
}

/// The result of an articulation apply: [applied] notes carry the requested
/// value; [outOfRange] were refused for their pitch ("지원 범위 밖") and
/// [noChannel] because the song has no free articulation channel ("채널
/// 부족"). Refused notes are unchanged.
class ArticulationEdit {
  const ArticulationEdit(
    this.notes,
    this.selection, {
    this.applied = 0,
    this.outOfRange = 0,
    this.noChannel = 0,
  });
  final List<PitchNote> notes;
  final Set<PitchNote> selection;
  final int applied, outOfRange, noChannel;
}

/// gt-003 apply: set [value] (null = "일반으로") on the selected notes, or on
/// the whole track when nothing is selected. Locked notes are skipped; muted
/// notes are tagged (they stay silent). Only the articulation field changes.
/// A palm or harmonic apply asks [channelFor] which channel the song would
/// give the role with the tentative notes; none refuses the whole apply and
/// counts it (a fallback is never reported as applied). Nothing to change
/// returns [notes] itself.
ArticulationEdit applyArticulation(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  Articulation? value, {
  int? Function(ArtRole role, List<PitchNote> tentative)? channelFor,
}) {
  final scope = selected.isEmpty ? notes.toSet() : selected;
  final out = List.of(notes);
  var applied = 0, outOfRange = 0;
  var changed = false;
  for (var i = 0; i < notes.length; i++) {
    final n = notes[i];
    if (!scope.contains(n) || n.locked) continue;
    if (value == null) {
      if (n.articulation == null) continue;
      out[i] = n.withArticulation(null);
      applied++;
      changed = true;
      continue;
    }
    if (!articulationFits(value.kind, n.midi)) {
      outOfRange++;
      continue;
    }
    applied++;
    if (n.articulation == value) continue;
    out[i] = n.withArticulation(value);
    changed = true;
  }
  final role = artRoleOf(value?.kind);
  if (role != null && applied > 0 && channelFor != null) {
    if (channelFor(role, out) == null) {
      return ArticulationEdit(
        notes,
        selected,
        outOfRange: outOfRange,
        noChannel: applied,
      );
    }
  }
  if (!changed) {
    return ArticulationEdit(
      notes,
      selected,
      applied: applied,
      outOfRange: outOfRange,
    );
  }
  return ArticulationEdit(
    out,
    {
      for (var i = 0; i < notes.length; i++)
        if (selected.contains(notes[i])) out[i],
    },
    applied: applied,
    outOfRange: outOfRange,
  );
}

/// Node fret of the natural harmonic that sounds [interval] semitones above
/// an open string (12 → fret 12, 19 → fret 7, 24 → fret 5).
const Map<int, int> kNaturalHarmonicNodeFret = {12: 12, 19: 7, 24: 5};

/// gt-003 display-only info: when [note] has a G2 string and its pitch is a
/// natural harmonic of that open string, the string and node fret ("n번 줄
/// m프렛"). Null = not a natural-harmonic position, or no string known.
({int string, int fret})? naturalHarmonicPosition(PitchNote note) {
  final s = note.guitarString;
  if (s == null || s < 1 || s > kGuitarStrings) return null;
  final fret = kNaturalHarmonicNodeFret[note.midi - kGuitarOpenMidi[s - 1]];
  return fret == null ? null : (string: s, fret: fret);
}

/// Grid marker for [note]'s articulation: "s" (짧게), "PM" (팜뮤트 근사,
/// drawn with a dotted outline) or "◇" (하모닉스 근사).
String? articulationMark(PitchNote note) => switch (note.articulation?.kind) {
  ArticulationKind.staccato => 's',
  ArticulationKind.palmTone => 'PM',
  ArticulationKind.harmonicTone => '◇',
  null => null,
};
