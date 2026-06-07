// LoopTap — Editor (the core screen). README §4.
// Vertical stack: top bar · SONG section bar · arrangement strip · surface
// header · track surface · transport bar. A Ticker-driven transport clock
// sweeps a 2/4-bar loop (16 steps/bar), with swing on odd 16ths.
//
// M1: shell + clock + sections + transport wired. Track surfaces land in M2–M4
// (a placeholder fills the surface area for now).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../audio/loop_audio.dart';
import '../models/loop_models.dart';
import '../music/song_util.dart';
import '../music/theory.dart';
import '../state/loop_store.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';
import '../widgets/arrangement.dart';
import '../widgets/section_bar.dart';
import '../widgets/sheets/hum_modal.dart';
import '../widgets/sheets/export_drawer.dart';
import '../widgets/sheets/key_sheet.dart';
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
  bool _metro = true;
  bool _countIn = false;
  int _octave = 0;
  String _melodyInput = 'pads'; // 'pads' | 'grid'
  int _countDown = 0; // count-in overlay (0 = none)

  // glow: currently-sounding notes
  Set<int> _litMidis = {};
  Set<String> _litDrums = {};

  // playhead (driven every frame — kept off setState to avoid full rebuilds)
  final ValueNotifier<double> _playStep = ValueNotifier(0);

  // whole-song preview (non-null while "Play song" is active)
  Section? _songSection;
  int? _songSteps;

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

  Map<String, PitchRange> get _ranges {
    final l = _ladder, b = _bassLadder;
    return {
      'melody': PitchRange(l.first.midi - 2, l.last.midi + 2),
      'bass': PitchRange(b.first.midi - 2, b.last.midi + 2),
    };
  }

  @override
  void initState() {
    super.initState();
    _audio.ensure();
  }

  @override
  void dispose() {
    _ticker?.dispose();
    _playStep.dispose();
    _audio.stopAll();
    super.dispose();
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
      _trigger(((_nextAbs % steps) + steps) % steps);
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
    final litD = <String>{};
    if (!(_mutes['melody'] ?? false)) {
      for (final n in T['melody']!.pitchNotes.where((n) => n.step == step)) {
        _audio.playPitch(n.midi, bass: false, vol: _vol['melody'] ?? 0.85, durSec: dsec(n.dur));
        litM.add(n.midi);
      }
    }
    if (!(_mutes['bass'] ?? false)) {
      for (final n in T['bass']!.pitchNotes.where((n) => n.step == step)) {
        _audio.playPitch(n.midi, bass: true, vol: _vol['bass'] ?? 0.85, durSec: dsec(n.dur));
        litM.add(n.midi);
      }
    }
    if (!(_mutes['drums'] ?? false)) {
      for (final n in T['drums']!.drumNotes.where((n) => n.step == step)) {
        _audio.playDrum(n.kind, vol: _vol['drums'] ?? 1);
        litD.add(n.kind);
      }
    }
    if (_metro && step % kStepsPerBeat == 0) {
      _audio.click(step % (kStepsPerBeat * kBeatsPerBar) == 0);
    }
    if (litM.isNotEmpty || litD.isNotEmpty || _litMidis.isNotEmpty || _litDrums.isNotEmpty) {
      setState(() {
        _litMidis = litM;
        _litDrums = litD;
      });
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
      } else {
        _stopClock();
      }
    });
  }

  void _stopAll() {
    _stopClock();
    _audio.stopAll();
    _playStep.value = 0;
    setState(() {
      _playing = false;
      _recording = false;
      _litMidis = {};
      _litDrums = {};
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

  void _addSection() {
    if (_playing) _stopAll();
    final name = String.fromCharCode(65 + _sections.length % 26);
    final ns = _sec.deepCopy()
      ..id = 'sec${DateTime.now().millisecondsSinceEpoch}'
      ..name = name
      ..repeats = 1;
    setState(() {
      _sections.add(ns);
      _activeIdx = _sections.length - 1;
      _playStep.value = 0;
    });
  }

  void _deleteSection(int idx) {
    if (_sections.length <= 1) return;
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

  void _setRepeats(int idx, int r) =>
      setState(() => _sections[idx].repeats = r.clamp(1, 8));

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
      final s = _quantStep();
      final dn = _tracks['drums']!.drumNotes;
      if (!dn.any((x) => x.kind == kind && x.step == s)) {
        setState(() => dn.add(DrumNote(kind: kind, step: s)));
      }
    }
  }

  // pending hold timing per midi (live pads): midi -> (step, pressedAtMs)
  final Map<int, ({int step, int t})> _pending = {};

  int _durFromHold(int ms) =>
      (ms / 1000 * (_bpm / 60) * kStepsPerBeat).round().clamp(1, _steps);

  void _pitchDown(Rung n, {required bool bass}) {
    _audio.playPitch(n.midi, bass: bass, vol: _vol[_activeId] ?? 0.85);
    if (_recording && _playing && _songSection == null) {
      _pending[n.midi] = (step: _quantStep(), t: DateTime.now().millisecondsSinceEpoch);
    }
  }

  void _pitchUp(Rung n) {
    final p = _pending.remove(n.midi);
    if (p == null) return;
    final dur = _durFromHold(DateTime.now().millisecondsSinceEpoch - p.t);
    _placePitched(_activeId, n, p.step, p.step + dur - 1);
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

  void _gridPlace(Rung n, int a, int b) {
    _audio.playPitch(n.midi, bass: false, vol: _vol['melody'] ?? 0.85);
    _placePitched('melody', n, a, b);
  }

  void _gridErase(Rung n, int step) {
    setState(() {
      _tracks['melody']!.pitchNotes.removeWhere(
        (x) => x.midi == n.midi && step >= x.step && step < x.step + x.dur,
      );
    });
  }

  void _clearTrack() {
    setState(() {
      final t = _tracks[_activeId]!;
      t.pitchNotes.clear();
      t.drumNotes.clear();
      t.clip = null;
    });
  }

  // ── sheets ────────────────────────────────────────────────────────
  void _openKey() {
    showKeySheet(
      context,
      root: _keyRoot,
      scale: _scale,
      onPick: (r, s) => setState(() {
        _keyRoot = r;
        _scale = s;
      }),
    );
  }

  void _openMixer() {
    showMixerSheet(
      context,
      vol: _vol,
      mutes: _mutes,
      onVol: (id, v) => setState(() => _vol[id] = v),
      onToggleMute: (id) => setState(() => _mutes[id] = !(_mutes[id] ?? false)),
    );
  }

  void _openHum() {
    _audio.ensure();
    showHumModal(
      context,
      trackLabel: _meta.label,
      accent: _meta.color,
      onConvert: _humConvert,
    );
  }

  void _humConvert() {
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

  void _setBars(int b) {
    if (_songSection != null) return;
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
      sections: _sections.map((s) => s.deepCopy()).toList(),
      updatedAt: DateTime.now(),
      wave: buildWave(flat),
    );
  }

  Future<void> _saveNow() async {
    await context.read<LoopStore>().upsert(_snapshot());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Saved'), duration: Duration(milliseconds: 1200)),
    );
  }

  Future<void> _backWithSave() async {
    await context.read<LoopStore>().upsert(_snapshot());
    if (mounted) Navigator.of(context).pop();
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
                  onPlaySong: _playSong,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                  child: ValueListenableBuilder<double>(
                    valueListenable: _playStep,
                    builder: (_, ps, __) => Arrangement(
                      section: _songSection ?? _sec,
                      activeId: _activeId,
                      mutes: _mutes,
                      onSelect: (id) => setState(() => _activeId = id),
                      onToggleMute: (id) => setState(() => _mutes[id] = !(_mutes[id] ?? false)),
                      playStep: ps,
                      steps: _steps,
                      ranges: _ranges,
                    ),
                  ),
                ),
                _surfaceHeader(pitched),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
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
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
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
                    onMetro: (v) => setState(() => _metro = v),
                    countIn: _countIn,
                    onCountIn: (v) => setState(() => _countIn = v),
                    onClear: _clearTrack,
                    swing: _swing,
                    onSwing: (v) => setState(() => _swing = v),
                    bars: _bars,
                    onBars: _setBars,
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
          const Spacer(),
          IconBtn(icon: LtIcons.tune, tooltip: 'Mixer', onTap: _openMixer),
          const SizedBox(width: 8),
          Pill(label: '$_keyRoot ${kScales[_scale]!.label}', icon: LtIcons.musicNote, onTap: _openKey),
          const SizedBox(width: 8),
          Pill(label: 'Save', icon: LtIcons.save, onTap: _saveNow),
          const SizedBox(width: 8),
          Pill(
            label: 'Export',
            icon: LtIcons.iosShare,
            tone: PillTone.lime,
            onTap: () => showExportDrawer(context, title: _title, sections: _sections, bpm: _bpm),
          ),
        ],
      ),
    );
  }

  Widget _surfaceHeader(bool pitched) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
      child: Row(
        children: [
          Ms(_meta.icon, size: 18, color: _meta.color),
          const SizedBox(width: 8),
          Text(_meta.label, style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.t1)),
          if (_activeId == 'melody') ...[
            const SizedBox(width: 6),
            _melodyToggle(),
          ],
          const Spacer(),
          if (pitched) _octaveStepper(),
          if (_activeId != 'vocal') ...[
            const SizedBox(width: 8),
            Pill(label: 'Hum to MIDI', icon: LtIcons.graphicEq, onTap: _openHum),
          ],
          const SizedBox(width: 8),
          LtLabel(
            _activeId == 'melody' && _melodyInput == 'grid'
                ? 'tap · drag to lengthen · auto-merge'
                : '● rec, then tap',
            color: LT.t3,
          ),
        ],
      ),
    );
  }

  Widget _melodyToggle() {
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
              onTap: () => setState(() => _melodyInput = v),
              child: Container(
                height: 26,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _melodyInput == v ? LT.lime : Colors.transparent,
                  borderRadius: BorderRadius.circular(LTRadius.pill),
                ),
                child: Text(v == 'pads' ? 'Pads' : 'Grid',
                    style: LTType.inter(size: 11, weight: FontWeight.w700, color: _melodyInput == v ? LT.bg : LT.t2)),
              ),
            ),
        ],
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
        return ValueListenableBuilder<double>(
          valueListenable: _playStep,
          builder: (_, ps, __) => DrumSurface(
            notes: map,
            litDrums: _litDrums,
            onHit: _hitDrum,
            playStep: ps,
            steps: _steps,
            bars: _bars,
          ),
        );
      case 'melody':
        final notes = (_songSection ?? _sec).tracks['melody']!.pitchNotes;
        if (_melodyInput == 'grid') {
          return ValueListenableBuilder<double>(
            valueListenable: _playStep,
            builder: (_, ps, __) => StepGrid(
              ladder: _ladder,
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
        return NotePads(
          ladder: _ladder,
          litMidis: _litMidis,
          accent: _meta.color,
          onDown: (n) => _pitchDown(n, bass: false),
          onUp: _pitchUp,
        );
      case 'bass':
        return BassPads(
          bassLadder: _bassLadder,
          litMidis: _litMidis,
          accent: _meta.color,
          onDown: (n) => _pitchDown(n, bass: true),
          onUp: _pitchUp,
        );
      case 'vocal':
        return VocalSurface(
          clip: _tracks['vocal']!.clip,
          onCommit: (wf) => setState(() => _tracks['vocal']!.clip = wf),
          onClear: () => setState(() => _tracks['vocal']!.clip = null),
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

}
