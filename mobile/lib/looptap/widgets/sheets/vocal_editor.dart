// LoopTap — Vocal clip editor (실험: 자르기/붙이기/늘리기 + 사운드 가공).
// Full-screen editor over the vocal lane. Light edits (trim/fade/gain/normalize)
// are NON-DESTRUCTIVE VocalClip params applied instantly — no file write, no
// network — and honored by export/playback via bounceVocalClips. Heavier DSP
// (EQ/reverb/comp/delay/stretch/pitch) round-trips the backend /process_fx,
// which bakes a new WAV and records an FxNode in the clip's history.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../../../api/engine_api.dart';
import '../../audio/loop_audio.dart';
import '../../models/loop_models.dart';
import '../../music/theory.dart';
import '../../music/wav_codec.dart';
import '../../music/wav_export.dart';
import '../../state/loop_storage.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';

/// Opens the editor for [vocal]'s clips and resolves to the edited TrackData,
/// or null when cancelled. [bpm]/[bars] give the section's grid for placement.
Future<TrackData?> openVocalEditor(
  BuildContext context, {
  required TrackData vocal,
  required int bpm,
  required int bars,
  required String songId,
  required String sectionId,
}) {
  return Navigator.of(context).push<TrackData>(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => VocalEditorScreen(
      vocal: vocal,
      bpm: bpm,
      bars: bars,
      songId: songId,
      sectionId: sectionId,
    ),
  ));
}

class VocalEditorScreen extends StatefulWidget {
  const VocalEditorScreen({
    super.key,
    required this.vocal,
    required this.bpm,
    required this.bars,
    required this.songId,
    required this.sectionId,
  });

  final TrackData vocal;
  final int bpm;
  final int bars;
  final String songId;
  final String sectionId;

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

  final _audio = LoopAudio.instance;

  VocalClip get _clip => _clips[_sel];
  WavData? get _curSrc => _src[_clip.path];

  @override
  void initState() {
    super.initState();
    final src = widget.vocal.effectiveClips;
    _clips = src.isEmpty ? [] : [for (final c in src) c.copy()];
    if (_clips.isNotEmpty) _loadSrc(_clip.path);
  }

  @override
  void dispose() {
    _audio.stopVocal();
    super.dispose();
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
    final b = (c.trimEnd == -1 ? src.samples.length : c.trimEnd).clamp(a, src.samples.length);
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

  // ── server FX (bakes a new WAV + records an FxNode) ───────────────────────
  Future<void> _applyFx(String fxType, Map<String, dynamic> params) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '$fxType…';
    });
    try {
      final res = await EngineApi().processFx(
        LoopStorage.resolveVocal(_clip.path),
        fxType: fxType,
        params: params,
      );
      final persisted = await LoopStorage.saveVocalBytes(
        res.wav,
        widget.songId,
        widget.sectionId,
        suffix: '_$fxType',
      );
      if (persisted == null) throw Exception('save failed');
      if (!mounted) return;
      setState(() {
        _clip.origPath ??= _clip.path; // first edit keeps the dry take
        _clip.path = persisted;
        _clip.peaks = res.peaks.isNotEmpty ? res.peaks : _clip.peaks;
        _clip.fx.add(FxNode(type: fxType, params: params));
        // the server returned the whole processed take — the old trim window
        // referenced the previous file's samples, so reset it to the new audio.
        _clip.trimStart = 0;
        _clip.trimEnd = -1;
        _src.remove(persisted);
      });
      await _loadSrc(persisted); // re-measures durSteps for the new file
    } catch (e) {
      if (mounted) _toast(e is EngineApiException ? e.message : 'Sound processing failed');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '';
        });
      }
    }
  }

  void _removeFx(int i) {
    // History only — re-rendering the chain from origPath is a follow-up. For
    // now removing a node restores the dry take and clears the chain so the
    // user can re-apply cleanly.
    final orig = _clip.origPath;
    setState(() {
      _clip.fx.removeAt(i);
      if (_clip.fx.isEmpty && orig != null) {
        _clip.path = orig;
        _clip.origPath = null;
        _loadSrc(orig);
      }
    });
  }

  // ── multi-take lane ───────────────────────────────────────────────────────
  void _deleteClip(int i) {
    if (_clips.length <= 1) return;
    setState(() {
      _clips.removeAt(i);
      _sel = _sel.clamp(0, _clips.length - 1);
    });
  }

  void _nudgeStart(int deltaSteps) {
    final maxStep = stepsForBars(widget.bars) - 1;
    setState(() => _clip.startStep = (_clip.startStep + deltaSteps).clamp(0, maxStep));
  }

  // ── preview (full multi-clip bounce → temp WAV → play) ────────────────────
  Future<void> _preview({bool dryOriginal = false}) async {
    final clips = dryOriginal
        ? [for (final c in _clips) (c.copy()..origPathToDry())]
        : _clips;
    // ensure all sources are loaded
    final sources = <String, ({Float32List pcm, int sampleRate})>{};
    for (final c in clips) {
      await _loadSrc(c.path);
      final s = _src[c.path];
      if (s != null) sources[c.path] = (pcm: s.samples, sampleRate: s.sampleRate);
    }
    if (sources.isEmpty) return;
    final lane = bounceVocalClips(clips, widget.bars, widget.bpm, sources);
    if (lane.isEmpty) return;
    final bytes = encodeWavMono16(lane, 44100);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/lt_preview.wav');
    await f.writeAsBytes(bytes);
    await _audio.stopVocal();
    await _audio.playVocal(f.path, vol: 1.0);
  }

  // ── save / cancel ─────────────────────────────────────────────────────────
  void _done() {
    final out = TrackData(clips: _clips);
    // mirror first clip to legacy fields so the surface waveform shows
    if (_clips.isNotEmpty) {
      out.vocalPath = _clips.first.path;
      out.clip = _clips.first.peaks.isNotEmpty ? _clips.first.peaks : widget.vocal.clip;
      out.vocalOrigPath = _clips.first.origPath;
    }
    out.vocalAligned = widget.vocal.vocalAligned;
    out.vocalBpm = widget.vocal.vocalBpm;
    out.vocalBars = widget.vocal.vocalBars;
    Navigator.of(context).pop(out);
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(m), duration: const Duration(milliseconds: 1600)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: LT.bg,
      body: SafeArea(
        child: _clips.isEmpty
            ? const Center(child: Text('No take to edit', style: TextStyle(color: LT.t2)))
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
            Row(children: [
              LtLabel(title),
              const Spacer(),
              if (trailing != null) trailing,
            ]),
            const SizedBox(height: 9),
            child,
          ],
        ),
      );

  Widget _header() => Row(
        children: [
          IconBtn(icon: LtIcons.close, tooltip: 'Cancel', onTap: () => Navigator.of(context).pop()),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Vocal editor',
                  style: LTType.inter(size: 17, weight: FontWeight.w800, color: LT.t1)),
              Text('${_clips.length} take${_clips.length == 1 ? '' : 's'} · ${widget.bpm} BPM · ${widget.bars} bar${widget.bars == 1 ? '' : 's'}',
                  style: LTType.mono(size: 11, weight: FontWeight.w600, color: LT.t3)),
            ],
          ),
          const Spacer(),
          if (_status.isNotEmpty) ...[
            const SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: LT.pink)),
            const SizedBox(width: 8),
            Text(_status, style: LTType.mono(size: 12, weight: FontWeight.w600, color: LT.pink)),
            const SizedBox(width: 12),
          ],
          Pill(label: 'Done', icon: LtIcons.checkCircle, tone: PillTone.lime, height: 40, onTap: _done),
        ],
      );

  Widget _clipLane() => SizedBox(
        height: 38,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _clips.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final sel = i == _sel;
            final c = _clips[i];
            return GestureDetector(
              onTap: () {
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
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Ms(LtIcons.mic, size: 13, color: sel ? LT.bg : LT.t2),
                  const SizedBox(width: 6),
                  Text('Take ${i + 1}',
                      style: LTType.inter(
                          size: 12, weight: FontWeight.w700, color: sel ? LT.bg : LT.t1)),
                  if (c.fx.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: (sel ? LT.bg : LT.pink).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text('${c.fx.length} fx',
                          style: LTType.mono(
                              size: 9, weight: FontWeight.w700, color: sel ? LT.bg : LT.pink)),
                    ),
                  ],
                ]),
              ),
            );
          },
        ),
      );

  Widget _waveCard() {
    final src = _curSrc;
    final n = src?.samples.length ?? 1;
    return LayoutBuilder(builder: (context, c) {
      return GestureDetector(
        onHorizontalDragStart: (d) => setState(() {
          _selA = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
          _selB = _selA;
        }),
        onHorizontalDragUpdate: (d) =>
            setState(() => _selB = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0)),
        onTap: () => setState(() => _selA = _selB = null),
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
          child: Stack(children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _WavePainter(
                  // full source so the trim window stays adjustable; falls back
                  // to the stored (trimmed) peaks until the source loads.
                  peaks: src != null
                      ? peaksFromPcm(src.samples, buckets: 220)
                      : _clip.peaks,
                  trimStart: n == 0 ? 0 : _clip.trimStart / n,
                  trimEnd: _clip.trimEnd == -1 ? 1.0 : (n == 0 ? 1.0 : _clip.trimEnd / n),
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
              child: Row(children: [
                Text(
                  (_selA != null && _selB != null) ? 'Drag set · tap Trim' : 'Drag to select a region',
                  style: LTType.mono(size: 10, weight: FontWeight.w600, color: LT.t3),
                ),
                const Spacer(),
                _readout(),
              ]),
            ),
          ]),
        ),
      );
    });
  }

  Widget _readout() {
    final parts = <String>[];
    if (_clip.trimEnd != -1 || _clip.trimStart != 0) parts.add('trimmed');
    if (_clip.fadeInMs != 0) parts.add('in ${_clip.fadeInMs}ms');
    if (_clip.fadeOutMs != 0) parts.add('out ${_clip.fadeOutMs}ms');
    if (_clip.gain != 1.0) parts.add('${_gainDb()}dB');
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(parts.join(' · '),
        style: LTType.mono(size: 10, weight: FontWeight.w700, color: LT.pink));
  }

  Widget _editGroup() => _group(
        'Edit',
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _tool('Trim', LtIcons.straighten, (_selA != null && _selB != null) ? _trimToSelection : null),
            _tool('Fade in ${_clip.fadeInMs}', LtIcons.chevronRight, () => _bumpFade(fadeIn: true)),
            _tool('Fade out ${_clip.fadeOutMs}', LtIcons.chevronLeft, () => _bumpFade(fadeIn: false)),
            _tool('Gain −', LtIcons.remove, () => _bumpGain(-1)),
            _tool('${_gainDb()} dB', LtIcons.volumeUp, null),
            _tool('Gain +', LtIcons.add, () => _bumpGain(1)),
            _tool('Normalize', LtIcons.tune, _curSrc == null ? null : _normalize),
          ],
        ),
        trailing: GestureDetector(
          onTap: _resetEdits,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Ms(LtIcons.undo, size: 13, color: LT.t3),
            const SizedBox(width: 4),
            Text('Reset', style: LTType.mono(size: 10, weight: FontWeight.w700, color: LT.t3)),
          ]),
        ),
      );

  Widget _effectsGroup() => _group(
        'Effects',
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _fxBtn('EQ', 'eq', {'low': 3.0, 'mid': 0.0, 'high': 4.0}),
                _fxBtn('Reverb', 'reverb', {'wet': 0.3, 'decay': 1.4}),
                _fxBtn('Comp', 'comp', {'threshold': -18.0, 'ratio': 3.0}),
                _fxBtn('Delay', 'delay', {'time': 300.0, 'feedback': 0.35, 'wet': 0.3}),
                _fxBtn('Slower', 'stretch', {'ratio': 1.2}),
                _fxBtn('Faster', 'stretch', {'ratio': 0.85}),
                _fxBtn('Pitch +2', 'pitch', {'semitones': 2.0}),
                _fxBtn('Pitch −2', 'pitch', {'semitones': -2.0}),
              ],
            ),
            if (_clip.fx.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(height: 1, color: LT.border),
              const SizedBox(height: 10),
              _fxChain(),
            ],
          ],
        ),
        trailing: Text('server',
            style: LTType.mono(size: 9, weight: FontWeight.w700, color: LT.t3)),
      );

  Widget _fxChain() => Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < _clip.fx.length; i++)
            GestureDetector(
              onTap: () => _removeFx(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: LT.pink.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(LTRadius.pill),
                  border: Border.all(color: LT.pink.withValues(alpha: 0.4)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('${i + 1}. ${_clip.fx[i].type}',
                      style: LTType.mono(size: 11, weight: FontWeight.w700, color: LT.t1)),
                  const SizedBox(width: 6),
                  const Ms(LtIcons.close, size: 13, color: LT.pink),
                ]),
              ),
            ),
        ],
      );

  Widget _tool(String label, IconData icon, VoidCallback? onTap) => Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Pill(label: label, icon: icon, tone: PillTone.surface, height: 36, onTap: onTap),
      );

  Widget _fxBtn(String label, String fx, Map<String, dynamic> params) => Opacity(
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

  Widget _transport() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: LT.surface,
          borderRadius: BorderRadius.circular(LTRadius.card),
          border: Border.all(color: LT.border),
        ),
        child: Row(
          children: [
            IconBtn(icon: LtIcons.playArrow, tooltip: 'Preview (edited)', size: 46, onTap: () => _preview()),
            const SizedBox(width: 8),
            IconBtn(icon: LtIcons.stop, tooltip: 'Stop', size: 46, onTap: _audio.stopVocal),
            const SizedBox(width: 8),
            Pill(label: 'A / B', icon: LtIcons.restore, height: 42, onTap: () => _preview(dryOriginal: true)),
            const Spacer(),
            // clip timing nudge
            Container(
              decoration: BoxDecoration(
                color: LT.surface2,
                borderRadius: BorderRadius.circular(LTRadius.pill),
                border: Border.all(color: LT.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                IconBtn(icon: LtIcons.chevronLeft, tooltip: 'Earlier', size: 38, onTap: () => _nudgeStart(-1)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text('step ${_clip.startStep}',
                      style: LTType.mono(size: 11, weight: FontWeight.w700, color: LT.t1)),
                ),
                IconBtn(icon: LtIcons.chevronRight, tooltip: 'Later', size: 38, onTap: () => _nudgeStart(1)),
              ]),
            ),
            if (_clips.length > 1) ...[
              const SizedBox(width: 8),
              IconBtn(icon: LtIcons.delete, tooltip: 'Delete take', size: 42, color: LT.danger, onTap: () => _deleteClip(_sel)),
            ],
          ],
        ),
      );

  String _gainDb() {
    final db = 20 * _log10(_clip.gain <= 0 ? 0.0001 : _clip.gain);
    return db.toStringAsFixed(1);
  }
}

double _log10(double x) => math.log(x <= 0 ? 1e-9 : x) / math.ln10;
double _pow10(double x) => math.pow(10, x).toDouble();

extension VocalClipDry on VocalClip {
  // For the A/B "original" preview: drop the fx-baked path back to the dry take
  // when one exists (so the comparison is dry vs processed).
  void origPathToDry() {
    if (origPath != null) {
      path = origPath!;
      origPath = null;
      fx.clear();
    }
  }
}

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
    canvas.drawLine(Offset(0, mid), Offset(w, mid),
        Paint()..color = LT.t1.withValues(alpha: 0.06));

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
        final bar = Paint()..color = inTrim ? LT.pink : LT.t3.withValues(alpha: 0.5);
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
    final fadePaint = Paint()
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
          Rect.fromLTRB(a, 0, b, size.height), Paint()..color = LT.lime.withValues(alpha: 0.18));
      final edge = Paint()
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
