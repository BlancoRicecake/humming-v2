import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart' show CancelToken;
import 'package:path_provider/path_provider.dart';
import '../../api/engine_api.dart';
import '../../models/models.dart' as eng;
import '../models/loop_models.dart';
import '../state/loop_storage.dart';
import 'theory.dart';
import 'wav_codec.dart';

enum VocalMidiFailure { invalidAudio, outsideSection, tooLong, noNotes }

class VocalMidiException implements Exception {
  const VocalMidiException(this.reason);
  final VocalMidiFailure reason;
}

class VocalMidiAudio {
  const VocalMidiAudio(
    this.wav,
    this.duration,
    this.offsetSeconds, {
    this.previewWav,
  });
  final Uint8List wav;
  final Uint8List? previewWav;
  final double duration;
  final double offsetSeconds;
}

/// Pad with silence to preserve the vocal lane's actual section position.
/// Backend quantization then applies the song's swing to the resulting notes.
/// Only the trimmed clip is uploaded; neighbouring takes never enter this file.
VocalMidiAudio prepareVocalMidiAudio(Map<String, Object> input) {
  final wav = parseWav(input['bytes'] as Uint8List);
  if (wav == null || wav.samples.isEmpty) {
    throw const VocalMidiException(VocalMidiFailure.invalidAudio);
  }
  final clip = input['clip'] as VocalClip;
  final bpm = input['bpm'] as int;
  final bars = input['bars'] as int;
  final start = clip.trimStart.clamp(0, wav.samples.length);
  final end =
      clip.trimEnd == -1
          ? wav.samples.length
          : clip.trimEnd.clamp(0, wav.samples.length);
  if (end <= start) {
    throw const VocalMidiException(VocalMidiFailure.invalidAudio);
  }
  final secondsPerStep = 60 / bpm / kStepsPerBeat;
  final offset = clip.startStep * secondsPerStep;
  final duration = (end - start) / wav.sampleRate;
  final sectionSeconds = stepsForBars(bars) * secondsPerStep;
  if (clip.startStep < 0 ||
      clip.startStep >= stepsForBars(bars) ||
      offset + duration > sectionSeconds + 0.01) {
    throw const VocalMidiException(VocalMidiFailure.outsideSection);
  }
  if (offset + duration > 60) {
    throw const VocalMidiException(VocalMidiFailure.tooLong);
  }
  final trimmed = fadePcm(
    Float32List.sublistView(wav.samples, start, end),
    (clip.fadeInMs / 1000 * wav.sampleRate).round(),
    (clip.fadeOutMs / 1000 * wav.sampleRate).round(),
  );
  final samples = resampleLinear(
    applyGain(trimmed, clip.gain),
    wav.sampleRate,
    16000,
  );
  final padding = (offset * 16000).round();
  final padded = Float32List(padding + samples.length)
    ..setRange(padding, padding + samples.length, samples);
  return VocalMidiAudio(
    encodeWavMono16(padded, 16000),
    duration,
    offset,
    previewWav: encodeWavMono16(samples, 16000),
  );
}

List<PitchNote> vocalMidiNotes(
  eng.AnalyzeResponse response, {
  required int bpm,
  required int bars,
  required int startStep,
}) {
  final secondsPerStep = 60 / bpm / kStepsPerBeat;
  final limit = stepsForBars(bars);
  final out = <PitchNote>[];
  for (final n in response.notes) {
    if (n.kind != 'pitched') continue;
    final step = n.step ?? (n.start / secondsPerStep).round();
    if (step < startStep || step >= limit || n.pitch < 0 || n.pitch > 127) {
      continue;
    }
    final dur = (n.durSteps ?? (n.duration / secondsPerStep).round()).clamp(
      1,
      limit - step,
    );
    if (out.any((x) => x.step == step && x.midi == n.pitch)) continue;
    out.add(
      PitchNote(
        midi: n.pitch,
        freq: midiToFreq(n.pitch),
        step: step,
        dur: dur,
        sourceMidi: n.pitchOriginal.clamp(0, 127),
        confidence: n.confidence.clamp(0, 1),
        assisted: n.assisted,
        locked: true,
      ),
    );
  }
  out.sort((a, b) => a.step.compareTo(b.step));
  if (out.isEmpty) throw const VocalMidiException(VocalMidiFailure.noNotes);
  return out;
}

class VocalMidiAnalysis {
  VocalMidiAnalysis(this.notes, this.preview, this.audio);
  final List<PitchNote> notes;
  final File preview;
  final VocalMidiAudio audio;
  Future<void> dispose() async {
    // This file belongs to this operation. Never remove a VocalClip source.
    try {
      if (await preview.exists()) await preview.delete();
    } on FileSystemException {
      /* Already gone or held by the player; never touch the source. */
    }
    try {
      await preview.parent.delete();
    } on FileSystemException {
      /* Already gone or held by the player; never touch the source. */
    }
  }
}

typedef VocalAnalyzer =
    Future<eng.AnalyzeResponse> Function(
      String path,
      eng.AnalyzeOptions options,
    );

class VocalMidiService {
  VocalMidiService({
    VocalAnalyzer? analyze,
    this.temporaryDirectory,
    CancelToken? cancelToken,
  }) : _analyze =
           analyze ??
           ((path, options) =>
               EngineApi().analyze(path, options, cancelToken: cancelToken));
  final VocalAnalyzer _analyze;
  final Directory? temporaryDirectory;

  Future<VocalMidiAnalysis> convert(
    VocalClip clip, {
    required int bpm,
    required int bars,
    required String keyRoot,
    required String scale,
    required double swing,
  }) async {
    final bytes = await File(LoopStorage.resolveVocal(clip.path)).readAsBytes();
    final audio = await compute(prepareVocalMidiAudio, {
      'bytes': bytes,
      'clip': clip.copy(),
      'bpm': bpm,
      'bars': bars,
      'swing': swing,
    });
    final base = temporaryDirectory ?? await getTemporaryDirectory();
    final folder = await base.createTemp('vocal_midi_');
    final preview = File('${folder.path}/selection.wav');
    var keep = false;
    try {
      await preview.writeAsBytes(audio.wav, flush: true);
      final response = await _analyze(
        preview.path,
        eng.AnalyzeOptions(
          autoKey: false,
          keyTonic: keyRoot,
          scale: scale == 'pentatonic' ? 'minor_pentatonic' : scale,
          tempoBpm: bpm,
          loopQuantize: true,
          loopBars: bars,
          stepsPerBar: kStepsPerBeat * kBeatsPerBar,
          swing: swing,
        ),
      );
      final notes = vocalMidiNotes(
        response,
        bpm: bpm,
        bars: bars,
        startStep: clip.startStep,
      );
      // The request has completed: reuse our own temporary file for an
      // immediate, unpadded preview. The persisted vocal is never rewritten.
      await preview.writeAsBytes(audio.previewWav!, flush: true);
      keep = true;
      return VocalMidiAnalysis(notes, preview, audio);
    } finally {
      if (!keep) {
        try {
          if (await preview.exists()) await preview.delete();
        } on FileSystemException {
          /* Already gone or held by the player; never touch the source. */
        }
        try {
          await folder.delete();
        } on FileSystemException {
          /* Already gone or held by the player; never touch the source. */
        }
      }
    }
  }
}

class VocalMidiResult {
  const VocalMidiResult(this.notes, this.program);
  final List<PitchNote> notes;
  final int program;
}

/// Song-wide track identity, with notes only in the source section.
/// Caller records one undo snapshot before committing this transaction.
String addVocalMidiTrack(
  List<Section> sections,
  String sectionId,
  String id,
  VocalMidiResult result, {
  bool useEmptyMelodyLane = false,
}) {
  if (!sections.any((s) => s.id == sectionId) ||
      sections.any((s) => s.tracks.containsKey(id))) {
    throw StateError('Invalid MIDI conversion target');
  }
  final target = sections.firstWhere((s) => s.id == sectionId);
  if (useEmptyMelodyLane &&
      (target.tracks['melody']?.pitchNotes.isEmpty ?? true)) {
    target.tracks['melody'] = TrackData(
      notes: result.notes.map((n) => n.copyWith()).toList(),
    );
    return 'melody';
  }
  for (final section in sections) {
    section.extras.add(TrackRef(id, 'melody'));
    section.tracks[id] = TrackData(
      notes:
          section.id == sectionId
              ? result.notes.map((n) => n.copyWith()).toList()
              : [],
    );
  }
  return id;
}
