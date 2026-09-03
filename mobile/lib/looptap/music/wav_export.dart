// HumTrack — on-device WAV / Stems render via dart_melty_soundfont.
//
// Unlike the old oscillator render, this plays the song's MIDI (buildMidi) back
// through the SAME GeneralUser-GS.sf2 used for live playback — so the exported WAV
// matches the timbre you hear in the editor (FluidSynth vs MeltySynth differ
// only subtly). buildMidi already covers all five lanes (melody/bass/melodyDec/
// drums/beatDec), so stems and the full mix include the decoration tracks too.
//
// The heavy render runs in a background isolate via compute(). Every SoundFont
// — bundled assets (materialised once to the app-support dir) and downloaded
// catalog fonts — is handed over as a file PATH and read inside the isolate
// (C20/A8): no multi-hundred-MB byte blobs are copied through the isolate
// message, only one SoundFont is parsed at a time, and the full mix is summed
// into a single shared L/R buffer instead of one full-length buffer per lane.
//
// Vocal recordings are PCM16 WAV (44.1k mono) since the opus→WAV switch, so
// the full mix decodes them in pure Dart (inside the render isolate — the main
// isolate only resolves file paths) and sums them into the render at each
// section instance's start (same schedule as live playback's _songVocalSched).
// Legacy opus takes (.caf/.ogg) are converted once via the backend's
// /process_vocal when online (cached as *.cnv.wav); otherwise they're skipped
// and reported via the returned counter.
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:dart_melty_soundfont/soundfont.dart' show SoundFont;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../../audio/backup_exclusion.dart';
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

// ── SF2 sources ─────────────────────────────────────────────────────
// A bundled SF2 asset is copied ONCE to <support>/looptap/sf2/<name> so the
// render isolate can open every soundfont from disk itself (rootBundle isn't
// reachable from a plain isolate). Re-copied when the asset size changes
// (app update).
Future<String> _assetSf2Path(String asset) async {
  final dir = await getApplicationSupportDirectory();
  final folder = Directory('${dir.path}/looptap/sf2');
  if (!await folder.exists()) await folder.create(recursive: true);
  // C18: pure copies of bundled assets (~tens of MB) — regenerable from the
  // app bundle, so keep them out of the backup too. Best effort, never throws.
  await excludeFromBackup(folder.path);
  final f = File('${folder.path}/${asset.split('/').last}');
  final bd = await rootBundle.load(asset);
  if (await f.exists() && await f.length() == bd.lengthInBytes) return f.path;
  await f.writeAsBytes(
      bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes),
      flush: true);
  return f.path;
}

/// The SoundFont files one render needs, deduplicated; jobs refer to them by
/// index into [paths].
class _Sf2Pool {
  final List<String> paths = [];
  final Map<String, int> _idx = {};

  int file(String path) => _idx.putIfAbsent(path, () {
        paths.add(path);
        return paths.length - 1;
      });

  Future<int> asset(String asset) async => file(await _assetSf2Path(asset));

  /// Index for a resolved render source (asset or file), or [fallback] when
  /// it's the GM font.
  Future<int> of({String? asset, String? path, required int fallback}) async {
    if (asset != null) return this.asset(asset);
    if (path != null) return file(path);
    return fallback;
  }
}

// ── instrument → render source resolution (shared by mix + stems, C10) ──
/// How a pitched lane's program renders: which SF2 it needs (asset or file;
/// both null = the GM font), the program to emit for it, and whether to force
/// the guitar strum (catalog guitars — buildMidi only sees the SF2 preset).
/// Base lanes and added instances resolve identically.
({String? asset, String? path, int program, bool strum}) _pitchedRender(int program) {
  if (program == kProgram808) {
    // 808.sf2's single preset is program 0
    return (asset: _sf808Asset, path: null, program: 0, strum: false);
  }
  if (isDynamicSlot(program)) {
    final e = SoundfontCatalog.instance.bySlot(program);
    final path = SoundfontCatalog.instance.localPath(program);
    if (e != null && path != null) {
      return (asset: null, path: path, program: e.sfProgram, strum: isGuitarProgram(program));
    }
    // not downloaded → GM fallback (same voice the .mid export uses)
    return (asset: null, path: null, program: SoundfontCatalog.instance.midiFallback(program), strum: false);
  }
  // any other out-of-range sentinel → nearest GM voice (mirrors buildMidi.gm)
  return (asset: null, path: null, program: program > 127 ? kProgram808MidiFallback : program, strum: false);
}

/// How a drum lane's kit renders: its SF2 (both null = GM font, bank 128) and
/// the bank-128 program to select (0 for custom kits: their only preset).
({String? asset, String? path, int gmKit}) _kitRender(int kit) {
  if (kit == kProgramHipHopKit) return (asset: _sfHipHopAsset, path: null, gmKit: 0);
  if (isDynamicSlot(kit)) {
    final path = SoundfontCatalog.instance.localPath(kit);
    // not downloaded → the GM standard kit
    return (asset: null, path: path, gmKit: 0);
  }
  return (asset: null, path: null, gmKit: kit > 127 ? 0 : kit);
}

// ── isolate render ──────────────────────────────────────────────────
// Input: a['sf2s'] = SoundFont file paths; a['jobs'] = list of {sf2:int(index
// into sf2s), midi:Uint8List}; a['mix'] = bool. Each job renders its MIDI
// through its own SoundFont — this is how the 808 bass lane (a second SF2) is
// mixed with the GM lanes. When mix=true every job is summed straight into ONE
// shared L/R buffer; otherwise one WAV per job (stems), encoded as soon as it's
// rendered. Vocal takes arrive as file paths (a['vocalPaths'] = {name: path})
// and are read/decoded/resampled HERE so nothing heavy crosses the isolate
// boundary; a['vocals'] schedules them by name.
List<Uint8List> _renderIso(Map<String, dynamic> a) {
  final sf2Paths = (a['sf2s'] as List).cast<String>();
  final jobs = (a['jobs'] as List).cast<Map>();
  final sampleRate = a['sampleRate'] as int;
  final tailSec = a['tail'] as double;
  final mix = a['mix'] as bool;
  // decode each take once to SOURCE pcm + sr (mix only) — see _vocalJobs. Trim/
  // fade are non-destructive and clip-specific, so they're applied per scheduled
  // occurrence below (in source samples) before resampling to the render rate.
  final vocalSrc = <String, WavData>{};
  for (final e in ((a['vocalPaths'] as Map?) ?? const {}).entries) {
    try {
      final wav = parseWav(File(e.value as String).readAsBytesSync());
      if (wav == null) continue; // corrupt take — drop from the mix
      vocalSrc[e.key as String] = wav;
    } catch (_) {
      // unreadable take — drop from the mix
    }
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

  // Parse every job's MIDI up front so the mix length is known before any
  // audio is allocated.
  final midis = [
    for (final j in jobs) MidiFile.fromByteData(ByteData.sublistView(j['midi'] as Uint8List)),
  ];
  int framesOf(MidiFile m) => ((m.length.inMicroseconds / 1e6 + tailSec) * sampleRate).ceil();
  // Render jobs grouped by SoundFont so each font is parsed once and released
  // before the next — only ONE font lives in memory at a time.
  final order = List<int>.generate(jobs.length, (i) => i)
    ..sort((x, y) => (jobs[x]['sf2'] as int).compareTo(jobs[y]['sf2'] as int));
  final settings = SynthesizerSettings(sampleRate: sampleRate, enableReverbAndChorus: true);
  SoundFont? font;
  var fontIdx = -1;
  SoundFont fontFor(int idx) {
    if (idx != fontIdx) {
      font = null; // let the previous font go before loading the next
      font = SoundFont.fromFile(sf2Paths[idx]);
      fontIdx = idx;
    }
    return font!;
  }

  if (mix) {
    var maxN = vocalMixEnd(vocals);
    for (final m in midis) {
      maxN = math.max(maxN, framesOf(m));
    }
    final left = Float32List(maxN);
    final right = Float32List(maxN);
    // Each job is rendered in small blocks and accumulated straight into the
    // shared mix — no per-job full-length buffers (A8).
    const block = 4096;
    final bl = Float32List(block), br = Float32List(block);
    for (final i in order) {
      final synth = Synthesizer.load(fontFor(jobs[i]['sf2'] as int), settings);
      final seq = MidiFileSequencer(synth);
      seq.play(midis[i], loop: false);
      final n = framesOf(midis[i]);
      var pos = 0;
      while (pos < n) {
        final cnt = math.min(block, n - pos);
        seq.render(bl, br);
        for (var k = 0; k < cnt; k++) {
          left[pos + k] += bl[k];
          right[pos + k] += br[k];
        }
        pos += cnt;
      }
      seq.stop(); // release the synth's voices before it goes out of scope
    }
    font = null;
    mixVocalsInto(left, right, vocals);
    // Final mix: normalize up to the headroom so exports are full-level and
    // consistent (stems above keep their relative balance — no upward boost).
    return [encodeWavMono16FromStereo(left, right, sampleRate, normalize: true)];
  }

  // Stems: one buffer per job, encoded right away so only one is alive.
  final out = List<Uint8List?>.filled(jobs.length, null);
  for (final i in order) {
    final synth = Synthesizer.load(fontFor(jobs[i]['sf2'] as int), settings);
    final seq = MidiFileSequencer(synth);
    seq.play(midis[i], loop: false);
    final n = framesOf(midis[i]);
    final left = Float32List(n);
    final right = Float32List(n);
    seq.render(left, right);
    seq.stop();
    out[i] = encodeWavMono16FromStereo(left, right, sampleRate);
  }
  font = null;
  return out.cast<Uint8List>();
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
/// A fresh export file under Documents/looptap/exports — shared sanitiser
/// (C11) + never-overwrite numbering (A20).
Future<File> _exportFile(String title, String ext, {required String fallback}) async {
  final folder = await exportsFolder(); // created + backup-excluded (C18)
  return uniqueExportFile(folder, exportFileName(title, fallback: fallback), ext);
}

// ── vocal scheduling for the full mix ───────────────────────────────
// Resolve each vocal take to a readable WAV path once (memoized INCLUDING
// failures, so a broken take is attempted/counted exactly once) and emit one
// schedule entry per section INSTANCE (repeats included), mirroring
// _songVocalSched in the editor. Legacy opus files round-trip through
// /process_vocal when online (cached next to the original as *.cnv.wav);
// failures count as skipped. Lanes at zero level (muted) are left out (C8).
// Reading/decoding/resampling happens inside the render isolate.
Future<({Map<String, String> paths, List<Map<String, Object>> schedule, int skipped})>
    _vocalJobs(
  List<Section> sections,
  int bpm,
  Map<String, double> vol,
) async {
  final pathByName = <String, String?>{};
  var skipped = 0;
  for (final sec in sections) {
    for (final vid in vocalTrackIds(sec)) {
      if ((vol[vid] ?? 0.85) <= 0) continue;
      for (final c in sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[]) {
        if (pathByName.containsKey(c.path)) continue;
        final path = await _loadVocalPath(c.path);
        pathByName[c.path] = path; // null memoizes the failure
        if (path == null) skipped++;
      }
    }
  }
  final ok = <String, String>{
    for (final e in pathByName.entries)
      if (e.value != null) e.key: e.value!,
  };
  return (
    paths: ok,
    schedule: scheduleVocalMixes(sections, bpm, vol['vocal'] ?? 0.85, ok.keys.toSet(), laneVol: vol),
    skipped: skipped,
  );
}

/// Song-level continuous vocal: resolve the one take and schedule it from t=0
/// over the whole arrangement (mirrors live playback, which replaces the
/// per-section vocals with this single clip). Same return shape as [_vocalJobs].
Future<({Map<String, String> paths, List<Map<String, Object>> schedule, int skipped})>
    _songVocalJob(String name, List<Section> sections, int bpm, double gain) async {
  if (gain <= 0) return (paths: <String, String>{}, schedule: const <Map<String, Object>>[], skipped: 0);
  final path = await _loadVocalPath(name);
  if (path == null) {
    return (paths: <String, String>{}, schedule: const <Map<String, Object>>[], skipped: 1);
  }
  final spStep = 60 / bpm / kStepsPerBeat * _sr; // samples per 16th step
  var totalSteps = 0;
  for (final sec in sections) {
    totalSteps += stepsForBars(sec.bars) * sec.repeats;
  }
  final len = (totalSteps * spStep).round(); // mixVocalsInto caps at the take length
  return (
    paths: {name: path},
    schedule: <Map<String, Object>>[
      {
        'name': name,
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
///
/// [gain] is the base Vocal lane's level. Added Audio lanes take their own
/// level from [laneVol] (C8) — when it's not given they follow [gain]. A lane
/// at zero level schedules nothing.
@visibleForTesting
List<Map<String, Object>> scheduleVocalMixes(
  List<Section> sections,
  int bpm,
  double gain,
  Set<String> names, {
  int sampleRate = _sr,
  Map<String, double>? laneVol,
}) {
  final spStep = 60 / bpm / kStepsPerBeat * sampleRate; // samples per 16th step
  final vocals = <Map<String, Object>>[];
  var offSteps = 0;
  for (final sec in sections) {
    final secSteps = stepsForBars(sec.bars);
    // every vocal lane in the section (base 'vocal' + any added vocal tracks)
    // mixes down together — overlapping clips on separate lanes play at once.
    final lanes = [
      for (final vid in vocalTrackIds(sec))
        (
          gain: vid == 'vocal' ? gain : (laneVol == null ? gain : (laneVol[vid] ?? 0.85)),
          clips: sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[],
        ),
    ];
    for (var r = 0; r < sec.repeats; r++) {
      for (final lane in lanes) {
        if (lane.gain <= 0) continue;
        for (final c in lane.clips) {
          if (!names.contains(c.path) || c.gain <= 0) continue;
          if (c.startStep < 0 || c.startStep >= secSteps) continue; // out of loop
          final start = ((offSteps + c.startStep) * spStep).round();
          final len = ((secSteps - c.startStep) * spStep).round();
          vocals.add({
            'name': c.path,
            'start': start,
            'len': len,
            'gain': lane.gain * c.gain,
            'trimStart': c.trimStart,
            'trimEnd': c.trimEnd,
            'fadeInMs': c.fadeInMs,
            'fadeOutMs': c.fadeOutMs,
          });
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

/// Bounce all of [sec]'s vocal-kind lanes (base Vocal + Audio lanes, each at
/// its own [vol] level; zero/muted lanes excluded — C8) into one mono WAV at
/// the export rate — the vocal STEM, reflecting every take's position/trim/
/// fade/gain. Returns null when nothing loads. Reuses [_loadVocalBytes]
/// (legacy-opus aware) and [bounceVocalClips].
Future<Uint8List?> bounceSectionVocalWav(
    Section sec, int bpm, Map<String, double> vol) async {
  final clips = <VocalClip>[];
  for (final vid in vocalTrackIds(sec)) {
    final laneVol = vol[vid] ?? 0.85;
    if (laneVol <= 0) continue; // muted lane → excluded
    for (final c in sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[]) {
      clips.add(c.copy()..gain = c.gain * laneVol);
    }
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

/// Resolve a stored vocal (basename) to a readable WAV file path, or null when
/// it can't be included (missing file / undecodable legacy take offline). The
/// backend conversion network call stays on the main isolate; the bytes are
/// read + parsed by whoever needs them (the render isolate for the mix).
Future<String?> _loadVocalPath(String name) async {
  final path = LoopStorage.resolveVocal(name);
  final f = File(path);
  if (!await f.exists()) return null;
  if (path.toLowerCase().endsWith('.wav')) return path;
  // legacy opus (.caf/.ogg): use a previous conversion if cached, else convert
  // through the backend once.
  final cnv = File('$path.cnv.wav');
  if (await cnv.exists()) return cnv.path;
  try {
    final res = await engineApi.processVocal(path);
    await cnv.writeAsBytes(res.wav); // cache the round-trip
    return cnv.path;
  } catch (e) {
    debugPrint('[export] legacy vocal convert failed ($name): $e');
    return null;
  }
}

/// Read a stored vocal (basename) as raw WAV bytes (see [_loadVocalPath]).
Future<Uint8List?> _loadVocalBytes(String name) async {
  final path = await _loadVocalPath(name);
  if (path == null) return null;
  try {
    return await File(path).readAsBytes();
  } catch (e) {
    debugPrint('[export] vocal read failed ($name): $e');
    return null;
  }
}

/// Full-mix WAV — all instrument lanes plus every section's vocal recording
/// at its scheduled offset. Lanes whose instrument lives outside the GM font
/// (808, hip-hop kit, downloaded catalog fonts — base AND added tracks, C10)
/// each render through their own SF2 and are summed with the GM render so the
/// mix matches live playback. [skippedVocals] counts takes that couldn't be
/// included (legacy format while offline / missing file).
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
  String fallbackName = 'loop',
}) async {
  final flat = flattenSong(sections);
  // Muted lanes arrive as vol == 0 from the editor. CC7 covers most of them,
  // but ch9 CC7 is driven by vol['drums'] alone, so a muted drum lane must be
  // dropped from note emission entirely.
  bool silent(String id) => (vol[id] ?? 0.85) <= 0;

  final pool = _Sf2Pool();
  final gmIdx = await pool.asset(_sfAsset); // index 0 = GM
  final jobs = <Map<String, Object>>[];
  // Lanes that stay in the single GM job, with the programs they use there
  // (dynamic-but-not-downloaded instruments fall back to their GM voice).
  final gmTracks = <String>{};
  int melGm = melodyProgram, mdGm = melodyDecProgram, bassGm = bassProgram;
  final gmExtra = <String, int>{};

  // A pitched lane: its own SF2 job when the instrument lives outside the GM
  // font, else queued into the GM job at (possibly fallback) GM program.
  Future<void> pitchedLane(String lane, int program, void Function(int gm) useGm) async {
    if (silent(lane)) return;
    final r = _pitchedRender(program);
    if (r.asset == null && r.path == null) {
      useGm(r.program);
      gmTracks.add(lane);
      return;
    }
    final idx = await pool.of(asset: r.asset, path: r.path, fallback: gmIdx);
    jobs.add({
      'sf2': idx,
      'midi': buildMidi(flat, bpm,
          melodyProgram: lane == 'melody' ? r.program : melodyProgram,
          melodyDecProgram: lane == 'melodyDec' ? r.program : melodyDecProgram,
          bassProgram: lane == 'bass' ? r.program : bassProgram,
          swing: swing,
          vol: vol,
          tracks: {lane},
          extras: extras,
          extraInstruments: {...instruments, lane: r.program},
          strumGuitar: r.strum),
    });
  }

  await pitchedLane('melody', melodyProgram, (p) => melGm = p);
  await pitchedLane('melodyDec', melodyDecProgram, (p) => mdGm = p);
  await pitchedLane('bass', bassProgram, (p) => bassGm = p);
  for (final e in extras) {
    final base = trackById(e.type);
    if (base.kind == TrackKind.pitched || base.kind == TrackKind.bass) {
      await pitchedLane(e.id, instruments[e.id] ?? base.defaultProgram, (p) => gmExtra[e.id] = p);
    }
  }

  // Base drums: in the GM job when the kit is a GM kit, else its own ch9 job.
  var drumGm = 0;
  if (!silent('drums')) {
    final r = _kitRender(drumProgram);
    if (r.asset == null && r.path == null) {
      drumGm = r.gmKit;
      gmTracks.add('drums');
    } else {
      jobs.add({
        'sf2': await pool.of(asset: r.asset, path: r.path, fallback: gmIdx),
        // custom kit's single bank-128 preset (ch9 default)
        'midi': buildMidi(flat, bpm, swing: swing, vol: vol, tracks: const {'drums'}),
      });
    }
  }

  // Drum lanes that carry their OWN kit, independent of the base ch9 'drums'
  // kit: beat-fill + every added drum track. Each renders as a separate ch9
  // job through its kit's SF2 and is summed like the other lanes, so different
  // drum tracks can use different kits in one mix. (MeltySynth only treats ch9
  // as percussion, so "per-kit" means per-render, not per-channel.)
  final perKitDrums = <String>[
    if (flat.beatDec.isNotEmpty) 'beatDec',
    for (final e in extras)
      if (trackById(e.type).kind == TrackKind.drums &&
          (flat.extraDrums[e.id]?.isNotEmpty ?? false))
        e.id,
  ];
  for (final lane in perKitDrums) {
    if (silent(lane)) continue; // no job → silent
    final r = _kitRender(instruments[lane] ?? kDefaultDrumKit);
    jobs.add({
      'sf2': await pool.of(asset: r.asset, path: r.path, fallback: gmIdx),
      // notes emit on ch9 (addDrums), so ch9's CC7 must carry THIS lane's volume.
      'midi': buildMidi(flat, bpm,
          drumProgram: r.gmKit,
          swing: swing,
          vol: {...vol, 'drums': vol[lane] ?? 0.85},
          tracks: {lane},
          extras: extras,
          extraInstruments: instruments),
    });
  }

  if (gmTracks.isNotEmpty) {
    jobs.insert(0, {
      'sf2': gmIdx,
      'midi': buildMidi(flat, bpm,
          melodyProgram: melGm,
          bassProgram: bassGm,
          melodyDecProgram: mdGm,
          drumProgram: drumGm,
          swing: swing,
          vol: vol,
          tracks: gmTracks,
          extras: extras,
          extraInstruments: {...instruments, ...gmExtra}),
    });
  }

  // A song-level take (recorded over the whole song) replaces the per-section
  // vocal schedule — one clip mixed from t=0, mirroring live playback.
  final vocal = songVocalPath != null
      ? await _songVocalJob(songVocalPath, sections, bpm, vol['vocal'] ?? 0.85)
      : await _vocalJobs(sections, bpm, vol);
  final wavs = await compute(_renderIso, {
    'sf2s': pool.paths,
    'jobs': jobs,
    'vocals': vocal.schedule,
    'vocalPaths': vocal.paths,
    'mix': true,
    'sampleRate': _sr,
    'tail': _tailSec,
  });
  final f = await _exportFile(title, 'wav', fallback: fallbackName);
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
  String fallbackName = 'loop',
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
  Future<File> stemFile(String label) =>
      _exportFile('$title - $label', 'wav', fallback: '$fallbackName - $label');

  if (present.isNotEmpty) {
    final pool = _Sf2Pool();
    final gmIdx = await pool.asset(_sfAsset);
    final jobs = <Map<String, Object>>[];
    for (final p in present) {
      final extraRef = extras.where((e) => e.id == p.id).firstOrNull;
      final isDrum = p.id == 'drums' ||
          p.id == 'beatDec' ||
          (extraRef != null && trackById(extraRef.type).kind == TrackKind.drums);
      if (isDrum) {
        // each drum stem renders through ITS kit — same resolution as the mix.
        final kit = p.id == 'drums' ? drumProgram : (instruments[p.id] ?? kDefaultDrumKit);
        final r = _kitRender(kit);
        jobs.add({
          'sf2': await pool.of(asset: r.asset, path: r.path, fallback: gmIdx),
          'midi': buildMidi(flat, bpm,
              drumProgram: r.gmKit,
              swing: swing,
              vol: p.id == 'drums' ? vol : {...vol, 'drums': vol[p.id] ?? 0.85},
              tracks: {p.id},
              extras: extras,
              extraInstruments: instruments),
        });
        continue;
      }
      // pitched: base lane programs, or the added instance's own instrument.
      final program = switch (p.id) {
        'melody' => melodyProgram,
        'bass' => bassProgram,
        'melodyDec' => melodyDecProgram,
        _ => instruments[p.id] ?? (extraRef == null ? 0 : trackById(extraRef.type).defaultProgram),
      };
      final r = _pitchedRender(program);
      jobs.add({
        'sf2': await pool.of(asset: r.asset, path: r.path, fallback: gmIdx),
        'midi': buildMidi(flat, bpm,
            melodyProgram: p.id == 'melody' ? r.program : melodyProgram,
            bassProgram: p.id == 'bass' ? r.program : bassProgram,
            melodyDecProgram: p.id == 'melodyDec' ? r.program : melodyDecProgram,
            swing: swing,
            vol: vol,
            tracks: {p.id},
            extras: extras,
            extraInstruments: {...instruments, p.id: r.program},
            strumGuitar: r.strum),
      });
    }
    final wavs = await compute(_renderIso, {
      'sf2s': pool.paths,
      'jobs': jobs,
      'mix': false,
      'sampleRate': _sr,
      'tail': _tailSec,
    });
    for (var i = 0; i < present.length; i++) {
      final f = await stemFile(present[i].label);
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
      final f = await stemFile('vocal (song)');
      await f.writeAsBytes(bytes);
      out.add(f);
    }
  } else {
    for (var i = 0; i < sections.length; i++) {
      final sec = sections[i];
      final bytes = await bounceSectionVocalWav(sec, bpm, vol);
      if (bytes == null) continue;
      final f = await stemFile('vocal ${i + 1} ${sec.name}');
      await f.writeAsBytes(bytes);
      out.add(f);
    }
  }
  return out;
}
