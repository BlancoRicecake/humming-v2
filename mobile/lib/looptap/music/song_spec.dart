import 'dart:convert';

import '../models/loop_models.dart';

/// Model-neutral, versioned handoff between HumTrack's editor and an optional
/// arrangement engine. No provider-specific prompt or token is persisted here.
class SongSpec {
  SongSpec({
    required this.title,
    required this.tonic,
    required this.scale,
    required this.bpm,
    required this.swing,
    required this.sections,
    required this.locks,
  });

  static const int schemaVersion = 1;
  final String title;
  final String tonic;
  final String scale;
  final int bpm;
  final double swing;
  final List<SongSpecSection> sections;
  final Map<String, bool> locks;

  factory SongSpec.fromSong(Song song) => SongSpec(
    title: song.title,
    tonic: song.key,
    scale: song.scale,
    bpm: song.bpm,
    swing: song.swing,
    locks: Map.of(song.generationLocks),
    sections: [
      for (final section in song.sections)
        SongSpecSection(
          id: section.id,
          name: section.name,
          bars: section.bars,
          repeats: section.repeats,
          tracks: {
            for (final entry in section.tracks.entries)
              entry.key: SongSpecTrack(
                notes: [
                  for (final note in entry.value.pitchNotes)
                    SongSpecNote(
                      midi: note.midi,
                      step: note.step,
                      duration: note.dur,
                      sourceMidi: note.sourceMidi,
                      confidence: note.confidence,
                      locked:
                          note.locked ||
                          (song.generationLocks[entry.key] ?? false),
                    ),
                ],
              ),
          },
        ),
    ],
  );

  Map<String, dynamic> toJson() => {
    'schema': 'humtrack.song-spec',
    'version': schemaVersion,
    'title': title,
    'tonic': tonic,
    'scale': scale,
    'bpm': bpm,
    'swing': swing,
    'locks': locks,
    'sections': [for (final section in sections) section.toJson()],
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// A compact ABC plan suitable for inspection and score-conditioned research.
  /// The melody is voice 1 and generated chord notes are voice 2. A production
  /// adapter may add provider-specific metadata outside this canonical score.
  String toAbc({int sectionIndex = 0}) {
    if (sections.isEmpty) throw StateError('SongSpec has no sections');
    final section = sections[sectionIndex.clamp(0, sections.length - 1)];
    final melody = section.tracks['melody']?.notes ?? const [];
    final chords = section.tracks['melodyDec']?.notes ?? const [];
    final key = '${_abcTonic(tonic)}${scale == 'minor' ? 'm' : ''}';
    final out = StringBuffer()
      ..writeln('X:1')
      ..writeln('T:${title.replaceAll('\n', ' ')}')
      ..writeln('M:4/4')
      ..writeln('L:1/16')
      ..writeln('Q:1/4=$bpm')
      ..writeln('K:$key')
      ..writeln('V:1 name="Melody"')
      ..writeln(_voiceToAbc(melody, section.bars * 16));
    if (chords.isNotEmpty) {
      out
        ..writeln('V:2 name="Chords"')
        ..writeln(_voiceToAbc(chords, section.bars * 16));
    }
    return out.toString();
  }
}

class SongSpecSection {
  SongSpecSection({
    required this.id,
    required this.name,
    required this.bars,
    required this.repeats,
    required this.tracks,
  });
  final String id;
  final String name;
  final int bars;
  final int repeats;
  final Map<String, SongSpecTrack> tracks;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'bars': bars,
    'repeats': repeats,
    'tracks': tracks.map((key, value) => MapEntry(key, value.toJson())),
  };
}

class SongSpecTrack {
  SongSpecTrack({required this.notes});
  final List<SongSpecNote> notes;
  Map<String, dynamic> toJson() => {
    'notes': [for (final n in notes) n.toJson()],
  };
}

class SongSpecNote {
  SongSpecNote({
    required this.midi,
    required this.step,
    required this.duration,
    required this.sourceMidi,
    required this.confidence,
    required this.locked,
  });
  final int midi;
  final int step;
  final int duration;
  final int? sourceMidi;
  final double confidence;
  final bool locked;
  Map<String, dynamic> toJson() => {
    'midi': midi,
    'step': step,
    'duration': duration,
    if (sourceMidi != null) 'sourceMidi': sourceMidi,
    'confidence': confidence,
    'locked': locked,
  };
}

String _abcTonic(String tonic) =>
    tonic.replaceAll('#', '^').replaceAll('b', '_');

String _voiceToAbc(List<SongSpecNote> notes, int totalSteps) {
  final grouped = <int, List<SongSpecNote>>{};
  for (final note in notes) {
    grouped.putIfAbsent(note.step, () => []).add(note);
  }
  final out = StringBuffer();
  var cursor = 0;
  while (cursor < totalSteps) {
    final due = grouped[cursor];
    if (due == null || due.isEmpty) {
      var rest = 1;
      while (cursor + rest < totalSteps &&
          !grouped.containsKey(cursor + rest)) {
        rest++;
      }
      out.write('z${_abcLength(rest)} ');
      cursor += rest;
      continue;
    }
    final duration = due.map((n) => n.duration).reduce((a, b) => a < b ? a : b);
    if (due.length == 1) {
      out.write('${_midiToAbc(due.first.midi)}${_abcLength(duration)} ');
    } else {
      out.write(
        '[${due.map((n) => _midiToAbc(n.midi)).join()}]${_abcLength(duration)} ',
      );
    }
    cursor += duration;
  }
  return out.toString().trimRight();
}

String _abcLength(int steps) => steps == 1 ? '' : '$steps';

String _midiToAbc(int midi) {
  const names = [
    'C',
    '^C',
    'D',
    '^D',
    'E',
    'F',
    '^F',
    'G',
    '^G',
    'A',
    '^A',
    'B',
  ];
  final pc = ((midi % 12) + 12) % 12;
  final octave = midi ~/ 12 - 1;
  var name = names[pc];
  if (octave >= 5) {
    name = name.toLowerCase() + _repeat("'", octave - 5);
  } else if (octave < 4) {
    name += _repeat(',', 4 - octave);
  }
  return name;
}

String _repeat(String value, int count) => List.filled(count, value).join();
