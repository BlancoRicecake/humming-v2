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
  int _octave = 0;
  // input mode per track ('pads' | 'grid') — melody/bass/drums each have one
  String _melodyInput = 'pads';
  String _bassInput = 'pads';
  String _drumsInput = 'pads';
  // melody chord mode: a pad tap places a key-based diatonic triad, not one note
  bool _melodyChord = false;
  // per-track GM instrument (program number) — drives live sound + MIDI export
  late final Map<String, int> _instruments = Map.of(widget.song.instruments);
  int _countDown = 0; // count-in overlay (0 = none)

  bool get _hasInputToggle => _activeId == 'melody' || _activeId == 'bass' || _activeId == 'drums';
  String get _inputMode => switch (_activeId) {
        'bass' => _bassInput,
        'drums' => _drumsInput,
        _ => _melodyInput,
      };
  void _setInputMode(String v) => setState(() {
        switch (_activeId) {
          case 'bass':
            _bassInput = v;
          case 'drums':
            _drumsInput = v;
          default:
            _melodyInput = v;
        }
      });

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
  TrackMeta get _meta => trackById(_activeId);

  List<Rung> get _ladder => buildLadder(_keyRoot, _scale, 4 + _octave, 8);
  List<Rung> get _bassLadder {
    final full = buildLadder(_keyRoot, _scale, 2, 8);
    return const [0, 3, 4, 5, 7].map((i) => full[i]).toList();
  }

  // full 8-row in-key bass ladder (one octave down) for the bass Grid
  List<Rung> get _bassGridLadder => buildLadder(_keyRoot, _scale, 2 + _octave, 8);

  /// active pitched ladder for the Grid surface (melody high / bass low)
  List<Rung> get _gridLadder => _activeId == 'bass' ? _bassGridLadder : _ladder;

  Map<String, PitchRange> get _ranges {
    final l = _ladder, b = _bassLadder;
    return {
      'melody': PitchRange(l.first.midi - 2, l.last.midi + 2),
      'bass': PitchRange(b.first.midi - 2, b.last.midi + 2),
    };
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
    // apply this song's chosen instruments, then warm the synth
    _audio.setPrograms(melody: _instruments['melody'], bass: _instruments['bass']);
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
        if (_vocalPlaying) _audio.seekVocalToStart();
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
    final litM = <int>{};
    if (!(_mutes['melody'] ?? false)) {
      for (final n in T['melody']!.pitchNotes.where((n) => n.step == step)) {
        if (_freshThisLoop.contains('melody:${n.midi}:$step')) continue;
        _audio.playPitch(n.midi, bass: false, vol: _vol['melody'] ?? 0.85, durSec: dsec(n.dur));
        litM.add(n.midi);
      }
    }
    if (!(_mutes['bass'] ?? false)) {
      for (final n in T['bass']!.pitchNotes.where((n) => n.step == step)) {
        if (_freshThisLoop.contains('bass:${n.midi}:$step')) continue;
        _audio.playPitch(n.midi, bass: true, vol: _vol['bass'] ?? 0.85, durSec: dsec(n.dur));
        litM.add(n.midi);
      }
    }
    // drums play but don't drive pad lighting (press-only feedback — item 2)
    if (!(_mutes['drums'] ?? false)) {
      for (final n in T['drums']!.drumNotes.where((n) => n.step == step)) {
        if (_freshThisLoop.contains('drums:${n.kind}:$step')) continue;
        _audio.playDrum(n.kind, vol: _vol['drums'] ?? 1);
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
    disp.tracks['bass'] = TrackData(notes: flat.bass);
    disp.tracks['drums'] = TrackData(drums: flat.drums);
    setState(() {
      _songSection = disp;
      _songSteps = flat.steps;
      _playStep.value = 0;
      _playing = true;
      _startClock();
    });
  }

  // ── editing ───────────────────────────────────────────────────────
  int _quantStep() => _playStep.value.round() % _steps;

  void _hitDrum(String kind) {
    _audio.playDrum(kind, vol: _vol['drums'] ?? 1);
    if (_recording && _playing && _songSection == null) {
      _pushUndo(coalesce: true);
      final s = _quantStep();
      final dn = _tracks['drums']!.drumNotes;
      if (!dn.any((x) => x.kind == kind && x.step == s)) {
        setState(() => dn.add(DrumNote(kind: kind, step: s)));
      }
      // heard live now → don't let the clock replay it this loop pass
      _freshThisLoop.add('drums:$kind:$s');
    }
  }

  // drums Grid mode: tap a cell to toggle a hit at (kind, step)
  void _toggleDrumCell(String kind, int step) {
    if (_songSection != null) return; // editing disabled while previewing the song
    _pushUndo(coalesce: true);
    final dn = _tracks['drums']!.drumNotes;
    final i = dn.indexWhere((x) => x.kind == kind && x.step == step);
    setState(() {
      if (i >= 0) {
        dn.removeAt(i);
      } else {
        dn.add(DrumNote(kind: kind, step: step));
        _audio.playDrum(kind, vol: _vol['drums'] ?? 1);
      }
    });
  }

  // pending hold timing per midi (live pads): midi -> (step, pressedAtMs)
  final Map<int, ({int step, int t})> _pending = {};

  int _durFromHold(int ms) =>
      (ms / 1000 * (_bpm / 60) * kStepsPerBeat).round().clamp(1, _steps);

  /// The midis a pad press produces: a diatonic triad in melody chord mode,
  /// otherwise just the pressed note.
  List<int> _chordMidis(int rootMidi) => (_activeId == 'melody' && _melodyChord)
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

  void _pitchDown(Rung n, {required bool bass}) {
    // held note(s): they sound while pressed, so what you hear == what's recorded
    for (final m in _chordMidis(n.midi)) {
      _audio.noteOnLive(m, bass: bass, vol: _vol[_activeId] ?? 0.85);
    }
    if (_recording && _playing && _songSection == null) {
      _pending[n.midi] = (step: _quantStep(), t: DateTime.now().millisecondsSinceEpoch);
    }
  }

  void _pitchUp(Rung n) {
    final bass = _activeId == 'bass';
    final midis = _chordMidis(n.midi);
    for (final m in midis) {
      _audio.noteOffLive(m, bass: bass);
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

  // grid place/erase work on the active pitched track (melody or bass)
  void _gridPlace(Rung n, int a, int b) {
    _pushUndo(coalesce: true);
    final bass = _activeId == 'bass';
    // preview sound length matches the drawn note length
    final sps = 60 / _bpm / kStepsPerBeat;
    final durSec = (((a - b).abs() + 1) * sps * 0.95).clamp(0.12, 8.0);
    _audio.playPitch(n.midi, bass: bass, vol: _vol[_activeId] ?? 0.85, durSec: durSec);
    _placePitched(_activeId, n, a, b);
    _freshThisLoop.add('$_activeId:${n.midi}:${a < b ? a : b}');
  }

  void _gridErase(Rung n, int step) {
    _pushUndo(coalesce: true);
    setState(() {
      _tracks[_activeId]!.pitchNotes.removeWhere(
        (x) => x.midi == n.midi && step >= x.step && step < x.step + x.dur,
      );
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

  /// Start the recorded vocal with the loop (single-section play only for now).
  void _startVocalIfAny() {
    if (_songSection != null) return; // "Play song" multi-section vocal = follow-up
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
    final id = _activeId; // 'melody' | 'bass'
    showInstrumentSheet(
      context,
      trackId: id,
      trackLabel: trackById(id).label,
      currentProgram: _instruments[id] ?? (id == 'bass' ? 33 : 0),
      onPick: (program) {
        _pushUndo(coalesce: true);
        setState(() => _instruments[id] = program);
        _audio.setPrograms(
          melody: id == 'melody' ? program : null,
          bass: id == 'bass' ? program : null,
        );
        // preview the new timbre on an in-key note in that track's own register
        // (bass uses the low bass ladder root; melody an in-key mid note).
        final isBass = id == 'bass';
        final ladder = isBass ? _bassLadder : _ladder;
        final preview = ladder.isNotEmpty ? ladder[isBass ? 0 : 2].midi : 60;
        _audio.playPitch(preview, bass: isBass, vol: _vol[id] ?? 0.85, durSec: 0.5);
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
    final drums = _activeId == 'drums';
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
      if (_activeId == 'drums') {
        for (final n in genDrums(_steps)) {
          if (!t.drumNotes.any((x) => x.kind == n.kind && x.step == n.step)) t.drumNotes.add(n);
        }
      } else if (_activeId == 'bass') {
        t.pitchNotes.addAll(genBass(_bassLadder, _bars));
      } else if (_activeId == 'melody') {
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
      await showPaywallSheet(context);
      if (!mounted) return;
      if (!context.read<LoopStore>().proActive) return; // 결제 안 한 채 닫힘.
    }
    if (!mounted) return;
    debugPrint('[export] opening drawer');
    await showExportDrawer(
      context,
      title: _title,
      sections: _sections,
      bpm: _bpm,
      melodyProgram: _instruments['melody'] ?? 0,
      bassProgram: _instruments['bass'] ?? 33,
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
    final pitched = _activeId == 'melody' || _activeId == 'bass';
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
                // arrangement : surface = 1 : 2 vertical split (user choice)
                Expanded(
                  flex: 1,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                    child: ValueListenableBuilder<double>(
                      valueListenable: _playStep,
                      builder: (_, ps, __) => Arrangement(
                        section: _songSection ?? _sec,
                        activeId: _activeId,
                        mutes: _mutes,
                        onSelect: (id) => setState(() => _activeId = id),
                        onToggleMute: _toggleMute,
                        playStep: ps,
                        steps: _steps,
                        ranges: _ranges,
                      ),
                    ),
                  ),
                ),
                _surfaceHeader(pitched),
                Expanded(
                  flex: 2,
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: LT.border))),
      child: Row(
        children: [
          IconBtn(icon: LtIcons.arrowBack, tooltip: 'Back', onTap: _backWithSave),
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
          const SizedBox(width: 10),
          _undoRedoBtn(LtIcons.undo, 'Undo', _undo.isNotEmpty, _undoAction),
          const SizedBox(width: 6),
          _undoRedoBtn(LtIcons.redo, 'Redo', _redo.isNotEmpty, _redoAction),
          const Spacer(),
          IconBtn(icon: LtIcons.tune, tooltip: 'Mixer', onTap: _openMixer),
          const SizedBox(width: 8),
          Pill(label: '$_keyRoot ${kScales[_scale]!.label}', icon: LtIcons.musicNote, onTap: _openKey),
          const SizedBox(width: 8),
          // Saved indicator — Save pill 왼쪽에 두어 Export 와 시각적 간섭 방지.
          if (_saveLabel().isNotEmpty) ...[
            AnimatedSwitcher(
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
            const SizedBox(width: 8),
          ],
          Pill(label: 'Save', icon: LtIcons.save, onTap: _saveNow),
          const SizedBox(width: 12),
          // Pro 게이트 — 비-Pro 면 paywall 우선 표시, 통과 후 export drawer 진입.
          Pill(
            label: 'Export',
            icon: LtIcons.iosShare,
            tone: PillTone.lime,
            onTap: _exportOrPaywall,
          ),
        ],
      ),
    );
  }

  Widget _undoRedoBtn(IconData icon, String tip, bool enabled, VoidCallback onTap) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: IconBtn(icon: icon, tooltip: tip, onTap: enabled ? onTap : null),
    );
  }

  Widget _surfaceHeader(bool pitched) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Row(
        children: [
          Ms(_meta.icon, size: 18, color: _meta.color),
          const SizedBox(width: 8),
          Text(_meta.label, style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.t1)),
          if (_hasInputToggle) ...[
            const SizedBox(width: 6),
            _inputToggle(),
          ],
          // chord mode (melody pads only): a pad tap = a key-based triad
          if (_activeId == 'melody' && _inputMode == 'pads') ...[
            const SizedBox(width: 6),
            _chordToggle(),
          ],
          // per-track instrument picker (melody/bass)
          if (_activeId == 'melody' || _activeId == 'bass') ...[
            const SizedBox(width: 6),
            Pill(
              label: instrumentLabel(_activeId, _instruments[_activeId] ?? (_activeId == 'bass' ? 33 : 0)),
              icon: LtIcons.piano,
              onTap: _openInstrument,
            ),
          ],
          const Spacer(),
          if (pitched) _octaveStepper(),
          if (_activeId != 'vocal') ...[
            const SizedBox(width: 8),
            Pill(label: 'Hum to MIDI', icon: LtIcons.graphicEq, onTap: _openHum),
          ],
          const SizedBox(width: 8),
          if (_inputMode == 'grid' && _activeId == 'drums')
            const LtLabel('tap cells to toggle', color: LT.t3)
          else if (_inputMode == 'grid' && pitched)
            const LtLabel('tap · drag to lengthen · auto-merge', color: LT.t3)
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 7, height: 7, decoration: const BoxDecoration(color: LT.danger, shape: BoxShape.circle)),
                const SizedBox(width: 5),
                const LtLabel('rec, then tap', color: LT.t3),
              ],
            ),
        ],
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

  // Melody chord-mode toggle (pads only): pad tap places a diatonic triad.
  Widget _chordToggle() {
    final on = _melodyChord;
    return GestureDetector(
      onTap: () => setState(() => _melodyChord = !on),
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
        IconBtn(icon: LtIcons.remove, size: 30, tooltip: 'Octave down', onTap: () => setState(() => _octave = (_octave - 1).clamp(-2, 2))),
        SizedBox(
          width: 34,
          child: Text('8va${_octave >= 0 ? '+' : ''}$_octave',
              textAlign: TextAlign.center, style: LTType.mono(size: 11, color: LT.t2)),
        ),
        IconBtn(icon: LtIcons.add, size: 30, tooltip: 'Octave up', onTap: () => setState(() => _octave = (_octave + 1).clamp(-2, 2))),
      ],
    );
  }

  Widget _surface() {
    switch (_activeId) {
      case 'drums':
        final dn = (_songSection ?? _sec).tracks['drums']!.drumNotes;
        final map = <String, Set<int>>{};
        for (final n in dn) {
          (map[n.kind] ??= <int>{}).add(n.step);
        }
        if (_drumsInput == 'grid') {
          return ValueListenableBuilder<double>(
            valueListenable: _playStep,
            builder: (_, ps, __) => DrumGrid(
              notes: map,
              onToggle: _toggleDrumCell,
              playStep: ps,
              steps: _steps,
              bars: _bars,
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
          ),
        );
      case 'melody':
      case 'bass':
        final bass = _activeId == 'bass';
        final notes = (_songSection ?? _sec).tracks[_activeId]!.pitchNotes;
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
            ),
          );
        }
        if (bass) {
          return BassPads(
            bassLadder: _bassLadder,
            litMidis: _litMidis,
            accent: _meta.color,
            onDown: (n) => _pitchDown(n, bass: true),
            onUp: _pitchUp,
          );
        }
        return NotePads(
          ladder: _ladder,
          litMidis: _litMidis,
          accent: _meta.color,
          onDown: (n) => _pitchDown(n, bass: false),
          onUp: _pitchUp,
        );
      case 'vocal':
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
      default:
        return _surfacePlaceholder();
    }
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
