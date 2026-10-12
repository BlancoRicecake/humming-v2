// Explicit QA entrypoint. Never distribute this target.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/audio/synth.dart';
import 'package:humming/audio/melty_synth_backend.dart';
import 'package:humming/audio/pcm_output.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/export_library.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/vocal_midi.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/loop_storage.dart';

Future<void> main() async {
  const output = String.fromEnvironment('CUSTOMER_SMOKE_OUTPUT');
  if (output.isEmpty || !Platform.isWindows) {
    throw StateError('Explicit Windows QA output is required');
  }
  final directory = await Directory(output).create(recursive: true);
  final report = <String, dynamic>{
    'passed': false,
    'input': 'synthetic melody',
  };
  VocalMidiAnalysis? analysis;
  try {
    LoopStorage.rootOverride = Directory('${directory.path}/sandbox');
    await app.main();
    await LoopStorage.ensureDirs();
    final samples = Float32List(48000);
    for (var i = 16000; i < 48000; i++) {
      final relative = i - 16000;
      final frequency = relative < 16000 ? 261.6256 : 329.6276;
      final envelope = math.min(
        1.0,
        math.min(relative / 160, (31999 - relative) / 160),
      );
      samples[i] =
          .4 *
          math.max(0.0, envelope) *
          math.sin(2 * math.pi * frequency * relative / 16000);
    }
    final bytes = encodeWavMono16(samples, 16000);
    final source = File(
      '${LoopStorage.rootOverride!.path}/looptap/vocals/synthetic.wav',
    );
    await source.writeAsBytes(bytes);
    final clip = VocalClip(path: source.path, trimStart: 16000, startStep: 3);
    analysis = await VocalMidiService().convert(
      clip,
      bpm: 120,
      bars: 2,
      keyRoot: 'C',
      scale: 'major',
      swing: 0,
    );
    if (analysis.notes.isEmpty || analysis.notes.any((n) => n.step < 3)) {
      throw StateError('No correctly placed notes');
    }
    report['notes'] = [
      for (final n in analysis.notes)
        {'midi': n.midi, 'step': n.step, 'duration': n.dur},
    ];
    final section = Section(id: 'a', name: 'A');
    section.tracks['vocal'] = TrackData(clips: [clip]);
    final id = addVocalMidiTrack(
      [section],
      section.id,
      'melody_converted',
      VocalMidiResult(analysis.notes, 24),
    );
    final song = Song(
      id: 'customer_smoke',
      title: 'Customer smoke',
      bpm: 120,
      key: 'C',
      scale: 'major',
      sections: [section],
      instruments: {id: 24},
    );
    await LoopStorage.save([song]);
    final reopened = (await LoopStorage.load()).firstWhere(
      (s) => s.id == song.id,
    );
    if (reopened.sections.single.tracks[id]!.pitchNotes.isEmpty ||
        reopened.instruments[id] != 24 ||
        reopened.sections.single.tracks['vocal']!.effectiveClips.isEmpty ||
        base64Encode(await source.readAsBytes()) != base64Encode(bytes)) {
      throw StateError('Save/reload or source preservation failed');
    }
    report['saveReloadAndOriginalPreserved'] = true;
    final midi = await exportMidiSong(
      reopened.sections,
      120,
      song.title,
      extras: section.extras,
      instruments: song.instruments,
    );
    final wav = await exportWavSong(
      reopened.sections,
      120,
      0,
      song.vol,
      song.title,
      extras: section.extras,
      instruments: song.instruments,
    );
    final library = await listExportedFiles();
    if (!library.any((f) => f.file.absolute.uri == midi.absolute.uri) ||
        !library.any((f) => f.file.absolute.uri == wav.file.absolute.uri)) {
      throw StateError('Export not discoverable');
    }
    final rendered = parseWav(await wav.file.readAsBytes());
    if (rendered == null || rendered.samples.every((s) => s.abs() < .001)) {
      throw StateError('Silent WAV');
    }
    report['midiBytes'] = await midi.length();
    report['wavBytes'] = await wav.file.length();
    report['exportsDiscoverable'] = true;
    final synth = SynthEngine();
    await synth.ensureLoaded();
    MeltyEngine().didChangeAppLifecycleState(AppLifecycleState.resumed);
    for (final n in analysis.notes.take(3)) {
      await synth.playNote(
        pitch: n.midi,
        velocity: 60,
        channel: 15,
        program: 24,
        release: const Duration(milliseconds: 180),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    final native = await const MethodChannel(
      'humtrack/desktop_pcm',
    ).invokeMapMethod<String, dynamic>('stats');
    if (native == null ||
        native['started'] != true ||
        (native['peak'] as int) <= 0 ||
        (native['framesWritten'] as int) < 10000) {
      throw StateError('Native audio output did not produce signal');
    }
    report['nativeAudio'] = native;
    report['passed'] = true;
  } catch (error, stack) {
    report['error'] = error.toString();
    report['stack'] = stack.toString();
  } finally {
    await analysis?.dispose();
    await PcmOutput.release();
    await File(
      '${directory.path}/smoke.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }
  exit(report['passed'] == true ? 0 : 1);
}
