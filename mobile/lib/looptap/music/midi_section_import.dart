// MIDI passage → one new section of an EXISTING song
// (docs/specs/midi-section-import.md).
//
// The notes come from [MidiReference.passage] unchanged (pitch, freq,
// velocity, offsetSteps, durationSteps): every mapped lane is converted on
// its own, so the temporary song's internal track ids never decide where a
// lane lands — the mapping is keyed by lane identity. The song's tempo,
// key/scale, swing, existing instruments and mix are never touched; only a
// NEW extra track may take the file's GM program.
import '../models/loop_models.dart';
import 'guitar_articulation.dart';
import 'midi_import.dart';
import 'theory.dart';

/// Mapping value: put the lane on a new added track.
const String kMidiNewTrack = '+new';

/// Mapping value: leave the lane out.
const String kMidiSkip = '-';

/// Why no new track can be added (null = some channel is free).
enum MidiNewTrackBlock {
  /// Every independent-instrument channel is taken.
  limit,

  /// The next channel is reserved by a guitar articulation voice.
  articulation,

  /// Sections disagree on their added tracks, so the next channel differs.
  layout,
}

/// The channels successive new tracks would get, and why the list stopped.
class MidiNewTrackChannels {
  const MidiNewTrackChannels(this.channels, this.block);
  final List<int> channels;
  final MidiNewTrackBlock? block;
}

/// The finished insert: apply it with [applyMidiSection].
class MidiSectionResult {
  MidiSectionResult({
    required this.section,
    required this.newTracks,
    required this.newInstruments,
    required this.laneTracks,
    required this.notes,
    required this.skipped,
    required this.outOfScale,
  });

  /// The new, unlinked section (repeats 1).
  final Section section;

  /// Added tracks; [applyMidiSection] appends them to every section.
  final List<TrackRef> newTracks;

  /// Programs of the added tracks only.
  final Map<String, int> newInstruments;

  /// MIDI lane id → the track id it was written to.
  final Map<String, String> laneTracks;
  final int notes, skipped, outOfScale;
}

/// The added tracks of the whole song, first-seen order (the track set is
/// song-wide; export and Play song use the same union).
List<TrackRef> songExtras(List<Section> sections) {
  final out = <TrackRef>[];
  final seen = <String>{};
  for (final s in sections) {
    for (final e in s.extras) {
      if (seen.add(e.id)) out.add(TrackRef(e.id, e.type));
    }
  }
  return out;
}

String _typeOf(String id, List<TrackRef> extras) {
  for (final e in extras) {
    if (e.id == id) return e.type;
  }
  return id;
}

/// The lanes with at least one note inside the window (same test as
/// [MidiReference.passage]).
List<ReferenceLane> midiLanesIn(
  MidiReference midi,
  int startBar,
  int lengthBars,
) {
  final start = (startBar - 1) * midi.ppq * 4;
  final end = start + lengthBars * midi.ppq * 4;
  return [
    for (final l in midi.lanes)
      if (l.notes.any((n) => n.tick < end && n.endTick > start)) l,
  ];
}

/// Existing tracks [lane] may go to: melody-type lanes → melody / melody
/// fill / bass (+ added pitched tracks), drum lanes → drums / beat fill
/// (+ added drum tracks).
List<String> midiTargetIds(ReferenceLane lane, List<Section> sections) {
  final want =
      lane.drums
          ? const {TrackKind.drums}
          : const {TrackKind.pitched, TrackKind.bass};
  return [
    for (final t in kTracks)
      if (want.contains(t.kind)) t.id,
    for (final e in songExtras(sections))
      if (want.contains(trackById(e.type).kind)) e.id,
  ];
}

/// Default mapping (GM program / channel heuristic): drum-channel lanes →
/// drums, beat fill, added drum tracks; the first bass-program (32–39) lane →
/// bass; every other melodic lane in order → melody, melody fill, then any
/// still-free melodic target. Lanes left over are skipped (a new track is
/// never chosen by default).
Map<String, String> defaultMidiMapping(
  List<ReferenceLane> lanes,
  List<Section> sections,
) {
  final out = <String, String>{};
  final taken = <String>{};
  String pick(List<String> order) {
    for (final id in order) {
      if (taken.add(id)) return id;
    }
    return kMidiSkip;
  }

  for (final l in lanes.where((l) => l.drums)) {
    out[l.id] = pick(midiTargetIds(l, sections));
  }
  for (final l in lanes) {
    if (!l.drums &&
        l.program >= 32 &&
        l.program <= 39 &&
        !taken.contains('bass')) {
      out[l.id] = pick(const ['bass']);
    }
  }
  for (final l in lanes) {
    if (l.drums || out.containsKey(l.id)) continue;
    final targets = midiTargetIds(l, sections);
    out[l.id] = pick([
      'melody',
      'melodyDec',
      for (final t in targets)
        if (t != 'melody' && t != 'melodyDec') t,
    ]);
  }
  return out;
}

/// The channels new tracks would take, in order. A channel is offered only
/// when it is the same in every section (channels are positional over each
/// section's added tracks) and no track of any section nor any guitar
/// articulation voice ([ArticulationPlan]) uses it.
MidiNewTrackChannels midiNewTrackChannels(
  List<Section> sections,
  Map<String, int> instruments,
) {
  final used = <int>{};
  for (final s in sections) {
    for (final m in sectionTrackMetas(s.extras)) {
      if (m.kind != TrackKind.vocal) used.add(m.channel);
    }
  }
  final art = <int>{
    for (final r
        in ArticulationPlan.build(
          sections: sections,
          instruments: instruments,
        ).routes)
      r.channel,
  };
  int pitchedCount(List<TrackRef> l) =>
      l.where((e) => trackById(e.type).kind != TrackKind.vocal).length;
  final layouts = [
    pitchedCount(songExtras(sections)),
    for (final s in sections) pitchedCount(s.extras),
  ];
  final out = <int>[];
  for (var k = 0; ; k++) {
    final chans = <int>{};
    for (final n in layouts) {
      if (n + k >= kExtraPitchChannels.length) {
        return MidiNewTrackChannels(out, MidiNewTrackBlock.limit);
      }
      chans.add(kExtraPitchChannels[n + k]);
    }
    if (chans.length != 1) {
      return MidiNewTrackChannels(out, MidiNewTrackBlock.layout);
    }
    final ch = chans.single;
    if (art.contains(ch)) {
      return MidiNewTrackChannels(out, MidiNewTrackBlock.articulation);
    }
    if (used.contains(ch)) {
      return MidiNewTrackChannels(out, MidiNewTrackBlock.layout);
    }
    out.add(ch);
  }
}

/// Pitched notes of the mapped lanes outside [key] + [scale].
int midiOutOfScale(
  MidiReference midi,
  int startBar,
  int lengthBars,
  Map<String, String> mapping,
  String key,
  String scale,
) {
  final start = (startBar - 1) * midi.ppq * 4;
  final end = start + lengthBars * midi.ppq * 4;
  var n = 0;
  for (final l in midiLanesIn(midi, startBar, lengthBars)) {
    if (l.drums || (mapping[l.id] ?? kMidiSkip) == kMidiSkip) continue;
    for (final note in l.notes) {
      if (note.tick < end &&
          note.endTick > start &&
          !inScale(note.pitch, key, scale)) {
        n++;
      }
    }
  }
  return n;
}

/// Build the new section after `sections[currentIdx]`. Pure: [sections] and
/// [instruments] are only read. Throws [FormatException] for files
/// [MidiReference.passage] refuses (non-4/4, tempo changes, …), an empty or
/// duplicate mapping, or more new tracks than free channels.
MidiSectionResult sectionFromPassage({
  required List<Section> sections,
  required int currentIdx,
  required Map<String, int> instruments,
  required String key,
  required String scale,
  required MidiReference midi,
  required String title,
  required int startBar,
  required int lengthBars,
  required Map<String, String> mapping,
  bool useFileProgram = true,
  int? stamp,
}) {
  final lanes = midiLanesIn(midi, startBar, lengthBars);
  final current = sections[currentIdx];
  final mapped = [
    for (final l in lanes)
      if ((mapping[l.id] ?? kMidiSkip) != kMidiSkip) l,
  ];
  if (mapped.isEmpty) {
    // let passage report its own refusals (tempo map, range, no notes) first
    midi.passage(title: title, startBar: startBar, lengthBars: lengthBars);
    throw const FormatException('Choose at least one part to import.');
  }
  final taken = <String>{};
  for (final l in mapped) {
    final t = mapping[l.id]!;
    if (t == kMidiNewTrack) continue;
    if (!midiTargetIds(l, sections).contains(t)) {
      throw FormatException('${l.name} cannot go to $t.');
    }
    if (!taken.add(t)) {
      throw const FormatException('Two parts cannot go to one track.');
    }
  }
  final wantNew = mapped.where((l) => mapping[l.id] == kMidiNewTrack).length;
  if (wantNew > midiNewTrackChannels(sections, instruments).channels.length) {
    throw const FormatException('No free channel for a new track.');
  }

  final t = stamp ?? DateTime.now().microsecondsSinceEpoch;
  final ids = <String>{
    for (final s in sections) ...s.tracks.keys,
    for (final s in sections) ...s.extras.map((e) => e.id),
  };
  var secId = 'sec$t';
  for (var i = 2; sections.any((s) => s.id == secId); i++) {
    secId = 'sec${t}_$i';
  }
  final union = songExtras(sections);
  final newRefs = <TrackRef>[];
  final newPrograms = <String, int>{};
  final laneTracks = <String, String>{};
  final data = <String, TrackData>{};
  var notes = 0;
  for (final l in mapped) {
    // one lane per passage call: its notes are exactly the new-song import's
    final tmp = midi.passage(
      title: title,
      startBar: startBar,
      lengthBars: lengthBars,
      selectedLanes: {l.id},
    );
    final tmpId = l.drums ? 'drums' : 'melody';
    final src = tmp.sections.single.tracks[tmpId]!;
    notes += src.pitchNotes.length + src.drumNotes.length;
    var target = mapping[l.id]!;
    if (target == kMidiNewTrack) {
      final type = l.drums ? 'drums' : 'melody';
      var id = '${type}_x$t';
      for (var i = 2; ids.contains(id); i++) {
        id = '${type}_x${t}_$i';
      }
      ids.add(id);
      newRefs.add(TrackRef(id, type));
      newPrograms[id] =
          useFileProgram && !l.drums
              ? tmp.instruments[tmpId]!
              : trackById(type).defaultProgram;
      data[id] = src; // keeps the lane label and percussion palette
      target = id;
    } else {
      final own = current.tracks[target];
      List<String>? kinds;
      if (l.drums) {
        final base =
            own?.drumKinds ??
            trackById(_typeOf(target, union)).drumKinds ??
            const <String>[];
        final merged = [
          ...base,
          for (final k in src.drumKinds ?? const <String>[])
            if (!base.contains(k)) k,
        ];
        kinds =
            own?.drumKinds == null && merged.length == base.length
                ? null
                : merged;
      }
      data[target] = TrackData(
        notes: src.pitchNotes,
        drums: src.drumNotes,
        label: own?.label,
        drumKinds: kinds,
      );
    }
    laneTracks[l.id] = target;
  }

  final extras = [...union, ...newRefs];
  final section = Section(
    id: secId,
    name: '$title [$startBar–${startBar + lengthBars - 1}]',
    autoName: false,
    bars: lengthBars,
    extras: extras,
    order: [...current.order],
  );
  for (final e in extras) {
    section.tracks[e.id] = TrackData();
  }
  section.tracks.addAll(data);
  return MidiSectionResult(
    section: section,
    newTracks: newRefs,
    newInstruments: newPrograms,
    laneTracks: laneTracks,
    notes: notes,
    skipped: lanes.length - mapped.length,
    outOfScale: midiOutOfScale(midi, startBar, lengthBars, mapping, key, scale),
  );
}

/// Commit [r]: every existing section gets the new tracks as empty lanes
/// (the track set is song-wide, so channels stay positional and equal), the
/// section goes right after [currentIdx], and only the new tracks' programs
/// enter [instruments]. The caller records ONE undo step before this.
void applyMidiSection(
  List<Section> sections,
  int currentIdx,
  MidiSectionResult r,
  Map<String, int> instruments,
) {
  for (final s in sections) {
    for (final e in r.newTracks) {
      s.extras.add(TrackRef(e.id, e.type));
      // linked sections share one map: add the empty lane once
      s.tracks.putIfAbsent(e.id, TrackData.new);
    }
  }
  sections.insert(currentIdx + 1, r.section);
  instruments.addAll(r.newInstruments);
}
