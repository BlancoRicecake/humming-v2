// gt-003 in a real EditScreen on a fake clock: live = WAV events per role
// from the same plan (plain and grooved lanes), the plan synced before the
// first trigger after an apply, articulation gates counted from the
// original start on seek/chase, the bpm 200 short-note gate, Stop with
// pending voices, articulation channels silenced on seek/mute/solo/loop
// wrap, released on a role change, pan mirrored, audition velocity, and
// the 연주법 UI.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/groove.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/audition_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/midi_all_events.dart';
import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

PitchNote n(
  int midi,
  int step, {
  int dur = 4,
  int? velocity,
  Articulation? art,
}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  velocity: velocity,
  articulation: art,
);

const palm = Articulation(
  kind: ArticulationKind.palmTone,
  gateMs: 250,
  velScale: .85,
);
const harm = Articulation(kind: ArticulationKind.harmonicTone);
const stac = Articulation(kind: ArticulationKind.staccato, gateMs: 120);

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

typedef Voice = ({int ch, int key, int? vel, double vol, double gate, double t});

class Rig {
  Rig(this.section);
  final Section section;
  final List<Voice> art = [], track = [];
  final List<int> stopped = [], released = [];
  // ordered per-channel event log: ('stop' | 'art' | 'pitch', channel, key)
  final List<(String, int, int, double)> log = [];
  double now = 0;
}

void main() {
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
    root = await Directory.systemTemp.createTemp('humtrack_g3_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
  });
  tearDown(() async {
    final a = LoopAudio.instance;
    a.debugOnPlayPitch = null;
    a.debugOnPitchGate = null;
    a.debugOnArticulation = null;
    a.debugOnStopChannel = null;
    a.debugOnRelease = null;
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<Rig> mount(
    WidgetTester tester,
    List<PitchNote> notes, {
    int bpm = 120,
    int bars = 1,
    GrooveContext? groove,
    Map<String, double>? pan,
    List<TrackRef> extras = const [],
    bool grid = false,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1100, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final onError = FlutterError.onError;
    FlutterError.onError = (d) {
      if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
    };
    addTearDown(() => FlutterError.onError = onError);
    final sec = Section(id: 'A', name: 'A', bars: bars, extras: List.of(extras))
      ..tracks['melody'] = TrackData(notes: notes);
    for (final e in extras) {
      sec.tracks[e.id] = TrackData();
    }
    final song = Song(
      id: 'g3',
      title: 'G3',
      bpm: bpm,
      bars: bars,
      sections: [sec],
      instruments: {'melody': 25},
      pan: pan,
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
    if (grid) {
      tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
      await tester.pumpAndSettle();
      tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.text('Grid'),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!();
      await tester.pumpAndSettle();
    }
    final rig = Rig(sec);
    final a = LoopAudio.instance;
    a.debugOnArticulation = (ch, prog, key, vel, vol, dur) {
      expect(prog, ch == 3 || ch == 5 ? isIn([28, 31]) : isIn([28, 31]));
      rig.art.add((ch: ch, key: key, vel: vel, vol: vol, gate: dur, t: rig.now));
      rig.log.add(('art', ch, key, rig.now));
    };
    int? lastVel;
    double lastVol = 0;
    a.debugOnPlayPitch = (ch, midi, vel, vol) {
      lastVel = vel;
      lastVol = vol;
    };
    a.debugOnPitchGate = (ch, midi, dur) {
      rig.track.add((
        ch: ch,
        key: midi,
        vel: lastVel,
        vol: lastVol,
        gate: dur,
        t: rig.now,
      ));
      rig.log.add(('pitch', ch, midi, rig.now));
    };
    a.debugOnStopChannel = (ch) {
      rig.stopped.add(ch);
      rig.log.add(('stop', ch, -1, rig.now));
    };
    a.debugOnRelease = rig.released.add;
    return rig;
  }

  Future<void> run(WidgetTester tester, Rig rig, double total) async {
    for (var t = 0.0; t < total; t += 5) {
      await tester.pump(const Duration(milliseconds: 5));
      rig.now += 5;
    }
  }

  DesktopCommands commands(WidgetTester tester) =>
      tester.widget<DesktopCommands>(find.byType(DesktopCommands));
  void seek(WidgetTester tester, double step) =>
      tester.widget<Arrangement>(find.byType(Arrangement)).onSeek!(step);
  Future<void> stopAndUnmount(WidgetTester tester) async {
    commands(tester).play();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(const SizedBox.shrink());
  }

  List<PitchNote> mixed() => [
    n(52, 0, velocity: 100, art: palm),
    n(88, 4, velocity: 80, art: harm),
    n(60, 8, velocity: 70, art: stac),
    n(64, 12, dur: 2, velocity: 90),
  ];

  for (final grooved in [false, true]) {
    testWidgets('live = WAV events per role from the same plan'
        '${grooved ? ' (grooved lane)' : ''}', (tester) async {
      const ctx = GrooveContext(
        trackGrooves: {'melody': GrooveAssign(grooveId: 'builtin:laidback')},
      );
      final rig = await mount(
        tester,
        mixed(),
        groove: grooved ? ctx : null,
      );
      commands(tester).play();
      await tester.pump();
      await run(tester, rig, 1900);
      // the WAV role jobs of the same song and plan
      final s = [rig.section];
      final plan = ArticulationPlan.build(
        sections: s,
        instruments: const {'melody': 25},
      );
      final flat = flattenSong(s, groove: grooved ? ctx : null);
      List<({int channel, int key, int velocity, int on, int off})> job(
        ArtRole role,
      ) {
        final r = readMidiEvents(
          buildMidi(
            flat,
            120,
            melodyProgram: 25,
            vol: const {'melody': .85},
            articulations: plan,
            articulationRole: role,
          ),
        );
        final msPerTick = 125 / (r.tpq / kStepsPerBeat);
        return [
          for (final x in midiNotes(r.events))
            (
              channel: x.channel,
              key: x.key,
              velocity: x.velocity,
              on: (x.on * msPerTick).round(),
              off: (x.off * msPerTick).round(),
            ),
        ];
      }

      for (final role in [ArtRole.muteVoice, ArtRole.harmonicVoice]) {
        final wav = job(role);
        final live = [
          for (final v in rig.art)
            if (v.ch == plan.channelFor('melody', role)) v,
        ];
        expect(live, hasLength(wav.length), reason: '$role');
        for (var i = 0; i < wav.length; i++) {
          expect(live[i].key, wav[i].key);
          expect(live[i].vel, wav[i].velocity);
          expect(live[i].t, closeTo(wav[i].on, 12), reason: '$role onset');
          expect(
            live[i].gate * 1000,
            closeTo(wav[i].off - wav[i].on, 2),
            reason: '$role gate',
          );
        }
      }
      // track role: the staccato note, 120 ms, velocity unchanged
      final st = rig.track.where((v) => v.key == 60).single;
      final wavTrack = job(ArtRole.track).firstWhere((x) => x.key == 60);
      expect(st.ch, 0);
      expect(st.vel, wavTrack.velocity);
      expect(st.t, closeTo(wavTrack.on, 12));
      expect(st.gate * 1000, closeTo(wavTrack.off - wavTrack.on, 2));
      // palm/harmonic notes never sound on the track channel
      expect(rig.track.any((v) => v.key == 52 || v.key == 88), isFalse);
      // the same gain rule: the track volume goes into every role's call
      expect(rig.art.every((v) => v.vol == st.vol), isTrue);
      await stopAndUnmount(tester);
    });
  }

  testWidgets('bpm 200, one-step 짧게 note: live gate == export (75 ms)', (
    tester,
  ) async {
    final rig = await mount(tester, [
      n(60, 0, dur: 1, velocity: 90, art: stac),
    ], bpm: 200);
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 200);
    final live = rig.track.where((v) => v.key == 60).first;
    final r = readMidiEvents(
      buildMidi(
        flattenSong([rig.section]),
        200,
        melodyProgram: 25,
        articulations: ArticulationPlan.build(
          sections: [rig.section],
          instruments: const {'melody': 25},
        ),
      ),
    );
    final note = midiNotes(r.events).single;
    final ms = (note.off - note.on) / (r.tpq / kStepsPerBeat) * 75;
    expect(ms, closeTo(75, .5));
    expect(live.gate * 1000, closeTo(ms, .5));
    await stopAndUnmount(tester);
  });

  testWidgets('an apply right before Play uses the new plan on the first '
      'trigger and mirrors the owner pan; unused channels stay centred', (
    tester,
  ) async {
    final rig = await mount(
      tester,
      [n(52, 0, velocity: 100), n(57, 0, velocity: 100)],
      pan: const {'melody': -.5},
      grid: true,
    );
    final g = tester.widget<StepGrid>(find.byType(StepGrid));
    final edit = applyArticulation(
      List.of(g.notes),
      {},
      palm,
      channelFor: g.articulationChannel,
    );
    expect(edit.applied, 2);
    expect(g.onEdit!(List.of(g.notes), edit.notes), isTrue);
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 20);
    expect(rig.art.map((v) => (v.ch, v.key)).toSet(), {(3, 52), (3, 57)});
    expect(LoopAudio.instance.panOf(3), -.5);
    expect(LoopAudio.instance.panOf(4), 0);
    await stopAndUnmount(tester);
  });

  testWidgets('seek/chase: the gate counts from the original start', (
    tester,
  ) async {
    // palm note 0..1 s, gate 250 ms
    final rig = await mount(tester, [n(52, 0, dur: 8, velocity: 100, art: palm)]);
    seek(tester, 1); // 125 ms in: 125 ms of gate left
    await tester.pump();
    commands(tester).play();
    await tester.pump();
    expect(rig.art, hasLength(1));
    expect(rig.art.single.gate, closeTo(.125, 1e-6));
    commands(tester).play(); // stop
    await tester.pump();
    rig.art.clear();
    seek(tester, 3); // 375 ms in: gate over, note still running → silent
    await tester.pump();
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 100);
    expect(rig.art, isEmpty);
    expect(rig.track.where((v) => v.key == 52), isEmpty);
    await stopAndUnmount(tester);
  });

  testWidgets('loop-wrap chase: a range starting inside a palm note plays '
      'only what is left of its gate, or nothing', (tester) async {
    // 2 bars; palm notes start in bar 1 and run into bar 2
    final rig = await mount(tester, [
      n(52, 15, dur: 4, velocity: 100, art: palm), // gate ends at 17
      n(55, 13, dur: 6, velocity: 100, art: palm), // gate ended at 15
    ], bars: 2);
    tester.widget<AuditionBar>(find.byType(AuditionBar)).onRange(
      const PlaybackRange(16, 32),
    );
    await tester.pump();
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 2000 + 40); // into the second pass
    final chased = rig.art.where((v) => v.key == 52).toList();
    expect(chased, isNotEmpty);
    for (final v in chased) {
      expect(v.gate, closeTo(.125, .01)); // 16 → 17
    }
    expect(rig.art.where((v) => v.key == 55), isEmpty);
    await stopAndUnmount(tester);
  });

  testWidgets('plain loop wrap: only the articulation channels are '
      'silenced; the normal track is untouched', (tester) async {
    final rig = await mount(tester, [
      n(64, 0, dur: 16, velocity: 90), // normal, whole bar
      n(88, 8, dur: 8, velocity: 80, art: harm), // sustains to the wrap
    ]);
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 1900);
    rig.log.clear();
    await run(tester, rig, 200); // across the wrap at 2000 ms
    final stops = [for (final e in rig.log) if (e.$1 == 'stop') e.$2];
    expect(stops, contains(3), reason: 'harmonic channel (3) at the wrap');
    expect(stops.contains(0), isFalse, reason: 'track channel untouched');
    // the wrap's cleanup comes before the next pass's first notes
    final firstOn = rig.log.indexWhere((e) => e.$1 != 'stop');
    final lastStop = rig.log.lastIndexWhere((e) => e.$1 == 'stop');
    expect(firstOn, greaterThan(lastStop));
    await stopAndUnmount(tester);
  });

  testWidgets('range wrap: full cleanup, then the first notes and a P1 '
      'later-cell string at delay 0 sound (never cut)', (tester) async {
    // 2 bars, range = bar 2. A converted string stored in cell 15 with its
    // onset exactly at 16 (P1), a palm note at 16 and a normal note at 16.
    final p1 = PitchNote(
      midi: 55,
      freq: midiToFreq(55),
      step: 15,
      dur: 3,
      offsetSteps: 1.0,
      durationSteps: 2,
      velocity: 90,
    );
    final rig = await mount(tester, [
      p1,
      n(52, 16, velocity: 100, art: palm),
      n(64, 16, velocity: 90),
    ], bars: 2);
    tester.widget<AuditionBar>(find.byType(AuditionBar)).onRange(
      const PlaybackRange(16, 32),
    );
    await tester.pump();
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 1900);
    rig.log.clear();
    await run(tester, rig, 200); // the wrap back to 16
    bool on(String kind, int ch, int key) =>
        rig.log.any((e) => e.$1 == kind && e.$2 == ch && e.$3 == key);
    expect(on('pitch', 0, 55), isTrue, reason: 'P1 string at delay 0');
    expect(on('art', 3, 52), isTrue, reason: 'palm at the range start');
    expect(on('pitch', 0, 64), isTrue);
    final firstOn = rig.log.indexWhere((e) => e.$1 != 'stop');
    final stops = [
      for (var i = 0; i < rig.log.length; i++)
        if (rig.log[i].$1 == 'stop') i,
    ];
    expect(stops, isNotEmpty);
    expect(
      stops.every((i) => i < firstOn),
      isTrue,
      reason: 'stop events strictly before the note-ons, none after',
    );
    expect(
      {for (final i in stops) rig.log[i].$2},
      containsAll([0, 3]),
    );
    await stopAndUnmount(tester);
  });

  testWidgets('Stop with pending articulation voices leaves none', (
    tester,
  ) async {
    final rig = await mount(tester, mixed());
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 100); // palm sounded; harmonic (500 ms) pending
    expect(rig.art.map((v) => v.key), [52]);
    commands(tester).play(); // stop
    await tester.pump();
    await run(tester, rig, 1000);
    expect(rig.art.map((v) => v.key), [52]);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('seek, mute, solo and loop wrap silence the articulation '
      'channels', (tester) async {
    final rig = await mount(tester, mixed());
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 50);
    rig.stopped.clear();
    seek(tester, 2);
    await tester.pump();
    expect(rig.stopped, containsAll([0, 3, 4]), reason: 'seek');
    rig.stopped.clear();
    final arr = tester.widget<Arrangement>(find.byType(Arrangement));
    arr.onToggleMute('melody');
    await tester.pump();
    expect(rig.stopped, containsAll([0, 3, 4]), reason: 'mute');
    arr.onToggleMute('melody');
    await tester.pump();
    rig.stopped.clear();
    tester.widget<Arrangement>(find.byType(Arrangement)).onToggleSolo!('bass');
    await tester.pump();
    expect(rig.stopped, containsAll([0, 3, 4]), reason: 'solo elsewhere');
    tester.widget<Arrangement>(find.byType(Arrangement)).onToggleSolo!('bass');
    await tester.pump();
    // a range loop silences every channel of the track at each wrap
    tester.widget<AuditionBar>(find.byType(AuditionBar)).onRange(
      const PlaybackRange(0, 16),
    );
    await tester.pump();
    await run(tester, rig, 200);
    rig.stopped.clear();
    await run(tester, rig, 2000);
    expect(rig.stopped, containsAll([3, 4]), reason: 'loop wrap');
    await stopAndUnmount(tester);
  });

  testWidgets('a role change releases the channel (undo of an apply)', (
    tester,
  ) async {
    final rig = await mount(tester, [n(52, 0, velocity: 100)], grid: true);
    var g = tester.widget<StepGrid>(find.byType(StepGrid));
    final edit = applyArticulation(List.of(g.notes), {}, palm);
    expect(g.onEdit!(List.of(g.notes), edit.notes), isTrue);
    commands(tester).play(); // plan: ch3 = palm voice
    await tester.pump();
    await run(tester, rig, 20);
    expect(LoopAudio.instance.roleOf(3), 'art:melody:muteVoice');
    commands(tester).play(); // stop
    await tester.pump();
    rig.released.clear();
    commands(tester).undo();
    await tester.pump();
    commands(tester).play(); // ch3 is free again
    await tester.pump();
    expect(rig.released, contains(3));
    expect(LoopAudio.instance.roleOf(3), 'free');
    g = tester.widget<StepGrid>(find.byType(StepGrid));
    expect(g.notes.single.articulation, isNull);
    await stopAndUnmount(tester);
  });

  testWidgets('audition of an articulated note = its playback (velocity, '
      'channel, gate); a normal note keeps its velocity', (tester) async {
    final rig = await mount(tester, mixed(), grid: true);
    final g = tester.widget<StepGrid>(find.byType(StepGrid));
    for (final note in g.notes.take(2)) {
      g.onPreviewNote!(note);
    }
    await tester.pump();
    final aud = List.of(rig.art);
    rig.art.clear();
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 900);
    expect(aud, hasLength(2));
    for (var i = 0; i < 2; i++) {
      expect(
        (aud[i].ch, aud[i].key, aud[i].vel, aud[i].gate),
        (rig.art[i].ch, rig.art[i].key, rig.art[i].vel, rig.art[i].gate),
      );
    }
    await stopAndUnmount(tester);
    final rig2 = await mount(tester, [n(62, 0, velocity: 77)], grid: true);
    tester.widget<StepGrid>(find.byType(StepGrid)).onPreviewNote!(
      tester.widget<StepGrid>(find.byType(StepGrid)).notes.single,
    );
    await tester.pump();
    expect(rig2.track.single.vel, 77);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('channel shortage: the badge shows and notes play normal', (
    tester,
  ) async {
    final rig = await mount(
      tester,
      mixed(),
      extras: [for (var i = 0; i < 9; i++) TrackRef('melody_x$i', 'melody')],
      grid: true,
    );
    final g = tester.widget<StepGrid>(find.byType(StepGrid));
    expect(g.articulationShort, [ArtRole.harmonicVoice]);
    // a further harmonic apply is refused (no channel)
    final extra = n(80, 2);
    final e = applyArticulation(
      [...g.notes, extra],
      {extra},
      harm,
      channelFor: g.articulationChannel,
    );
    expect(e.noChannel, 1);
    commands(tester).play();
    await tester.pump();
    await run(tester, rig, 700);
    // the harmonic note plays normal on the track channel, never dropped
    expect(rig.track.where((v) => v.key == 88 && v.ch == 0), hasLength(1));
    expect(rig.art.where((v) => v.key == 64), isEmpty);
    // the palm voice still has its channel (14, the last free one)
    expect(rig.art.where((v) => v.key == 52).single.ch, 14);
    commands(tester).play(); // stop before opening the panel
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byKey(const ValueKey('note-guitar-tools')).first);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('articulation-short-badge')),
      findsOneWidget,
    );
    Navigator.of(
      tester.element(find.byKey(const ValueKey('articulation-short-badge'))),
    ).pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('연주법 UI', () {
    Future<void> panelTap(WidgetTester tester, String key) async {
      await tapGridButton(tester, 'stroke-more');
      final f = find.byKey(ValueKey(key));
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('only on guitar tracks, inside 기타 연주', (tester) async {
      await mountGrid(tester, [n(62, 0, dur: 1)]);
      expect(find.byKey(const ValueKey('note-guitar-tools')), findsNothing);
      expect(find.byKey(const ValueKey('stroke-more')), findsNothing);
      final key = await mountGrid(tester, [n(62, 0, dur: 1)], guitar: true);
      await tapGridButton(tester, 'note-guitar-tools');
      expect(find.text('Technique'), findsOneWidget);
      for (final k in [
        'articulation-normal',
        'articulation-staccato',
        'articulation-palm',
        'articulation-harmonic',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget);
      }
      final labels = tester.widget<Text>(
        find.byKey(const ValueKey('articulation-labels')),
      );
      expect(labels.data, contains('not a recorded nylon palm mute'));
      expect(labels.data, contains('approximation with the GM harmonics'));
      expect(labels.data, contains('not palm mute'));
      Navigator.of(tester.element(find.text('Technique'))).pop();
      await tester.pumpAndSettle();
      expect(key.currentState!.commits, 0);
    });

    testWidgets('apply = one undo step with counts; 일반으로 restores', (
      tester,
    ) async {
      final key = await mountGrid(tester, [
        n(62, 0, dur: 1),
        n(64, 2, dur: 1),
      ], guitar: true);
      final before = [
        for (final x in key.currentState!.notes) x.toJson(),
      ].toString();
      await panelTap(tester, 'articulation-harmonic');
      // 62 and 64 sound below 74: refused, counted, unchanged
      expect(key.currentState!.commits, 0);
      expect(find.text('Applied 0, out of range 2, no channel 0'), findsWidgets);
      await panelTap(tester, 'articulation-palm');
      expect(key.currentState!.commits, 1);
      expect(
        key.currentState!.notes.every((x) => x.articulation?.kind == ArticulationKind.palmTone),
        isTrue,
      );
      await tapGridButton(tester, 'stroke-more');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('articulation-result'))).data,
        'Applied 2, out of range 0, no channel 0',
      );
      Navigator.of(tester.element(find.text('Technique'))).pop();
      await tester.pumpAndSettle();
      await panelTap(tester, 'articulation-normal');
      expect(key.currentState!.commits, 2);
      expect(
        [for (final x in key.currentState!.notes) x.toJson()].toString(),
        before,
      );
    });

    testWidgets('natural-harmonic info is display only', (tester) async {
      await mountGrid(
        tester,
        [PitchNote(midi: 76, freq: 1, step: 0, guitarString: 1)],
        guitar: true,
        low: 74,
        high: 78,
      );
      await tapGridButton(tester, 'stroke-more');
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('articulation-natural-info'))).data,
        contains('string 1 fret 12'),
      );
    });
  });
}
