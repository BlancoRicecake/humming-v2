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
      );

  Map<String, dynamic> toJson() => {
        if (pitchNotes.isNotEmpty) 'notes': pitchNotes.map((n) => n.toJson()).toList(),
        if (drumNotes.isNotEmpty) 'drums': drumNotes.map((n) => n.toJson()).toList(),
        if (clip != null) 'clip': clip,
        if (vocalPath != null) 'vocalPath': vocalPath,
        if (vocalOrigPath != null) 'vocalOrigPath': vocalOrigPath,
        if (vocalAligned) 'vocalAligned': true,
        if (vocalBpm != null) 'vocalBpm': vocalBpm,
        if (vocalBars != null) 'vocalBars': vocalBars,
      };

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
    this.bars = 2,
    this.repeats = 1,
  })  : tracks = tracks ?? _emptyTracks(),
        extras = extras ?? [],
        order = order ?? [];

  String id;
  String name;
  final Map<String, TrackData> tracks; // keyed by track id (base ids + extra ids)
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
        bars: bars,
        repeats: repeats,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tracks': tracks.map((k, v) => MapEntry(k, v.toJson())),
        'extras': [for (final e in extras) e.toJson()],
        'order': order,
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
      );

  static String encodeList(List<Song> songs) =>
      jsonEncode(songs.map((s) => s.toJson()).toList());

  static List<Song> decodeList(String raw) {
    final list = jsonDecode(raw) as List;
    return list.map((e) => Song.fromJson(e as Map<String, dynamic>)).toList();
  }
}
