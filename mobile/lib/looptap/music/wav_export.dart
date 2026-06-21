// HumTrack — on-device WAV / Stems render via dart_melty_soundfont.
//
// Unlike the old oscillator render, this plays the song's MIDI (buildMidi) back
// through the SAME GeneralUser-GS.sf2 used for live playback — so the exported WAV
// matches the timbre you hear in the editor (FluidSynth vs MeltySynth differ
// only subtly). buildMidi already covers all five lanes (melody/bass/melodyDec/
// drums/beatDec), so stems and the full mix include the decoration tracks too.
//
// The heavy render runs in a background isolate via compute(): the SF2 bytes are
// loaded on the main isolate (rootBundle) and passed in, since rootBundle isn't
// available inside a plain isolate.
//
// Vocal recordings are PCM16 WAV (44.1k mono) since the opus→WAV switch, so
// the full mix decodes them in pure Dart (inside the render isolate — the main
// isolate only reads the raw bytes) and sums them into the render at each
// section instance's start (same schedule as live playback's _songVocalSched).
// Legacy opus takes (.caf/.ogg) are converted once via the backend's
// /process_vocal when online (cached as *.cnv.wav); otherwise they're skipped
// and reported via the returned counter.
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../../main.dart' show engineApi;
import '../models/loop_models.dart';
import '../state/loop_storage.dart';
import 'instruments.dart';
import 'midi_export.dart';
import 'song_util.dart';
import 'soundfont_catalog.dart';
import 'theory.dart';
import 'wav_codec.dart';

const int _sr = 44100;
const String _sfAsset = 'assets/sounds/GeneralUser-GS.sf2';
const String _sf808Asset = 'assets/sounds/808.sf2';
const String _sfHipHopAsset = 'assets/sounds/hiphop_kit.sf2';
// Render past the last note-off so reverb/release tails aren't cut.
const double _tailSec = 1.2;

// ── SF2 asset bytes (loaded on the main isolate, passed into compute) ──
Future<Uint8List> _sf2Bytes() async {
  final bd = await rootBundle.load(_sfAsset);
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

Future<Uint8List> _sf808Bytes() async {
  final bd = await rootBundle.load(_sf808Asset);
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

Future<Uint8List> _sfHipHopBytes() async {
  final bd = await rootBundle.load(_sfHipHopAsset);
  return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
}

// ── isolate render ──────────────────────────────────────────────────
// Input: a['sf2s'] = list of SoundFont blobs; a['jobs'] = list of {sf2:int(index
// into sf2s), midi:Uint8List}; a['mix'] = bool. Each job renders its MIDI through
// its own SoundFont — this is how the 808 bass lane (a second SF2) is mixed with
// the GM lanes. When mix=true the job buffers are summed into one WAV; otherwise
// one WAV per job (stems). Vocal takes arrive as raw WAV bytes
// (a['vocalBytes'] = {name: Uint8List}) and are decoded/resampled HERE so the
// parse doesn't jank the UI isolate; a['vocals'] schedules them by name.
List<Uint8List> _renderIso(Map<String, dynamic> a) {
  final sf2s = (a['sf2s'] as List).cast<Uint8List>();
  final jobs = (a['jobs'] as List).cast<Map>();
  final sampleRate = a['sampleRate'] as int;
  final tailSec = a['tail'] as double;
  final mix = a['mix'] as bool;
  // decode each take once to SOURCE pcm + sr (mix only) — see _vocalJobs. Trim/
  // fade are non-destructive and clip-specific, so they're applied per scheduled
  // occurrence below (in source samples) before resampling to the render rate.
  final vocalSrc = <String, WavData>{};
  for (final e in ((a['vocalBytes'] as Map?) ?? const {}).entries) {
    final wav = parseWav(e.value as Uint8List);
    if (wav == null) continue; // corrupt take — drop from the mix
    vocalSrc[e.key as String] = wav;
  }
  // Memoize the no-edit resample (a take repeated across sections is common).
  final resampledPlain = <String, Float32List>{};
  Float32List plain(String name, WavData src) => resampledPlain[name] ??=
      resampleLinear(src.samples, src.sampleRate, sampleRate);
  // scheduled vocal occurrences (mix only) — see scheduleVocalMixes
  final vocals = <VocalMix>[];
  for (final v in (a['vocals'] as List?) ?? const []) {
    final m = v as Map;
    final src = vocalSrc[m['name']];
    if (src == null) continue;
    final trimStart = (m['trimStart'] as int?) ?? 0;
    final trimEnd = (m['trimEnd'] as int?) ?? -1;
    final fadeInMs = (m['fadeInMs'] as int?) ?? 0;
    final fadeOutMs = (m['fadeOutMs'] as int?) ?? 0;
    final Float32List pcm;
    if (trimStart == 0 && trimEnd == -1 && fadeInMs == 0 && fadeOutMs == 0) {
      pcm = plain(m['name'] as String, src); // legacy/whole take — shared buffer
    } else {
      var p = (trimStart == 0 && trimEnd == -1)
          ? src.samples
          : trimPcm(src.samples, trimStart, trimEnd == -1 ? src.samples.length : trimEnd);
      if (fadeInMs != 0 || fadeOutMs != 0) {
        p = fadePcm(p, (fadeInMs / 1000 * src.sampleRate).round(),
            (fadeOutMs / 1000 * src.sampleRate).round());
      }
      pcm = resampleLinear(p, src.sampleRate, sampleRate);
    }
    vocals.add(VocalMix(
      pcm: pcm,
      start: m['start'] as int,
      len: m['len'] as int,
      gain: m['gain'] as double,
    ));
  }

  final lefts = <Float32List>[];
  final rights = <Float32List>[];
  var maxN = vocalMixEnd(vocals);
  for (final job in jobs) {
    final synth = Synthesizer.loadByteData(
      ByteData.sublistView(sf2s[job['sf2'] as int]),
      SynthesizerSettings(sampleRate: sampleRate, enableReverbAndChorus: true),
    );
    final midiFile = MidiFile.fromByteData(ByteData.sublistView(job['midi'] as Uint8List));
    final seq = MidiFileSequencer(synth);
    seq.play(midiFile, loop: false);

    final totalSec = midiFile.length.inMicroseconds / 1e6 + tailSec;
    final n = (totalSec * sampleRate).ceil();
    if (n > maxN) maxN = n;
    final left = Float32List(n);
    final right = Float32List(n);
    seq.render(left, right);
    lefts.add(left);
    rights.add(right);
  }

  if (!mix) {
    return [for (var i = 0; i < lefts.length; i++) encodeWavMono16FromStereo(lefts[i], rights[i], sampleRate)];
  }
  // Sum all job buffers (different lengths possible) into one mix.
  final left = Float32List(maxN);
  final right = Float32List(maxN);
  for (var j = 0; j < lefts.length; j++) {
    final l = lefts[j], r = rights[j];
    for (var i = 0; i < l.length; i++) {
      left[i] += l[i];
      right[i] += r[i];
    }
  }
  mixVocalsInto(left, right, vocals);
  // Final mix: normalize up to the headroom so exports are full-level and
  // consistent (stems above keep their relative balance — no upward boost).
  return [encodeWavMono16FromStereo(left, right, sampleRate, normalize: true)];
}

// Debug-only: report duration + level so an export can be sanity-checked from
// logs (non-silent? right length?) without pulling the file off-device.
void _logWavStats(String tag, String path, Uint8List wav) {
  if (!kDebugMode) return;
  final samples = (wav.length - 44) ~/ 2;
  final sec = samples / _sr;
  final bd = ByteData.sublistView(wav, 44);
  var peak = 0;
  var sumSq = 0.0;
  for (var i = 0; i + 1 < bd.lengthInBytes; i += 2) {
    final s = bd.getInt16(i, Endian.little);
    final a = s.abs();
    if (a > peak) peak = a;
    sumSq += s * s.toDouble();
  }
  final rms = samples > 0 ? math.sqrt(sumSq / samples) : 0.0;
  debugPrint('[export] $tag ${path.split('/').last}: '
      '${(wav.length / 1024).toStringAsFixed(0)}KB, ${sec.toStringAsFixed(2)}s, '
      'peak=${(peak / 32768 * 100).toStringAsFixed(1)}% rms=${(rms / 32768 * 100).toStringAsFixed(1)}%');
}

// ── public API ──────────────────────────────────────────────────────
Future<String> _exportPath(String title, String ext) async {
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/looptap/exports');
  if (!await folder.exists()) await folder.create(recursive: true);
  final safe = title.trim().isEmpty ? 'loop' : title.trim().replaceAll(RegExp(r'[^\w\- ]+'), '_');
  return '${folder.path}/$safe.$ext';
}

// ── vocal scheduling for the full mix ───────────────────────────────
// Load each section's vocal bytes once (memoized INCLUDING failures, so a
// broken take is attempted/counted exactly once) and emit one schedule entry
// per section INSTANCE (repeats included), mirroring _songVocalSched in the
// editor. Legacy opus files round-trip through /process_vocal when online
// (cached next to the original as *.cnv.wav); failures count as skipped.
// Decoding/resampling the bytes happens inside the render isolate.
Future<({Map<String, Uint8List> bytes, List<Map<String, Object>> schedule, int skipped})>
    _vocalJobs(
  List<Section> sections,
  int bpm,
  double gain,
) async {
  final bytesByName = <String, Uint8List?>{};
  var skipped = 0;
  if (gain > 0) {
    for (final sec in sections) {
      for (final vid in vocalTrackIds(sec)) {
        for (final c in sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[]) {
          if (bytesByName.containsKey(c.path)) continue;
          final bytes = await _loadVocalBytes(c.path);
          bytesByName[c.path] = bytes; // null memoizes the failure
          if (bytes == null) skipped++;
        }
      }
    }
  }
  final ok = <String, Uint8List>{
    for (final e in bytesByName.entries)
      if (e.value != null) e.key: e.value!,
  };
  return (
    bytes: ok,
    schedule: scheduleVocalMixes(sections, bpm, gain, ok.keys.toSet()),
    skipped: skipped,
  );
}

/// Song-level continuous vocal: load the one take and schedule it from t=0 over
/// the whole arrangement (mirrors live playback, which replaces the per-section
/// vocals with this single clip). Same return shape as [_vocalJobs].
Future<({Map<String, Uint8List> bytes, List<Map<String, Object>> schedule, int skipped})>
    _songVocalJob(String path, List<Section> sections, int bpm, double gain) async {
  if (gain <= 0) return (bytes: <String, Uint8List>{}, schedule: const <Map<String, Object>>[], skipped: 0);
  final bytes = await _loadVocalBytes(path);
  if (bytes == null) {
    return (bytes: <String, Uint8List>{}, schedule: const <Map<String, Object>>[], skipped: 1);
  }
  final spStep = 60 / bpm / kStepsPerBeat * _sr; // samples per 16th step
  var totalSteps = 0;
  for (final sec in sections) {
    totalSteps += stepsForBars(sec.bars) * sec.repeats;
  }
  final len = (totalSteps * spStep).round(); // mixVocalsInto caps at the take length
  return (
    bytes: {path: bytes},
    schedule: <Map<String, Object>>[
      {
        'name': path,
        'start': 0,
        'len': len,
        'gain': gain,
        'trimStart': 0,
        'trimEnd': -1,
        'fadeInMs': 0,
        'fadeOutMs': 0,
      },
    ],
    skipped: 0,
  );
}

/// Pure schedule walk (testable): one entry per CLIP per section INSTANCE whose
/// take loaded ([names]), at `(cumulative + clip.startStep) × samples-per-step`.
/// Section boundaries are multiples of 16 steps, so swing (odd 16ths only) never
/// shifts them. `len` is the room left in the section instance after the clip's
/// start; mixVocalsInto truncates to the decoded take's length. `trimStart`/
/// `trimEnd` (source samples) and `fadeInMs`/`fadeOutMs` are the non-destructive
/// edits the render isolate applies before resampling. A legacy single-take
/// section resolves (via [TrackData.effectiveClips]) to one clip at step 0,
/// gain 1, no edits — byte-identical to the old per-section schedule.
@visibleForTesting
List<Map<String, Object>> scheduleVocalMixes(
  List<Section> sections,
  int bpm,
  double gain,
  Set<String> names, {
  int sampleRate = _sr,
}) {
  final spStep = 60 / bpm / kStepsPerBeat * sampleRate; // samples per 16th step
  final vocals = <Map<String, Object>>[];
  var offSteps = 0;
  for (final sec in sections) {
    final secSteps = stepsForBars(sec.bars);
    // every vocal lane in the section (base 'vocal' + any added vocal tracks)
    // mixes down together — overlapping clips on separate lanes play at once.
    final lanes = [
      for (final vid in vocalTrackIds(sec)) sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[],
    ];
    for (var r = 0; r < sec.repeats; r++) {
      if (gain > 0) {
        for (final clips in lanes) {
          for (final c in clips) {
            if (!names.contains(c.path) || c.gain <= 0) continue;
            if (c.startStep < 0 || c.startStep >= secSteps) continue; // out of loop
            final start = ((offSteps + c.startStep) * spStep).round();
            final len = ((secSteps - c.startStep) * spStep).round();
            vocals.add({
              'name': c.path,
              'start': start,
              'len': len,
              'gain': gain * c.gain,
              'trimStart': c.trimStart,
              'trimEnd': c.trimEnd,
              'fadeInMs': c.fadeInMs,
              'fadeOutMs': c.fadeOutMs,
            });
          }
        }
      }
      offSteps += secSteps;
    }
  }
  return vocals;
}

/// The vocal-kind track ids in [s]: the base 'vocal' lane plus any added vocal
/// track instances (so overlapping takes can live on separate lanes and play
/// simultaneously, like a multitrack). Order is stable (base first).
List<String> vocalTrackIds(Section s) {
  final ids = <String>['vocal'];
  for (final e in s.extras) {
    if (trackById(e.type).kind == TrackKind.vocal) ids.add(e.id);
  }
  return ids;
}

/// Pre-bounce a vocal lane's [clips] (one section loop, [bars] long) into a
/// single mono buffer at [sampleRate], applying each clip's trim/fade/gain at
/// its [startStep] offset. [sources] maps clip path → decoded mono PCM at its
/// own source rate. Pure (no IO) — backs both on-device pre-bounce playback and
/// the editor's A/B preview, and reuses the same trim/fade/mix math as export.
Float32List bounceVocalClips(
  List<VocalClip> clips,
  int bars,
  int bpm,
  Map<String, ({Float32List pcm, int sampleRate})> sources, {
  int sampleRate = _sr,
  double laneGain = 1.0,
  int minLen = 0,
}) {
  final spStep = 60 / bpm / kStepsPerBeat * sampleRate;
  final secSteps = stepsForBars(bars);
  final mixes = <VocalMix>[];
  for (final c in clips) {
    final src = sources[c.path];
    if (src == null || c.gain <= 0) continue;
    if (c.startStep < 0 || c.startStep >= secSteps) continue;
    var p = (c.trimStart == 0 && c.trimEnd == -1)
        ? src.pcm
        : trimPcm(src.pcm, c.trimStart, c.trimEnd == -1 ? src.pcm.length : c.trimEnd);
    if (c.fadeInMs != 0 || c.fadeOutMs != 0) {
      p = fadePcm(p, (c.fadeInMs / 1000 * src.sampleRate).round(),
          (c.fadeOutMs / 1000 * src.sampleRate).round());
    }
    final res = resampleLinear(p, src.sampleRate, sampleRate);
    mixes.add(VocalMix(
      pcm: res,
      start: (c.startStep * spStep).round(),
      len: ((secSteps - c.startStep) * spStep).round(),
      gain: laneGain * c.gain,
    ));
  }
  final n = math.max(vocalMixEnd(mixes), minLen); // pad to the loop for looping
  final left = Float32List(n), right = Float32List(n);
  mixVocalsInto(left, right, mixes); // writes the mono sum equally to L/R
  return left;
}

/// Bounce all of [sec]'s vocal-kind lanes (base Vocal + Audio lanes, skipping
/// any whose [vol] is 0) into one mono WAV at the export rate — the vocal STEM,
/// reflecting every take's position/trim/fade/gain. Returns null when nothing
/// loads. Reuses [_loadVocalBytes] (legacy-opus aware) and [bounceVocalClips].
Future<Uint8List?> bounceSectionVocalWav(
    Section sec, int bpm, Map<String, double> vol) async {
  final clips = <VocalClip>[];
  for (final vid in vocalTrackIds(sec)) {
    if ((vol[vid] ?? 0.85) <= 0) continue; // muted lane → excluded
    clips.addAll(sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[]);
  }
  if (clips.isEmpty) return null;
  final sources = <String, ({Float32List pcm, int sampleRate})>{};
  for (final c in clips) {
    if (sources.containsKey(c.path)) continue;
    final bytes = await _loadVocalBytes(c.path);
    if (bytes == null) continue;
    final wav = parseWav(bytes);
    if (wav != null) sources[c.path] = (pcm: wav.samples, sampleRate: wav.sampleRate);
  }
  if (sources.isEmpty) return null;
  final lane = bounceVocalClips(clips, sec.bars, bpm, sources, sampleRate: _sr);
  if (lane.isEmpty) return null;
  return encodeWavMono16(lane, _sr);
}

/// Read a stored vocal (basename) as raw WAV bytes, or null when it can't be
/// included (missing file / undecodable legacy take offline). The backend
/// conversion network call stays on the main isolate; parse/resample of the
/// returned bytes happens in the render isolate.
Future<Uint8List?> _loadVocalBytes(String name) async {
  final path = LoopStorage.resolveVocal(name);
  final f = File(path);
  if (!await f.exists()) return null;
  if (path.toLowerCase().endsWith('.wav')) return f.readAsBytes();
  // legacy opus (.caf/.ogg): use a previous conversion if cached, else convert
  // through the backend once.
  final cnv = File('$path.cnv.wav');
  if (await cnv.exists()) return cnv.readAsBytes();
  try {
    final res = await engineApi.processVocal(path);
    await cnv.writeAsBytes(res.wav); // cache the round-trip
    return res.wav;
  } catch (e) {
    debugPrint('[export] legacy vocal convert failed ($name): $e');
    return null;
  }
}

/// Full-mix WAV — all instrument lanes plus every section's vocal recording
/// at its scheduled offset. When the bass uses the 808 (no GM slot) the bass
/// lane renders through 808.sf2 and the rest through the GM SF2, then the two
/// are summed so the mix matches live playback. [skippedVocals] counts takes
/// that couldn't be included (legacy format while offline / missing file).
Future<({File file, int skippedVocals})> exportWavSong(
  List<Section> sections,
  int bpm,
  double swing,
  Map<String, double> vol,
  String title, {
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
  int drumProgram = 0,
  List<TrackRef> extras = const [],
  Map<String, int> instruments = const {},
  String? songVocalPath,
}) async {
  final flat = flattenSong(sections);
  // Custom-soundfont lanes (no GM slot) render through their own SF2 and are
  // summed with the GM render. 808 bass → 808.sf2; hip-hop kit → hiphop_kit.sf2;
  // runtime-catalog instruments (slot >= 1000) → their downloaded SF2.
  final use808 = bassProgram == kProgram808;
  final useHipHop = drumProgram == kProgramHipHopKit;
  final sf2s = <Uint8List>[await _sf2Bytes()]; // index 0 = GM
  int idx808 = 0, idxHip = 0;
  if (use808) {
    sf2s.add(await _sf808Bytes());
    idx808 = sf2s.length - 1;
  }
  if (useHipHop) {
    sf2s.add(await _sfHipHopBytes());
    idxHip = sf2s.length - 1;
  }
  // Muted lanes arrive as vol == 0 from the editor. CC7 covers most of them,
  // but ch9 CC7 is driven by vol['drums'] alone, so a muted beat-fill must be
  // dropped from note emission entirely.
  bool silent(String id) => (vol[id] ?? 0.85) <= 0;

  // Resolve the three base pitched lanes that carry a downloaded catalog slot
  // into their own SF2 render jobs (mirrors 808). A dynamic-but-not-downloaded
  // lane stays in the GM job at its GM fallback program so export never goes
  // silent or stalls on a network fetch.
  final dynJobs = <Map<String, Object>>[];
  final dynLanes = <String>{}; // lanes pulled out of the GM render
  int melGm = melodyProgram, mdGm = melodyDecProgram, bassGm = bassProgram;
  Future<void> addDynLane(String lane, int program, int channelProgArg) async {
    if (!isDynamicSlot(program)) return;
    final e = SoundfontCatalog.instance.bySlot(program);
    final path = SoundfontCatalog.instance.localPath(program);
    if (e == null) return;
    if (path == null) {
      // not downloaded → render as the GM fallback in the main job
      final fb = e.midiFallback;
      if (lane == 'melody') melGm = fb;
      if (lane == 'melodyDec') mdGm = fb;
      if (lane == 'bass') bassGm = fb;
      return;
    }
    if (silent(lane)) {
      dynLanes.add(lane);
      return;
    }
    sf2s.add(await File(path).readAsBytes());
    final sfIdx = sf2s.length - 1;
    dynLanes.add(lane);
    dynJobs.add({
      'sf2': sfIdx,
      'midi': buildMidi(flat, bpm,
          melodyProgram: lane == 'melody' ? e.sfProgram : melodyProgram,
          melodyDecProgram: lane == 'melodyDec' ? e.sfProgram : melodyDecProgram,
          bassProgram: lane == 'bass' ? e.sfProgram : bassProgram,
          swing: swing,
          vol: vol,
          tracks: {lane},
          // the lane's real program is a catalog slot here; force strum when
          // that slot is a guitar (buildMidi only sees the SF2's preset = 0).
          strumGuitar: isGuitarProgram(program)),
    });
  }

  await addDynLane('melody', melodyProgram, 0);
  await addDynLane('melodyDec', melodyDecProgram, 2);
  await addDynLane('bass', bassProgram, 1);

  // Dynamic drum kit (downloaded) → its own bank-128 SF2 job, like hip-hop.
  final useDynDrum = isDynamicSlot(drumProgram) && SoundfontCatalog.instance.localPath(drumProgram) != null;
  int idxDynDrum = 0;
  if (useDynDrum) {
    sf2s.add(await File(SoundfontCatalog.instance.localPath(drumProgram)!).readAsBytes());
    idxDynDrum = sf2s.length - 1;
  }
  // A dynamic-but-not-downloaded drum kit falls back to the GM standard kit.
  final drumGm = isDynamicSlot(drumProgram) ? 0 : drumProgram;

  // Drum lanes that carry their OWN kit, independent of the base ch9 'drums'
  // kit: beat-fill + every added drum track. Each renders as a separate ch9
  // job through its kit's SF2 and is summed like the 808/hip-hop lanes, so
  // different drum tracks can use different kits in one mix. (MeltySynth only
  // treats ch9 as percussion, so "per-kit" means per-render, not per-channel.)
  final perKitDrums = <String>[
    if (flat.beatDec.isNotEmpty) 'beatDec',
    for (final e in extras)
      if (trackById(e.type).kind == TrackKind.drums &&
          (flat.extraDrums[e.id]?.isNotEmpty ?? false))
        e.id,
  ];
  final perKitDrumJobs = <Map<String, Object>>[];
  final perKitDrumLanes = <String>{}; // pulled out of the GM render
  for (final lane in perKitDrums) {
    perKitDrumLanes.add(lane);
    if (silent(lane)) continue; // excluded from GM + no job → silent
    final kit = instruments[lane] ?? kDefaultDrumKit;
    final int sfIdx;
    final int gmKit;
    if (kit == kProgramHipHopKit) {
      if (idxHip == 0) {
        sf2s.add(await _sfHipHopBytes());
        idxHip = sf2s.length - 1;
      }
      sfIdx = idxHip;
      gmKit = 0;
    } else if (isDynamicSlot(kit) && SoundfontCatalog.instance.localPath(kit) != null) {
      sf2s.add(await File(SoundfontCatalog.instance.localPath(kit)!).readAsBytes());
      sfIdx = sf2s.length - 1;
      gmKit = 0;
    } else {
      sfIdx = 0; // a GM kit lives in bank 128 of the main SF2
      gmKit = isDynamicSlot(kit) ? 0 : kit;
    }
    perKitDrumJobs.add({
      'sf2': sfIdx,
      // notes emit on ch9 (addDrums), so ch9's CC7 must carry THIS lane's volume.
      'midi': buildMidi(flat, bpm,
          drumProgram: gmKit,
          swing: swing,
          vol: {...vol, 'drums': vol[lane] ?? 0.85},
          tracks: {lane},
          extras: extras,
          extraInstruments: instruments),
    });
  }

  final gmTracks = <String>{'melody', 'melodyDec', 'bass', 'drums', for (final e in extras) e.id};
  gmTracks.removeAll({if (use808) 'bass', if (useHipHop || useDynDrum) 'drums', ...dynLanes, ...perKitDrumLanes});
  gmTracks.removeWhere(silent);
  // base 'drums' (ch9) only — beat-fill is now its own per-kit job above.
  final hipTracks = silent('drums') ? const <String>{} : const {'drums'};
  final jobs = <Map<String, Object>>[
    {
      'sf2': 0,
      'midi': buildMidi(flat, bpm,
          melodyProgram: melGm,
          bassProgram: bassGm,
          melodyDecProgram: mdGm,
          drumProgram: (useHipHop || useDynDrum) ? 0 : drumGm,
          swing: swing,
          vol: vol,
          tracks: gmTracks,
          extras: extras,
          extraInstruments: instruments),
    },
    if (use808 && !silent('bass'))
      // bassProgram 0 → selects the 808.sf2's single preset.
      {'sf2': idx808, 'midi': buildMidi(flat, bpm, bassProgram: 0, swing: swing, vol: vol, tracks: const {'bass'})},
    if (useHipHop && hipTracks.isNotEmpty)
      // base drums → the hip-hop kit's bank-128 preset (ch9 default).
      {'sf2': idxHip, 'midi': buildMidi(flat, bpm, swing: swing, vol: vol, tracks: hipTracks)},
    if (useDynDrum && hipTracks.isNotEmpty)
      // base drums → the catalog kit's bank-128 preset (ch9 default).
      {'sf2': idxDynDrum, 'midi': buildMidi(flat, bpm, swing: swing, vol: vol, tracks: hipTracks)},
    ...dynJobs,
    ...perKitDrumJobs,
  ];
  // A song-level take (recorded over the whole song) replaces the per-section
  // vocal schedule — one clip mixed from t=0, mirroring live playback.
  final vocal = songVocalPath != null
      ? await _songVocalJob(songVocalPath, sections, bpm, vol['vocal'] ?? 0.85)
      : await _vocalJobs(sections, bpm, vol['vocal'] ?? 0.85);
  final wavs = await compute(_renderIso, {
    'sf2s': sf2s,
    'jobs': jobs,
    'vocals': vocal.schedule,
    'vocalBytes': vocal.bytes,
    'mix': true,
    'sampleRate': _sr,
    'tail': _tailSec,
  });
  final f = File(await _exportPath(title, 'wav'));
  await f.writeAsBytes(wavs.first);
  _logWavStats('WAV mix', f.path, wavs.first);
  return (file: f, skippedVocals: vocal.skipped);
}

/// One WAV per non-empty instrument lane + each section's vocal recording.
Future<List<File>> exportStems(
  List<Section> sections,
  int bpm,
  double swing,
  Map<String, double> vol,
  String title, {
  int melodyProgram = 0,
  int bassProgram = 33,
  int melodyDecProgram = 48,
  int drumProgram = 0,
  List<TrackRef> extras = const [],
  Map<String, int> instruments = const {},
  String? songVocalPath,
}) async {
  final flat = flattenSong(sections);
  final labelOf = {for (final m in sectionTrackMetas(extras)) m.id: m.label};
  // Muted lanes arrive as vol == 0 from the editor — skip them outright
  // (their CC7 would render a useless silent stem otherwise).
  bool audible(String id) => (vol[id] ?? 0.85) > 0;
  // present lanes: non-empty, unmuted base lanes + added instances.
  final present = <({String id, String label})>[
    if (flat.melody.isNotEmpty && audible('melody')) (id: 'melody', label: 'melody'),
    if (flat.bass.isNotEmpty && audible('bass')) (id: 'bass', label: 'bass'),
    if (flat.melodyDec.isNotEmpty && audible('melodyDec')) (id: 'melodyDec', label: 'melodyDec'),
    if (flat.drums.isNotEmpty && audible('drums')) (id: 'drums', label: 'drums'),
    if (flat.beatDec.isNotEmpty && audible('beatDec')) (id: 'beatDec', label: 'beatDec'),
    for (final e in extras)
      if (((flat.extraPitched[e.id]?.isNotEmpty ?? false) ||
              (flat.extraDrums[e.id]?.isNotEmpty ?? false)) &&
          audible(e.id))
        (id: e.id, label: labelOf[e.id] ?? e.id),
  ];
  final out = <File>[];

  if (present.isNotEmpty) {
    final use808 = bassProgram == kProgram808;
    final useHipHop = drumProgram == kProgramHipHopKit;
    final sf2s = <Uint8List>[await _sf2Bytes()]; // index 0 = GM
    int idx808 = 0, idxHip = 0;
    if (use808) {
      sf2s.add(await _sf808Bytes());
      idx808 = sf2s.length - 1;
    }
    if (useHipHop) {
      sf2s.add(await _sfHipHopBytes());
      idxHip = sf2s.length - 1;
    }
    final jobs = <Map<String, Object>>[];
    for (final p in present) {
      final isBaseDrums = p.id == 'drums';
      final extraDrum =
          extras.any((e) => e.id == p.id && trackById(e.type).kind == TrackKind.drums);
      // beat-fill + added drum tracks each carry their own kit; only the base
      // 'drums' lane uses the song-level drumProgram.
      final isDrum = isBaseDrums || p.id == 'beatDec' || extraDrum;
      final isBass808 = use808 && p.id == 'bass';
      int sf2i = 0;
      int gmKit = 0;
      if (isBass808) {
        sf2i = idx808;
      } else if (isDrum) {
        // each drum stem renders through ITS kit — same resolution as the mix.
        final kit = isBaseDrums ? drumProgram : (instruments[p.id] ?? kDefaultDrumKit);
        if (kit == kProgramHipHopKit) {
          if (idxHip == 0) {
            sf2s.add(await _sfHipHopBytes());
            idxHip = sf2s.length - 1;
          }
          sf2i = idxHip;
        } else if (isDynamicSlot(kit) && SoundfontCatalog.instance.localPath(kit) != null) {
          sf2s.add(await File(SoundfontCatalog.instance.localPath(kit)!).readAsBytes());
          sf2i = sf2s.length - 1;
        } else {
          sf2i = 0; // GM kit lives in bank 128 of the main SF2
          gmKit = isDynamicSlot(kit) ? 0 : kit;
        }
      }
      jobs.add({
        'sf2': sf2i,
        'midi': buildMidi(flat, bpm,
            melodyProgram: melodyProgram,
            // 808 bass stem → program 0 selects the 808.sf2 preset.
            bassProgram: isBass808 ? 0 : bassProgram,
            melodyDecProgram: melodyDecProgram,
            drumProgram: gmKit,
            swing: swing,
            vol: vol,
            tracks: {p.id},
            extras: extras,
            extraInstruments: instruments),
      });
    }
    final wavs = await compute(_renderIso, {
      'sf2s': sf2s,
      'jobs': jobs,
      'mix': false,
      'sampleRate': _sr,
      'tail': _tailSec,
    });
    for (var i = 0; i < present.length; i++) {
      final f = File(await _exportPath('$title - ${present[i].label}', 'wav'));
      await f.writeAsBytes(wavs[i]);
      _logWavStats('stem ${present[i].label}', f.path, wavs[i]);
      out.add(f);
    }
  }

  // Vocal stem(s). A song-level take replaces the per-section vocals (mirrors
  // the full-mix/playback), so export it as ONE stem; otherwise one per-section
  // MIX of every vocal-kind lane's takes (positions/trim/fade/gain applied).
  if (songVocalPath != null) {
    final bytes = await _loadVocalBytes(songVocalPath);
    if (bytes != null) {
      final f = File(await _exportPath('$title - vocal (song)', 'wav'));
      await f.writeAsBytes(bytes);
      out.add(f);
    }
  } else {
    for (var i = 0; i < sections.length; i++) {
      final sec = sections[i];
      final bytes = await bounceSectionVocalWav(sec, bpm, vol);
      if (bytes == null) continue;
      final f = File(await _exportPath('$title - vocal ${i + 1} ${sec.name}', 'wav'));
      await f.writeAsBytes(bytes);
      out.add(f);
    }
  }
  return out;
}
