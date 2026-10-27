// LoopTap — Vocal clip editor (실험: 자르기/붙이기/늘리기 + 사운드 가공).
// Full-screen editor over the vocal lane. Light edits (trim/fade/gain/normalize)
// are NON-DESTRUCTIVE VocalClip params applied instantly — no file write, no
// network — and honored by export/playback via bounceVocalClips. The effect
// library runs locally in isolates; legacy EQ/reverb/comp/delay/stretch/pitch
// and autotune use the server. Only a complete rendered chain is committed.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:path_provider/path_provider.dart';

import '../../../api/engine_api.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../audio/loop_audio.dart';
import '../../audio/vocal_fx_processor.dart';
import '../../models/loop_models.dart';
import '../../music/theory.dart';
import '../../music/vocal_midi.dart';
import '../../music/vocal_fx.dart';
import '../../music/vocal_fx_catalog.dart';
import 'vocal_midi_sheet.dart';
import '../../music/wav_codec.dart';
import '../../music/vocal_comparison.dart';
import '../../state/loop_storage.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';

/// Opens the editor for [vocal]'s clips and resolves to the edited TrackData,
/// or null when cancelled. [bpm]/[bars] give the section's grid for placement.
class VocalEditorResult {
  const VocalEditorResult(this.vocal, [this.converted]);
  final TrackData vocal;
  final VocalMidiResult? converted;
}

Future<VocalEditorResult?> openVocalEditor(
  BuildContext context, {
  required TrackData vocal,
  required int bpm,
  required int bars,
  required String songId,
  required String sectionId,
  required String keyRoot,
  required String scale,
  required double swing,
  bool convertImmediately = false,
}) {
  return Navigator.of(context).push<VocalEditorResult>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder:
          (_) => VocalEditorScreen(
            vocal: vocal,
            bpm: bpm,
            bars: bars,
            songId: songId,
            sectionId: sectionId,
            keyRoot: keyRoot,
            scale: scale,
            swing: swing,
            convertImmediately: convertImmediately,
          ),
    ),
  );
}

class VocalEditorScreen extends StatefulWidget {
  const VocalEditorScreen({
    super.key,
    required this.vocal,
    required this.bpm,
    required this.bars,
    required this.songId,
    required this.sectionId,
    required this.keyRoot,
    required this.scale,
    required this.swing,
    this.convertImmediately = false,
    this.fxRenderer,
    this.autoPreview = true,
  });

  final TrackData vocal;
  final int bpm;
  final int bars;
  final String songId;
  final String sectionId;
  final String keyRoot, scale;
  final double swing;
  final bool convertImmediately;
  final VocalFxRenderer? fxRenderer;
  final bool autoPreview;

  @override
  State<VocalEditorScreen> createState() => _VocalEditorScreenState();
}

class _VocalEditorScreenState extends State<VocalEditorScreen> {
  late List<VocalClip> _clips;
  int _sel = 0;
  final Map<String, WavData> _src = {}; // resolved source PCM per clip path
  // selection over the SOURCE samples of the selected clip (fractions 0..1)
  double? _selA, _selB;
  bool _busy = false;
  String _status = '';
  double _fxAmount = .7;
  late bool _autoPreview = widget.autoPreview;
  bool _previewDry = false, _previewPlaying = false, _previewLoading = false;
  bool _previewLoop = true, _matchLevel = true;
  StreamSubscription<bool>? _playbackSubscription;
  int _previewGeneration = 0;
  final Set<File> _previewFiles = {};

  VocalFxRenderer get _fxRenderer =>
      widget.fxRenderer ?? vocalFxRenderer(widget.songId, widget.sectionId);

  final _audio = LoopAudio.instance;

  VocalClip get _clip => _clips[_sel];
  WavData? get _curSrc => _src[_clip.path];

  @override
  void initState() {
    super.initState();
    _playbackSubscription = _audio.vocalPlaying.listen((playing) {
      if (mounted && _previewPlaying != playing) {
        setState(() => _previewPlaying = playing);
      }
    });
    final src = widget.vocal.effectiveClips;
    _clips = src.isEmpty ? [] : [for (final c in src) c.copy()];
    if (_clips.isNotEmpty) _loadSrc(_clip.path);
    if (widget.convertImmediately && _clips.length == 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_convertToMidi());
      });
    }
  }

  @override
  void dispose() {
    _previewGeneration++;
    unawaited(_playbackSubscription?.cancel());
    unawaited(_disposePreview());
    super.dispose();
  }

  Future<void> _disposePreview() async {
    await _audio.stopVocal();
    for (final file in _previewFiles) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best-effort cleanup of this editor's own previews.
      }
    }
  }

  Future<void> _loadSrc(String path) async {
    if (_src.containsKey(path)) return;
    try {
      final bytes = await File(LoopStorage.resolveVocal(path)).readAsBytes();
      final wav = parseWav(bytes);
      if (wav != null && mounted) {
        setState(() {
          _src[path] = wav;
          for (final c in _clips) {
            if (c.path == path) {
              _measureDur(c);
              _refreshPeaks(c);
            }
          }
        });
      }
    } catch (e) {
      debugPrint('[vocal_editor] load failed ($path): $e');
    }
  }

  // Measure a clip's on-grid length (steps) from its trimmed audio + the section
  // bpm, so the arrangement strip can size its chunk. No-op until the source is
  // loaded.
  void _measureDur(VocalClip c) {
    final src = _src[c.path];
    if (src == null) return;
    final end = c.trimEnd == -1 ? src.samples.length : c.trimEnd;
    final n = end - c.trimStart;
    if (n <= 0) return;
    final secPerStep = 60 / widget.bpm / kStepsPerBeat;
    final steps = (n / src.sampleRate / secPerStep).round();
    c.durSteps = steps.clamp(1, stepsForBars(widget.bars));
  }

  // Recompute a clip's display peaks from its TRIMMED region so the arrangement
  // chunk (and the vocal surface) show only what actually plays. The editor's
  // own waveform still renders the full source (with a dim trim overlay) so the
  // user can re-trim.
  void _refreshPeaks(VocalClip c) {
    final src = _src[c.path];
    if (src == null) return;
    final a = c.trimStart.clamp(0, src.samples.length);
    final b = (c.trimEnd == -1 ? src.samples.length : c.trimEnd).clamp(
      a,
      src.samples.length,
    );
    if (b - a < 1) return;
    c.peaks = peaksFromPcm(trimPcm(src.samples, a, b), buckets: 64);
  }

  // ── non-destructive light edits (instant) ────────────────────────────────
  void _trimToSelection() {
    final src = _curSrc;
    if (src == null || _selA == null || _selB == null) return;
    final n = src.samples.length;
    // normalize so a right-to-left drag trims the same as left-to-right
    final lo = (math.min(_selA!, _selB!).clamp(0.0, 1.0) * n).round();
    final hi = (math.max(_selA!, _selB!).clamp(0.0, 1.0) * n).round();
    if (hi - lo < 64) return; // ignore a too-tiny selection
    setState(() {
      _clip.trimStart = lo;
      _clip.trimEnd = hi;
      _measureDur(_clip);
      _refreshPeaks(_clip);
      _selA = _selB = null;
    });
  }

  // Fade steps span up to 3 s so a fade can be subtle or very dramatic.
  static const _fadeSteps = [0, 150, 400, 800, 1500, 3000];
  void _bumpFade({required bool fadeIn}) {
    int next(int cur) {
      final i = _fadeSteps.indexWhere((v) => v > cur);
      return i == -1 ? 0 : _fadeSteps[i];
    }

    setState(() {
      if (fadeIn) {
        _clip.fadeInMs = next(_clip.fadeInMs);
      } else {
        _clip.fadeOutMs = next(_clip.fadeOutMs);
      }
    });
  }

  void _bumpGain(double db) {
    setState(() {
      final cur = _clip.gain <= 0 ? 0.0001 : _clip.gain;
      // work in dB so steps feel even; clamp to [-24 dB, +12 dB]
      var newDb = (20 * (_log10(cur))) + db;
      newDb = newDb.clamp(-24.0, 12.0);
      _clip.gain = _pow10(newDb / 20);
    });
  }

  void _normalize() {
    final src = _curSrc;
    if (src == null) return;
    final s = src.samples;
    final a = _clip.trimStart;
    final b = _clip.trimEnd == -1 ? s.length : _clip.trimEnd;
    var peak = 0.0;
    for (var i = a; i < b && i < s.length; i++) {
      final v = s[i].abs();
      if (v > peak) peak = v;
    }
    if (peak <= 1e-6) return;
    setState(() => _clip.gain = (0.99 / peak).clamp(0.1, 8.0));
  }

  void _resetEdits() {
    setState(() {
      _clip.trimStart = 0;
      _clip.trimEnd = -1;
      _clip.fadeInMs = 0;
      _clip.fadeOutMs = 0;
      _clip.gain = 1.0;
      _measureDur(_clip);
      _refreshPeaks(_clip);
      _selA = _selB = null;
    });
  }

  /// Display name for an FX node type (the codes are persisted in the clip's
  /// history, so they stay English on disk and are localized only here).
  String _fxName(L10n l, String type) {
    for (final effect in localVocalEffects) {
      if (effect.type == type) {
        return effect.label(l.localeName.startsWith('ko'));
      }
    }
    return switch (type) {
      'eq' => l.ltFxEq,
      'reverb' => l.ltFxReverb,
      'comp' => l.ltFxComp,
      'delay' => l.ltFxDelay,
      'stretch' => l.ltFxStretch,
      'pitch' => l.ltFxPitch,
      'autotune' => l.ltEditorAutotuneTitle,
      _ => type,
    };
  }

  Future<void> _applyPreset(VocalEffectPreset preset) => _changeFx(
    vocalPresetChain(_clip, preset),
    status: preset.label(L10n.of(context).localeName.startsWith('ko')),
  );

  // ── transactional FX chain changes ──────────────────────────────────────
  Future<void> _applyFx(String fxType, Map<String, dynamic> params) async {
    await _changeFx([
      ..._clip.fx,
      FxNode(type: fxType, params: params),
    ], status: _fxName(L10n.of(context), fxType));
  }

  Future<void> _changeFx(List<FxNode> chain, {required String status}) async {
    await _renderFxEdit(
      (clip) =>
          _fxRenderer.render(clip, chain, bpm: widget.bpm, bars: widget.bars),
      status,
    );
  }

  Future<void> _restoreOriginal() => _renderFxEdit(
    (clip) =>
        _fxRenderer.restoreOriginal(clip, bpm: widget.bpm, bars: widget.bars),
    L10n.of(context).ltVocalEditorRestoreOriginal,
  );

  Future<void> _renderFxEdit(
    Future<VocalClip> Function(VocalClip) render,
    String status,
  ) async {
    if (_busy) return;
    final target = _clip;
    final index = _sel;
    final wasPlaying = _previewPlaying;
    Duration? resumeAt;
    var applied = false;
    final previewGeneration = ++_previewGeneration;
    setState(() {
      _busy = true;
      _previewLoading = false;
      _previewPlaying = false;
      _status = L10n.of(context).ltVocalEditorFxProcessing(status);
    });
    try {
      if (wasPlaying) resumeAt = await _audio.vocalPosition();
      await _audio.stopVocal();
      final result = await render(target.copy());
      if (!mounted ||
          index >= _clips.length ||
          !identical(_clips[index], target)) {
        return;
      }
      setState(() {
        _clips[index] = result;
        _selA = _selB = null;
      });
      await _loadSrc(result.path);
      applied = true;
    } catch (e) {
      if (mounted) {
        _toast(
          e is VocalFxSourceMissing
              ? L10n.of(context).ltVocalEditorFxSourceMissing
              : e is EngineApiException
              ? e.message
              : L10n.of(context).ltVocalEditorProcessFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
    if (applied &&
        mounted &&
        previewGeneration == _previewGeneration &&
        (_autoPreview || wasPlaying)) {
      await _preview(startAt: wasPlaying ? resumeAt : Duration.zero);
    }
  }

  Future<void> _removeFx(int i) async {
    if (_busy) return;
    final chain = _clip.fx.map((f) => f.copy()).toList()..removeAt(i);
    await _changeFx(chain, status: _fxName(L10n.of(context), _clip.fx[i].type));
  }

  // ── multi-take lane ───────────────────────────────────────────────────────
  void _deleteClip(int i) {
    if (_busy) return;
    if (_clips.length <= 1) return;
    setState(() {
      _clips.removeAt(i);
      _sel = _sel.clamp(0, _clips.length - 1);
    });
  }

  void _nudgeStart(int deltaSteps) {
    if (_busy) return;
    final maxStep = stepsForBars(widget.bars) - 1;
    setState(
      () => _clip.startStep = (_clip.startStep + deltaSteps).clamp(0, maxStep),
    );
  }

  // ── preview (full multi-clip bounce → temp WAV → play) ────────────────────
  Future<void> _preview({bool dryOriginal = false, Duration? startAt}) async {
    if (_busy) return;
    final generation = ++_previewGeneration;
    final clips = [for (final c in _clips) c.copy()];
    setState(() => _previewLoading = true);
    try {
      final sources = <String, WavData>{};
      for (final c in clips) {
        for (final path in {c.path, c.origPath ?? c.fxSourcePath ?? c.path}) {
          final source =
              _src[path] ??
              parseWav(
                await File(LoopStorage.resolveVocal(path)).readAsBytes(),
              );
          if (source == null || source.samples.isEmpty) {
            throw const FormatException('Invalid comparison audio');
          }
          sources[path] = source;
          _src[path] = source;
        }
        if (!mounted || generation != _previewGeneration) return;
      }
      final comparison = vocalComparison(
        clips,
        sources,
        bars: widget.bars,
        bpm: widget.bpm,
        matchLevel: _matchLevel,
      );
      final pcm = dryOriginal ? comparison.original : comparison.processed;
      if (pcm.isEmpty) throw const FormatException('Empty preview');
      final bytes = encodeWavMono16(pcm, 44100);
      final dir = await getTemporaryDirectory();
      if (!mounted || generation != _previewGeneration) return;
      final f = File(
        '${dir.path}/lt_preview_${identityHashCode(this)}_$generation.wav',
      );
      _previewFiles.add(f);
      await f.writeAsBytes(bytes, flush: true);
      if (!mounted || generation != _previewGeneration) return;
      final position =
          startAt ??
          (_previewPlaying ? await _audio.vocalPosition() : null) ??
          Duration.zero;
      if (!mounted || generation != _previewGeneration) return;
      final lengthMs = (pcm.length / 44.1).floor();
      final seek = Duration(
        milliseconds: position.inMilliseconds % lengthMs.clamp(1, 1 << 31),
      );
      await _audio.stopVocal();
      if (!mounted || generation != _previewGeneration) return;
      final played = await _audio.playVocalChecked(
        f.path,
        vol: 1,
        loop: _previewLoop,
        position: seek,
      );
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _previewDry = dryOriginal;
        _previewPlaying = played;
      });
      if (!played) _toast(L10n.of(context).ltVocalPreviewFailed);
    } catch (e) {
      debugPrint('[vocal_preview] $e');
      if (mounted && generation == _previewGeneration) {
        setState(() => _previewPlaying = false);
        _toast(L10n.of(context).ltVocalPreviewFailed);
      }
    } finally {
      if (mounted && generation == _previewGeneration) {
        setState(() => _previewLoading = false);
      }
    }
  }

  void _stopPreview() {
    _previewGeneration++;
    setState(() {
      _previewPlaying = false;
      _previewLoading = false;
    });
    _audio.stopVocal();
  }

  bool _presetSelected(VocalEffectPreset preset) {
    final effects = _clip.fx.where((f) => f.type != 'autotune').toList();
    final target = preset.nodes();
    if (effects.length != target.length) return false;
    for (var i = 0; i < effects.length; i++) {
      if (!effects[i].enabled ||
          effects[i].type != target[i].type ||
          !mapEquals(effects[i].params, target[i].params)) {
        return false;
      }
    }
    return true;
  }

  Future<void> _convertToMidi() async {
    if (_busy || _clips.isEmpty) return;
    _audio.stopVocal();
    final result = await showVocalMidiSheet(
      context,
      clip: _clip,
      bpm: widget.bpm,
      bars: widget.bars,
      keyRoot: widget.keyRoot,
      scale: widget.scale,
      swing: widget.swing,
    );
    if (mounted && result != null) _done(result);
  }

  // ── save / cancel ─────────────────────────────────────────────────────────
  void _done([VocalMidiResult? converted]) {
    if (_busy) return;
    final out = TrackData(clips: _clips);
    // mirror first clip to legacy fields so the surface waveform shows
    if (_clips.isNotEmpty) {
      out.vocalPath = _clips.first.path;
      out.clip =
          _clips.first.peaks.isNotEmpty
              ? _clips.first.peaks
              : widget.vocal.clip;
      out.vocalOrigPath = _clips.first.origPath;
    }
    out.vocalAligned = widget.vocal.vocalAligned;
    out.vocalBpm = widget.vocal.vocalBpm;
    out.vocalBars = widget.vocal.vocalBars;
    Navigator.of(context).pop(VocalEditorResult(out, converted));
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(m), duration: const Duration(milliseconds: 1600)),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LT.bg,
      body: SafeArea(
        child:
            _clips.isEmpty
                ? Center(
                  child: Text(
                    L10n.of(context).ltVocalEditorNoTake,
                    style: const TextStyle(color: LT.t2),
                  ),
                )
                : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _header(),
                      const SizedBox(height: 10),
                      _clipLane(), // pinned up top to free vertical space
                      const SizedBox(height: 10),
                      // Middle scrolls so the controls never overflow on short
                      // screens; header + takes + transport stay pinned.
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(height: 132, child: _waveCard()),
                              const SizedBox(height: 14),
                              FilledButton.icon(
                                onPressed: _busy ? null : _convertToMidi,
                                icon: const Icon(Icons.piano),
                                label: Text(L10n.of(context).ltMidiTitle),
                              ),
                              Text(L10n.of(context).ltMidiSelectedClip),
                              const SizedBox(height: 10),
                              _editGroup(),
                              const SizedBox(height: 10),
                              _effectsGroup(),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _transport(),
                    ],
                  ),
                ),
      ),
    );
  }

  // ── reusable bits ─────────────────────────────────────────────────────────
  Widget _group(String title, Widget child, {Widget? trailing}) => Container(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
    decoration: BoxDecoration(
      color: LT.surface,
      borderRadius: BorderRadius.circular(LTRadius.card),
      border: Border.all(color: LT.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            LtLabel(title),
            const Spacer(),
            if (trailing != null) trailing,
          ],
        ),
        const SizedBox(height: 9),
        child,
      ],
    ),
  );

  Widget _header() {
    final l = L10n.of(context);
    return Row(
      children: [
        IconBtn(
          icon: LtIcons.close,
          tooltip: l.cancel,
          onTap: () => Navigator.of(context).pop(),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.ltVocalEditorTitle,
              style: LTType.inter(
                size: 17,
                weight: FontWeight.w800,
                color: LT.t1,
              ),
            ),
            Text(
              l.ltVocalEditorMeta(_clips.length, widget.bpm, widget.bars),
              style: LTType.mono(
                size: 11,
                weight: FontWeight.w600,
                color: LT.t3,
              ),
            ),
          ],
        ),
        const Spacer(),
        if (_status.isNotEmpty) ...[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: LT.pink),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              _status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: LTType.mono(
                size: 12,
                weight: FontWeight.w600,
                color: LT.pink,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Pill(
          label: l.done,
          icon: LtIcons.checkCircle,
          tone: PillTone.lime,
          height: 40,
          onTap: _busy ? null : _done,
        ),
      ],
    );
  }

  Widget _clipLane() {
    final l = L10n.of(context);
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _clips.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final sel = i == _sel;
          final c = _clips[i];
          return GestureDetector(
            onTap:
                _busy
                    ? null
                    : () {
                      setState(() {
                        _sel = i;
                        _selA = _selB = null;
                      });
                      _loadSrc(c.path);
                    },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sel ? LT.pink : LT.surface2,
                borderRadius: BorderRadius.circular(LTRadius.pill),
                border: Border.all(color: sel ? Colors.transparent : LT.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Ms(LtIcons.mic, size: 13, color: sel ? LT.bg : LT.t2),
                  const SizedBox(width: 6),
                  Text(
                    l.ltVocalEditorTake(i + 1),
                    style: LTType.inter(
                      size: 12,
                      weight: FontWeight.w700,
                      color: sel ? LT.bg : LT.t1,
                    ),
                  ),
                  if (c.fx.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: (sel ? LT.bg : LT.pink).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        l.ltVocalEditorFxCount(c.fx.length),
                        style: LTType.mono(
                          size: 9,
                          weight: FontWeight.w700,
                          color: sel ? LT.bg : LT.pink,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _waveCard() {
    final src = _curSrc;
    final n = src?.samples.length ?? 1;
    return LayoutBuilder(
      builder: (context, c) {
        return GestureDetector(
          onHorizontalDragStart:
              _busy
                  ? null
                  : (d) => setState(() {
                    _selA = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
                    _selB = _selA;
                  }),
          onHorizontalDragUpdate:
              _busy
                  ? null
                  : (d) => setState(
                    () =>
                        _selB = (d.localPosition.dx / c.maxWidth).clamp(
                          0.0,
                          1.0,
                        ),
                  ),
          onTap: _busy ? null : () => setState(() => _selA = _selB = null),
          child: Container(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF181012), Color(0xFF120E10)],
              ),
              borderRadius: BorderRadius.circular(LTRadius.card),
              border: Border.all(color: LT.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _WavePainter(
                      // full source so the trim window stays adjustable; falls back
                      // to the stored (trimmed) peaks until the source loads.
                      peaks:
                          src != null
                              ? peaksFromPcm(src.samples, buckets: 220)
                              : _clip.peaks,
                      trimStart: n == 0 ? 0 : _clip.trimStart / n,
                      trimEnd:
                          _clip.trimEnd == -1
                              ? 1.0
                              : (n == 0 ? 1.0 : _clip.trimEnd / n),
                      selA: _selA,
                      selB: _selB,
                      fadeIn: _clip.fadeInMs,
                      fadeOut: _clip.fadeOutMs,
                    ),
                  ),
                ),
                // caption row: hint + live edit readout
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 8,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          (_selA != null && _selB != null)
                              ? L10n.of(context).ltVocalEditorDragSet
                              : L10n.of(context).ltVocalEditorDragHint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: LTType.mono(
                            size: 10,
                            weight: FontWeight.w600,
                            color: LT.t3,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(child: _readout()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _readout() {
    final l = L10n.of(context);
    final parts = <String>[];
    if (_clip.trimEnd != -1 || _clip.trimStart != 0) {
      parts.add(l.ltVocalEditorTrimmed);
    }
    if (_clip.fadeInMs != 0) {
      parts.add(l.ltVocalEditorFadeInReadout(_clip.fadeInMs));
    }
    if (_clip.fadeOutMs != 0) {
      parts.add(l.ltVocalEditorFadeOutReadout(_clip.fadeOutMs));
    }
    if (_clip.gain != 1.0) parts.add('${_gainDb()}dB');
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: LTType.mono(size: 10, weight: FontWeight.w700, color: LT.pink),
    );
  }

  Widget _editGroup() {
    final l = L10n.of(context);
    return _group(
      l.ltVocalEditorEditGroup,
      Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _tool(
            l.ltVocalEditorTrim,
            LtIcons.straighten,
            (_selA != null && _selB != null) ? _trimToSelection : null,
          ),
          _tool(
            l.ltVocalEditorFadeIn(_clip.fadeInMs),
            LtIcons.chevronRight,
            () => _bumpFade(fadeIn: true),
          ),
          _tool(
            l.ltVocalEditorFadeOut(_clip.fadeOutMs),
            LtIcons.chevronLeft,
            () => _bumpFade(fadeIn: false),
          ),
          _tool(l.ltVocalEditorGainDown, LtIcons.remove, () => _bumpGain(-1)),
          _tool('${_gainDb()} dB', LtIcons.volumeUp, null),
          _tool(l.ltVocalEditorGainUp, LtIcons.add, () => _bumpGain(1)),
          _tool(
            l.ltVocalEditorNormalize,
            LtIcons.tune,
            _curSrc == null ? null : _normalize,
          ),
        ],
      ),
      trailing: GestureDetector(
        onTap: _busy ? null : _resetEdits,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Ms(LtIcons.undo, size: 13, color: LT.t3),
            const SizedBox(width: 4),
            Text(
              l.ltVocalEditorReset,
              style: LTType.mono(
                size: 10,
                weight: FontWeight.w700,
                color: LT.t3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _effectsGroup() {
    final l = L10n.of(context);
    final korean = l.localeName.startsWith('ko');
    return _group(
      l.ltVocalEditorEffectsGroup,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_clip.fx.isNotEmpty) ...[_fxChain(), const SizedBox(height: 10)],
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (_clip.fx.isNotEmpty)
                _tool(
                  l.ltVocalEditorClearFx,
                  LtIcons.close,
                  () => _changeFx([], status: l.ltVocalEditorClearFx),
                ),
              _tool(
                l.ltVocalEditorRestoreOriginal,
                LtIcons.restore,
                _restoreOriginal,
              ),
            ],
          ),
          const SizedBox(height: 16),
          LtLabel(l.ltVocalFxPresets),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in vocalEffectPresets)
                Pill(
                  key: ValueKey('vocal-preset-${preset.id}'),
                  label: preset.label(korean),
                  icon: LtIcons.graphicEq,
                  height: 36,
                  tone:
                      _presetSelected(preset)
                          ? PillTone.lime
                          : PillTone.surface,
                  onTap: _busy ? null : () => _applyPreset(preset),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l.ltVocalFxPresetHint,
            style: LTType.inter(size: 11, color: LT.t3),
          ),
          const SizedBox(height: 16),
          LtLabel(l.ltVocalFxLocal),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final effect in localVocalEffects)
                _tool(
                  effect.label(korean),
                  LtIcons.graphicEq,
                  () => _applyFx(effect.type, {
                    ...effect.params,
                    'mix': _fxAmount,
                  }),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                l.ltVocalFxAmount,
                style: LTType.inter(size: 11, color: LT.t2),
              ),
              Expanded(
                child: Slider(
                  key: const ValueKey('vocal-fx-amount'),
                  value: _fxAmount,
                  min: .1,
                  max: 1,
                  divisions: 9,
                  label: '${(_fxAmount * 100).round()}%',
                  onChanged:
                      _busy ? null : (v) => setState(() => _fxAmount = v),
                ),
              ),
              Text(
                '${(_fxAmount * 100).round()}%',
                style: LTType.mono(size: 11),
              ),
            ],
          ),
          Text(
            l.ltVocalFxAmountHint,
            style: LTType.inter(size: 11, color: LT.t3),
          ),
          const SizedBox(height: 8),
          Material(
            color: Colors.transparent,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                l.ltVocalFxServer,
                style: LTType.inter(size: 12, color: LT.t2),
              ),
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _fxBtn(l.ltFxEq, 'eq', {
                      'low': 3.0,
                      'mid': 0.0,
                      'high': 4.0,
                    }),
                    _fxBtn(l.ltFxReverb, 'reverb', {'wet': 0.3, 'decay': 1.4}),
                    _fxBtn(l.ltFxComp, 'comp', {
                      'threshold': -18.0,
                      'ratio': 3.0,
                    }),
                    _fxBtn(l.ltFxDelay, 'delay', {
                      'time': 300.0,
                      'feedback': 0.35,
                      'wet': 0.3,
                    }),
                    _fxBtn(l.ltFxSlower, 'stretch', {'ratio': 1.2}),
                    _fxBtn(l.ltFxFaster, 'stretch', {'ratio': 0.85}),
                    _fxBtn(l.ltFxPitchUp, 'pitch', {'semitones': 2.0}),
                    _fxBtn(l.ltFxPitchDown, 'pitch', {'semitones': -2.0}),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fxChain() {
    final l = L10n.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < _clip.fx.length; i++)
          GestureDetector(
            onTap: _busy ? null : () => _removeFx(i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: LT.pink.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(LTRadius.pill),
                border: Border.all(color: LT.pink.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l.ltVocalEditorFxChainItem(
                      i + 1,
                      _fxName(l, _clip.fx[i].type),
                    ),
                    style: LTType.mono(
                      size: 11,
                      weight: FontWeight.w700,
                      color: LT.t1,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Ms(LtIcons.close, size: 13, color: LT.pink),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _tool(String label, IconData icon, VoidCallback? onTap) => Opacity(
    opacity: _busy || onTap == null ? 0.4 : 1,
    child: Pill(
      label: label,
      icon: icon,
      tone: PillTone.surface,
      height: 36,
      onTap: _busy ? null : onTap,
    ),
  );

  Widget _fxBtn(String label, String fx, Map<String, dynamic> params) =>
      Opacity(
        opacity: _busy ? 0.4 : 1,
        child: Pill(
          label: label,
          icon: LtIcons.graphicEq,
          iconColor: LT.pink,
          tone: PillTone.surface,
          height: 36,
          onTap: _busy ? null : () => _applyFx(fx, params),
        ),
      );

  Widget _transport() {
    final l = L10n.of(context);
    final count = _clips.fold<int>(
      0,
      (n, c) => n + c.fx.where((f) => f.enabled).length,
    );
    final status =
        _previewLoading
            ? l.ltVocalPreviewLoading
            : _previewPlaying
            ? (_previewDry
                ? l.ltVocalPreviewOriginalPlaying
                : l.ltVocalPreviewProcessedPlaying)
            : l.ltVocalPreviewStopped;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: LT.surface,
        borderRadius: BorderRadius.circular(LTRadius.card),
        border: Border.all(color: LT.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  status,
                  key: const ValueKey('vocal-preview-status'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: LTType.inter(
                    size: 12,
                    color: _previewPlaying ? LT.lime : LT.t2,
                  ),
                ),
              ),
              Text(
                count == 0
                    ? l.ltVocalPreviewNoEffects
                    : '${l.ltVocalPreviewEffects}: $count',
                style: LTType.inter(size: 11, color: LT.t2),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Pill(
                key: const ValueKey('vocal-preview-original'),
                label: l.ltVocalPreviewOriginal,
                icon: LtIcons.playArrow,
                height: 40,
                tone: _previewDry ? PillTone.lime : PillTone.surface,
                onTap: _busy ? null : () => _preview(dryOriginal: true),
              ),
              Pill(
                key: const ValueKey('vocal-preview-processed'),
                label: l.ltVocalPreviewProcessed,
                icon: LtIcons.playArrow,
                height: 40,
                tone: !_previewDry ? PillTone.lime : PillTone.surface,
                onTap: _busy ? null : () => _preview(),
              ),
              IconBtn(
                icon: LtIcons.stop,
                tooltip: l.pendingStop,
                size: 40,
                onTap: _stopPreview,
              ),
              Pill(
                key: const ValueKey('vocal-preview-loop'),
                label: l.ltVocalPreviewLoop,
                icon: LtIcons.restore,
                height: 36,
                tone: _previewLoop ? PillTone.lime : PillTone.surface,
                onTap:
                    _busy
                        ? null
                        : () {
                          setState(() => _previewLoop = !_previewLoop);
                          if (_previewPlaying) {
                            unawaited(_preview(dryOriginal: _previewDry));
                          }
                        },
              ),
              Pill(
                key: const ValueKey('vocal-preview-level'),
                label: l.ltVocalPreviewLevel,
                height: 36,
                tone: _matchLevel ? PillTone.lime : PillTone.surface,
                onTap:
                    _busy
                        ? null
                        : () {
                          setState(() => _matchLevel = !_matchLevel);
                          if (_previewPlaying) {
                            unawaited(_preview(dryOriginal: _previewDry));
                          }
                        },
              ),
              Pill(
                key: const ValueKey('vocal-preview-auto'),
                label: l.ltVocalPreviewAuto,
                height: 36,
                tone: _autoPreview ? PillTone.lime : PillTone.surface,
                onTap:
                    _busy
                        ? null
                        : () => setState(() => _autoPreview = !_autoPreview),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconBtn(
                    icon: LtIcons.chevronLeft,
                    tooltip: l.ltVocalEditorEarlier,
                    size: 36,
                    onTap: () => _nudgeStart(-1),
                  ),
                  Text(
                    l.ltVocalEditorStep(_clip.startStep),
                    style: LTType.mono(size: 11),
                  ),
                  IconBtn(
                    icon: LtIcons.chevronRight,
                    tooltip: l.ltVocalEditorLater,
                    size: 36,
                    onTap: () => _nudgeStart(1),
                  ),
                ],
              ),
              if (_clips.length > 1)
                IconBtn(
                  icon: LtIcons.delete,
                  tooltip: l.ltVocalEditorDeleteTake,
                  size: 40,
                  color: LT.danger,
                  onTap: () => _deleteClip(_sel),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _gainDb() {
    final db = 20 * _log10(_clip.gain <= 0 ? 0.0001 : _clip.gain);
    return db.toStringAsFixed(1);
  }
}

double _log10(double x) => math.log(x <= 0 ? 1e-9 : x) / math.ln10;
double _pow10(double x) => math.pow(10, x).toDouble();

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.peaks,
    required this.trimStart,
    required this.trimEnd,
    required this.selA,
    required this.selB,
    required this.fadeIn,
    required this.fadeOut,
  });

  final List<double> peaks;
  final double trimStart, trimEnd; // fractions
  final double? selA, selB;
  final int fadeIn, fadeOut;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final w = size.width;

    // faint center baseline
    canvas.drawLine(
      Offset(0, mid),
      Offset(w, mid),
      Paint()..color = LT.t1.withValues(alpha: 0.06),
    );

    // dim outside the trim window
    final dim = Paint()..color = Colors.black.withValues(alpha: 0.45);
    canvas.drawRect(Rect.fromLTRB(0, 0, trimStart * w, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(trimEnd * w, 0, w, size.height), dim);

    if (peaks.isNotEmpty) {
      final bw = w / peaks.length;
      final radius = Radius.circular((bw * 0.4).clamp(0.5, 2.0));
      for (var i = 0; i < peaks.length; i++) {
        final frac = (i + 0.5) / peaks.length;
        final inTrim = frac >= trimStart && frac <= trimEnd;
        final h = (peaks[i].clamp(0.0, 1.0)) * (size.height * 0.44);
        final bar =
            Paint()..color = inTrim ? LT.pink : LT.t3.withValues(alpha: 0.5);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(i * bw + bw * 0.1, mid - h, bw * 0.8, h * 2),
            radius,
          ),
          bar,
        );
      }
    }

    // fade ramps drawn as guide lines from the trim edges
    final fadePaint =
        Paint()
          ..color = LT.lime.withValues(alpha: 0.85)
          ..strokeWidth = 1.5;
    if (fadeIn > 0) {
      final x0 = trimStart * w;
      final x1 = x0 + (fadeIn / 3000).clamp(0.0, 0.4) * w;
      canvas.drawLine(Offset(x0, size.height - 6), Offset(x1, 6), fadePaint);
    }
    if (fadeOut > 0) {
      final x1 = trimEnd * w;
      final x0 = x1 - (fadeOut / 3000).clamp(0.0, 0.4) * w;
      canvas.drawLine(Offset(x0, 6), Offset(x1, size.height - 6), fadePaint);
    }

    // selection overlay
    if (selA != null && selB != null) {
      final a = (selA! < selB! ? selA! : selB!) * w;
      final b = (selA! < selB! ? selB! : selA!) * w;
      canvas.drawRect(
        Rect.fromLTRB(a, 0, b, size.height),
        Paint()..color = LT.lime.withValues(alpha: 0.18),
      );
      final edge =
          Paint()
            ..color = LT.lime
            ..strokeWidth = 2;
      canvas.drawLine(Offset(a, 0), Offset(a, size.height), edge);
      canvas.drawLine(Offset(b, 0), Offset(b, size.height), edge);
      // grab handles
      final knob = Paint()..color = LT.lime;
      canvas.drawCircle(Offset(a, mid), 4, knob);
      canvas.drawCircle(Offset(b, mid), 4, knob);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.peaks != peaks ||
      old.trimStart != trimStart ||
      old.trimEnd != trimEnd ||
      old.selA != selA ||
      old.selB != selB ||
      old.fadeIn != fadeIn ||
      old.fadeOut != fadeOut;
}
