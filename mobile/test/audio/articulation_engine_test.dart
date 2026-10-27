// gt-003 engine-level checks.
//
// * Two-engine pitch regression, MeltySynth half (desktop/iOS engine): the
//   partial-structure fit (a PROXY for the sounding pitch, not a confirmed
//   perceived pitch) of GM 31 at key S-24 at f(S), and of GM 28 at key K at
//   f(K). The FluidSynth half is kept as evidence logs (Android path; not
//   run in CI).
// * Palm-tone range boundaries: 40 and 86 render non-silent and fit; 39 and
//   87 are refused.
// * Channel-role switch with the REAL synth: a channel used as a drum
//   track, then as an articulation voice, then as a plain pitched track,
//   renders the right kind of sound in every phase (no stale kit/program).
// * Android path (flutter_midi_pro) with a fake plugin: a channel reset is
//   serialized before the new role's set-up and notes; the font-loading
//   fallback plays the normal voice and Stop leaves no stale voice.
import 'dart:async';
import 'dart:io';

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_pro/flutter_midi_pro.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/audio/melty_synth_backend.dart';
import 'package:humming/audio/synth.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';

import '../support/structure_fit.dart';

class FakeMidi implements MidiPro {
  final List<String> log = [];
  Completer<void>? stopGate;
  Completer<int>? loadGate;

  @override
  Future<int> loadSoundfontAsset({
    required String assetPath,
    int bank = 0,
    int program = 0,
  }) async {
    log.add('load');
    return loadGate == null ? 1 : loadGate!.future;
  }

  @override
  Future<void> selectInstrument({
    required int sfId,
    required int program,
    int channel = 0,
    int bank = 0,
  }) async => log.add('select ch$channel bank$bank prog$program');

  @override
  Future<void> playNote({
    int channel = 0,
    required int key,
    int velocity = 127,
    int sfId = 1,
  }) async => log.add('on ch$channel key$key');

  @override
  Future<void> stopNote({
    int channel = 0,
    required int key,
    int sfId = 1,
  }) async {
    final gate = stopGate;
    if (gate != null) await gate.future;
    log.add('off ch$channel key$key');
  }

  @override
  Future<void> stopAllNotes({int sfId = 1}) async => log.add('stopAll');

  @override
  Future<void> controlChange({
    required int controller,
    required int value,
    int channel = 0,
    int sfId = 1,
  }) async => log.add('cc ch$channel $controller=$value');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  final gmBytes = File('assets/sounds/GeneralUser-GS.sf2').readAsBytesSync();

  group('two-engine pitch regression (MeltySynth)', () {
    for (final s in [74, 76, 83, 88, 95, 110]) {
      test('GM 31 key ${s - 24} fits f($s) >= 0.85 (structure proxy)', () {
        final pcm = renderMono(gmBytes, kHarmonicToneProgram, s - kHarmonicKeyOffset);
        final fit = structureFit(powerSpectrum(pcm, .1, .9), midiHz(s));
        expect(fit, greaterThanOrEqualTo(.85), reason: 'fit $fit');
        // the support range used by the app agrees
        expect(articulationFits(ArticulationKind.harmonicTone, s), isTrue);
      });
    }
    for (final k in [40, 52, 64, 76]) {
      test('GM 28 key $k fits f($k) >= 0.85', () {
        final pcm = renderMono(gmBytes, kPalmToneProgram, k);
        final fit = structureFit(powerSpectrum(pcm, .1, .9), midiHz(k));
        expect(fit, greaterThanOrEqualTo(.85), reason: 'fit $fit');
      });
    }

    test('palm-tone range boundaries: 40 and 86 sound and fit; 39 and 87 '
        'are refused; 73/111 refused for the harmonic tone', () {
      for (final k in [kPalmToneLo, kPalmToneHi]) {
        final pcm = renderMono(gmBytes, kPalmToneProgram, k);
        expect(rms(pcm, 0, .2), greaterThan(1e-3), reason: 'key $k audible');
        expect(
          structureFit(powerSpectrum(pcm, .1, .9), midiHz(k)),
          greaterThanOrEqualTo(.85),
          reason: 'key $k',
        );
      }
      expect(kPalmToneLo, 40);
      expect(kPalmToneHi, 86);
      for (final k in [kPalmToneLo - 1, kPalmToneHi + 1]) {
        expect(articulationFits(ArticulationKind.palmTone, k), isFalse);
        final e = applyArticulation(
          [PitchNote(midi: k, freq: 1, step: 0)],
          {},
          newArticulation(ArticulationKind.palmTone),
        );
        expect((e.applied, e.outOfRange), (0, 1));
      }
      for (final s in [kHarmonicToneLo - 1, kHarmonicToneHi + 1]) {
        expect(articulationFits(ArticulationKind.harmonicTone, s), isFalse);
      }
    });
  });

  group('channel-role switch (real MeltySynth)', () {
    final engine = MeltyEngine();
    late Synthesizer gm;
    setUp(() {
      engine.debugReset();
      gm = Synthesizer.loadByteData(
        ByteData.sublistView(gmBytes),
        SynthesizerSettings(sampleRate: kFitSampleRate),
      );
      engine.debugInstallMain(gm);
    });
    tearDown(() {
      engine.debugReset();
      LoopAudio.instance.debugResetReady();
    });

    Float32List renderNow(double seconds) {
      final l = Float32List((kFitSampleRate * seconds).round());
      final r = Float32List(l.length);
      gm.render(l, r);
      return Float32List.fromList([
        for (var i = 0; i < l.length; i++) (l[i] + r[i]) / 2,
      ]);
    }

    test('drum track -> articulation voice -> pitched track on ch3', () async {
      final audio = LoopAudio.instance;
      // phase 1: an added drum track on ch3 (GM standard kit)
      await audio.ensure();
      audio.assignChannelRole(3, 'drums:d1');
      await audio.setDrumKitOn(3, 0);
      expect(engine.debugIsDrumChannel(3), isTrue);
      await engine.noteOn(channel: 3, pitch: 52, velocity: 100);
      final drum = renderNow(1.2);
      final drumFit = structureFit(powerSpectrum(drum, .1, .9), midiHz(52));
      expect(rms(drum, 0, .3), greaterThan(1e-3));
      expect(drumFit, lessThan(.85), reason: 'kit note 52 is a cymbal');

      // phase 2: the same channel becomes a palm-tone articulation voice
      expect(audio.assignChannelRole(3, 'art:melody:muteVoice'), isTrue);
      expect(engine.debugIsDrumChannel(3), isFalse);
      expect(audio.debugDrumKitChannels.contains(3), isFalse);
      renderNow(.5); // let the cut voices go
      audio.playArticulation(
        channel: 3,
        program: kPalmToneProgram,
        key: 52,
        trackChannel: 0,
        soundingMidi: 52,
        velocity: 110,
        vol: 1,
        durSec: 1.2,
      );
      await flush();
      final palmPcm = renderNow(1.2);
      expect(rms(palmPcm, 0, .3), greaterThan(1e-3));
      expect(
        structureFit(powerSpectrum(palmPcm, .1, .9), midiHz(52)),
        greaterThanOrEqualTo(.85),
      );
      // the same render as a fresh GM 28 voice (no stale kit/bank)
      final ref = renderMono(gmBytes, kPalmToneProgram, 52, velocity: 110);
      expect(
        (rms(palmPcm, 0, .3) / rms(ref, 0, .3) - 1).abs(),
        lessThan(.25),
      );

      // phase 3: a plain pitched track (piano) on ch3
      expect(audio.assignChannelRole(3, 'pitched:melody_x1'), isTrue);
      renderNow(.5);
      await engine.noteOn(channel: 3, pitch: 60, velocity: 100, program: 0);
      final piano = renderNow(1.2);
      expect(
        structureFit(powerSpectrum(piano, .1, .9), midiHz(60)),
        greaterThanOrEqualTo(.85),
      );
      final pianoRef = renderMono(gmBytes, 0, 60);
      expect(
        (rms(piano, 0, .3) / rms(pianoRef, 0, .3) - 1).abs(),
        lessThan(.25),
        reason: 'not the palm tone any more',
      );
      // assigning the same role again changes nothing
      expect(audio.assignChannelRole(3, 'pitched:melody_x1'), isFalse);
    });

    test('a kit load overtaken by a role switch commits nothing', () async {
      final loading = Completer<void>();
      engine.debugReset();
      engine.debugInstallMain(gm, loading: loading.future);
      // the old role (drum track) starts setting up while the font loads
      final kit = engine.ensureDrumKitOn(3, 0);
      final oldHit = engine.noteOn(channel: 3, pitch: 38, velocity: 100);
      // role switch to a palm-tone voice before the load completes
      engine.releaseChannel(3);
      final palmNote = engine.noteOn(
        channel: 3,
        pitch: 52,
        velocity: 110,
        program: kPalmToneProgram,
      );
      loading.complete();
      await Future.wait([kit, oldHit, palmNote]);
      expect(engine.debugIsDrumChannel(3), isFalse, reason: 'not percussion');
      final pcm = renderNow(1.2);
      expect(rms(pcm, 0, .3), greaterThan(1e-3), reason: 'new note sounds');
      expect(
        structureFit(powerSpectrum(pcm, .1, .9), midiHz(52)),
        greaterThanOrEqualTo(.85),
        reason: 'GM 28 key 52, no stale snare',
      );
      final ref = renderMono(gmBytes, kPalmToneProgram, 52, velocity: 110);
      expect((rms(pcm, 0, .3) / rms(ref, 0, .3) - 1).abs(), lessThan(.25));
    });
  });

  group('Android path (fake flutter_midi_pro)', () {
    final synth = SynthEngine();
    late FakeMidi fake;
    setUp(() {
      fake = FakeMidi();
      synth.debugUseMidiPro(fake, loadedSfId: 1);
    });
    tearDown(() {
      synth.debugUseMidiPro(null);
      LoopAudio.instance.debugResetReady();
    });

    test('a slow channel reset lands before the new role set-up and notes',
        () async {
      await synth.noteOn(channel: 3, pitch: 52, velocity: 90, program: 0);
      expect(fake.log, ['select ch3 bank0 prog0', 'on ch3 key52']);
      fake.log.clear();
      fake.stopGate = Completer<void>();
      final release = synth.releaseChannel(3);
      // the new role (articulation voice) starts while the reset is pending
      final pan = synth.controlChange(3, 10, 30);
      final note = synth.noteOn(
        channel: 3,
        pitch: 52,
        velocity: 85,
        program: kPalmToneProgram,
      );
      await flush();
      expect(fake.log, isEmpty, reason: 'everything waits for the reset');
      fake.stopGate!.complete();
      fake.stopGate = null;
      await Future.wait([release, pan, note]);
      // old role's voice off and controllers reset first; then the new
      // role's pan, program and note (the pan is re-sent on the new
      // soundfont binding, still the new value)
      expect(fake.log.take(4), [
        'off ch3 key52',
        'cc ch3 121=0',
        'cc ch3 10=30',
        'select ch3 bank0 prog28',
      ]);
      expect(fake.log.last, 'on ch3 key52');
      expect(
        fake.log.skip(2).every((e) => e == 'cc ch3 10=30' || !e.startsWith('cc')),
        isTrue,
      );
      expect(fake.log.skip(2).any((e) => e.startsWith('off')), isFalse);
    });

    test('a pending kit / font set-up overtaken by a role switch commits '
        'nothing', () async {
      fake = FakeMidi()..loadGate = Completer<int>();
      synth.debugUseMidiPro(fake); // font not loaded yet
      final kit = synth.ensureDrumKitOn(3, 0);
      final pitched = synth.noteOn(channel: 3, pitch: 60, program: 0);
      final release = synth.releaseChannel(3);
      final palmNote = synth.noteOn(
        channel: 3,
        pitch: 52,
        velocity: 85,
        program: kPalmToneProgram,
      );
      fake.loadGate!.complete(1);
      await Future.wait([kit, pitched, release, palmNote]);
      final ch3 = fake.log.where((e) => e.contains('ch3')).toList();
      expect(ch3, ['select ch3 bank0 prog28', 'on ch3 key52']);
    });

    test('font still loading: the articulation plays as normal on the track '
        'channel; Stop leaves no stale voice', () async {
      for (final stop in [true, false]) {
        fake = FakeMidi()..loadGate = Completer<int>();
        synth.debugUseMidiPro(fake);
        final audio = LoopAudio.instance..debugResetReady();
        audio.playArticulation(
          channel: 4,
          program: kHarmonicToneProgram,
          key: 64,
          trackChannel: 0,
          soundingMidi: 88,
          trackProgram: 25,
          velocity: 90,
          durSec: .3,
        );
        if (stop) await audio.stopAll();
        fake.loadGate!.complete(1);
        await flush();
        final ons = fake.log.where((e) => e.startsWith('on ')).toList();
        if (stop) {
          expect(ons, isEmpty, reason: 'no stale voice after Stop');
        } else {
          expect(ons, ['on ch0 key88'], reason: 'normal voice, track channel');
          expect(fake.log.any((e) => e.contains('ch4')), isFalse);
        }
      }
    });
  });
}
