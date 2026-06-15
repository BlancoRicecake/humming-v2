// LoopTap data model — README §State management.
// Song -> sections[] -> tracks{melody,bass,drums,vocal} -> notes/clip.
// JSON round-trips to <Documents>/looptap/songs.json (single list, like the
// prototype's localStorage["looptap_songs_v1"]).
import 'dart:convert';

import '../music/theory.dart';

/// A pitched note: { midi, freq, step, dur }.
class PitchNote {
  PitchNote({required this.midi, required this.freq, required this.step, this.dur = 1});

  final int midi;
  final double freq;
  int step;
  int dur;

  PitchNote copyWith({int? step}) =>
      PitchNote(midi: midi, freq: freq, step: step ?? this.step, dur: dur);

  Map<String, dynamic> toJson() => {'midi': midi, 'freq': freq, 'step': step, 'dur': dur};

  static PitchNote fromJson(Map<String, dynamic> j) => PitchNote(
        midi: (j['midi'] as num).toInt(),
        freq: (j['freq'] as num).toDouble(),
        step: (j['step'] as num).toInt(),
        dur: (j['dur'] as num?)?.toInt() ?? 1,
      );
}

/// A drum hit: { kind:'kick'|'snare'|'hihat', step }.
class DrumNote {
  DrumNote({required this.kind, required this.step});

  final String kind;
  int step;

  DrumNote copyWith({int? step}) => DrumNote(kind: kind, step: step ?? this.step);

  Map<String, dynamic> toJson() => {'kind': kind, 'step': step};

  static DrumNote fromJson(Map<String, dynamic> j) =>
      DrumNote(kind: j['kind'] as String, step: (j['step'] as num).toInt());
}

/// One server-side effect applied to a vocal clip, kept non-destructively so
/// the chain can be re-ordered, disabled, or reverted. [type] is the fx name
/// ('eq'|'reverb'|'comp'|'delay'|'stretch'|'pitch'); [params] are its knobs.
class FxNode {
  FxNode({required this.type, Map<String, dynamic>? params, this.enabled = true})
      : params = params ?? {};

  String type;
  Map<String, dynamic> params;
  bool enabled;

  FxNode copy() => FxNode(
        type: type,
        params: Map<String, dynamic>.from(params),
        enabled: enabled,
      );

  Map<String, dynamic> toJson() =>
      {'type': type, 'params': params, if (!enabled) 'enabled': false};

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
    this.startStep = 0,
    this.durSteps = -1,
    this.trimStart = 0,
    this.trimEnd = -1,
    this.gain = 1.0,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    List<FxNode>? fx,
    List<double>? peaks,
  })  : fx = fx ?? [],
        peaks = peaks ?? [];

  String path;
  String? origPath;
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
        startStep: (j['startStep'] as num?)?.toInt() ?? 0,
        durSteps: (j['durSteps'] as num?)?.toInt() ?? -1,
        trimStart: (j['trimStart'] as num?)?.toInt() ?? 0,
        trimEnd: (j['trimEnd'] as num?)?.toInt() ?? -1,
        gain: (j['gain'] as num?)?.toDouble() ?? 1.0,
        fadeInMs: (j['fadeInMs'] as num?)?.toInt() ?? 0,
        fadeOutMs: (j['fadeOutMs'] as num?)?.toInt() ?? 0,
        fx: (j['fx'] as List?)
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
  })  : pitchNotes = notes ?? [],
        drumNotes = drums ?? [];

  final List<PitchNote> pitchNotes;
  final List<DrumNote> drumNotes;
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
      if (pitchNotes.isNotEmpty) 'notes': pitchNotes.map((n) => n.toJson()).toList(),
      if (drumNotes.isNotEmpty) 'drums': drumNotes.map((n) => n.toJson()).toList(),
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
      notes: (j['notes'] as List?)?.map((e) => PitchNote.fromJson(e as Map<String, dynamic>)).toList(),
      drums: (j['drums'] as List?)?.map((e) => DrumNote.fromJson(e as Map<String, dynamic>)).toList(),
      clip: (j['clip'] as List?)?.map((e) => (e as num).toDouble()).toList(),
      vocalPath: _basename(j['vocalPath'] as String?),
      vocalOrigPath: _basename(j['vocalOrigPath'] as String?),
      vocalAligned: (j['vocalAligned'] as bool?) ?? false,
      vocalBpm: (j['vocalBpm'] as num?)?.toInt(),
      vocalBars: (j['vocalBars'] as num?)?.toInt(),
      clips: (j['clips'] as List?)
          ?.map((e) => VocalClip.fromJson((e as Map).cast<String, dynamic>()))
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
  })  : tracks = tracks ?? _emptyTracks(),
        extras = extras ?? [],
        order = order ?? [],
        fillKinds = (fillKinds != null && fillKinds.length == kFillKindsDefault.length)
            ? List.of(fillKinds)
            : List.of(kFillKindsDefault);

  String id;
  String name;
  /// True while [name] is an auto-assigned position letter (A, B, C…). The
  /// editor re-letters auto-named sections by their position on add/move/delete;
  /// a user rename flips this false so the custom name is left alone.
  bool autoName;
  final Map<String, TrackData> tracks; // keyed by track id (base ids + extra ids)
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
    Map<String, bool>? mutes,
    Map<String, int>? instruments,
    List<Section>? sections,
    this.updatedAt,
    List<double>? wave,
    this.songVocalPath,
    this.songVocalPeaks,
    this.songVocalBpm,
    this.songVocalBars,
  })  : vol = vol ?? {for (final t in kTracks) t.id: t.kind == TrackKind.drums ? 1.0 : 0.85},
        mutes = mutes ?? {},
        instruments = instruments ??
            {
              for (final t in kPitchedTracks) t.id: t.defaultProgram,
            },
        sections = sections ?? [Section(id: 'A', name: 'A')],
        wave = wave ?? List<double>.filled(30, 0.12);

  String id;
  String title;
  String key; // root note name
  String scale;
  int bpm;
  double swing; // 0–0.6
  int bars; // 1 | 2 | 4
  final Map<String, double> vol;
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'key': key,
        'scale': scale,
        'bpm': bpm,
        'swing': swing,
        'bars': bars,
        'vol': vol,
        'mutes': mutes,
        'instruments': instruments,
        'sections': sections.map((s) => s.toJson()).toList(),
        'updatedAt': updatedAt?.millisecondsSinceEpoch,
        'wave': wave,
        if (songVocalPath != null) 'songVocalPath': songVocalPath,
        if (songVocalPeaks != null) 'songVocalPeaks': songVocalPeaks,
        if (songVocalBpm != null) 'songVocalBpm': songVocalBpm,
        if (songVocalBars != null) 'songVocalBars': songVocalBars,
      };

  static Song fromJson(Map<String, dynamic> j) => Song(
        id: (j['id'] ?? 'lt') as String,
        title: (j['title'] ?? 'Untitled loop') as String,
        key: (j['key'] ?? 'A') as String,
        scale: (j['scale'] ?? 'minor') as String,
        bpm: (j['bpm'] as num?)?.toInt() ?? 92,
        swing: (j['swing'] as num?)?.toDouble() ?? 0,
        bars: (j['bars'] as num?)?.toInt() ?? 2,
        vol: (j['vol'] as Map?)?.map((k, v) => MapEntry(k as String, (v as num).toDouble())),
        mutes: (j['mutes'] as Map?)?.map((k, v) => MapEntry(k as String, v as bool)),
        instruments: (j['instruments'] as Map?)?.map((k, v) => MapEntry(k as String, (v as num).toInt())),
        sections: (j['sections'] as List?)
            ?.map((e) => Section.fromJson(e as Map<String, dynamic>))
            .toList(),
        updatedAt: j['updatedAt'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch((j['updatedAt'] as num).toInt()),
        wave: (j['wave'] as List?)?.map((e) => (e as num).toDouble()).toList(),
        songVocalPath:
            (j['songVocalPath'] as String?)?.split('/').last.split('\\').last,
        songVocalPeaks: (j['songVocalPeaks'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList(),
        songVocalBpm: (j['songVocalBpm'] as num?)?.toInt(),
        songVocalBars: (j['songVocalBars'] as num?)?.toInt(),
      );

  static String encodeList(List<Song> songs) =>
      jsonEncode(songs.map((s) => s.toJson()).toList());

  static List<Song> decodeList(String raw) {
    final list = jsonDecode(raw) as List;
    return list.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }
}
