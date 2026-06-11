// LoopTap — Editor (the core screen). README §4.
// Vertical stack: top bar · SONG section bar · arrangement strip · surface
// header · track surface · transport bar. A Ticker-driven transport clock
// sweeps a 2/4-bar loop (16 steps/bar), with swing on odd 16ths.
//
// M1: shell + clock + sections + transport wired. Track surfaces land in M2–M4
// (a placeholder fills the surface area for now).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../api/engine_api.dart';
import '../../models/models.dart' as eng;
import '../audio/loop_audio.dart';
import '../models/loop_models.dart';
import '../music/hum_map.dart';
import '../music/instruments.dart';
import '../music/song_util.dart';
import '../music/theory.dart';
import '../state/loop_prefs.dart';
import '../state/loop_storage.dart';
import '../state/loop_store.dart';
import '../theme/atoms.dart';
import '../theme/pad_scale.dart';
import '../theme/tokens.dart';
import '../widgets/arrangement.dart';
import '../widgets/section_bar.dart';
import '../widgets/sheets/hum_modal.dart';
import '../widgets/sheets/paywall_sheet.dart';
import '../widgets/sheets/export_drawer.dart';
import '../widgets/sheets/instrument_sheet.dart';
import '../widgets/sheets/key_sheet.dart';
import '../widgets/sheets/lt_modal.dart';
import '../widgets/sheets/mixer_sheet.dart';
import '../widgets/surfaces/drum_surface.dart';
import '../widgets/surfaces/live_pads.dart';
import '../widgets/surfaces/step_grid.dart';
import '../widgets/surfaces/vocal_surface.dart';
import '../widgets/transport_bar.dart';

class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.song});
  final Song song;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

// TickerProviderStateMixin (not Single*) — the transport clock disposes and
// re-creates its Ticker on every play/stop, which Single* would assert against.
class _EditScreenState extends State<EditScreen> with TickerProviderStateMixin {
  final LoopAudio _audio = LoopAudio.instance;
  final math.Random _rng = math.Random();

  // ── persisted-ish song state ──
  late String _title = widget.song.title;
  late String _keyRoot = widget.song.key;
  late String _scale = widget.song.scale;
  late int _bpm = widget.song.bpm;
  late double _swing = widget.song.swing;
  late final Map<String, double> _vol = Map.of(widget.song.vol);
  late final Map<String, bool> _mutes = Map.of(widget.song.mutes);

  // ── sections (each an independent loop × repeats) ──
  late final List<Section> _sections = widget.song.sections.map((s) => s.deepCopy()).toList();
  int _activeIdx = 0;

  // ── editor runtime ──
  String _activeId = 'drums';
  bool _playing = false;
  bool _recording = false;
  bool _metro = LoopPrefs.instance.metro.value; // shared with Settings sheet
  bool _countIn = true; // count-in on by default
  // Octave shift, tracked PER REGISTER (melody group + bass) — mirrors the
  // per-register windows below. A single global octave made changing one track's
  // octave move every other pitched track; scoping it per register fixes that.
  // melody + melody-fill share the melody register (same ladder/window/octave).
  int _melodyOctave = 0;
  int _bassOctave = 0;
  int get _octave => _isBass ? _bassOctave : _melodyOctave; // active-track view
  void _setOctave(int v) => setState(() {
        final c = v.clamp(-2, 2);
        if (_isBass) {
          _bassOctave = c;
        } else {
          _melodyOctave = c;
        }
      });
  // Pitched pads (melody / fill / bass): an 8-pad window that slides across a
  // wider in-key ladder via a horizontal swipe. The offset (in scale degrees)
  // is tracked per register — melody group and bass have separate ladders.
  int _melodyWindow = 7; // ~oct4 (one octave up from the melody ladder base)
  int _bassWindow = 7; // ~oct2 (one octave up from the bass ladder base)
  // input mode per track id ('pads' | 'grid') — defaults to 'pads' when unset
  final Map<String, String> _inputModes = {};
  // chord mode per track id: a pad tap places a key-based diatonic triad, not a
  // single note. Available on the melody group (melody + melody-fill).
  final Map<String, bool> _chordMode = {};
  bool get _chordOn => _chordMode[_activeId] ?? false;
  // per-track GM instrument (program number) — drives live sound + MIDI export
  late final Map<String, int> _instruments = Map.of(widget.song.instruments);
  int _countDown = 0; // count-in overlay (0 = none)

  bool get _hasInputToggle => _meta.kind != TrackKind.vocal;
  String get _inputMode => _inputModes[_activeId] ?? 'pads';
  void _setInputMode(String v) => setState(() => _inputModes[_activeId] = v);

  // Active-track kind helpers.
  bool get _isBass => _meta.kind == TrackKind.bass;
  bool get _isPitched => _meta.kind == TrackKind.pitched || _meta.kind == TrackKind.bass;

  // glow: currently-sounding pitched notes (drums use press-only feedback)
  Set<int> _litMidis = {};

  // notes recorded during the current loop pass — the clock skips replaying them
  // until the loop wraps, so a freshly-tapped note isn't heard twice (live tap +
  // scheduled playback) in the same pass.
  final Set<String> _freshThisLoop = {};

  // playhead (driven every frame — kept off setState to avoid full rebuilds)
  final ValueNotifier<double> _playStep = ValueNotifier(0);

  // whole-song preview (non-null while "Play song" is active)
  Section? _songSection;
  int? _songSteps;

  // recorded-vocal playback state
  bool _vocalPlaying = false;
  // Play song: section-instance start step -> that section's vocalPath (or null).
  // The current section's vocal switches in as the playhead crosses each boundary.
  Map<int, String?>? _songVocalSched;

  // undo / redo — snapshots of the editable song state
  final List<_EditSnapshot> _undo = [];
  final List<_EditSnapshot> _redo = [];
  int _lastUndoMs = 0;

  // transport clock
  Ticker? _ticker;
  double _startStep = 0;
  int _nextAbs = 0;

  Section get _sec => _sections[_activeIdx];
  Map<String, TrackData> get _tracks => _sec.tracks;
  int get _bars => _sec.bars;
  int get _steps => _songSteps ?? stepsForBars(_bars);

  // The full track-meta list (base 6 + added instances) for a section, and for
  // the active editing section. _meta resolves the active track from it so added
  // instances get their own channel/label/instrument like the base tracks.
  List<TrackMeta> _metasFor(Section s) => sectionTrackMetas(s.extras);
  List<TrackMeta> get _editMetas => _metasFor(_sec);
  TrackMeta get _meta =>
      _editMetas.firstWhere((t) => t.id == _activeId, orElse: () => _editMetas.first);

  /// Base track type of the active track — an added instance's type, or the id
  /// itself for a base track. Used for type-keyed lookups (instrument list etc.).
  String get _activeType {
    for (final e in _sec.extras) {
      if (e.id == _activeId) return e.type;
    }
    return _activeId;
  }

  /// Track metas in the section's display order (drag-reordered). Ids not listed
  /// in [Section.order] fall back to natural order at the end.
  List<TrackMeta> _orderedMetas(Section s) {
    final byId = {for (final m in sectionTrackMetas(s.extras)) m.id: m};
    final out = <TrackMeta>[];
    for (final id in s.order) {
      final m = byId.remove(id);
      if (m != null) out.add(m);
    }
    out.addAll(byId.values);
    return out;
  }

  /// Apply a drag-reorder of the arrangement rows. Display-only; written to every
  /// section so the order stays consistent across the song.
  void _reorderTracks(int oldIndex, int newIndex) {
    final ids = _orderedMetas(_sec).map((m) => m.id).toList();
    if (oldIndex < 0 || oldIndex >= ids.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    final id = ids.removeAt(oldIndex);
    ids.insert(newIndex.clamp(0, ids.length), id);
    setState(() {
      for (final s in _sections) {
        s.order
          ..clear()
          ..addAll(ids);
      }
    });
  }

  List<Rung> get _ladder => buildLadder(_keyRoot, _scale, 4 + _melodyOctave, 8);

  // Wide in-key ladders (~3 octaves) the pad window slides across — melody
  // group sits mid-register, bass low.
  // Visible pad count adapts to width: narrow phones keep 8, wide phones/tablets
  // fan out to up to 12 so each pad stays a comfortable size (PadScale band).
  // Clamped to the ladder length as a safety bound.
  int get _padCount {
    final w = (MediaQuery.maybeOf(context)?.size.width ?? 0) - 32; // surface h-padding
    return math.min(padCountForWidth(w), _activeFullLadder.length);
  }
  List<Rung> get _melodyFullLadder => buildLadder(_keyRoot, _scale, 3 + _melodyOctave, 22);
  List<Rung> get _bassFullLadder => buildLadder(_keyRoot, _scale, 1 + _bassOctave, 22);
  List<Rung> get _activeFullLadder => _isBass ? _bassFullLadder : _melodyFullLadder;
  int get _windowOffset => _isBass ? _bassWindow : _melodyWindow;
  int get _maxWindow => (_activeFullLadder.length - _padCount).clamp(0, _activeFullLadder.length);

  /// The 8 pads currently shown for the active pitched track.
  List<Rung> get _padWindow {
    final full = _activeFullLadder;
    final off = _windowOffset.clamp(0, _maxWindow);
    return full.sublist(off, off + _padCount);
  }

  // Called when a pad swipe begins: release the note that started the gesture so
  // it doesn't drone or get recorded. The strip's glide/snap is owned by NotePads.
  void _padSlideStart(Rung n) {
    final ch = _meta.channel;
    for (final m in _chordMidis(n.midi)) {
      _audio.noteOffLive(ch, m);
    }
    _pending.remove(n.midi);
  }

  List<Rung> get _bassLadder {
    final full = buildLadder(_keyRoot, _scale, 2, 8);
    return const [0, 3, 4, 5, 7].map((i) => full[i]).toList();
  }

  /// active pitched ladder for the Grid surface — the SAME windowed slice the
  /// pads show, so the grid covers the full slide range too (drag the row
  /// labels vertically to move the window).
  List<Rung> get _gridLadder => _padWindow;

  /// Move the pitched pad/grid window (shared by pads + grid). Clamped.
  void _setWindowOffset(int o) {
    final c = o.clamp(0, _maxWindow);
    setState(() {
      if (_isBass) {
        _bassWindow = c;
      } else {
        _melodyWindow = c;
      }
    });
  }

  Map<String, PitchRange> get _ranges {
    final mfull = _melodyFullLadder, bfull = _bassFullLadder;
    // ranges span the whole slide ladders so the arrangement preview shows notes
    // placed anywhere in the window.
    final mel = PitchRange(mfull.first.midi - 2, mfull.last.midi + 2);
    final bass = PitchRange(bfull.first.midi - 2, bfull.last.midi + 2);
    final r = {
      'melody': mel,
      'melodyDec': mel, // melody-fill shares the melody register
      'bass': bass,
    };
    // added pitched instances reuse their base type's range for the lane preview.
    for (final e in _sec.extras) {
      r[e.id] = e.type == 'bass' ? bass : mel;
    }
    return r;
  }

  // ── auto-save 상태 ────────────────────────────────────────────────
  // 12초마다 silent autosave (LoopStore.upsert 가 idempotent — dirty 추적 정밀도
  // 가 낮은 데이터플로우 회피용 always-save 패턴).
  // _savedAt: 가장 최근 저장 시각 (UI 표시용).
  // _savedFlash: 명시적 Save 버튼 누른 직후 lime 강조 (2초간) 플래그.
  // _dirty: 명시적 Save / autosave 이후 추가 입력 여부 — 현재는 항상 false 로
  // 시작해서 첫 autosave 가 'Saved · 13:42' 로 표시되도록.
  Timer? _autosaveTimer;
  bool _dirty = false;
  DateTime? _savedAt;
  bool _savedFlash = false;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    // apply this song's chosen instruments (per pitched channel), then warm the synth
    _audio.setPrograms({
      for (final t in kPitchedTracks) t.channel: _instruments[t.id] ?? t.defaultProgram,
    });
    _audio.prewarm();
    // 12초마다 dirty 면 silent autosave — 사용자 명시적 Save 와 충돌 없음.
    _autosaveTimer = Timer.periodic(const Duration(seconds: 12), (_) => _autoSaveTick());
  }

  @override
  void dispose() {
    _autosaveTimer?.cancel();
    _flashTimer?.cancel();
    _ticker?.dispose();
    _playStep.dispose();
    _audio.stopAll();
    super.dispose();
  }

  /// 12초마다 호출. 변경 사항이 없어 보여도 일단 저장 — upsert 는 idempotent
  /// 하고, 자잘한 미반영 mutation 도 모두 잡힌다 (dirty 추적 정밀도가 낮은
  /// 데이터플로우 회피). UI 갱신은 setState 로 saved indicator 만.
  Future<void> _autoSaveTick() async {
    if (!mounted) return;
    try {
      await context.read<LoopStore>().upsert(_snapshot());
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _savedAt = DateTime.now();
      });
    } catch (_) {
      // 실패 시 다음 주기에 재시도.
    }
  }

  // ── transport clock ───────────────────────────────────────────────
  double _swFrac(int a) {
    final steps = _steps;
    final s = ((a % steps) + steps) % steps;
    return (s % 2 == 1) ? _swing * 0.5 : 0;
  }

  void _onTick(Duration elapsed) {
    final steps = _steps;
    final sec = elapsed.inMicroseconds / 1e6;
    final beats = sec * (_bpm / 60);
    final abs = _startStep + beats * kStepsPerBeat;
    while (abs >= _nextAbs + _swFrac(_nextAbs)) {
      final st = ((_nextAbs % steps) + steps) % steps;
      // new loop pass — notes recorded last pass may now play normally; re-align
      // the recorded vocal to the loop start so it stays in sync.
      if (st == 0) {
        _freshThisLoop.clear();
        // single-section loop re-aligns its one vocal; song mode handles vocals
        // per-section in _trigger (the step-0 boundary restarts the first one).
        if (_songSection == null && _vocalPlaying) _audio.seekVocalToStart();
      }
      _trigger(st);
      _nextAbs++;
    }
    _playStep.value = ((abs % steps) + steps) % steps;
  }

  Map<String, TrackData> get _effectiveTracks =>
      _songSection != null ? _songSection!.tracks : _tracks;

  void _trigger(int step) {
    final T = _effectiveTracks;
    final sps = 60 / _bpm / kStepsPerBeat;
    double dsec(int dur) => (dur * sps * 0.95).clamp(0.12, 8);
    // Play song: switch the recorded vocal in at each section boundary
    final sched = _songVocalSched;
    if (sched != null && sched.containsKey(step)) {
      final path = sched[step];
      if (path != null && !(_mutes['vocal'] ?? false)) {
        _vocalPlaying = true;
        _audio.playVocal(path, vol: _vol['vocal'] ?? 0.85);
      } else {
        _vocalPlaying = false;
        _audio.stopVocal();
      }
    }
    // Iterate every track (main + decoration). Pitched voices play on their own
    // MIDI channel/program; percussion tracks (drums + beat-fill) share ch9 but
    // keep independent mute/volume. Drums don't drive pad lighting.
    final litM = <int>{};
    for (final tk in _metasFor(_songSection ?? _sec)) {
      if (_mutes[tk.id] ?? false) continue;
      final data = T[tk.id];
      if (data == null) continue;
      if (tk.kind == TrackKind.pitched || tk.kind == TrackKind.bass) {
        final prog = _instruments[tk.id] ?? tk.defaultProgram;
        for (final n in data.pitchNotes.where((n) => n.step == step)) {
          if (_freshThisLoop.contains('${tk.id}:${n.midi}:$step')) continue;
          _audio.playPitch(tk.channel, n.midi, program: prog, vol: _vol[tk.id] ?? 0.85, durSec: dsec(n.dur));
          // glow only the ACTIVE track's pads — otherwise a melody note would
          // light a same-pitch pad on melody-fill/bass while they're showing.
          if (tk.id == _activeId) litM.add(n.midi);
        }
      } else if (tk.kind == TrackKind.drums) {
        for (final n in data.drumNotes.where((n) => n.step == step)) {
          if (_freshThisLoop.contains('${tk.id}:${n.kind}:$step')) continue;
          _audio.playDrum(n.kind, vol: _vol[tk.id] ?? 1);
        }
      }
    }
    if (_metro && step % kStepsPerBeat == 0) {
      _audio.click(step % (kStepsPerBeat * kBeatsPerBar) == 0);
    }
    if (litM.isNotEmpty || _litMidis.isNotEmpty) {
      setState(() => _litMidis = litM);
    }
  }

  void _startClock() {
    _ticker?.dispose();
    _startStep = _playStep.value;
    _nextAbs = _startStep.ceil();
    // Ticker.elapsed starts at ~0 on start(), so it doubles as our clock base.
    _ticker = createTicker(_onTick)..start();
  }

  void _stopClock() {
    _ticker?.dispose();
    _ticker = null;
  }

  /// Scrub the playhead to [step] (arrangement drag). While playing, rebase the
  /// clock so playback continues from the new position; song-preview is read-only.
  void _seekTo(double step) {
    if (_songSection != null) return;
    final s = step.clamp(0.0, _steps.toDouble());
    _playStep.value = s;
    if (_playing) {
      _freshThisLoop.clear();
      _startClock(); // rebase elapsed to the new position
    }
  }

  // ── add-track ─────────────────────────────────────────────────────
  /// Append a new instance of [type] (one of the base track ids) to EVERY
  /// section so the track set stays consistent across the song, then select it.
  void _addTrack(String type) {
    _pushUndo();
    final id = '${type}_x${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      for (final s in _sections) {
        s.extras.add(TrackRef(id, type));
        s.tracks[id] = TrackData();
      }
      _instruments[id] = trackById(type).defaultProgram;
      _activeId = id;
      _inputModes[id] = 'pads';
    });
  }

  Future<void> _openAddTrack() async {
    final type = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: LT.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Add track',
                      style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
                ),
              ),
              // vocal is a single audio-recording track, not a synth voice — no
              // instances of it.
              for (final t in kTracks.where((t) => t.kind != TrackKind.vocal))
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(ctx).pop(t.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    child: Row(
                      children: [
                        Ms(t.icon, size: 18, color: t.color),
                        const SizedBox(width: 12),
                        Text(t.label, style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.t1)),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    if (type != null) _addTrack(type);
  }

  // ── transport actions ─────────────────────────────────────────────
  void _togglePlay() {
    _audio.ensure();
    setState(() {
      _playing = !_playing;
      if (_playing) {
        _startClock();
        _startVocalIfAny();
      } else {
        _stopClock();
        _stopVocal();
      }
    });
  }

  void _stopAll() {
    _stopClock();
    _audio.stopAll();
    _vocalPlaying = false;
    _playStep.value = 0;
    setState(() {
      _playing = false;
      _recording = false;
      _litMidis = {};
      if (_songSection != null) {
        _songSection = null;
        _songSteps = null;
        _songVocalSched = null;
      }
    });
  }

  void _armRecord() {
    _audio.ensure();
    if (_recording) {
      setState(() => _recording = false);
      return;
    }
    void begin() {
      setState(() {
        _recording = true;
        if (!_playing) {
          _playStep.value = 0;
          _playing = true;
          _startClock();
          _startVocalIfAny();
        }
      });
    }

    if (_countIn && !_playing) {
      _doCountIn(begin);
    } else {
      begin();
    }
  }

  void _doCountIn(VoidCallback then) {
    _audio.ensure();
    final beatMs = (60 / _bpm * 1000).round();
    var n = 4;
    setState(() => _countDown = 4);
    _audio.click(true);
    void step() {
      Future.delayed(Duration(milliseconds: beatMs), () {
        if (!mounted) return;
        n -= 1;
        if (n <= 0) {
          setState(() => _countDown = 0);
          then();
        } else {
          setState(() => _countDown = n);
          _audio.click(false);
          step();
        }
      });
    }

    step();
  }

  // ── section management ────────────────────────────────────────────
  void _switchSection(int idx) {
    if (idx == _activeIdx) return;
    if (_playing) _stopAll();
    setState(() {
      _activeIdx = idx;
      _playStep.value = 0;
    });
  }

  String _nextSectionName() => String.fromCharCode(65 + _sections.length % 26);

  // "+" → a brand-new EMPTY section (not a copy of the current one).
  void _addSection() {
    _pushUndo();
    if (_playing) _stopAll();
    final ns = Section(
      id: 'sec${DateTime.now().millisecondsSinceEpoch}',
      name: _nextSectionName(),
      bars: _bars,
    );
    setState(() {
      _sections.add(ns);
      _activeIdx = _sections.length - 1;
      _playStep.value = 0;
    });
  }

  // long-press → Duplicate: deep-copy a section in place (the old "+" behavior).
  void _duplicateSection(int idx) {
    _pushUndo();
    if (_playing) _stopAll();
    final copy = _sections[idx].deepCopy()
      ..id = 'sec${DateTime.now().millisecondsSinceEpoch}'
      ..name = _nextSectionName();
    setState(() {
      _sections.insert(idx + 1, copy);
      _activeIdx = idx + 1;
      _playStep.value = 0;
    });
  }

  // long-press → Move left/right (reorder); active follows the moved chip.
  void _moveSection(int idx, int dir) {
    final j = idx + dir;
    if (j < 0 || j >= _sections.length) return;
    _pushUndo();
    if (_playing) _stopAll();
    setState(() {
      final s = _sections.removeAt(idx);
      _sections.insert(j, s);
      if (_activeIdx == idx) {
        _activeIdx = j;
      } else if (_activeIdx == j) {
        _activeIdx = idx;
      }
      _playStep.value = 0;
    });
  }

  void _deleteSection(int idx) {
    if (_sections.length <= 1) return;
    _pushUndo();
    if (_playing) _stopAll();
    setState(() {
      _sections.removeAt(idx);
      _activeIdx = _activeIdx.clamp(0, _sections.length - 1);
      if (idx < _activeIdx || _activeIdx >= _sections.length) {
        _activeIdx = (_activeIdx - 1).clamp(0, _sections.length - 1);
      }
      _playStep.value = 0;
    });
  }

  void _renameSection(int idx, String name) => _sections[idx].name = name;

  // long-press a section chip → Duplicate / Move left / Move right
  Future<void> _openSectionMenu(int idx) async {
    await showLtModal(
      context,
      width: 300,
      child: StatefulBuilder(
        builder: (context, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Section ${_sections[idx].name}',
                style: LTType.inter(size: 15, weight: FontWeight.w800, color: LT.t1)),
            const SizedBox(height: 14),
            _menuRow(LtIcons.layers, 'Duplicate', () {
              Navigator.of(context).pop();
              _duplicateSection(idx);
            }),
            _menuRow(LtIcons.arrowBack, 'Move left', idx > 0
                ? () {
                    Navigator.of(context).pop();
                    _moveSection(idx, -1);
                  }
                : null),
            _menuRow(LtIcons.playArrow, 'Move right', idx < _sections.length - 1
                ? () {
                    Navigator.of(context).pop();
                    _moveSection(idx, 1);
                  }
                : null),
          ],
        ),
      ),
    );
  }

  Widget _menuRow(IconData icon, String label, VoidCallback? onTap) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          height: 48,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: LT.surface2,
            borderRadius: BorderRadius.circular(LTRadius.control),
            border: Border.all(color: LT.border),
          ),
          child: Row(
            children: [
              Ms(icon, size: 18, color: LT.t2),
              const SizedBox(width: 12),
              Text(label, style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t1)),
            ],
          ),
        ),
      ),
    );
  }

  void _setRepeats(int idx, int r) {
    _pushUndo(coalesce: true);
    setState(() => _sections[idx].repeats = r.clamp(1, 8));
  }

  void _playSong() {
    _audio.ensure();
    if (_songSection != null) {
      _stopAll();
      return;
    }
    final flat = flattenSong(_sections);
    final disp = Section(id: 'song', name: 'SONG', bars: _bars);
    disp.tracks['melody'] = TrackData(notes: flat.melody);
    disp.tracks['melodyDec'] = TrackData(notes: flat.melodyDec);
    disp.tracks['bass'] = TrackData(notes: flat.bass);
    disp.tracks['drums'] = TrackData(drums: flat.drums);
    disp.tracks['beatDec'] = TrackData(drums: flat.beatDec);
    // schedule each section instance's vocal at its flattened start step
    final sched = <int, String?>{};
    var off = 0;
    for (final sec in _sections) {
      final st = stepsForBars(sec.bars);
      final vp = sec.tracks['vocal']?.vocalPath;
      for (var r = 0; r < sec.repeats; r++) {
        sched[off] = vp;
        off += st;
      }
    }
    setState(() {
      _songSection = disp;
      _songSteps = flat.steps;
      _songVocalSched = sched;
      _playStep.value = 0;
      _playing = true;
      _startClock();
    });
  }

  // ── editing ───────────────────────────────────────────────────────
  int _quantStep() => _playStep.value.round() % _steps;

  void _hitDrum(String kind) {
    _audio.playDrum(kind, vol: _vol[_activeId] ?? 1);
    if (_recording && _playing && _songSection == null) {
      _pushUndo(coalesce: true);
      final s = _quantStep();
      final dn = _tracks[_activeId]!.drumNotes;
      if (!dn.any((x) => x.kind == kind && x.step == s)) {
        setState(() => dn.add(DrumNote(kind: kind, step: s)));
      }
      // heard live now → don't let the clock replay it this loop pass
      _freshThisLoop.add('$_activeId:$kind:$s');
    }
  }

  // drums Grid mode: tap a cell to toggle a hit at (kind, step) on the active
  // percussion track (main drums or beat-fill).
  void _toggleDrumCell(String kind, int step) {
    if (_songSection != null) return; // editing disabled while previewing the song
    _pushUndo(coalesce: true);
    final dn = _tracks[_activeId]!.drumNotes;
    final i = dn.indexWhere((x) => x.kind == kind && x.step == step);
    setState(() {
      if (i >= 0) {
        dn.removeAt(i);
      } else {
        dn.add(DrumNote(kind: kind, step: step));
        _audio.playDrum(kind, vol: _vol[_activeId] ?? 1);
      }
    });
  }

  // pending hold timing per midi (live pads): midi -> (step, pressedAtMs)
  final Map<int, ({int step, int t})> _pending = {};

  int _durFromHold(int ms) =>
      (ms / 1000 * (_bpm / 60) * kStepsPerBeat).round().clamp(1, _steps);

  /// The midis a pad press produces: a diatonic triad in melody chord mode,
  /// otherwise just the pressed note.
  List<int> _chordMidis(int rootMidi) => (_meta.group == 'melody' && _chordOn)
      ? diatonicTriad(rootMidi, _keyRoot, _scale)
      : [rootMidi];

  /// A Rung for an arbitrary chord-member midi (the root reuses the real Rung).
  Rung _rungFor(int midi, Rung root) => midi == root.midi
      ? root
      : Rung(
          midi: midi,
          name: kNoteNames[((midi % 12) + 12) % 12],
          degree: root.degree,
          freq: midiToFreq(midi),
          index: root.index,
        );

  void _pitchDown(Rung n) {
    // held note(s): they sound while pressed, so what you hear == what's recorded
    final ch = _meta.channel;
    final prog = _instruments[_activeId] ?? _meta.defaultProgram;
    for (final m in _chordMidis(n.midi)) {
      _audio.noteOnLive(ch, m, program: prog, vol: _vol[_activeId] ?? 0.85);
    }
    if (_recording && _playing && _songSection == null) {
      _pending[n.midi] = (step: _quantStep(), t: DateTime.now().millisecondsSinceEpoch);
    }
  }

  void _pitchUp(Rung n) {
    final ch = _meta.channel;
    final midis = _chordMidis(n.midi);
    for (final m in midis) {
      _audio.noteOffLive(ch, m);
    }
    final p = _pending.remove(n.midi);
    if (p == null) return;
    _pushUndo(coalesce: true);
    final dur = _durFromHold(DateTime.now().millisecondsSinceEpoch - p.t);
    for (final m in midis) {
      _placePitched(_activeId, _rungFor(m, n), p.step, p.step + dur - 1);
      // heard live now → don't let the clock replay it this loop pass
      _freshThisLoop.add('$_activeId:$m:${p.step}');
    }
  }

  /// Place a pitched note spanning [a,b], merging overlapping same-pitch notes.
  void _placePitched(String id, Rung n, int a, int b) {
    setState(() {
      var lo = a < b ? a : b;
      var hi = a < b ? b : a;
      final kept = <PitchNote>[];
      for (final x in _tracks[id]!.pitchNotes) {
        if (x.midi == n.midi) {
          final xs = x.step, xe = x.step + x.dur - 1;
          if (xs <= hi && xe >= lo) {
            lo = lo < xs ? lo : xs;
            hi = hi > xe ? hi : xe;
          } else {
            kept.add(x);
          }
        } else {
          kept.add(x);
        }
      }
      kept.add(PitchNote(midi: n.midi, freq: n.freq, step: lo, dur: hi - lo + 1));
      _tracks[id]!.pitchNotes
        ..clear()
        ..addAll(kept);
    });
  }

  // grid place/erase work on the active pitched track (melody / melody-fill / bass)
  void _gridPlace(Rung n, int a, int b) {
    _pushUndo(coalesce: true);
    // preview sound length matches the drawn note length
    final sps = 60 / _bpm / kStepsPerBeat;
    final durSec = (((a - b).abs() + 1) * sps * 0.95).clamp(0.12, 8.0);
    _audio.playPitch(_meta.channel, n.midi,
        program: _instruments[_activeId] ?? _meta.defaultProgram, vol: _vol[_activeId] ?? 0.85, durSec: durSec);
    _placePitched(_activeId, n, a, b);
    _freshThisLoop.add('$_activeId:${n.midi}:${a < b ? a : b}');
  }

  // Erase only the touched CELL (one step), not the whole note: split the note
  // into its before/after remainders so a long note keeps its other steps.
  void _gridErase(Rung n, int step) {
    _pushUndo(coalesce: true);
    setState(() {
      final notes = _tracks[_activeId]!.pitchNotes;
      final i = notes.indexWhere((x) => x.midi == n.midi && step >= x.step && step < x.step + x.dur);
      if (i < 0) return;
      final note = notes.removeAt(i);
      final end = note.step + note.dur; // exclusive
      if (step > note.step) {
        notes.add(PitchNote(midi: note.midi, freq: note.freq, step: note.step, dur: step - note.step));
      }
      if (step + 1 < end) {
        notes.add(PitchNote(midi: note.midi, freq: note.freq, step: step + 1, dur: end - (step + 1)));
      }
    });
  }

  void _clearTrack() {
    _pushUndo();
    setState(() {
      final t = _tracks[_activeId]!;
      t.pitchNotes.clear();
      t.drumNotes.clear();
      t.clip = null;
      if (_activeId == 'vocal') {
        t.vocalPath = null;
        _audio.stopVocal();
        _vocalPlaying = false;
      }
    });
  }

  // ── vocal playback (item 7) ───────────────────────────────────────
  Future<void> _commitVocal(List<double> wf, String? path) async {
    _pushUndo();
    String? persisted = path;
    if (path != null) {
      persisted = await LoopStorage.copyVocal(path, widget.song.id, _sec.id) ?? path;
    }
    if (!mounted) return;
    setState(() {
      _tracks['vocal']!.clip = wf;
      _tracks['vocal']!.vocalPath = persisted;
    });
  }

  /// Start the recorded vocal for single-section loop play. (Play song handles
  /// per-section vocals via the schedule in _trigger, so skip here.)
  void _startVocalIfAny() {
    if (_songSection != null) return;
    final path = _tracks['vocal']!.vocalPath;
    if (path != null && !(_mutes['vocal'] ?? false)) {
      _vocalPlaying = true;
      _audio.playVocal(path, vol: _vol['vocal'] ?? 0.85);
    }
  }

  void _stopVocal() {
    _vocalPlaying = false;
    _audio.stopVocal();
  }

  // mute/volume go through here so the live vocal player follows the mixer
  void _toggleMute(String id) {
    setState(() => _mutes[id] = !(_mutes[id] ?? false));
    if (id == 'vocal') {
      if (_mutes['vocal'] == true) {
        _stopVocal();
      } else if (_playing) {
        _startVocalIfAny();
      }
    }
  }

  void _setVol(String id, double v) {
    setState(() => _vol[id] = v);
    if (id == 'vocal' && _vocalPlaying) _audio.setVocalVolume(v);
  }

  // ── sheets ────────────────────────────────────────────────────────
  void _openKey() {
    showKeySheet(
      context,
      root: _keyRoot,
      scale: _scale,
      onPick: (r, s) {
        _pushUndo(coalesce: true);
        setState(() {
          _keyRoot = r;
          _scale = s;
        });
      },
    );
  }

  void _openInstrument() {
    final id = _activeId; // any pitched track: melody / melodyDec / bass (+ instances)
    final ch = _meta.channel;
    showInstrumentSheet(
      context,
      trackId: _activeType, // base type drives the instrument list
      trackLabel: _meta.label, // instance label (e.g. "Bass 2")
      currentProgram: _instruments[id] ?? _meta.defaultProgram,
      onPick: (program) {
        _pushUndo(coalesce: true);
        setState(() => _instruments[id] = program);
        _audio.setProgram(ch, program);
        // preview the new timbre on an in-key note in that track's own register
        // (bass uses the low bass ladder root; melody/fill an in-key mid note).
        final isBass = _isBass;
        final ladder = isBass ? _bassLadder : _ladder;
        final preview = ladder.isNotEmpty ? ladder[isBass ? 0 : 2].midi : 60;
        _audio.playPitch(ch, preview, program: program, vol: _vol[id] ?? 0.85, durSec: 0.5);
      },
    );
  }

  void _openMixer() {
    showMixerSheet(
      context,
      vol: _vol,
      mutes: _mutes,
      onVol: _setVol,
      onToggleMute: _toggleMute,
    );
  }

  void _openHum() {
    _audio.ensure();
    if (_playing) _stopAll();
    showHumModal(
      context,
      trackLabel: _meta.label,
      accent: _meta.color,
      onConvert: _humConvert,
      bpm: _bpm,
      bars: _bars,
      swing: _swing,
      onClick: (accent) => _audio.click(accent),
      startBacking: _startHumBacking,
      stopBacking: _stopHumBacking,
    );
  }

  // Play the loop (clock + clicks) from the downbeat so the user hums in time.
  // Starts at step 0 so the recording's t=0 aligns with the grid.
  void _startHumBacking() {
    _audio.ensure();
    _stopClock();
    _playStep.value = 0;
    _freshThisLoop.clear();
    setState(() => _playing = true);
    _startClock();
  }

  void _stopHumBacking() {
    _stopClock();
    _audio.stopAll();
    _playStep.value = 0;
    if (mounted) {
      setState(() {
        _playing = false;
        _litMidis = {};
      });
    }
  }

  // Send the hum recording to the FastAPI humming→MIDI engine, map its notes
  // (seconds → steps) into the active track. Falls back to a generated phrase
  // if the engine is unreachable so the button always does something.
  // LoopTap scale name -> backend Scale literal (schemas.py). Only 'pentatonic'
  // differs; minor/major/dorian match.
  static const _engineScale = {'pentatonic': 'minor_pentatonic'};

  Future<void> _humConvert(String audioPath) async {
    _pushUndo();
    final drums = _meta.kind == TrackKind.drums;
    final opts = eng.AnalyzeOptions(
      // snap to the song's chosen key/scale (LoopTap's in-key guarantee)
      autoKey: false,
      pitchAssistant: true,
      assistAggressive: true,
      keyTonic: _keyRoot,
      scale: _engineScale[_scale] ?? _scale,
      asDrums: drums,
      tempoBpm: _bpm,
      quantizeGrid: 16,
      // loop-grid mode: backend hard-snaps to the fixed grid and returns integer
      // step/dur_steps (de-swung, deduped, loop-bounded) — no client re-rounding.
      loopQuantize: true,
      loopBars: _bars,
      stepsPerBar: kStepsPerBeat * kBeatsPerBar,
      swing: _swing,
    );
    try {
      final res = await EngineApi().analyze(audioPath, opts);
      final sps = 60 / _bpm / kStepsPerBeat;
      final steps = _steps;
      final t = _tracks[_activeId]!;
      var count = 0;
      if (drums) {
        final out = <DrumNote>[];
        for (final n in res.notes) {
          // backend loop mode stamps integer step; fall back to seconds→step.
          final step = n.step ?? (n.start / sps).round();
          if (step < 0 || step >= steps) continue;
          final kind = _drumKind(n);
          if (kind == null) continue;
          if (t.drumNotes.any((x) => x.kind == kind && x.step == step)) continue;
          if (out.any((x) => x.kind == kind && x.step == step)) continue;
          out.add(DrumNote(kind: kind, step: step));
        }
        if (out.isEmpty) throw StateError('no drums');
        setState(() => t.drumNotes.addAll(out));
        count = out.length;
      } else {
        // snap each note onto the active grid's in-key rows so it always lands
        // on a visible row (and stays in-key)
        final ladder = _gridLadder;
        final pitched = res.notes.where((n) => n.kind != 'percussive').toList();
        // shift the whole phrase into the grid's octave first (keeps contour,
        // avoids octave wrap when the hum is sung above/below the grid range)
        final shift = _phraseOctaveShift(pitched.map((n) => n.pitch), ladder);
        final out = <PitchNote>[];
        for (final n in pitched) {
          // backend loop mode stamps integer step/dur_steps; fall back to seconds.
          final step = n.step ?? (n.start / sps).round();
          if (step < 0 || step >= steps) continue;
          final dur = (n.durSteps ?? math.max(1, (n.duration / sps).round()))
              .clamp(1, steps - step);
          final r = _snapToLadder(n.pitch + shift, ladder);
          out.add(PitchNote(midi: r.midi, freq: r.freq, step: step, dur: dur));
        }
        if (out.isEmpty) throw StateError('no notes');
        setState(() => t.pitchNotes.addAll(out));
        count = out.length;
      }
      _toast('Added $count notes from your hum');
    } catch (e) {
      _humFallback();
      _toast('Engine unavailable — used a generated phrase');
    }
  }

  // Fit an engine MIDI note onto the grid's in-key rows. The grid spans ~1
  // octave, so a hum sung higher/lower than the grid would otherwise clamp to
  // the top/bottom row. Instead we FOLD the note by whole octaves into the
  // grid's range first (preserving the melodic shape — a phrase sung an octave
  // up shifts down as a unit), then snap to the nearest in-key rung.
  // whole-octave shift to center the hummed phrase on the grid's range
  // Pure mapping helpers live in music/hum_map.dart (shared with the Python eval
  // mirror). These thin wrappers keep the call sites unchanged.
  int _phraseOctaveShift(Iterable<int> midis, List<Rung> ladder) =>
      phraseOctaveShift(midis, ladder);

  Rung _snapToLadder(int midi, List<Rung> ladder) => snapToLadder(midi, ladder);

  String? _drumKind(eng.Note n) => drumKind(n.drum, n.drumName, n.pitch);

  // generated-phrase fallback (the original behaviour) when the engine fails
  void _humFallback() {
    setState(() {
      final t = _tracks[_activeId]!;
      final kind = _meta.kind;
      if (kind == TrackKind.drums) {
        // main kit → the canonical beat; decoration kit → a light fill on its
        // own kinds (first kind every 2 steps).
        final gen = _meta.decoration
            ? [for (var s = 0; s < _steps; s += 2) DrumNote(kind: _meta.drumKinds!.first, step: s)]
            : genDrums(_steps);
        for (final n in gen) {
          if (!t.drumNotes.any((x) => x.kind == n.kind && x.step == n.step)) t.drumNotes.add(n);
        }
      } else if (kind == TrackKind.bass) {
        t.pitchNotes.addAll(genBass(_bassLadder, _bars));
      } else if (kind == TrackKind.pitched) {
        t.pitchNotes.addAll(genMelody(_ladder, _steps, _rng));
      }
    });
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 1400)),
    );
  }

  void _setBars(int b) {
    if (_songSection != null) return;
    _pushUndo();
    setState(() => _sec.bars = b);
  }

  // ── persistence ───────────────────────────────────────────────────
  Song _snapshot() {
    final flat = flattenSong(_sections);
    return Song(
      id: widget.song.id,
      title: _title.trim().isEmpty ? 'Untitled loop' : _title.trim(),
      key: _keyRoot,
      scale: _scale,
      bpm: _bpm,
      swing: _swing,
      bars: _bars,
      vol: Map.of(_vol),
      mutes: Map.of(_mutes),
      instruments: Map.of(_instruments),
      sections: _sections.map((s) => s.deepCopy()).toList(),
      updatedAt: DateTime.now(),
      wave: buildWave(flat),
    );
  }

  Future<void> _saveNow() async {
    await context.read<LoopStore>().upsert(_snapshot());
    if (!mounted) return;
    setState(() {
      _dirty = false;
      _savedAt = DateTime.now();
      _savedFlash = true;
    });
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _savedFlash = false);
    });
  }

  Future<void> _backWithSave() async {
    await context.read<LoopStore>().upsert(_snapshot());
    if (mounted) Navigator.of(context).pop();
  }

  /// Pro 활성이면 export drawer, 아니면 paywall 먼저. paywall 닫힌 시점에
  /// Pro 가 됐으면 자동으로 export drawer 진입.
  Future<void> _exportOrPaywall() async {
    final store = context.read<LoopStore>();
    debugPrint('[export] tap proActive=${store.proActive}');
    if (!store.proActive) {
      await showPaywallSheet(context, trigger: PaywallTrigger.export);
      if (!mounted) return;
      if (!context.read<LoopStore>().proActive) return; // 결제 안 한 채 닫힘.
    }
    if (!mounted) return;
    debugPrint('[export] opening drawer');
    // union of added instances across sections (kept consistent by _addTrack).
    final extras = <TrackRef>[];
    final seen = <String>{};
    for (final s in _sections) {
      for (final e in s.extras) {
        if (seen.add(e.id)) extras.add(e);
      }
    }
    await showExportDrawer(
      context,
      title: _title,
      sections: _sections,
      bpm: _bpm,
      swing: _swing,
      vol: Map.of(_vol),
      melodyProgram: _instruments['melody'] ?? 0,
      bassProgram: _instruments['bass'] ?? 33,
      melodyDecProgram: _instruments['melodyDec'] ?? 48,
      extras: extras,
      instruments: Map.of(_instruments),
    );
  }

  /// Save indicator 텍스트 — "Saved" (방금) / "Saved · 13:42" (시간 표시) /
  /// "Unsaved" (dirty).
  String _saveLabel() {
    if (_savedAt == null) return _dirty ? 'Unsaved' : '';
    final t = _savedAt!;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return _savedFlash ? 'Saved' : 'Saved · $hh:$mm';
  }

  // ── build ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pitched = _isPitched;
    return Scaffold(
      backgroundColor: LT.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                _topBar(),
                SectionBar(
                  sections: _sections,
                  activeIdx: _activeIdx,
                  songMode: _songSection != null,
                  onSwitch: _switchSection,
                  onAdd: _addSection,
                  onRename: _renameSection,
                  onRepeats: _setRepeats,
                  onDelete: _deleteSection,
                  onLongPress: _openSectionMenu,
                  onPlaySong: _playSong,
                ),
                // arrangement : surface = 2 : 3 vertical split. lane 영역이
                // 화면 커질 때 조금 더 자라도록 1:2 → 2:3 으로 조정 (40% / 60%).
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _playStep,
                      builder: (_, ps, __) => Arrangement(
                        section: _songSection ?? _sec,
                        tracks: _orderedMetas(_songSection ?? _sec),
                        activeId: _activeId,
                        mutes: _mutes,
                        onSelect: (id) => setState(() => _activeId = id),
                        onToggleMute: _toggleMute,
                        // editing only (song-preview is read-only)
                        onAddTrack: _songSection == null ? _openAddTrack : null,
                        onReorder: _songSection == null ? _reorderTracks : null,
                        playing: _playing,
                        playStep: ps,
                        steps: _steps,
                        ranges: _ranges,
                        // song-preview is read-only → no scrubbing there
                        onSeek: _songSection == null ? _seekTo : null,
                      ),
                    ),
                  ),
                ),
                _surfaceHeader(pitched),
                Expanded(
                  flex: 3,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(LTRadius.card),
                        gradient: RadialGradient(
                          center: const Alignment(0, 1.3),
                          radius: 1.0,
                          colors: [_meta.color.withValues(alpha: 0.08), Colors.transparent],
                          stops: const [0, 0.6],
                        ),
                      ),
                      child: _surface(),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: LT.border))),
                  child: TransportBar(
                    playing: _playing,
                    recording: _recording,
                    onPlay: _togglePlay,
                    onStop: _stopAll,
                    onRec: _armRecord,
                    bpm: _bpm,
                    onBpm: (v) => setState(() => _bpm = v),
                    metro: _metro,
                    onMetro: (v) {
                      setState(() => _metro = v);
                      LoopPrefs.instance.setMetro(v); // keep Settings in sync + persist
                    },
                    countIn: _countIn,
                    onCountIn: (v) => setState(() => _countIn = v),
                    onClear: _clearTrack,
                    swing: _swing,
                    onSwing: (v) => setState(() => _swing = v),
                    bars: _bars,
                    onBars: _setBars,
                    showRecord: _activeId != 'vocal',
                  ),
                ),
              ],
            ),
            if (_countDown > 0) _countInOverlay(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    // 좌측 그룹(뒤로/제목/undo/redo)과 우측 그룹(mixer/key/saved/save/export) 으로
    // 분리. Spacer 가 둘 사이를 벌리되, 작은 폰(iPhone SE 등)에선 좌·우 그룹의
    // 자연 너비 합이 부모 폭을 넘기 때문에 각 그룹을 Flexible+FittedBox(scaleDown)
    // 으로 감싸 비율 유지하며 축소. 큰 폰/아이패드는 원본 크기 그대로.
    // _topBar 전용 컴팩트 사이즈 — 헤더 공간 절약 (옵션 B).
    const btnSize = 30.0;
    const pillH = 26.0;
    const pillFS = 11.0;
    const pillPad = 10.0;

    final leftGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconBtn(icon: LtIcons.arrowBack, size: btnSize, tooltip: 'Back', onTap: _backWithSave),
        const SizedBox(width: 8),
        const Ms(LtIcons.edit, size: 14, color: LT.t3),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: IntrinsicWidth(
            child: TextField(
              controller: TextEditingController(text: _title)
                ..selection = TextSelection.collapsed(offset: _title.length),
              onChanged: (v) => _title = v,
              cursorColor: LT.lime,
              style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.t1),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 2),
                border: InputBorder.none,
              ),
            ),
          ),
        ),
      ],
    );

    // 아이콘 전용 버튼은 hold(롱프레스) 시 IconBtn 내부 Tooltip 으로 라벨 노출.
    // Save / Export 의 텍스트 라벨을 빼는 대신 동일한 정보 전달.
    final rightGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Saved indicator — 고정폭 슬롯으로 예약. 라벨이 등장/사라져도 rightGroup
        // 자연 너비 불변 → 다른 버튼들 흔들림/축소 없음.
        SizedBox(
          width: 90,
          child: Align(
            alignment: Alignment.centerRight,
            child: AnimatedSwitcher(
              duration: LTMotion.state,
              child: Text(
                _saveLabel(),
                key: ValueKey(_saveLabel()),
                style: LTType.mono(
                  size: 11,
                  weight: FontWeight.w600,
                  color: _savedFlash ? LT.lime : LT.t3,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _undoRedoBtn(LtIcons.undo, 'Undo', _undo.isNotEmpty, _undoAction),
        const SizedBox(width: 6),
        _undoRedoBtn(LtIcons.redo, 'Redo', _redo.isNotEmpty, _redoAction),
        const SizedBox(width: 8),
        IconBtn(icon: LtIcons.save, size: btnSize, tooltip: 'Save', onTap: _saveNow),
        const SizedBox(width: 8),
        IconBtn(icon: LtIcons.tune, size: btnSize, tooltip: 'Mixer', onTap: _openMixer),
        const SizedBox(width: 8),
        Pill(
          label: '$_keyRoot ${kScales[_scale]!.label}',
          icon: LtIcons.musicNote,
          height: pillH,
          fontSize: pillFS,
          horizontalPadding: pillPad,
          onTap: _openKey,
        ),
        const SizedBox(width: 12),
        // Pro 게이트 — 비-Pro 면 paywall 우선 표시, 통과 후 export drawer 진입.
        // active: true 로 라임 배경 → 1순위 액션 시각 강조.
        IconBtn(
          icon: LtIcons.iosShare,
          size: btnSize,
          active: true,
          tooltip: 'Export',
          onTap: _exportOrPaywall,
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: LT.border))),
      // 우측 그룹은 자연 크기 유지(라벨이 등장해도 버튼 사이즈 그대로). 좌측만
      // 남은 공간(= 부모 폭 − 우측 자연 폭) 안에서 자연 크기를 쓰되, 그게 부족하면
      // FittedBox(scaleDown) 으로 비율 유지하며 축소. Expanded 가 남은 폭 전부를
      // 차지해서 좌측이 우측과 시각적으로 분리되도록 함.
      child: Row(
        children: [
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: leftGroup,
              ),
            ),
          ),
          rightGroup,
        ],
      ),
    );
  }

  Widget _undoRedoBtn(IconData icon, String tip, bool enabled, VoidCallback onTap) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      // _topBar 내부 컴팩트 사이즈 (기본 36 → 30).
      child: IconBtn(icon: icon, size: 30, tooltip: tip, onTap: enabled ? onTap : null),
    );
  }

  Widget _surfaceHeader(bool pitched) {
    final hasInstrument = _activeType == 'melody' || _activeType == 'bass';

    final leftGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 트랙 식별 — melody/bass 는 instrument picker pill 이 라벨 역할까지
        // 겸함 (아이콘은 트랙 컬러로 칠해 식별성 유지). 그 외 트랙은 기존
        // 아이콘 + 라벨.
        if (hasInstrument)
          Pill(
            label: instrumentLabel(_activeType, _instruments[_activeId] ?? _meta.defaultProgram),
            icon: _meta.icon,
            iconColor: _meta.color,
            onTap: _openInstrument,
          )
        else ...[
          Ms(_meta.icon, size: 18, color: _meta.color),
          const SizedBox(width: 8),
          Text(_meta.label, style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.t1)),
        ],
        if (_hasInputToggle) ...[
          const SizedBox(width: 6),
          _inputToggle(),
        ],
        // chord mode (melody-group pads: melody + melody-fill): pad tap = triad
        if (_meta.group == 'melody' && _inputMode == 'pads') ...[
          const SizedBox(width: 6),
          _chordToggle(),
        ],
      ],
    );

    // hint 라벨 — 최대 폭 110dp 슬롯에서:
    //  1. 기본 9pt 로 시도, 2줄 안에 들어가면 그대로
    //  2. 안 들어가면 폰트를 0.5pt 씩 줄여 가며 다시 측정 (하한 6pt)
    //  3. 하한 6pt + 2줄로도 안 들어가면 가로 스크롤로 fallback
    Widget hintSlot(String text) {
      final upper = text.toUpperCase();
      final baseStyle = LTType.microLabel(LT.t3);
      const slotW = 110.0;
      const maxFont = 9.0;
      const minFont = 6.0;

      return SizedBox(
        width: slotW,
        child: LayoutBuilder(
          builder: (context, c) {
            for (double fs = maxFont; fs >= minFont; fs -= 0.5) {
              final style = baseStyle.copyWith(fontSize: fs);
              final tp = TextPainter(
                text: TextSpan(text: upper, style: style),
                textDirection: TextDirection.ltr,
                maxLines: 2,
              )..layout(maxWidth: slotW);
              if (!tp.didExceedMaxLines) {
                return Text(
                  upper,
                  maxLines: 2,
                  softWrap: true,
                  textAlign: TextAlign.right,
                  style: style,
                );
              }
            }
            // 6pt + 2줄로도 안 들어감 → 가로 스크롤로 마저 볼 수 있게.
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Text(upper, maxLines: 1, style: baseStyle.copyWith(fontSize: minFont)),
            );
          },
        ),
      );
    }

    final rightGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // pitched pads: current swipe-able note range (melody/fill/bass).
        if (pitched && _inputMode == 'pads') _rangeReadout(),
        if (pitched) _octaveStepper(),
        if (_activeId != 'vocal') ...[
          const SizedBox(width: 8),
          Pill(label: 'Hum to MIDI', icon: LtIcons.graphicEq, onTap: _openHum),
        ],
        const SizedBox(width: 8),
        if (_inputMode == 'grid' && _meta.kind == TrackKind.drums)
          hintSlot('tap cells to toggle')
        else if (_inputMode == 'grid' && pitched)
          hintSlot('tap · drag to lengthen · auto-merge')
        else
          // Pads 모드의 짧은 hint — 자연 너비 그대로. 빨간 점과 텍스트 간격이
          // hintSlot 의 110dp 고정폭 안에 갇히면 멀어지므로 원래 LtLabel 사용.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 7, height: 7, decoration: const BoxDecoration(color: LT.danger, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              const LtLabel('rec, then tap', color: LT.t3),
            ],
          ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      // Vocal 트랙은 instrument pill/toggle/octave/Hum to MIDI 가 전부 빠져서
      // Row 자연 높이가 줄어 → 트랙 전환 시 화면이 흔들림. SizedBox(height: 32)
      // 로 트랙 종류와 무관하게 일정 높이 보장.
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: leftGroup,
                ),
              ),
            ),
            rightGroup,
          ],
        ),
      ),
    );
  }

  Widget _inputToggle() {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(LTRadius.pill),
        border: Border.all(color: LT.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in const ['pads', 'grid'])
            GestureDetector(
              onTap: () => _setInputMode(v),
              child: Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _inputMode == v ? LT.lime : Colors.transparent,
                  borderRadius: BorderRadius.circular(LTRadius.pill),
                ),
                child: Text(v == 'pads' ? 'Pads' : 'Grid',
                    style: LTType.inter(size: 11, weight: FontWeight.w700, color: _inputMode == v ? LT.bg : LT.t2)),
              ),
            ),
        ],
      ),
    );
  }

  // Chord-mode toggle (melody-group pads only): pad tap places a diatonic triad.
  // Independent per track so melody and melody-fill can differ.
  Widget _chordToggle() {
    final on = _chordOn;
    return GestureDetector(
      onTap: () => setState(() => _chordMode[_activeId] = !on),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? LT.lime : LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.pill),
          border: Border.all(color: on ? LT.lime : LT.border),
        ),
        child: Text('Chord',
            style: LTType.inter(size: 11, weight: FontWeight.w700, color: on ? LT.bg : LT.t2)),
      ),
    );
  }

  Widget _octaveStepper() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconBtn(icon: LtIcons.remove, size: 30, tooltip: 'Octave down', onTap: () => _setOctave(_octave - 1)),
        SizedBox(
          width: 46,
          child: Text('Oct ${_octave > 0 ? '+' : ''}$_octave',
              textAlign: TextAlign.center, style: LTType.mono(size: 11, color: LT.t2)),
        ),
        IconBtn(icon: LtIcons.add, size: 30, tooltip: 'Octave up', onTap: () => _setOctave(_octave + 1)),
      ],
    );
  }

  // Passive status chip showing the current pad range (melody/fill/bass). NOT a
  // control — the pads themselves are swiped to move the range.
  Widget _rangeReadout() {
    final w = _padWindow;
    if (w.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.pill),
          border: Border.all(color: LT.border),
        ),
        child: Text('${w.first.name}–${w.last.name}',
            style: LTType.mono(size: 11, weight: FontWeight.w700, color: LT.t2)),
      ),
    );
  }

  Widget _surface() {
    final kind = _meta.kind;
    final src = (_songSection ?? _sec).tracks[_activeId]!;
    if (kind == TrackKind.drums) {
      final specs = drumSpecsFor(_meta.drumKinds);
      final map = <String, Set<int>>{};
      for (final n in src.drumNotes) {
        (map[n.kind] ??= <int>{}).add(n.step);
      }
      if (_inputMode == 'grid') {
        return ValueListenableBuilder<double>(
          valueListenable: _playStep,
          builder: (_, ps, __) => DrumGrid(
            notes: map,
            onToggle: _toggleDrumCell,
            playStep: ps,
            steps: _steps,
            bars: _bars,
            specs: specs,
          ),
        );
      }
      return ValueListenableBuilder<double>(
        valueListenable: _playStep,
        builder: (_, ps, __) => DrumSurface(
          notes: map,
          onHit: _hitDrum,
          playStep: ps,
          steps: _steps,
          bars: _bars,
          specs: specs,
        ),
      );
    }
    if (kind == TrackKind.pitched || kind == TrackKind.bass) {
      final notes = src.pitchNotes;
      if (_inputMode == 'grid') {
        return ValueListenableBuilder<double>(
          valueListenable: _playStep,
          builder: (_, ps, __) => StepGrid(
            ladder: _gridLadder,
            notes: notes,
            onPlace: _gridPlace,
            onErase: _gridErase,
            playStep: ps,
            accent: _meta.color,
            steps: _steps,
            bars: _bars,
            // vertical drag on the row labels moves the pitch window (same
            // window the pads slide), so the grid reaches the full range.
            windowOffset: _windowOffset.clamp(0, _maxWindow),
            maxOffset: _maxWindow,
            onWindowChanged: _setWindowOffset,
          ),
        );
      }
      // melody / melody-fill / bass: a horizontal strip of the whole in-key
      // ladder; swipe to glide the strip and snap to a pad.
      return NotePads(
        key: ValueKey('pads-$_activeId'),
        ladder: _activeFullLadder,
        visibleCount: _padCount,
        offset: _windowOffset.clamp(0, _maxWindow),
        litMidis: _litMidis,
        accent: _meta.color,
        onDown: _pitchDown,
        onUp: _pitchUp,
        onSlideStart: _padSlideStart,
        onOffsetChanged: _setWindowOffset,
      );
    }
    if (kind == TrackKind.vocal) {
      return VocalSurface(
        clip: _tracks['vocal']!.clip,
        onCommit: _commitVocal,
        onClear: () {
          _pushUndo();
          _audio.stopVocal();
          _vocalPlaying = false;
          setState(() {
            _tracks['vocal']!.clip = null;
            _tracks['vocal']!.vocalPath = null;
          });
        },
      );
    }
    return _surfacePlaceholder();
  }

  Widget _surfacePlaceholder() {
    return Container(
      decoration: BoxDecoration(
        color: LT.surface,
        borderRadius: BorderRadius.circular(LTRadius.card),
        border: Border.all(color: LT.border),
      ),
      child: Center(
        child: Text('${_meta.label} surface — M3–M4', style: LTType.inter(size: 13, color: LT.t3)),
      ),
    );
  }

  Widget _countInOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        alignment: Alignment.center,
        child: Text('$_countDown',
            style: LTType.inter(size: 96, weight: FontWeight.w900, color: LT.lime)),
      ),
    );
  }

  // ── undo / redo ───────────────────────────────────────────────────
  _EditSnapshot _capture() => _EditSnapshot(
        sections: _sections.map((s) => s.deepCopy()).toList(),
        activeIdx: _activeIdx,
        keyRoot: _keyRoot,
        scale: _scale,
        bpm: _bpm,
        swing: _swing,
        vol: Map.of(_vol),
        mutes: Map.of(_mutes),
        title: _title,
      );

  /// Snapshot current state before a mutation. [coalesce] merges rapid bursts
  /// (drag-erase, live recording taps) into a single undo step.
  void _pushUndo({bool coalesce = false}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (coalesce && now - _lastUndoMs < 500) {
      _lastUndoMs = now;
      return;
    }
    _lastUndoMs = now;
    _undo.add(_capture());
    if (_undo.length > 60) _undo.removeAt(0);
    _redo.clear();
  }

  void _restore(_EditSnapshot s) {
    if (_playing || _songSection != null) _stopAll();
    setState(() {
      _sections
        ..clear()
        ..addAll(s.sections.map((x) => x.deepCopy()));
      _activeIdx = s.activeIdx.clamp(0, _sections.length - 1);
      _keyRoot = s.keyRoot;
      _scale = s.scale;
      _bpm = s.bpm;
      _swing = s.swing;
      _vol
        ..clear()
        ..addAll(s.vol);
      _mutes
        ..clear()
        ..addAll(s.mutes);
      _title = s.title;
      _playStep.value = 0;
    });
  }

  void _undoAction() {
    if (_undo.isEmpty) return;
    _redo.add(_capture());
    _restore(_undo.removeLast());
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    _undo.add(_capture());
    _restore(_redo.removeLast());
  }
}

/// Immutable snapshot of the editable song state for undo/redo.
class _EditSnapshot {
  _EditSnapshot({
    required this.sections,
    required this.activeIdx,
    required this.keyRoot,
    required this.scale,
    required this.bpm,
    required this.swing,
    required this.vol,
    required this.mutes,
    required this.title,
  });
  final List<Section> sections;
  final int activeIdx;
  final String keyRoot, scale, title;
  final int bpm;
  final double swing;
  final Map<String, double> vol;
  final Map<String, bool> mutes;
}
