// MIDI passage → a new section of an existing song.
// docs/specs/midi-section-import.md
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/midi_section_import.dart';
import 'package:humming/looptap/music/section_links.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/section_bar.dart';
import 'package:humming/looptap/widgets/sheets/midi_import_sheet.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

// ── SMF builder (ppq 480: a bar is 1920 ticks, a step 120) ──
class Part {
  const Part(this.name, this.channel, this.program, this.notes);
  final String name;
  final int channel, program;

  /// (pitch, tick, length, velocity)
  final List<(int, int, int, int)> notes;
}

List<int> vlq(int v) {
  final out = [v & 127];
  v >>= 7;
  while (v > 0) {
    out.insert(0, (v & 127) | 128);
    v >>= 7;
  }
  return out;
}

List<int> tempo(int bpm) {
  final us = (60000000 / bpm).round();
  return [0xff, 0x51, 3, (us >> 16) & 255, (us >> 8) & 255, us & 255];
}

Uint8List midiFile(
  List<Part> parts, {
  int bpm = 100,
  bool fourFour = true,
  bool tempoChange = false,
}) {
  final tracks = <List<int>>[
    [
      0,
      ...tempo(bpm),
      0,
      0xff,
      0x58,
      4,
      fourFour ? 4 : 3,
      2,
      24,
      8,
      if (tempoChange) ...[...vlq(1920), ...tempo(bpm + 20)],
      0,
      0xff,
      0x2f,
      0,
    ],
  ];
  for (final p in parts) {
    final name = utf8.encode(p.name);
    final ev = <(int, int, List<int>)>[
      (0, 0, [0xff, 3, name.length, ...name]),
      if (p.channel != 9) (0, 0, [0xc0 | p.channel, p.program]),
      for (final n in p.notes) ...[
        (n.$2, 2, [0x90 | p.channel, n.$1, n.$4]),
        (n.$2 + n.$3, 1, [0x80 | p.channel, n.$1, 0]),
      ],
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
    final t = <int>[];
    var last = 0;
    for (final e in ev) {
      t
        ..addAll(vlq(e.$1 - last))
        ..addAll(e.$3);
      last = e.$1;
    }
    t.addAll([0, 0xff, 0x2f, 0]);
    tracks.add(t);
  }
  return Uint8List.fromList([
    ...'MThd'.codeUnits,
    0, 0, 0, 6, 0, 1, 0, tracks.length, 1, 224, //
    for (final t in tracks) ...[
      ...'MTrk'.codeUnits,
      (t.length >> 24) & 255,
      (t.length >> 16) & 255,
      (t.length >> 8) & 255,
      t.length & 255,
      ...t,
    ],
  ]);
}

// Lane order follows the first note: bass, piano, strings, drums.
const bassLane = '1:2:33', pianoLane = '2:0:0';
const stringsLane = '3:1:48', drumLane = '4:9:0';
const verseParts = [
  Part('Bass', 2, 33, [(45, 0, 400, 90), (40, 2050, 300, 70)]),
  Part('Piano', 0, 0, [
    (60, 10, 230, 100),
    (61, 960, 240, 64),
    (69, 1930, 480, 111),
  ]),
  Part('Strings', 1, 48, [(66, 20, 1900, 50), (64, 2000, 600, 80)]),
  Part('Drums', 9, 0, [
    (36, 30, 60, 120),
    (42, 480, 60, 90),
    (49, 1920, 60, 127),
  ]),
];
MidiReference verse({int bpm = 100}) =>
    MidiReference.parse(midiFile(verseParts, bpm: bpm));

PitchNote pn(int midi, int step) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step);

/// A: melody + drums, B linked to A, C independent; one added guitar track.
Song existingSong({bool palmMuted = false}) {
  final a = Section(id: 'A', name: 'A', repeats: 2);
  a.tracks['melody']!.pitchNotes.addAll([pn(57, 0), pn(60, 4)]);
  a.tracks['drums']!.drumNotes.add(DrumNote(kind: 'kick', step: 0));
  final b = duplicateLinked(a, 'B')..repeats = 1;
  final c = Section(id: 'C', name: 'Chorus', autoName: false, bars: 4);
  c.tracks['bass']!.pitchNotes.add(pn(45, 0));
  for (final s in [a, b, c]) {
    s.extras.add(const TrackRef('melody_x1', 'melody'));
    s.tracks.putIfAbsent('melody_x1', TrackData.new);
  }
  final g = pn(52, 8);
  c.tracks['melody_x1']!.pitchNotes.add(
    palmMuted
        ? g.withArticulation(
          const Articulation(kind: ArticulationKind.palmTone),
        )
        : g,
  );
  return Song(
    id: 'song',
    title: 'Existing',
    key: 'A',
    scale: 'minor',
    bpm: 92,
    swing: 0.2,
    sections: [a, b, c],
    instruments: {'melody': 4, 'melodyDec': 48, 'bass': 34, 'melody_x1': 25},
    vol: {'melody': 0.7, 'drums': 0.9, 'melody_x1': 0.5},
    pan: {'melody': -0.4, 'melody_x1': 0.3},
    mutes: {'beatDec': true},
    trackGrooves: {'drums': const GrooveAssign(grooveId: 'builtin:swing8')},
  );
}

Map<String, int> programs(Song s) => {
  for (final t in kPitchedTracks) t.id: s.instruments[t.id] ?? t.defaultProgram,
  ...s.instruments,
};

MidiSectionResult build(
  Song song,
  MidiReference midi,
  Map<String, String> mapping, {
  int currentIdx = 0,
  int startBar = 1,
  int lengthBars = 2,
  bool useFileProgram = true,
}) => sectionFromPassage(
  sections: song.sections,
  currentIdx: currentIdx,
  instruments: programs(song),
  key: song.key,
  scale: song.scale,
  midi: midi,
  title: 'verse',
  startBar: startBar,
  lengthBars: lengthBars,
  mapping: mapping,
  useFileProgram: useFileProgram,
);

Map<String, String> defaults(Song song, MidiReference midi, [int bars = 2]) =>
    defaultMidiMapping(midiLanesIn(midi, 1, bars), song.sections);

String notesJson(TrackData t) => jsonEncode({
  'notes': [for (final n in t.pitchNotes) n.toJson()],
  'drums': [for (final n in t.drumNotes) n.toJson()],
});

/// Song-level values the import must never change (sections/dates aside).
Map<String, dynamic> songLevel(Song s) =>
    s.toJson()
      ..remove('sections')
      ..remove('updatedAt')
      ..remove('wave');

/// A section's JSON without the lanes in [added] (the new tracks' empty
/// lanes that every section receives).
String without(Section s, Set<String> added) {
  final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
  (j['tracks'] as Map).removeWhere((k, _) => added.contains(k));
  (j['extras'] as List).removeWhere((e) => added.contains((e as Map)['id']));
  return jsonEncode(j);
}

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

void main() {
  group('sectionFromPassage', () {
    test('notes equal the new-song import of the same passage, by lane', () {
      final midi = verse();
      final song = existingSong();
      final mapping = defaults(song, midi);
      // GM heuristic: the bass program goes to bass even though it comes first
      expect(mapping, {
        bassLane: 'bass',
        pianoLane: 'melody',
        stringsLane: 'melodyDec',
        drumLane: 'drums',
      });
      final r = build(song, midi, mapping);
      // the unchanged new-song importer maps pitched lanes in file order
      final imported =
          midi
              .passage(title: 'verse', startBar: 1, lengthBars: 2)
              .sections
              .single
              .tracks;
      const importerIds = {
        bassLane: 'melody',
        pianoLane: 'melodyDec',
        stringsLane: 'bass',
        drumLane: 'drums',
      };
      expect(imported['melody']!.label, 'Bass · 3');
      for (final e in importerIds.entries) {
        final mine = r.section.tracks[r.laneTracks[e.key]]!;
        expect(notesJson(mine), notesJson(imported[e.value]!), reason: e.key);
      }
      final piano = r.section.tracks['melody']!.pitchNotes;
      expect([for (final n in piano) n.midi], [60, 61, 69]);
      expect([for (final n in piano) n.velocity], [100, 64, 111]);
      expect(piano.first.offsetSteps, closeTo(10 / 120, 1e-9));
      expect(piano.first.durationSteps, closeTo(230 / 120, 1e-9));
      expect(piano.last.freq, midiToFreq(69));
      final bass = r.section.tracks['bass']!.pitchNotes.last;
      expect(bass.step, 17);
      expect(bass.offsetSteps, closeTo(10 / 120, 1e-9));
      expect(r.section.tracks['drums']!.drumNotes.map((n) => n.velocity), [
        120,
        90,
        127,
      ]);
      expect((r.notes, r.skipped, r.outOfScale), (10, 0, 2));
    });

    test('existing sections, links and song values are unchanged', () {
      final midi = verse();
      final song = existingSong();
      final before = [for (final s in song.sections) jsonEncode(s.toJson())];
      final level = jsonEncode(songLevel(song));
      final r = build(song, midi, defaults(song, midi), currentIdx: 1);
      expect(r.newTracks, isEmpty);
      expect(r.newInstruments, isEmpty);
      applyMidiSection(song.sections, 1, r, song.instruments);
      expect(song.sections.map((s) => s.id).toList(), [
        'A',
        'B',
        r.section.id,
        'C',
      ]);
      final rest = [...song.sections]..removeAt(2);
      expect([for (final s in rest) jsonEncode(s.toJson())], before);
      expect(jsonEncode(songLevel(song)), level);
      // linked group untouched; the new section is independent
      expect(
        identical(song.sections[0].tracks, song.sections[1].tracks),
        isTrue,
      );
      expect(song.sections[1].linkId, song.sections[0].linkId);
      final added = song.sections[2];
      expect(added.linkId, isNull);
      expect(added.repeats, 1);
      expect(added.bars, 2);
      expect(added.name, 'verse [1–2]');
      expect(added.autoName, isFalse);
      // song-wide track set: the added guitar lane exists, empty
      expect(added.extras.map((e) => e.id), ['melody_x1']);
      expect(added.tracks['melody_x1']!.pitchNotes, isEmpty);
    });

    test('a new track: free channel, own id, file program; others gain an '
        'empty lane only', () {
      final midi = verse();
      final song = existingSong();
      final before = [for (final s in song.sections) jsonEncode(s.toJson())];
      final level = songLevel(song);
      final mapping = defaults(song, midi)..[stringsLane] = kMidiNewTrack;
      final r = build(song, midi, mapping);
      final ref = r.newTracks.single;
      expect(ref.type, 'melody');
      expect(song.sections.any((s) => s.tracks.containsKey(ref.id)), isFalse);
      expect(r.newInstruments, {ref.id: 48});
      expect(r.laneTracks[stringsLane], ref.id);
      expect(r.section.tracks[ref.id]!.label, 'Strings · 2');
      expect(
        build(
          song,
          midi,
          mapping,
          useFileProgram: false,
        ).newInstruments.values.single,
        trackById('melody').defaultProgram,
      );

      applyMidiSection(song.sections, 0, r, song.instruments);
      final rest = [...song.sections]..removeAt(1);
      expect([
        for (final s in rest) without(s, {ref.id}),
      ], before);
      // only the new track's program enters the song's instruments
      final after = songLevel(song);
      expect(
        (after['instruments'] as Map)..remove(ref.id),
        level['instruments'],
      );
      for (final k in level.keys.where((k) => k != 'instruments')) {
        expect(jsonEncode(after[k]), jsonEncode(level[k]), reason: k);
      }
      // the channel is the same in every section and nobody else's
      final channels = {
        for (final s in song.sections)
          sectionTrackMetas(s.extras).firstWhere((m) => m.id == ref.id).channel,
      };
      expect(channels, {4});
      for (final s in song.sections) {
        final others = sectionTrackMetas(
          s.extras,
        ).where((m) => m.id != ref.id && m.kind != TrackKind.vocal);
        expect(others.map((m) => m.channel), isNot(contains(4)));
      }
      expect(
        identical(song.sections[0].tracks, song.sections[2].tracks),
        isTrue,
      );
      expect(song.sections[1].linkId, isNull);
    });

    test('mapping rules: skip, no duplicates, compatible targets only', () {
      final midi = verse();
      final song = existingSong();
      final skip = defaults(song, midi)..[stringsLane] = kMidiSkip;
      final r = build(song, midi, skip);
      expect((r.notes, r.skipped, r.outOfScale), (8, 1, 1));
      expect(r.laneTracks.containsKey(stringsLane), isFalse);
      expect(r.section.tracks['melodyDec']!.pitchNotes, isEmpty);
      expect(
        () => build(song, midi, defaults(song, midi)..[stringsLane] = 'melody'),
        throwsFormatException,
      );
      expect(
        () => build(song, midi, defaults(song, midi)..[drumLane] = 'melodyDec'),
        throwsFormatException,
      );
      expect(
        () => build(song, midi, {for (final l in midi.lanes) l.id: kMidiSkip}),
        throwsFormatException,
      );
      // an added pitched track is a valid target; drums only reach drum lanes
      final lane = midi.lanes.firstWhere((l) => l.id == pianoLane);
      expect(midiTargetIds(lane, song.sections), [
        'melody',
        'melodyDec',
        'bass',
        'melody_x1',
      ]);
      expect(
        midiTargetIds(
          midi.lanes.firstWhere((l) => l.id == drumLane),
          song.sections,
        ),
        ['drums', 'beatDec'],
      );
      final toGuitar = defaults(song, midi)..[stringsLane] = 'melody_x1';
      expect(
        build(song, midi, toGuitar).section.tracks['melody_x1']!.pitchNotes,
        hasLength(2),
      );
      // the instrument of an existing target is never touched
      expect(build(song, midi, toGuitar).newInstruments, isEmpty);
    });

    test('new tracks avoid articulation channels and stop at the limit', () {
      final free = midiNewTrackChannels(
        existingSong().sections,
        programs(existingSong()),
      );
      expect(free.channels, [4, 5, 6, 7, 8, 11, 12, 13, 14]);
      expect(free.block, MidiNewTrackBlock.limit);

      // a palm-muted guitar holds channel 4 for its articulation voice
      final palm = existingSong(palmMuted: true);
      final plan = ArticulationPlan.build(
        sections: palm.sections,
        instruments: programs(palm),
      );
      expect(plan.channelFor('melody_x1', ArtRole.muteVoice), 4);
      final blocked = midiNewTrackChannels(palm.sections, programs(palm));
      expect(blocked.channels, isEmpty);
      expect(blocked.block, MidiNewTrackBlock.articulation);
      final midi = verse();
      expect(
        () => build(
          palm,
          midi,
          defaults(palm, midi)..[stringsLane] = kMidiNewTrack,
        ),
        throwsFormatException,
      );

      // every independent channel used
      final full = existingSong();
      for (final s in full.sections) {
        for (var i = 2; i <= 10; i++) {
          s.extras.add(TrackRef('melody_x$i', 'melody'));
          s.tracks.putIfAbsent('melody_x$i', TrackData.new);
        }
      }
      final none = midiNewTrackChannels(full.sections, programs(full));
      expect(none.channels, isEmpty);
      expect(none.block, MidiNewTrackBlock.limit);

      // sections disagreeing on their added tracks
      final odd = existingSong();
      odd.sections[2].extras.add(const TrackRef('drums_x9', 'drums'));
      expect(
        midiNewTrackChannels(odd.sections, programs(odd)).block,
        MidiNewTrackBlock.layout,
      );
    });

    test('tempo changes and non-4/4 files are refused', () {
      final song = existingSong();
      for (final bytes in [
        midiFile(verseParts, fourFour: false),
        midiFile(verseParts, tempoChange: true),
      ]) {
        final midi = MidiReference.parse(bytes);
        expect(midi.constantTempo && midi.fourFour, isFalse);
        expect(
          () => build(song, midi, defaults(song, midi)),
          throwsFormatException,
        );
      }
    });

    test('an 8-bar passage fits one section', () {
      final midi = MidiReference.parse(
        midiFile([
          Part('Lead', 0, 0, [
            for (var bar = 0; bar < 9; bar++) (64, bar * 1920 + 60, 240, 90),
          ]),
        ]),
      );
      final song = existingSong();
      final r = build(song, midi, defaults(song, midi, 8), lengthBars: 8);
      expect(r.section.bars, 8);
      final notes = r.section.tracks['melody']!.pitchNotes;
      expect(notes, hasLength(8));
      expect(notes.last.step, 7 * 16);
      expect(notes.last.offsetSteps, closeTo(.5, 1e-9));
      expect(
        notesJson(r.section.tracks['melody']!),
        notesJson(
          midi
              .passage(title: 'x', startBar: 1, lengthBars: 8)
              .sections
              .single
              .tracks['melody']!,
        ),
      );
    });

    test('save and load keep the new section, track and links', () {
      final midi = verse();
      final song = existingSong();
      final mapping = defaults(song, midi)..[stringsLane] = kMidiNewTrack;
      final r = build(song, midi, mapping);
      applyMidiSection(song.sections, 0, r, song.instruments);
      final loaded = Song.fromJson(
        jsonDecode(jsonEncode(song.toJson())) as Map<String, dynamic>,
      );
      final sections = relinkSections(loaded.sections);
      expect(
        [for (final s in sections) jsonEncode(s.toJson())],
        [for (final s in song.sections) jsonEncode(s.toJson())],
      );
      expect(identical(sections[0].tracks, sections[2].tracks), isTrue);
      expect(sections[1].linkId, isNull);
      expect(loaded.instruments[r.newTracks.single.id], 48);
    });
  });

  group('dialog', () {
    setUp(useOfflineTestFonts);

    testWidgets('notices, out-of-scale count and mapping table', (
      tester,
    ) async {
      final song = existingSong();
      final midi = verse();
      MidiSectionResult? result;
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showMidiSectionDialog(
                        context,
                        midi: midi,
                        title: 'verse',
                        target: MidiSectionTarget(
                          sections: song.sections,
                          currentIdx: 0,
                          instruments: programs(song),
                          keyRoot: song.key,
                          scale: song.scale,
                          bpm: song.bpm,
                        ),
                      );
                      closed = true;
                    },
                    child: const Text('Open'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('MIDI passage as new section'), findsOneWidget);
      expect(find.byKey(const ValueKey('midi-section-bpm')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('midi-section-instruments')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('midi-section-rejected')), findsNothing);
      expect(
        find.byKey(const ValueKey('midi-section-new-blocked')),
        findsNothing,
      );
      Text scale() =>
          tester.widget<Text>(find.byKey(const ValueKey('midi-section-scale')));
      expect(scale().data, startsWith('2 notes are outside'));

      // strings → skip: one fewer out-of-scale note
      await tester.tap(find.byKey(const ValueKey('midi-map-$stringsLane')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip').last);
      await tester.pumpAndSettle();
      expect(scale().data, startsWith('1 notes are outside'));

      // melody is taken by the piano: disabled for the bass lane
      await tester.tap(find.byKey(const ValueKey('midi-map-$bassLane')));
      await tester.pumpAndSettle();
      final melodyItem = tester.widget<DropdownMenuItem<String>>(
        find.ancestor(
          of: find.text('Melody').last,
          matching: find.byType(DropdownMenuItem<String>),
        ),
      );
      expect(melodyItem.enabled, isFalse);
      await tester.tap(find.text('Bass').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('midi-import-confirm')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(result!.laneTracks, {
        bassLane: 'bass',
        pianoLane: 'melody',
        drumLane: 'drums',
      });
      expect((result!.skipped, result!.outOfScale), (1, 1));
    });

    testWidgets('no free channel: new track disabled with a reason; refused '
        'files cannot be added', (tester) async {
      final palm = existingSong(palmMuted: true);
      Future<void> show(MidiReference midi) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder:
                  (context) => Scaffold(
                    body: TextButton(
                      onPressed:
                          () => showMidiSectionDialog(
                            context,
                            midi: midi,
                            title: 'verse',
                            target: MidiSectionTarget(
                              sections: palm.sections,
                              currentIdx: 0,
                              instruments: programs(palm),
                              keyRoot: palm.key,
                              scale: palm.scale,
                              bpm: 100,
                            ),
                          ),
                      child: const Text('Open'),
                    ),
                  ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
      }

      await show(verse());
      expect(
        find.byKey(const ValueKey('midi-section-new-blocked')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('midi-section-bpm')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('midi-map-$stringsLane')));
      await tester.pumpAndSettle();
      final item = tester.widget<DropdownMenuItem<String>>(
        find.ancestor(
          of: find.text('New track').last,
          matching: find.byType(DropdownMenuItem<String>),
        ),
      );
      expect(item.enabled, isFalse);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();

      await show(MidiReference.parse(midiFile(verseParts, fourFour: false)));
      expect(
        find.byKey(const ValueKey('midi-section-rejected')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('midi-import-confirm')),
            )
            .onPressed,
        isNull,
      );
    });
  });

  group('editor', () {
    late Directory root;
    setUp(() async {
      useOfflineTestFonts();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'xyz.luan/audioplayers',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
      }
      root = await Directory.systemTemp.createTemp('humtrack_midi_section_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    testWidgets('section menu → injected file → mapping → insert; one undo '
        'step restores everything, redo re-applies', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        final e = d.exceptionAsString();
        // The transport's BPM readout overflows with the Ahem test font, and
        // the real-async window for the MIDI isolate lets audioplayers try
        // its (unmocked, per-player) event channel; both unrelated here.
        if (e.contains('overflowed') ||
            (e.contains('MissingPluginException') &&
                e.contains('audioplayers'))) {
          return;
        }
        onError?.call(d);
      };
      final store = _Store();
      final song = existingSong();
      final level = songLevel(song);
      var picks = 0;
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(
              song: song,
              midiFilePicker: () async {
                picks++;
                return (name: 'verse.mid', bytes: midiFile(verseParts));
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      SectionBar bar() => tester.widget<SectionBar>(find.byType(SectionBar));
      DesktopCommands commands() =>
          tester.widget<DesktopCommands>(find.byType(DesktopCommands));
      List<String> sectionsJson() => [
        for (final s in bar().sections) jsonEncode(s.toJson()),
      ];
      Future<Song> saved() async {
        commands().save();
        await tester.pumpAndSettle();
        return store.lastSaved!;
      }

      final before = sectionsJson();
      expect(bar().activeIdx, 0);
      final instrumentsBefore = Map.of((await saved()).instruments);

      // not a new song: no quota / Pro gate (works without Pro)
      expect(store.proActive, isFalse);
      bar().onLongPress(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section-midi-import')));
      // MIDI parsing runs in an isolate (compute)
      for (
        var i = 0;
        i < 100 && find.byType(AlertDialog).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(find.text('MIDI passage as new section'), findsOneWidget);
      // strings → a new track with the file's instrument
      await tester.tap(find.byKey(const ValueKey('midi-map-$stringsLane')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New track').last);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('midi-section-file-program')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('midi-import-confirm')));
      await tester.pump();
      expect(
        find.text(
          "Added section 'verse [1–4]' · 10 notes · 0 skipped · 2 out of scale",
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();

      final secs = bar().sections;
      expect(secs, hasLength(4));
      expect(bar().activeIdx, 1);
      final added = secs[1];
      expect(
        (added.name, added.repeats, added.linkId, added.bars),
        ('verse [1–4]', 1, null, 4),
      );
      final newId = added.extras.last.id;
      expect(newId, isNot('melody_x1'));
      expect(added.tracks[newId]!.pitchNotes, hasLength(2));
      expect(identical(secs[0].tracks, secs[2].tracks), isTrue);
      final rest = [...secs]..removeAt(1);
      expect([
        for (final s in rest) without(s, {newId}),
      ], before);
      final afterJson = sectionsJson();
      final afterSong = await saved();
      expect(afterSong.instruments, {...instrumentsBefore, newId: 48});
      final afterLevel = songLevel(afterSong);
      for (final k in [
        'key',
        'scale',
        'bpm',
        'swing',
        'vol',
        'pan',
        'mutes',
        'trackGrooves',
        'generationLocks',
      ]) {
        expect(jsonEncode(afterLevel[k]), jsonEncode(level[k]), reason: k);
      }

      // one undo step: sections, active section, tracks and instruments
      commands().undo();
      await tester.pumpAndSettle();
      expect(sectionsJson(), before);
      expect(bar().activeIdx, 0);
      expect(
        identical(bar().sections[0].tracks, bar().sections[1].tracks),
        isTrue,
      );
      expect((await saved()).instruments, instrumentsBefore);

      commands().redo();
      await tester.pumpAndSettle();
      expect(sectionsJson(), afterJson);
      expect(bar().activeIdx, 1);
      expect((await saved()).instruments, {...instrumentsBefore, newId: 48});

      await tester.pumpWidget(const SizedBox.shrink());
      FlutterError.onError = onError;
    });
  });
}
