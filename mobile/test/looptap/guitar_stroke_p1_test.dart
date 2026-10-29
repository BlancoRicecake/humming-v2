// gt-001 P1 fix: converted stroke strings stored in an earlier cell than
// their actual onset (offsetSteps >= 1) play exactly once per pass when
// playback starts (seek / range loop / wrap) after their cell but before
// their onset. Real EditScreen, fake clock.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:provider/provider.dart';

import '../support/midi_events.dart';
import '../support/offline_fonts.dart';

const bpm = 120; // 1 step = 125 ms
const sps = 60 / bpm / kStepsPerBeat;
const ms = 125.0; // ms per step

/// A slow 6-string down stroke on [step]: at 120 BPM a 60 ms spread puts
/// the strings at +0, .48, .96, 1.44, 1.92, 2.4 steps (cells 0,0,0,1,1,2
/// relative to the hit), all stored in the hit's own cell.
List<PitchNote> slowStroke(int step) =>
    applyGuitarStroke(
      [
        for (final m in [40, 45, 50, 55, 59, 64])
          PitchNote(midi: m, freq: midiToFreq(m), step: step, dur: 4),
      ],
      {},
      const StrokeSpec.down(spreadMs: 60),
      bpm: bpm,
    ).notes;

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

void main() {
  test('pure rule: only later-cell notes before the first cell, once', () {
    final notes = [
      ...slowStroke(0),
      // legacy / imported sub-step offset: never matched
      PitchNote(
        midi: 70,
        freq: midiToFreq(70),
        step: 0,
        offsetSteps: .9,
        durationSteps: 1,
      ),
    ];
    const range = PlaybackRange(0, 16);
    List<int> pend(double from, int first) => [
      for (final p in laterCellOnsets(
        notes,
        range,
        from: from,
        firstCell: first,
      ))
        p.note.midi,
    ];
    expect(pend(1, 1), [55, 59, 64]);
    expect(pend(1.5, 2), [59, 64]);
    expect(pend(0, 0), isEmpty, reason: 'cell 0 is triggered normally');
    expect(pend(2.5, 3), isEmpty, reason: 'every onset already passed');
    expect(onsetInLaterCell(notes.last), isFalse);
    // onsets past the range end are not scheduled
    expect(
      laterCellOnsets(
        notes,
        const PlaybackRange(0, 2),
        from: 1,
        firstCell: 1,
      ).map((p) => p.note.midi),
      [55, 59],
    );
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
      root = await Directory.systemTemp.createTemp('humtrack_p1_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopAudio.instance.debugOnPlayPitch = null;
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    /// Mounts the editor; returns the played (midi, ms) log and a pump
    /// helper that advances the fake clock in 5 ms frames.
    Future<
      ({
        List<(int, double)> played,
        Future<void> Function(double ms) run,
        Section section,
      })
    >
    mount(
      WidgetTester tester, {
      required List<PitchNote> notes,
      int bars = 1,
      GrooveContext? groove,
    }) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      addTearDown(() => FlutterError.onError = onError);
      final sec = Section(id: 'A', name: 'A', bars: bars)
        ..tracks['melody'] = TrackData(notes: notes);
      final song = Song(
        id: 'p1',
        title: 'P1',
        bpm: bpm,
        bars: bars,
        sections: [sec],
        instruments: {'melody': 25},
        trackGrooves: groove == null ? null : Map.of(groove.trackGrooves),
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: _Store(),
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: song),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final played = <(int, double)>[];
      var now = 0.0;
      LoopAudio.instance.debugOnPlayPitch =
          (ch, midi, velocity, vol) => played.add((midi, now));
      Future<void> run(double total) async {
        for (var t = 0.0; t < total; t += 5) {
          await tester.pump(const Duration(milliseconds: 5));
          now += 5;
        }
      }

      return (played: played, run: run, section: sec);
    }

    DesktopCommands commands(WidgetTester tester) =>
        tester.widget<DesktopCommands>(find.byType(DesktopCommands));
    void seek(WidgetTester tester, double step) =>
        tester.widget<Arrangement>(find.byType(Arrangement)).onSeek!(step);

    /// Times (ms after play) of each pitch's attacks.
    Map<int, List<double>> attacks(List<(int, double)> log) {
      final out = <int, List<double>>{};
      for (final (m, t) in log) {
        (out[m] ??= []).add(t);
      }
      return out;
    }

    testWidgets('seek into a hit: the not-yet-struck strings play once, on '
        'time; export agrees', (tester) async {
      final notes = slowStroke(0);
      final m = await mount(tester, notes: notes);
      seek(tester, 1);
      await tester.pump();
      commands(tester).play();
      await tester.pump();
      // the three strings already sounding at 1.0 are chased immediately
      expect(m.played.map((e) => e.$1).toSet(), {40, 45, 50});
      await m.run(400);
      final a = attacks(m.played);
      // strings with onset >= 1 play exactly once, at (onset - 1) steps
      for (final n in notes.where((n) => n.startSteps >= 1)) {
        expect(a[n.midi], hasLength(1), reason: '${n.midi}');
        expect(
          a[n.midi]!.single,
          closeTo((n.startSteps - 1) * ms, 10),
          reason: '${n.midi} timing',
        );
      }
      // the export has the same strings at the same onsets
      final flat = flattenSong([m.section]);
      final read = readNoteOns(buildMidi(flat, bpm, melodyProgram: 25));
      final tps = read.tpq / kStepsPerBeat;
      expect(
        {
          for (final e in read.ons)
            if (e.tick >= tps) (e.pitch, ((e.tick / tps - 1) * ms).round()),
        },
        {
          for (final n in notes.where((n) => n.startSteps >= 1))
            (n.midi, ((n.startSteps - 1) * ms).round()),
        },
      );
      commands(tester).play(); // stop
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a fractional seek between strings', (tester) async {
      final notes = slowStroke(0);
      final m = await mount(tester, notes: notes);
      seek(tester, 1.5);
      await tester.pump();
      commands(tester).play();
      await tester.pump();
      await m.run(300);
      final a = attacks(m.played);
      expect(a[59], hasLength(1));
      expect(a[59]!.single, closeTo((1.92 - 1.5) * ms, 10));
      expect(a[64], hasLength(1));
      expect(a[64]!.single, closeTo((2.4 - 1.5) * ms, 10));
      // 1.44 had sounded already: it is chased at once, never re-attacked
      expect(a[55], [0]);
      commands(tester).play();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Stop mid-hit leaves no stray strings', (tester) async {
      final m = await mount(tester, notes: slowStroke(0));
      seek(tester, 1);
      await tester.pump();
      commands(tester).play();
      await tester.pump();
      await m.run(80); // 55 (55 ms) sounds; 59 (115 ms), 64 (175 ms) pending
      expect(attacks(m.played)[55], hasLength(1));
      commands(tester).play(); // stop
      await tester.pump();
      await m.run(400);
      final a = attacks(m.played);
      expect(a.containsKey(59), isFalse);
      expect(a.containsKey(64), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final grooved in [false, true]) {
      testWidgets('range loop: strings stored before the range start play '
          'once per pass${grooved ? ' (grooved lane)' : ''}', (tester) async {
        // 2 bars; the hit sits on cell 15, its last three strings sound in
        // bar 2 (16.44, 16.92, 17.4); loop bar 2 only
        final notes = slowStroke(15);
        const ctx = GrooveContext(
          trackGrooves: {'melody': GrooveAssign(grooveId: 'builtin:laidback')},
        );
        final m = await mount(
          tester,
          notes: notes,
          bars: 2,
          groove: grooved ? ctx : null,
        );
        // ui-001 stage 2: the desktop range comes from the ruler (Arrangement)
        tester
            .widget<Arrangement>(find.byType(Arrangement))
            .onLoopRange!(const PlaybackRange(16, 32));
        await tester.pump();
        commands(tester).play();
        await tester.pump();
        const pass = 16 * ms;
        await m.run(pass * 3 - 50); // three passes
        final a = attacks(m.played);
        final onsets = {
          for (final n in notes) n.midi: n.startSteps,
        };
        if (grooved) {
          for (final e in liveGrooveSchedule(
            m.section,
            bpm,
            0,
            ctx,
          )) {
            onsets[(e.note as PitchNote).midi] = e.seconds / sps;
          }
        }
        for (final midi in [55, 59, 64]) {
          expect(a[midi], hasLength(3), reason: '$midi once per pass');
          for (var k = 0; k < 3; k++) {
            expect(
              a[midi]![k],
              closeTo(k * pass + (onsets[midi]! - 16) * ms, 12),
              reason: '$midi pass $k',
            );
          }
        }
        expect(a.keys.toSet().difference({40, 45, 50, 55, 59, 64}), isEmpty);
        commands(tester).play();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('grooved lane: fractional seek plays later-cell strings once', (
      tester,
    ) async {
      final notes = slowStroke(0);
      const ctx = GrooveContext(
        trackGrooves: {'melody': GrooveAssign(grooveId: 'builtin:laidback')},
      );
      final m = await mount(tester, notes: notes, groove: ctx);
      final sched = {
        for (final e in liveGrooveSchedule(m.section, bpm, 0, ctx))
          (e.note as PitchNote).midi: e.seconds / sps,
      };
      seek(tester, 1.2);
      await tester.pump();
      commands(tester).play();
      await tester.pump();
      await m.run(400);
      final a = attacks(m.played);
      for (final n in notes.where((n) => n.startSteps >= 1.2)) {
        expect(a[n.midi], hasLength(1), reason: '${n.midi}');
        expect(
          a[n.midi]!.single,
          closeTo((sched[n.midi]! - 1.2) * ms, 12),
          reason: '${n.midi} grooved timing',
        );
      }
      commands(tester).play();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
