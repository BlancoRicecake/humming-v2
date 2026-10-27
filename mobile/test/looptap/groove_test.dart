// groove-001: groove templates (apply, extract, non-destructive).
// docs/specs/groove/gr-001-groove-templates.md
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

GrooveTemplate builtin(String key) => findGroove('builtin:$key', const [])!;

PitchNote pn(int midi, double start, {int? velocity, int dur = 1}) {
  final step = start.floor();
  return PitchNote(
    midi: midi,
    freq: midiToFreq(midi),
    step: step,
    dur: dur,
    offsetSteps: start - step,
    velocity: velocity,
  );
}

String sig(FlatSong f) => [
  for (final l in [f.melody, f.bass, f.melodyDec, ...f.extraPitched.values])
    [for (final n in l) n.toJson()],
  for (final l in [f.drums, f.beatDec, ...f.extraDrums.values])
    [for (final n in l) n.toJson()],
].toString();

/// A small song: melody on every other 16th, drums on every 16th.
List<Section> song({int bars = 1}) {
  final a = Section(id: 'A', name: 'A', bars: bars, repeats: 2);
  a.tracks['melody'] = TrackData(
    notes: [for (var i = 0; i < 16; i += 2) pn(60 + i, i.toDouble(), dur: 2)],
  );
  a.tracks['drums'] = TrackData(
    drums: [
      for (var i = 0; i < 16; i++)
        DrumNote(kind: i % 4 == 0 ? 'kick' : 'hihat', step: i, velocity: 90),
    ],
  );
  a.tracks['bass'] = TrackData(notes: [pn(36, 3, velocity: 70)]);
  return [a];
}

Set<(int, int)> onsets(Uint8List bytes, int channel) => {
  for (final l in MidiReference.parse(bytes).lanes)
    if (l.channel == channel)
      for (final n in l.notes) (n.pitch, n.tick),
};

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

void main() {
  group('applyGroove', () {
    const full = GrooveAssign(grooveId: 'x');
    test('Swing 16 medium equals the Swing knob at 0.4', () {
      final t = builtin('swing16-medium');
      expect(applyGroove(3, null, t, full).start, closeTo(3.2, 1e-9));
      expect(applyGroove(2, null, t, full).start, 2.0);
      expect(swingOffset(3, .4), closeTo(.2, 1e-12));
    });

    test('Quantize pulls first; Timing 0 leaves only Quantize', () {
      final straight = builtin('straight');
      final q = const GrooveAssign(grooveId: 'x', quantize: .5);
      expect(applyGroove(2.4, null, straight, q).start, closeTo(2.2, 1e-9));
      final t0 = const GrooveAssign(grooveId: 'x', timing: 0);
      final swing = builtin('swing16-medium');
      expect(applyGroove(3, null, swing, t0).start, 3);
      expect(
        applyGroove(2.4, null, swing, t0.copyWith(quantize: .5)).start,
        closeTo(2.2, 1e-9),
      );
    });

    test('Amount 1.3 and the clamp at 0', () {
      expect(
        applyGroove(2, null, builtin('swing8'), full, amount: 1.3).start,
        closeTo(2.871, 1e-9),
      );
      final early = GrooveTemplate(
        id: 'e',
        name: 'e',
        length: 16,
        timing: [-.5],
        accent: const [],
      );
      expect(applyGroove(0, null, early, full).start, 0);
    });

    test('Pulse accents (and an inverted Velocity)', () {
      final p = builtin('pulse');
      expect(applyGroove(0, 80, p, full).velocity, 120);
      expect(applyGroove(1, 80, p, full).velocity, 60);
      expect(applyGroove(2, null, p, full).velocity, isNull);
      final inv = const GrooveAssign(grooveId: 'x', velocity: -1);
      expect(applyGroove(0, 80, p, inv).velocity, 40);
    });
  });

  group('flattenSong / buildMidi', () {
    test('no groove: output unchanged (Swing 0.4 included)', () {
      final plain = flattenSong(song(), variationSeed: 3);
      final ctx = flattenSong(
        song(),
        variationSeed: 3,
        groove: const GrooveContext(swing: .4),
      );
      expect(sig(ctx), sig(plain));
      expect(ctx.selfTimed, isEmpty);
      expect(buildMidi(ctx, 120, swing: .4), buildMidi(plain, 120, swing: .4));
    });

    test('positions are section-relative', () {
      final a = Section(id: 'A', name: 'A', bars: 1);
      final b = Section(id: 'B', name: 'B', bars: 2);
      b.tracks['melody'] = TrackData(notes: [pn(60, 0), pn(62, 16)]);
      final t = GrooveTemplate(
        id: 'g32',
        name: 'g',
        length: 32,
        timing: [for (var p = 0; p < 32; p++) p == 0 ? .3 : 0],
        accent: const [],
      );
      final flat = flattenSong(
        [a, b],
        groove: GrooveContext(
          grooves: [t],
          trackGrooves: const {'melody': GrooveAssign(grooveId: 'g32')},
        ),
      );
      // B's first note sits at p = 0 (song step 16 would be p = 16)
      expect(flat.melody.map((n) => n.startSteps), [closeTo(16.3, 1e-9), 32]);
    });

    test('section override beats the track groove; null = Swing', () {
      final a = Section(id: 'A', name: 'A', bars: 1);
      final b = Section(id: 'B', name: 'B', bars: 1);
      final c = Section(id: 'C', name: 'C', bars: 1);
      for (final s in [a, b, c]) {
        s.tracks['melody'] = TrackData(notes: [pn(60, 2), pn(62, 3), pn(64, 4)]);
      }
      b.grooveOverrides['melody'] = null; // "no groove" → Swing
      c.grooveOverrides['melody'] = const GrooveAssign(
        grooveId: 'builtin:laidback',
      );
      final flat = flattenSong(
        [a, b, c],
        groove: const GrooveContext(
          trackGrooves: {'melody': GrooveAssign(grooveId: 'builtin:swing8')},
          swing: .4,
        ),
      );
      final starts = flat.melody.map((n) => n.startSteps).toList();
      // A: Swing 8 (p = 2 → +0.67)
      expect(starts.sublist(0, 3), [closeTo(2.67, 1e-9), 3, 4]);
      // B: Swing only (odd step 3 → +0.2), baked as an offset
      expect(starts.sublist(3, 6), [18, closeTo(19.2, 1e-9), 20]);
      // C: Laid-back (p = 4 → +0.15)
      expect(starts.sublist(6), [34, 35, closeTo(36.15, 1e-9)]);
      expect(flat.selfTimed, {'melody'});
    });

    test('a self-timed lane is not swung twice by buildMidi', () {
      final s = Section(id: 'A', name: 'A', bars: 1);
      s.tracks['melody'] = TrackData(notes: [pn(60, 3)]);
      s.tracks['bass'] = TrackData(notes: [pn(36, 3)]);
      final b = Section(id: 'B', name: 'B', bars: 1);
      b.tracks['melody'] = TrackData(notes: [pn(60, 3)]);
      b.grooveOverrides['melody'] = const GrooveAssign(
        grooveId: 'builtin:straight',
      );
      final flat = flattenSong(
        [s, b],
        groove: const GrooveContext(
          trackGrooves: {},
          swing: .4,
        ),
      );
      expect(flat.selfTimed, {'melody'});
      final bytes = buildMidi(flat, 120, swing: .4);
      const tps = 9600 / 4; // precise file (baked offsets)
      expect(onsets(bytes, 0), {(60, (3.2 * tps).round()), (60, (19 * tps).round())});
      // the clock-swung bass still gets its Swing from buildMidi
      expect(onsets(bytes, 1), {(36, (3.2 * tps).round())});
    });

    test('drums groove too (start and velocity, no length)', () {
      final s = Section(id: 'A', name: 'A', bars: 1);
      s.tracks['drums'] = TrackData(
        drums: [DrumNote(kind: 'kick', step: 0, velocity: 80)],
      );
      final flat = flattenSong(
        [s],
        groove: const GrooveContext(
          trackGrooves: {'drums': GrooveAssign(grooveId: 'builtin:pulse')},
        ),
      );
      expect(flat.drums.single.velocity, 120);
      expect(flat.drums.single.durationSteps, isNull);
    });
  });

  group('extractGroove', () {
    test('uniform lateness is removed; relative feel is kept', () {
      final late = extractGroove(
        [for (var i = 0; i < 16; i++) (steps: i + .1, velocity: 90)],
        length: 16,
        name: 'g',
        id: 'g',
      )!;
      expect(late.timing.every((t) => t.abs() < 1e-9), isTrue);
      expect(late.accent.every((a) => a == 0), isTrue);
      final swing = extractGroove(
        [for (var i = 0; i < 16; i++) (steps: i + (i.isOdd ? .25 : 0), velocity: 90)],
        length: 16,
        name: 'g',
        id: 'g',
      )!;
      for (var p = 0; p < 16; p++) {
        expect(swing.timing[p], closeTo(p.isOdd ? .125 : -.125, 1e-9));
      }
    });

    test('accents from velocity; too few beats → null', () {
      final g = extractGroove(
        [for (var i = 0; i < 16; i++) (steps: i.toDouble(), velocity: i.isEven ? 100 : 50)],
        length: 16,
        name: 'g',
        id: 'g',
      )!;
      for (var p = 0; p < 16; p++) {
        expect(g.accent[p], p.isEven ? 1 : -1);
      }
      expect(
        extractGroove(
          [for (var i = 0; i < 3; i++) (steps: i.toDouble(), velocity: 90)],
          length: 16,
          name: 'g',
          id: 'g',
        ),
        isNull,
      );
    });
  });

  test('JSON round-trip; defaults write no keys', () {
    final plain = Song(id: 's', title: 't');
    final j = plain.toJson();
    expect(j.containsKey('grooves'), isFalse);
    expect(j.containsKey('trackGrooves'), isFalse);
    expect(j.containsKey('grooveAmount'), isFalse);
    expect(plain.sections.first.toJson().containsKey('grooveOverrides'), isFalse);
    final t = extractGroove(
      [for (var i = 0; i < 8; i++) (steps: i + (i.isOdd ? .2 : 0), velocity: 60 + i)],
      length: 32,
      name: 'Mine',
      id: 'g1',
      origin: 'take',
    )!;
    final song = Song(
      id: 's',
      title: 't',
      grooves: [t],
      trackGrooves: {
        'drums': const GrooveAssign(
          grooveId: 'g1',
          timing: .5,
          velocity: -.25,
          quantize: .1,
        ),
      },
      grooveAmount: 1.2,
    );
    song.sections.first.grooveOverrides['melody'] = null;
    song.sections.first.grooveOverrides['bass'] = const GrooveAssign(
      grooveId: 'builtin:pulse',
    );
    final back = Song.decodeList(Song.encodeList([song])).single;
    expect(back.grooves.single.toJson(), t.toJson());
    expect(back.trackGrooves, song.trackGrooves);
    expect(back.grooveAmount, 1.2);
    final o = back.sections.first.grooveOverrides;
    expect(o.containsKey('melody'), isTrue);
    expect(o['melody'], isNull);
    expect(o['bass'], const GrooveAssign(grooveId: 'builtin:pulse'));
    // deepCopy (undo snapshots) keeps overrides
    expect(back.sections.first.deepCopy().grooveOverrides, o);
  });

  test('live schedule matches the flattened song (1 ms)', () {
    final s = song(bars: 1).single..repeats = 1;
    s.grooveOverrides['bass'] = const GrooveAssign(
      grooveId: 'builtin:laidback',
      quantize: .3,
    );
    final early = GrooveTemplate(
      id: 'early',
      name: 'early',
      length: 16,
      timing: [for (var p = 0; p < 16; p++) p.isOdd ? -.3 : .1],
      accent: [for (var p = 0; p < 16; p++) p.isEven ? .5 : -.5],
    );
    final ctx = GrooveContext(
      grooves: [early],
      trackGrooves: const {
        'melody': GrooveAssign(grooveId: 'early'),
        'drums': GrooveAssign(grooveId: 'builtin:swing16-heavy'),
      },
      amount: 1.1,
      swing: .4,
    );
    const bpm = 97;
    final sps = 60 / bpm / kStepsPerBeat;
    final live = liveGrooveSchedule(s, bpm, .4, ctx);
    final flat = flattenSong([s], groove: ctx);
    final flatSec = [
      for (final n in [...flat.melody, ...flat.bass]) n.startSteps * sps,
      for (final n in flat.drums) n.startSteps * sps,
    ]..sort();
    final liveSec = live.map((e) => e.seconds).toList()..sort();
    expect(liveSec.length, flatSec.length);
    for (var i = 0; i < liveSec.length; i++) {
      expect(liveSec[i], closeTo(flatSec[i], .001));
    }
    final liveVel = live.map((e) => e.velocity).toList()..sort(_cmp);
    final flatVel = [
      for (final n in [...flat.melody, ...flat.bass]) n.velocity,
      for (final n in flat.drums) n.velocity,
    ]..sort(_cmp);
    expect(liveVel, flatVel);
    // early notes are scheduled from the previous step's trigger
    final slot = liveGrooveSlot(2.7, .4, 16);
    expect(slot.trigger, 2);
    expect(slot.delay, closeTo(.7, 1e-9));
    expect(liveGrooveSlot(3.05, .4, 16).trigger, 2); // before step 3's 3.2
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
      root = await Directory.systemTemp.createTemp('humtrack_groove_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    testWidgets('assign → Undo clears trackGrooves, Redo restores', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // The transport's BPM readout overflows by a few pixels with the Ahem
      // test font; unrelated to grooves.
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      final store = _Store();
      final song = Song(id: 'g', title: 'Groove', sections: song1());
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: song),
          ),
        ),
      );
      await tester.pumpAndSettle();
      DesktopCommands commands() =>
          tester.widget<DesktopCommands>(find.byType(DesktopCommands));
      commands().groove!(); // Ctrl/Cmd+G
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('groove-builtin:swing8')));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byKey(const ValueKey('groove-none'))))
          .pop();
      await tester.pumpAndSettle();
      Future<Map<String, GrooveAssign>> saved() async {
        await tester.runAsync(() async => commands().save());
        await tester.pump();
        return store.lastSaved!.trackGrooves;
      }

      expect((await saved()).values.single.grooveId, 'builtin:swing8');
      commands().undo();
      await tester.pump();
      expect(await saved(), isEmpty);
      commands().redo();
      await tester.pump();
      expect((await saved()).values.single.grooveId, 'builtin:swing8');
      await tester.pumpWidget(const SizedBox.shrink());
      FlutterError.onError = onError;
    });
  });
}

int _cmp(int? a, int? b) => (a ?? -1).compareTo(b ?? -1);

List<Section> song1() => song();
