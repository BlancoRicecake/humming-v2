// LoopTap — Editor (the core screen). README §4.
// Vertical stack: top bar · SONG section bar · arrangement strip · surface
// header · track surface · transport bar. A Ticker-driven transport clock
// sweeps a 2/4-bar loop (16 steps/bar), with swing on odd 16ths.
//
// M1: shell + clock + sections + transport wired. Track surfaces land in M2–M4
// (a placeholder fills the surface area for now).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../api/engine_api.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/models.dart' as eng;
import '../audio/loop_audio.dart';
import '../models/loop_models.dart';
import '../music/hum_map.dart';
import '../music/instruments.dart';
import '../music/song_util.dart';
import '../music/soundfont_catalog.dart';
import '../music/theory.dart';
import '../music/wav_codec.dart';
import '../music/wav_export.dart' show bounceVocalClips, vocalTrackIds;
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
import '../../audio/headset.dart';
import '../widgets/sheets/mixer_sheet.dart';
import '../widgets/sheets/vocal_record_modal.dart';
import '../widgets/sheets/vocal_editor.dart';
import '../widgets/surfaces/drum_surface.dart';
import '../widgets/surfaces/fill_launchpad.dart';
import '../widgets/surfaces/live_pads.dart';
import '../widgets/surfaces/step_grid.dart';
import '../widgets/surfaces/vocal_surface.dart';
import '../widgets/transport_bar.dart';
import '../../services/clarity_service.dart';

class EditScreen extends StatefulWidget {
  const EditScreen({super.key, required this.song});
  final Song song;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

// TickerProviderStateMixin (not Single*) — the transport clock disposes and
// re-creates its Ticker on every play/stop, which Single* would assert against.
class _EditScreenState extends State<EditScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final LoopAudio _audio = LoopAudio.instance;

  // ── persisted-ish song state ──
  late String _title = widget.song.title;
  // One controller for the title field, owned by the State (C21) — rebuilding
  // it per build reset the cursor on every keystroke.
  late final TextEditingController _titleCtl =
      TextEditingController(text: widget.song.title);
  late String _keyRoot = widget.song.key;
  // unknown scale names (old builds / hand-edited saves) fall back to minor —
  // every kScales lookup below would otherwise `!`-crash (C5).
  late String _scale =
      kScales.containsKey(widget.song.scale) ? widget.song.scale : 'minor';
  late int _bpm = widget.song.bpm;
  late double _swing = widget.song.swing;
  late final Map<String, double> _vol = Map.of(widget.song.vol);
  late final Map<String, bool> _mutes = Map.of(widget.song.mutes);

  // ── sections (each an independent loop × repeats) ──
  late final List<Section> _sections =
      widget.song.sections.map((s) => s.deepCopy()).toList();
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
  // power-chord mode per track id: a pad tap places a root + 5th + octave power
  // chord (no third). Mutually exclusive with chord mode — enabling one clears
  // the other. Also melody-group pads only.
  final Map<String, bool> _powerMode = {};
  bool get _powerOn => _powerMode[_activeId] ?? false;
  // per-track GM instrument (program number) — drives live sound + MIDI export
  late final Map<String, int> _instruments = Map.of(widget.song.instruments);
  int _countDown = 0; // count-in overlay (0 = none)

  bool get _hasInputToggle => _meta.kind != TrackKind.vocal;
  String get _inputMode => _inputModes[_activeId] ?? 'pads';
  void _setInputMode(String v) => setState(() => _inputModes[_activeId] = v);

  // Active-track kind helpers.
  bool get _isBass => _meta.kind == TrackKind.bass;
  bool get _isPitched =>
      _meta.kind == TrackKind.pitched || _meta.kind == TrackKind.bass;

  // glow: currently-sounding pitched notes (drums use press-only feedback)
  /// Pads currently lit by playback. A ValueNotifier, not State: it changes
  /// on nearly every 16th step and only NotePads reads it, so a setState here
  /// rebuilt the whole editor several times a second (audit C22).
  final ValueNotifier<Set<int>> _litMidis = ValueNotifier(const {});

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
  // True while the live vocal is a loop-length file looping natively in the
  // player (a padded section mix, or an aligned single take) — the wrap-time
  // re-sync in _onTick is then skipped (it would only add a glitch).
  bool _vocalLoopNative = false;
  // Play song: section-instance start step -> that section's vocalPath (or null).
  // The current section's vocal switches in as the playhead crosses each boundary.
  Map<int, String?>? _songVocalSched;
  // Per-section bounced vocal mix: all vocal-kind lanes' clips → one loop-length
  // WAV basename, so multiple takes / Audio lanes / trims play live. Key = section
  // id; '' = "computed, just use the raw single take". Cleared on record/edit.
  final Map<String, String> _vocalMix = {};
  // True while the live vocal is a bounced section MIX (lane levels baked in,
  // played at unity) rather than a raw single take (played at vol['vocal']).
  bool _vocalIsMix = false;
  // A vocal-lane level changed while a mix was playing: rebounce + restart it
  // at the next loop start so the change is heard in sync (C8).
  bool _vocalRestartAtWrap = false;

  // ── song-level continuous vocal take (recorded over the WHOLE song) ──
  // Local mirror of widget.song.songVocal*; written back in _snapshot. Plays
  // from step 0 during Play Song, replacing the per-section vocal schedule.
  late String? _songVocalPath = widget.song.songVocalPath;
  late List<double>? _songVocalPeaks = widget.song.songVocalPeaks;
  late int? _songVocalBpm = widget.song.songVocalBpm;
  late int? _songVocalBars = widget.song.songVocalBars;
  bool _songVocalActive = false; // the live vocal currently IS the song-level take

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

  /// [tracks][id], falling back to the drums lane when [id] is dangling (e.g.
  /// an added track that an undo removed, or a section without it) — never a
  /// `!` crash (C2).
  TrackData _trackIn(Map<String, TrackData> tracks, String id) =>
      tracks[id] ?? tracks['drums'] ?? (tracks['drums'] = TrackData());
  TrackData get _activeTrack => _trackIn(_tracks, _activeId);

  /// Re-point the active track at 'drums' when the current section doesn't
  /// have it (undo removed an added track / switched to a section without it).
  void _ensureActiveIdValid() {
    if (!_tracks.containsKey(_activeId)) _activeId = 'drums';
  }
  /// The Beat-Fill launchpad's 6 pad sounds for the rendered section (preview
  /// section when previewing the song, else the editing section).
  List<String> get _fillKinds => (_songSection ?? _sec).fillKinds;
  int get _bars => _sec.bars;
  int get _steps => _songSteps ?? stepsForBars(_bars);

  // Total bars across the whole arrangement (every section instance) — the
  // song-level vocal is recorded as one continuous "loop" this long.
  int get _songTotalBars {
    var b = 0;
    for (final sec in _sections) {
      b += sec.bars * sec.repeats;
    }
    return b;
  }

  // The full track-meta list (base 6 + added instances) for a section, and for
  // the active editing section. _meta resolves the active track from it so added
  // instances get their own channel/label/instrument like the base tracks.
  List<TrackMeta> _metasFor(Section s) => sectionTrackMetas(s.extras);
  List<TrackMeta> get _editMetas => _metasFor(_sec);
  TrackMeta get _meta => _editMetas.firstWhere(
    (t) => t.id == _activeId,
    orElse: () => _editMetas.first,
  );

  /// Base track type of the active track — an added instance's type, or the id
  /// itself for a base track. Used for type-keyed lookups (instrument list etc.).
  String get _activeType {
    for (final e in _sec.extras) {
      if (e.id == _activeId) return e.type;
    }
    return _activeId;
  }

  // Each track — including every drum track (base drums, beat-fill, and added
  // instances) — owns its own instrument/kit, keyed by its own id.
  String get _instrumentTargetId => _activeId;

  // The vocal-kind track currently being edited — the base 'vocal' lane or an
  // added "Audio" lane. Vocal record/edit/autotune handlers operate on THIS id
  // (they're only reachable while a vocal-kind surface is active); falls back to
  // 'vocal' otherwise.
  String get _vocalId => _meta.kind == TrackKind.vocal ? _activeId : 'vocal';

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
      _dirty = true;
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
    final w =
        (MediaQuery.maybeOf(context)?.size.width ?? 0) -
        32; // surface h-padding
    return math.min(padCountForWidth(w), _activeFullLadder.length);
  }

  /// Active pitched track's program + whether it's a guitar (drives guitar
  /// chord voicing, strum and the lower guitar register).
  int get _activeProgram => _instruments[_activeId] ?? _meta.defaultProgram;
  bool get _activeIsGuitar => isGuitarProgram(_activeProgram);

  // Guitars sit an octave lower than the generic melody register so the pads
  // land in a real guitar's playing range (≈E2–E6).
  List<Rung> get _melodyFullLadder =>
      buildLadder(_keyRoot, _scale, (_activeIsGuitar ? 2 : 3) + _melodyOctave, 22);
  List<Rung> get _bassFullLadder =>
      buildLadder(_keyRoot, _scale, 1 + _bassOctave, 22);
  List<Rung> get _activeFullLadder =>
      _isBass ? _bassFullLadder : _melodyFullLadder;
  int get _windowOffset => _isBass ? _bassWindow : _melodyWindow;
  int get _maxWindow =>
      (_activeFullLadder.length - _padCount).clamp(0, _activeFullLadder.length);

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
  // _dirty: 명시적 Save / autosave 이후 추가 입력 여부 — 모든 편집은 _pushUndo
  // 를 지나므로 거기서 true, 저장 시 false (C24).
  Timer? _autosaveTimer;
  bool _dirty = false;
  DateTime? _savedAt;
  bool _savedFlash = false;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // apply this song's chosen instruments (per pitched channel), then warm the synth
    _audio.setPrograms({
      for (final t in kPitchedTracks)
        t.channel: _instruments[t.id] ?? t.defaultProgram,
    });
    _applyDrumKits();
    _audio.prewarm();
    // Pre-download any runtime-catalog instruments this song uses so live
    // playback + export resolve the real SF2 (else they fall back to GM until
    // fetched). Fire-and-forget; _bindChannel re-checks at play time.
    for (final p in _instruments.values) {
      if (isDynamicSlot(p)) SoundfontCatalog.instance.ensureDownloaded(p);
    }
    // pre-load the section's vocal so the first ▶ starts it without the
    // source-load latency
    final vp = _tracks['vocal']?.vocalPath;
    if (vp != null) _audio.prepareVocal(LoopStorage.resolveVocal(vp));
    // 12초마다 dirty 면 silent autosave — 사용자 명시적 Save 와 충돌 없음.
    _autosaveTimer = Timer.periodic(
      const Duration(seconds: 12),
      (_) => _autoSaveTick(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _titleCtl.dispose();
    _autosaveTimer?.cancel();
    _flashTimer?.cancel();
    for (final t in _strumTimers) {
      t.cancel();
    }
    _ticker?.dispose();
    _playStep.dispose();
    _litMidis.dispose();
    _audio.stopAll();
    super.dispose();
  }

  /// 12초마다 호출. 변경 사항이 없어 보여도 일단 저장 — upsert 는 idempotent
  /// 하고, 자잘한 미반영 mutation 도 모두 잡힌다 (dirty 추적 정밀도가 낮은
  /// 데이터플로우 회피). UI 갱신은 setState 로 saved indicator 만.
  // Backgrounded (or hidden) → stop the transport like the user pressed stop.
  // A clock left running would only pile up a catch-up burst on resume (A7),
  // and a pending count-in must not start recording into the void (C25).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.paused && state != AppLifecycleState.hidden) return;
    if (_playing || _songSection != null || _countDown > 0) _stopAll();
  }

  Future<void> _autoSaveTick() async {
    if (!mounted) return;
    try {
      final store = context.read<LoopStore>();
      // an untouched brand-new song doesn't earn a library slot yet (C15)
      if (_isPristineNew(store)) return;
      await store.upsert(_snapshot());
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
    // Fell more than a whole loop behind (frames stalled / app resumed): skip
    // ahead instead of firing every missed trigger in one burst (A7).
    if (abs - _nextAbs > steps) {
      _nextAbs = abs.ceil();
      _freshThisLoop.clear();
    }
    while (abs >= _nextAbs + _swFrac(_nextAbs)) {
      final st = ((_nextAbs % steps) + steps) % steps;
      // new loop pass — notes recorded last pass may now play normally; re-align
      // the recorded vocal to the loop start so it stays in sync.
      if (st == 0) {
        _freshThisLoop.clear();
        // a lane level changed mid-loop → swap in the rebounced mix here, at
        // the loop start, so it comes back in sync.
        if (_vocalRestartAtWrap && _songSection == null) {
          _vocalRestartAtWrap = false;
          _stopVocal();
          _startVocalIfAny();
        }
        // single-section loop re-aligns its one vocal; song mode handles vocals
        // per-section in _trigger (the step-0 boundary restarts the first one).
        // Aligned takes loop natively in the player (ReleaseMode.loop) — a
        // wrap-time seek would only add a glitch on top. Alignment is only
        // valid at the take's recorded bpm/bars (vocalIsAligned).
        // Re-sync a non-natively-looping vocal at the loop start: the single
        // section take, or the song-level take during Play Song.
        if (_vocalPlaying &&
            !_vocalLoopNative &&
            (_songSection == null || _songVocalActive)) {
          _audio.seekVocalToStart();
        }
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
      // The scheduled file is the section's pre-bounced vocal mix (null when the
      // section has no audible vocal lane) — muting was already applied at the
      // bounce, so no live mute re-check here.
      final path = sched[step];
      if (path != null) {
        _vocalPlaying = true;
        _vocalIsMix = _isMixFile(path);
        _audio.playVocal(
          LoopStorage.resolveVocal(path),
          vol: _vocalFileVol(path),
        );
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
        final vol = _vol[tk.id] ?? 0.85;
        final due = [
          for (final n in data.pitchNotes.where((n) => n.step == step))
            if (!_freshThisLoop.contains('${tk.id}:${n.midi}:$step')) n,
        ];
        if (isGuitarProgram(prog) && due.length > 1) {
          // strum the chord on playback the same way the live pad does
          final byMidi = {for (final n in due) n.midi: n};
          for (final s in strumPlan([for (final n in due) n.midi])) {
            final note = byMidi[s.midi]!;
            void hit() => _audio.playPitch(tk.channel, s.midi,
                program: prog, vol: vol * s.velScale, durSec: dsec(note.dur));
            // fire-and-forget: the strum sweep is a few ms, no cancellation
            if (s.delayMs <= 0) {
              hit();
            } else {
              Timer(Duration(milliseconds: s.delayMs), hit);
            }
          }
        } else {
          for (final n in due) {
            _audio.playPitch(tk.channel, n.midi,
                program: prog, vol: vol, durSec: dsec(n.dur));
          }
        }
        // glow only the ACTIVE track's pads — otherwise a melody note would
        // light a same-pitch pad on melody-fill/bass while they're showing.
        if (tk.id == _activeId) {
          for (final n in due) {
            litM.add(n.midi);
          }
        }
      } else if (tk.kind == TrackKind.drums) {
        for (final n in data.drumNotes.where((n) => n.step == step)) {
          if (_freshThisLoop.contains('${tk.id}:${n.kind}:$step')) continue;
          _audio.playDrum(n.kind, channel: tk.channel, vol: _vol[tk.id] ?? 1);
        }
      }
    }
    if (_metro && step % kStepsPerBeat == 0) {
      _audio.click(step % (kStepsPerBeat * kBeatsPerBar) == 0);
    }
    if (litM.isNotEmpty || _litMidis.value.isNotEmpty) {
      _litMidis.value = litM;
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
    // a new drum track needs its kit selected on its freshly-allocated channel
    if (trackById(type).kind == TrackKind.drums) {
      final m = _editMetas.firstWhere((t) => t.id == id);
      _audio.setDrumKitOn(m.channel, _instruments[id] ?? kDefaultDrumKit);
    }
  }

  Future<void> _openAddTrack() async {
    final l = L10n.of(context);
    final type = await showDialog<String>(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: LT.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        l.addTrackTitle,
                        style: LTType.inter(
                          size: 16,
                          weight: FontWeight.w800,
                          color: LT.t1,
                        ),
                      ),
                    ),
                  ),
                  // base instanceable tracks + the addable "Audio" lane (a
                  // second vocal-kind lane for overlapping/layered takes).
                  for (final t in kAddableTracks)
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(ctx).pop(t.id),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Ms(t.icon, size: 18, color: t.color),
                            const SizedBox(width: 12),
                            Text(
                              t.label,
                              style: LTType.inter(
                                size: 14,
                                weight: FontWeight.w700,
                                color: LT.t1,
                              ),
                            ),
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
    _songVocalActive = false;
    _playStep.value = 0;
    _countInGen++; // abandon any pending count-in
    setState(() {
      _playing = false;
      _recording = false;
      _countDown = 0;
      _litMidis.value = const {};
      if (_songSection != null) {
        _songSection = null;
        _songSteps = null;
        _songVocalSched = null;
      }
    });
  }

  void _armRecord() {
    _audio.ensure();
    // Rec tapped again DURING the count-in → cancel the pending start (C25).
    if (_countDown > 0) {
      _countInGen++;
      setState(() => _countDown = 0);
      return;
    }
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

  // Bumped to abandon an in-flight count-in (Rec toggled off, stop, background).
  int _countInGen = 0;

  void _doCountIn(VoidCallback then) {
    _audio.ensure();
    final gen = ++_countInGen;
    final beatMs = (60 / _bpm * 1000).round();
    var n = 4;
    setState(() => _countDown = 4);
    _audio.click(true);
    void step() {
      Future.delayed(Duration(milliseconds: beatMs), () {
        if (!mounted || gen != _countInGen) return; // cancelled
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
      _ensureActiveIdValid();
      _playStep.value = 0;
    });
  }

  String _nextSectionName() => String.fromCharCode(65 + _sections.length % 26);

  // Re-letter auto-named sections by position so the chips read A, B, C… left to
  // right after any add / duplicate / move / delete. Custom-renamed sections
  // (autoName == false) keep their name; their position letter is just skipped.
  void _relabelSections() {
    for (var i = 0; i < _sections.length; i++) {
      if (_sections[i].autoName) {
        _sections[i].name = String.fromCharCode(65 + i % 26);
      }
    }
  }

  // "+" → a brand-new EMPTY section (not a copy of the current one).
  void _addSection() {
    _pushUndo();
    if (_playing) _stopAll();
    final ns = Section(
      id: 'sec${DateTime.now().millisecondsSinceEpoch}',
      name: _nextSectionName(),
      bars: _bars,
      // the track set is song-wide (see _addTrack) — a new section gets every
      // added track too, so switching to it never dangles the active id.
      extras: [for (final e in _sec.extras) TrackRef(e.id, e.type)],
      order: [..._sec.order],
    );
    for (final e in ns.extras) {
      ns.tracks[e.id] = TrackData();
    }
    setState(() {
      _sections.add(ns);
      _relabelSections();
      _activeIdx = _sections.length - 1;
      _playStep.value = 0;
    });
  }

  // long-press → Duplicate: deep-copy a section in place (the old "+" behavior).
  void _duplicateSection(int idx) {
    _pushUndo();
    if (_playing) _stopAll();
    final copy =
        _sections[idx].deepCopy()
          ..id = 'sec${DateTime.now().millisecondsSinceEpoch}'
          ..autoName = true // a duplicate gets a fresh position letter
          ..name = _nextSectionName();
    setState(() {
      _sections.insert(idx + 1, copy);
      _relabelSections();
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
      _relabelSections();
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
      _relabelSections();
      _activeIdx = _activeIdx.clamp(0, _sections.length - 1);
      if (idx < _activeIdx || _activeIdx >= _sections.length) {
        _activeIdx = (_activeIdx - 1).clamp(0, _sections.length - 1);
      }
      _playStep.value = 0;
    });
  }

  // User typed a name → it's custom now, so _relabelSections leaves it alone.
  void _renameSection(int idx, String name) {
    _pushUndo(coalesce: true); // one undo entry per typing burst
    setState(() {
      _sections[idx]
        ..name = name
        ..autoName = false;
    });
  }

  // long-press a section chip → Duplicate / Move left / Move right
  Future<void> _openSectionMenu(int idx) async {
    final l = L10n.of(context);
    await showLtModal(
      context,
      width: 300,
      child: StatefulBuilder(
        builder:
            (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.ltEditorSectionMenuTitle(_sections[idx].name),
                  style: LTType.inter(
                    size: 15,
                    weight: FontWeight.w800,
                    color: LT.t1,
                  ),
                ),
                const SizedBox(height: 14),
                _menuRow(LtIcons.layers, l.projectOptionDuplicate, () {
                  Navigator.of(context).pop();
                  _duplicateSection(idx);
                }),
                _menuRow(
                  LtIcons.arrowBack,
                  l.ltEditorMoveLeft,
                  idx > 0
                      ? () {
                        Navigator.of(context).pop();
                        _moveSection(idx, -1);
                      }
                      : null,
                ),
                _menuRow(
                  LtIcons.playArrow,
                  l.ltEditorMoveRight,
                  idx < _sections.length - 1
                      ? () {
                        Navigator.of(context).pop();
                        _moveSection(idx, 1);
                      }
                      : null,
                ),
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
              Text(
                label,
                style: LTType.inter(
                  size: 13,
                  weight: FontWeight.w700,
                  color: LT.t1,
                ),
              ),
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

  Future<void> _playSong() async {
    _audio.ensure();
    if (_songSection != null) {
      _stopAll();
      return;
    }
    final flat = flattenSong(_sections);
    final disp = _songDisplay(flat);
    // Bounce each section's vocal lanes once (cached), then schedule that mix at
    // every section instance — so the full-song preview hears all takes/Audio
    // lanes/trims, matching export (not just the first raw take).
    final mixBySec = <String, String?>{};
    for (final sec in _sections) {
      mixBySec[sec.id] = await _sectionVocalFile(sec);
    }
    if (!mounted) return;
    final sched = <int, String?>{};
    var off = 0;
    for (final sec in _sections) {
      final st = stepsForBars(sec.bars);
      for (var r = 0; r < sec.repeats; r++) {
        sched[off] = mixBySec[sec.id];
        off += st;
      }
    }
    setState(() {
      _songSection = disp;
      _songSteps = flat.steps;
      _playStep.value = 0;
      _playing = true;
    });
    // A song-level take plays from step 0 and REPLACES the per-section vocals;
    // otherwise fall back to the per-section schedule.
    if (_songVocalPath != null) {
      _songVocalSched = null;
      final native = _songVocalBpm == _bpm && _songVocalBars == _songTotalBars;
      _vocalLoopNative = native;
      _vocalPlaying = true;
      _vocalIsMix = false;
      _songVocalActive = true;
      _audio.playVocal(
        LoopStorage.resolveVocal(_songVocalPath!),
        vol: _vol['vocal'] ?? 0.85,
        loop: native,
      );
    } else {
      _songVocalSched = sched;
      _songVocalActive = false;
    }
    _startClock();
  }

  // ── editing ───────────────────────────────────────────────────────
  int _quantStep() => _playStep.value.round() % _steps;

  // ── overdub while playing the whole song ──────────────────────────────
  // The full-song playhead step (0.._songSteps) maps back to ONE real section
  // instance + the local step inside it. Repeats of a section share its data,
  // so recording into the section affects every repeat (consistent with play).
  ({Section section, int localStep})? _songStepToSection(int globalStep) {
    var off = 0;
    for (final sec in _sections) {
      final st = stepsForBars(sec.bars);
      for (var r = 0; r < sec.repeats; r++) {
        if (globalStep >= off && globalStep < off + st) {
          return (section: sec, localStep: globalStep - off);
        }
        off += st;
      }
    }
    return null;
  }

  // Where a just-played note should be recorded. Single-section mode: the active
  // section at the (already local) step. Song mode: the section under the
  // playhead at the local step — null if the playhead/active track can't resolve.
  ({Map<String, TrackData> tracks, int step})? _recTarget(int globalStep) {
    if (_songSection == null) return (tracks: _tracks, step: globalStep);
    final m = _songStepToSection(globalStep);
    if (m == null || m.section.tracks[_activeId] == null) return null;
    return (tracks: m.section.tracks, step: m.localStep);
  }

  // Rebuild the flattened SONG display from the real sections so an overdubbed
  // note plays on the next loop pass. Mirrors the track assignment in _playSong.
  void _reflattenSong() {
    final s = _songSection;
    if (s == null) return;
    _fillSongTracks(s, flattenSong(_sections));
  }

  /// The flattened whole-song display section: every base lane PLUS every
  /// added track (so Play song hears them and the surface can show the active
  /// one — C3), carrying the editing section's pad layout / row order.
  Section _songDisplay(FlatSong flat) {
    final extras = <TrackRef>[];
    final seen = <String>{};
    for (final s in _sections) {
      for (final e in s.extras) {
        if (seen.add(e.id)) extras.add(TrackRef(e.id, e.type));
      }
    }
    final disp = Section(
      id: 'song',
      name: 'SONG',
      bars: _bars,
      extras: extras,
      order: [..._sec.order],
      fillKinds: [..._sec.fillKinds],
    );
    _fillSongTracks(disp, flat);
    return disp;
  }

  void _fillSongTracks(Section disp, FlatSong flat) {
    disp.tracks['melody'] = TrackData(notes: flat.melody);
    disp.tracks['melodyDec'] = TrackData(notes: flat.melodyDec);
    disp.tracks['bass'] = TrackData(notes: flat.bass);
    disp.tracks['drums'] = TrackData(drums: flat.drums);
    disp.tracks['beatDec'] = TrackData(drums: flat.beatDec);
    for (final e in disp.extras) {
      disp.tracks[e.id] = switch (trackById(e.type).kind) {
        TrackKind.drums => TrackData(drums: flat.extraDrums[e.id] ?? []),
        // audio lanes are display-only here (vocals play via the schedule)
        TrackKind.vocal => _sec.tracks[e.id]?.deepCopy() ?? TrackData(),
        _ => TrackData(notes: flat.extraPitched[e.id] ?? []),
      };
    }
    // cosmetic (C32): the song-level take's waveform when there is one, else
    // the editing section's vocal lane.
    disp.tracks['vocal'] = _songVocalPeaks != null
        ? TrackData(clip: _songVocalPeaks)
        : (_sec.tracks['vocal']?.deepCopy() ?? TrackData());
  }

  // Re-assert every drum track's kit on its channel: base drums on ch9, beat-fill
  // on ch10, and each added drum track on its own channel — every drum track owns
  // an independent kit. The drum kit is a sticky synth-side selection, so this
  // runs on open / undo-restore / after adding a track.
  void _applyDrumKits() {
    _audio.setDrumKitOn(LoopAudio.drumChannel, _instruments['drums'] ?? kDefaultDrumKit);
    for (final m in _editMetas) {
      if (m.kind == TrackKind.drums && m.channel != LoopAudio.drumChannel) {
        _audio.setDrumKitOn(m.channel, _instruments[m.id] ?? kDefaultDrumKit);
      }
    }
  }

  void _hitDrum(String kind) {
    _audio.playDrum(kind, channel: _meta.channel, vol: _vol[_activeId] ?? 1);
    if (!(_recording && _playing)) return;
    final g = _quantStep(); // global step in song mode, local step otherwise
    final tgt = _recTarget(g);
    if (tgt == null) return;
    _pushUndo(coalesce: true);
    final dn = _trackIn(tgt.tracks, _activeId).drumNotes;
    if (!dn.any((x) => x.kind == kind && x.step == tgt.step)) {
      setState(() => dn.add(DrumNote(kind: kind, step: tgt.step)));
    }
    // heard live now → don't let the clock replay it this loop pass. The clock
    // checks the PLAYED step (global in song mode), so key fresh on `g`.
    _freshThisLoop.add('$_activeId:$kind:$g');
    if (_songSection != null) _reflattenSong(); // so it plays on the next pass
  }

  // drums Grid mode: tap a cell to toggle a hit at (kind, step) on the active
  // percussion track (main drums or beat-fill).
  void _toggleDrumCell(String kind, int step) {
    if (_songSection != null) {
      return; // editing disabled while previewing the song
    }
    _pushUndo(coalesce: true);
    final dn = _activeTrack.drumNotes;
    final i = dn.indexWhere((x) => x.kind == kind && x.step == step);
    setState(() {
      if (i >= 0) {
        dn.removeAt(i);
      } else {
        dn.add(DrumNote(kind: kind, step: step));
        _audio.playDrum(kind, channel: _meta.channel, vol: _vol[_activeId] ?? 1);
      }
    });
  }

  // Beat-Fill launchpad: open the percussion picker for pad [padIndex] and
  // reassign its sound. Notes already recorded with the swapped-away sound are
  // REMAPPED to the new sound, so the pattern keeps playing on the pad with its
  // new timbre.
  Future<void> _openFillPadPicker(int padIndex) async {
    if (_songSection != null) return; // editing disabled while previewing
    final current = _sec.fillKinds[padIndex];
    final picked = await showLtModal<String>(
      context,
      child: FillPaletteSheet(
        current: current,
        onPreview: (k) =>
            _audio.playDrum(k, channel: _meta.channel, vol: _vol[_activeId] ?? 1),
      ),
    );
    if (picked == null || picked == current) return;
    _pushUndo();
    setState(() {
      _sec.fillKinds[padIndex] = picked;
      // Remap the swapped-away sound's notes → the new sound, deduping any
      // (kind, step) collision with notes the new sound already had. Operate on
      // the ACTIVE beat-fill track (could be an added instance, not 'beatDec').
      final track = _activeTrack;
      final seen = <String>{};
      final remapped = <DrumNote>[];
      for (final n in track.drumNotes) {
        final k = (n.kind == current) ? picked : n.kind;
        if (seen.add('$k:${n.step}')) {
          remapped.add(k == n.kind ? n : DrumNote(kind: k, step: n.step));
        }
      }
      track.drumNotes
        ..clear()
        ..addAll(remapped);
    });
  }

  // pending hold timing per midi (live pads): midi -> (step, pressedAtMs)
  final Map<int, ({int step, int t})> _pending = {};

  int _durFromHold(int ms) =>
      (ms / 1000 * (_bpm / 60) * kStepsPerBeat).round().clamp(1, _steps);

  /// The midis a pad press produces: a diatonic triad in melody chord mode,
  /// otherwise just the pressed note.
  List<int> _chordMidis(int rootMidi) {
    if (_meta.group != 'melody') return [rootMidi];
    // Power chord (root + 5th + octave, no third). Guitar gets a low-register
    // voicing; other melody instruments get the plain power chord.
    if (_powerOn) {
      return _activeIsGuitar
          ? guitarPowerVoicing(rootMidi)
          : powerChord(rootMidi);
    }
    if (!_chordOn) return [rootMidi];
    // Guitar gets a spread barre/open voicing in the guitar register; other
    // melody instruments keep the close diatonic triad. Either way the voiced
    // notes are what gets stored on release, so playback/export stay in sync.
    return _activeIsGuitar
        ? guitarVoicing(rootMidi, _keyRoot, _scale)
        : diatonicTriad(rootMidi, _keyRoot, _scale);
  }

  /// A Rung for an arbitrary chord-member midi (the root reuses the real Rung).
  Rung _rungFor(int midi, Rung root) =>
      midi == root.midi
          ? root
          : Rung(
            midi: midi,
            name: kNoteNames[((midi % 12) + 12) % 12],
            degree: root.degree,
            freq: midiToFreq(midi),
            index: root.index,
          );

  // Pending strum note-ons (a guitar chord sweeps over a few ms); cancelled on
  // release so a quick tap never leaves a late string ringing.
  final List<Timer> _strumTimers = [];

  void _pitchDown(Rung n) {
    // held note(s): they sound while pressed, so what you hear == what's recorded
    final ch = _meta.channel;
    final prog = _instruments[_activeId] ?? _meta.defaultProgram;
    final vol = _vol[_activeId] ?? 0.85;
    final midis = _chordMidis(n.midi);
    if (_activeIsGuitar && midis.length > 1) {
      // strum the chord: each string a little after the previous, slightly softer
      for (final s in strumPlan(midis)) {
        void hit() => _audio.noteOnLive(ch, s.midi, program: prog, vol: vol * s.velScale);
        if (s.delayMs <= 0) {
          hit();
        } else {
          _strumTimers.add(Timer(Duration(milliseconds: s.delayMs), hit));
        }
      }
    } else {
      for (final m in midis) {
        _audio.noteOnLive(ch, m, program: prog, vol: vol);
      }
    }
    if (_recording && _playing) {
      // Song-mode overdub records the global step; _pitchUp maps it to the
      // section under the playhead. Single-section mode records the local step.
      _pending[n.midi] = (
        step: _quantStep(),
        t: DateTime.now().millisecondsSinceEpoch,
      );
    }
  }

  void _pitchUp(Rung n) {
    final ch = _meta.channel;
    final midis = _chordMidis(n.midi);
    // drop any not-yet-struck strum strings so a fast tap doesn't leave one on
    if (_strumTimers.isNotEmpty) {
      for (final t in _strumTimers) {
        t.cancel();
      }
      _strumTimers.clear();
    }
    for (final m in midis) {
      _audio.noteOffLive(ch, m);
    }
    final p = _pending.remove(n.midi);
    if (p == null) return;
    final dur = _durFromHold(DateTime.now().millisecondsSinceEpoch - p.t);
    final tgt = _recTarget(p.step); // p.step is the played step (global in song mode)
    if (tgt == null) return; // song-mode playhead/active track didn't resolve
    _pushUndo(coalesce: true);
    for (final m in midis) {
      _placePitched(tgt.tracks, _activeId, _rungFor(m, n), tgt.step, tgt.step + dur - 1);
      // heard live now → don't let the clock replay it this loop pass (the clock
      // checks the played/global step).
      _freshThisLoop.add('$_activeId:$m:${p.step}');
    }
    if (_songSection != null) _reflattenSong(); // so it plays on the next pass
  }

  /// Place a pitched note spanning [a,b] in [tracks], merging overlapping
  /// same-pitch notes. [tracks] is the active section normally, or the section
  /// under the playhead for a song-mode overdub.
  void _placePitched(Map<String, TrackData> tracks, String id, Rung n, int a, int b) {
    setState(() {
      var lo = a < b ? a : b;
      var hi = a < b ? b : a;
      final target = _trackIn(tracks, id);
      final kept = <PitchNote>[];
      for (final x in target.pitchNotes) {
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
      kept.add(
        PitchNote(midi: n.midi, freq: n.freq, step: lo, dur: hi - lo + 1),
      );
      target.pitchNotes
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
    _audio.playPitch(
      _meta.channel,
      n.midi,
      program: _instruments[_activeId] ?? _meta.defaultProgram,
      vol: _vol[_activeId] ?? 0.85,
      durSec: durSec,
    );
    _placePitched(_tracks, _activeId, n, a, b);
    _freshThisLoop.add('$_activeId:${n.midi}:${a < b ? a : b}');
  }

  // Erase only the touched CELL (one step), not the whole note: split the note
  // into its before/after remainders so a long note keeps its other steps.
  void _gridErase(Rung n, int step) {
    _pushUndo(coalesce: true);
    setState(() {
      final notes = _activeTrack.pitchNotes;
      final i = notes.indexWhere(
        (x) => x.midi == n.midi && step >= x.step && step < x.step + x.dur,
      );
      if (i < 0) return;
      final note = notes.removeAt(i);
      final end = note.step + note.dur; // exclusive
      if (step > note.step) {
        notes.add(
          PitchNote(
            midi: note.midi,
            freq: note.freq,
            step: note.step,
            dur: step - note.step,
          ),
        );
      }
      if (step + 1 < end) {
        notes.add(
          PitchNote(
            midi: note.midi,
            freq: note.freq,
            step: step + 1,
            dur: end - (step + 1),
          ),
        );
      }
    });
  }

  void _clearTrack() {
    _pushUndo();
    setState(() {
      final t = _activeTrack;
      t.pitchNotes.clear();
      t.drumNotes.clear();
      t.clip = null;
      if (trackById(_activeType).kind == TrackKind.vocal) {
        t.clips = null;
        t.vocalPath = null;
        t.vocalOrigPath = null;
        t.vocalBpm = null;
        t.vocalBars = null;
        _stopVocal();
        _vocalMix.remove(_sec.id);
      }
    });
    // Offer an immediate undo — clearing has no confirm dialog (keeps the flow
    // fast), so a one-tap recovery path catches accidental clears.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ltEditorTrackCleared),
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
              label: L10n.of(context).ltEditorUndo, onPressed: _undoAction),
        ),
      );
  }

  // ── vocal playback (item 7) ───────────────────────────────────────
  /// Returns true when the take was persisted and committed to the track.
  Future<bool> _commitVocal(
    List<double> wf,
    String? path, {
    bool aligned = false,
  }) async {
    if (path == null) return false;
    // persisted is a BASENAME under Documents/looptap/vocals (durable across
    // iOS container moves). No temp-path fallback: the OS reclaims temp files,
    // so a failed copy must surface instead of silently rotting.
    // Copy FIRST — only a successful copy snapshots undo + mutates state, so a
    // failure can't pop someone else's undo entry or clear the redo stack.
    final persisted = await LoopStorage.copyVocal(
      path,
      widget.song.id,
      _sec.id,
    );
    if (!mounted) return false;
    if (persisted == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ltRecSaveFailed),
          duration: const Duration(milliseconds: 1600),
        ),
      );
      return false;
    }
    _pushUndo();
    var laneWasFull = false;
    setState(() {
      final t = _trackIn(_tracks, _vocalId);
      // Multi-take: APPEND a new clip to the lane instead of replacing. The
      // first recording seeds the lane (migrating any legacy single take).
      final lane = t.clips ?? (t.vocalPath != null ? List.of(t.effectiveClips) : <VocalClip>[]);
      // Place each new take to the RIGHT of the rightmost existing chunk so they
      // never stack on top of each other (drag it on the strip to reposition).
      final secSteps = stepsForBars(_bars);
      var startStep = 0;
      for (final c in lane) {
        final dur = c.durSteps > 0 ? c.durSteps : secSteps;
        final end = c.startStep + dur;
        if (end > startStep) startStep = end;
      }
      // Lane already full → start over at step 0 (overlapping the first take)
      // rather than a 1-step sliver at the loop end (C9). Told below.
      if (startStep >= secSteps) {
        startStep = 0;
        laneWasFull = true;
      }
      final clip = VocalClip(
        path: persisted,
        startStep: startStep,
        durSteps: aligned ? secSteps : -1,
        peaks: wf,
      );
      lane.add(clip);
      t.clips = lane;
      // legacy mirror = first clip (surface waveform + back-compat / export).
      final first = lane.first;
      t.clip = first.peaks.isNotEmpty ? first.peaks : wf;
      t.vocalPath = first.path;
      t.vocalOrigPath = first.origPath;
      t.vocalAligned = aligned;
      t.vocalBpm = _bpm;
      t.vocalBars = _bars;
    });
    _vocalMix.remove(_sec.id); // section mix is stale → rebounce on next play
    if (laneWasFull) {
      _toast(L10n.of(context).ltEditorLaneFull);
    }
    return true;
  }

  /// Start the recorded vocal for single-section loop play. Plays a per-section
  /// MIX of every vocal-kind lane's clips (multiple takes / Audio lanes / trims
  /// all audible), padded to the loop so it loops natively. A single untouched
  /// take skips the mix and plays its own file. (Play song handles per-section
  /// vocals via the schedule in _trigger.)
  Future<void> _startVocalIfAny() async {
    if (_songSection != null) return;
    final sec = _sec;
    final file = await _sectionVocalFile(sec);
    if (!mounted || !identical(_sec, sec) || file == null) return;
    // A padded section mix (name prefixed '_mix_') always loops natively; a raw
    // single take loops only when it's loop-aligned at this bpm/bars.
    _vocalIsMix = _isMixFile(file);
    _vocalLoopNative =
        _vocalIsMix || (_tracks['vocal']?.vocalIsAligned(_bpm, _bars) ?? false);
    _vocalPlaying = true;
    _audio.playVocal(
      LoopStorage.resolveVocal(file),
      vol: _vocalFileVol(file),
      loop: _vocalLoopNative,
    );
  }

  static bool _isMixFile(String name) => name.startsWith('_mix_');

  /// Player volume for a vocal file: a bounced section mix already has every
  /// lane's mixer level baked in (unity here); a raw single take is the base
  /// Vocal lane, so its level is applied by the player.
  double _vocalFileVol(String name) => _isMixFile(name) ? 1.0 : (_vol['vocal'] ?? 0.85);

  /// The cached playable vocal basename for [sec] (the lane mix, or a raw single
  /// take). '' is cached for "nothing to play". Cleared on record/edit/mute.
  Future<String?> _sectionVocalFile(Section sec) async {
    final cached = _vocalMix[sec.id];
    if (cached != null) return cached.isEmpty ? null : cached;
    final f = (await _bounceSectionVocal(sec)) ?? '';
    _vocalMix[sec.id] = f;
    return f.isEmpty ? null : f;
  }

  /// Bounce all of [sec]'s vocal-kind lanes (base Vocal + added Audio lanes,
  /// skipping muted ones) into one loop-length WAV and return its basename, so
  /// multiple takes / lanes / trims play live. Returns null when there's nothing
  /// to play; a single untouched take returns its own path (no mix written).
  Future<String?> _bounceSectionVocal(Section sec) async {
    // Each lane's mixer level is baked into its clips' gain so added Audio
    // lanes get their own volume (C8); muted / zero lanes are left out — so
    // muting the base Vocal never silences the other lanes.
    final clips = <VocalClip>[];
    var baseLaneOnly = true;
    for (final vid in vocalTrackIds(sec)) {
      if (_mutes[vid] ?? false) continue;
      final laneVol = _vol[vid] ?? 0.85;
      if (laneVol <= 0) continue;
      final lane = sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[];
      if (lane.isEmpty) continue;
      if (vid != 'vocal') baseLaneOnly = false;
      for (final c in lane) {
        clips.add(c.copy()..gain = c.gain * laneVol);
      }
    }
    if (clips.isEmpty) return null;
    if (clips.length == 1 && baseLaneOnly) {
      final c = sec.tracks['vocal']!.effectiveClips.first;
      final untouched = c.startStep == 0 &&
          c.trimStart == 0 &&
          c.trimEnd == -1 &&
          c.fadeInMs == 0 &&
          c.fadeOutMs == 0 &&
          c.gain == 1.0;
      if (untouched) return c.path; // play the raw take directly (level via the player)
    }
    final sources = <String, ({Float32List pcm, int sampleRate})>{};
    for (final c in clips) {
      if (sources.containsKey(c.path)) continue;
      try {
        final wav = parseWav(await File(LoopStorage.resolveVocal(c.path)).readAsBytes());
        if (wav != null) sources[c.path] = (pcm: wav.samples, sampleRate: wav.sampleRate);
      } catch (_) {}
    }
    if (sources.isEmpty) return null;
    final minLen = (stepsForBars(sec.bars) * 60 / _bpm / kStepsPerBeat * 44100).round();
    final lane = bounceVocalClips(clips, sec.bars, _bpm, sources, minLen: minLen);
    if (lane.isEmpty) return null;
    // fixed name per section → overwrites in place (no file accumulation).
    final name = '_mix_${widget.song.id}_${sec.id}.wav';
    await File(LoopStorage.resolveVocal(name)).writeAsBytes(encodeWavMono16(lane, 44100));
    return name;
  }

  void _stopVocal() {
    _vocalPlaying = false;
    _vocalLoopNative = false;
    _audio.stopVocal();
  }

  // mute/volume go through here so the live vocal player follows the mixer
  void _toggleMute(String id) {
    _pushUndo();
    setState(() => _mutes[id] = !(_mutes[id] ?? false));
    // Muting any vocal-kind lane (base Vocal or an Audio lane) changes the
    // section mix, so invalidate it and restart the blended playback.
    if (trackById(_typeOf(id)).kind == TrackKind.vocal) {
      _vocalMix.remove(_sec.id);
      _stopVocal();
      if (_playing) _startVocalIfAny();
    }
  }

  // The base track type backing a track id (extra ids resolve via the section's
  // TrackRefs; base ids are their own type).
  String _typeOf(String id) {
    for (final e in _sec.extras) {
      if (e.id == id) return e.type;
    }
    return id;
  }

  // Hold-and-drag retime of a vocal/audio chunk on the arrangement strip. Moving
  // a legacy single take materializes the clip lane first.
  void _moveVocalClip(String trackId, int clipIndex, int newStartStep) {
    final t = _tracks[trackId];
    if (t == null) return;
    final lane = t.clips ?? List.of(t.effectiveClips);
    if (clipIndex < 0 || clipIndex >= lane.length) return;
    if (lane[clipIndex].startStep == newStartStep) return;
    _pushUndo(coalesce: true); // one undo entry per drag gesture
    setState(() {
      lane[clipIndex].startStep = newStartStep;
      t.clips = lane;
    });
    _vocalMix.remove(_sec.id); // position changed → rebounce on next play
  }

  void _setVol(String id, double v) {
    // Coalesce the drag stream into one undo entry per gesture (500ms window).
    _pushUndo(coalesce: true);
    setState(() => _vol[id] = v);
    if (trackById(_typeOf(id)).kind != TrackKind.vocal) return;
    // lane levels are baked into the section mix → it's stale now (C8)
    _vocalMix.remove(_sec.id);
    if (!_vocalPlaying) return;
    if (id == 'vocal' && (!_vocalIsMix || _songVocalActive)) {
      _audio.setVocalVolume(v); // raw take / song-level take: live
    } else if (_songSection == null) {
      _vocalRestartAtWrap = true; // mix: swap in the rebounce at the loop start
    }
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
    final id = _instrumentTargetId;
    final ch = _meta.channel;
    showInstrumentSheet(
      context,
      trackId: _activeType, // base type drives the instrument list
      trackLabel: _meta.label, // instance label (e.g. "Bass 2")
      currentProgram: _instruments[id] ?? _meta.defaultProgram,
      onPick: (program) {
        // A not-yet-downloaded catalog sound (200–400MB): keep the current
        // instrument, download in the BACKGROUND (progress shows in the picker,
        // which can be closed), and apply only when ready — so the user is never
        // blocked nor hears the piano fallback. GM / already-downloaded / drums
        // apply immediately as before.
        if (_meta.kind != TrackKind.drums &&
            isDynamicSlot(program) &&
            !SoundfontCatalog.instance.isDownloaded(program)) {
          SoundfontCatalog.instance.ensureDownloaded(program).then((path) {
            if (!mounted) return;
            if (path == null) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(L10n.of(context).ltEditorSoundDownloadFailed),
                  duration: const Duration(milliseconds: 1800)));
              return;
            }
            _applyInstrument(id, ch, program);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(L10n.of(context).ltEditorSoundReady),
                duration: const Duration(milliseconds: 1300)));
          });
          return;
        }
        if (_meta.kind == TrackKind.drums) {
          // Drums pick a KIT (bank-128 program / kit soundfont) on the track's
          // own channel, so each drum track sounds independently.
          _pushUndo(coalesce: true);
          setState(() => _instruments[id] = program);
          _audio.setDrumKitOn(ch, program);
          _audio.playDrum('kick', channel: ch, vol: _vol[_activeId] ?? 1);
          return;
        }
        _applyInstrument(id, ch, program);
      },
    );
  }

  /// Apply a pitched instrument to track [id] on [ch] + preview it. Used both
  /// for immediate picks and when a background catalog download completes.
  void _applyInstrument(String id, int ch, int program) {
    _pushUndo(coalesce: true);
    setState(() => _instruments[id] = program); // each track stores its own
    _audio.setProgram(ch, program);
    // preview the new timbre — only when the picked track is still the target,
    // in its own register (bass uses the low ladder root, melody an in-key mid).
    if (id == _instrumentTargetId) {
      final isBass = _isBass;
      final ladder = isBass ? _bassLadder : _ladder;
      final preview = ladder.isNotEmpty ? ladder[isBass ? 0 : 2].midi : 60;
      _audio.playPitch(ch, preview,
          program: program, vol: _vol[id] ?? 0.85, durSec: 0.5);
    }
  }

  void _openMixer() {
    showMixerSheet(
      context,
      tracks: _editMetas,
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

  // ── loop-aligned vocal recording ──────────────────────────────────
  Future<void> _openVocalRecord() async {
    _audio.ensure();
    if (_playing) _stopAll();
    final route = await headsetRoute();
    final canMonitorBacking = route != HeadsetRoute.none;
    if (!mounted) return;
    showVocalRecordModal(
      context,
      accent: _meta.color,
      bpm: _bpm,
      bars: _bars,
      headset: route,
      keyTonic: _keyRoot,
      scale: _engineScale[_scale] ?? _scale,
      latencyMs: LoopPrefs.instance.vocalLatencyMs.value,
      onClick: canMonitorBacking ? (accent) => _audio.click(accent) : null,
      startBacking: canMonitorBacking ? _startHumBacking : null,
      stopBacking: canMonitorBacking ? _stopHumBacking : null,
      onDone: (peaks, path) => _commitVocal(peaks, path, aligned: true),
    );
  }

  // ── song-level vocal: one continuous take over the WHOLE song ─────────
  Future<void> _openSongVocalRecord() async {
    _audio.ensure();
    if (_playing) _stopAll();
    final route = await headsetRoute();
    final canMonitorBacking = route != HeadsetRoute.none;
    if (!mounted) return;
    showVocalRecordModal(
      context,
      accent: LT.pink,
      bpm: _bpm,
      bars: _songTotalBars, // record the whole arrangement as one long "loop"
      headset: route,
      keyTonic: _keyRoot,
      scale: _engineScale[_scale] ?? _scale,
      latencyMs: LoopPrefs.instance.vocalLatencyMs.value,
      onClick: canMonitorBacking ? (accent) => _audio.click(accent) : null,
      startBacking: canMonitorBacking ? _startSongBacking : null,
      stopBacking: canMonitorBacking ? _stopSongBacking : null,
      onDone: _commitSongVocal,
    );
  }

  // Full-song backing while recording the song vocal: play every section's
  // instrument lanes from step 0 (no vocals — they'd bleed into the take).
  void _startSongBacking() {
    _audio.ensure();
    _stopClock();
    final flat = flattenSong(_sections);
    final disp = _songDisplay(flat);
    _playStep.value = 0;
    _freshThisLoop.clear();
    setState(() {
      _songSection = disp;
      _songSteps = flat.steps;
      _songVocalSched = null;
      _playing = true;
    });
    _startClock();
  }

  void _stopSongBacking() {
    _stopClock();
    _audio.stopAll();
    _playStep.value = 0;
    if (mounted) {
      setState(() {
        _playing = false;
        _songSection = null;
        _songSteps = null;
        _litMidis.value = const {};
      });
    }
  }

  Future<bool> _commitSongVocal(List<double> peaks, String? path) async {
    if (path == null) return false;
    final persisted = await LoopStorage.copyVocal(path, widget.song.id, 'song');
    if (!mounted) return false;
    if (persisted == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).ltRecSaveFailed),
          duration: const Duration(milliseconds: 1600),
        ),
      );
      return false;
    }
    _pushUndo();
    setState(() {
      _songVocalPath = persisted;
      _songVocalPeaks = peaks;
      _songVocalBpm = _bpm;
      _songVocalBars = _songTotalBars;
    });
    return true;
  }

  void _clearSongVocal() {
    if (_songVocalPath == null) return;
    if (_songVocalActive) _stopVocal();
    _pushUndo();
    setState(() {
      _songVocalActive = false;
      _songVocalPath = null;
      _songVocalPeaks = null;
      _songVocalBpm = null;
      _songVocalBars = null;
    });
  }

  // ── autotune (server-side WORLD vocoder; non-destructive) ─────────
  void _openAutotune() {
    if (_playing) _stopAll();
    final l = L10n.of(context);
    showLtModal(
      context,
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Ms(LtIcons.autoFix, size: 18, color: LT.pink),
              const SizedBox(width: 8),
              Text(
                l.ltEditorAutotuneTitle,
                style: LTType.inter(
                  size: 16,
                  weight: FontWeight.w800,
                  color: LT.t1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            l.ltEditorAutotuneSub(_keyRoot, ltScaleLabel(l, _scale)),
            textAlign: TextAlign.center,
            style: LTType.inter(size: 12, color: LT.t2),
          ),
          const SizedBox(height: 18),
          _autotunePresetRow(
            l.ltEditorAutotuneNatural,
            l.ltEditorAutotuneNaturalSub,
            () => _applyAutotune(strength: 0.7, retuneMs: 120),
          ),
          const SizedBox(height: 10),
          _autotunePresetRow(
            l.ltEditorAutotuneStrong,
            l.ltEditorAutotuneStrongSub,
            () => _applyAutotune(strength: 1.0, retuneMs: 40),
          ),
        ],
      ),
    );
  }

  Widget _autotunePresetRow(String title, String sub, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.of(context).pop();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: LT.surface2,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: LT.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: LTType.inter(
                      size: 14,
                      weight: FontWeight.w700,
                      color: LT.t1,
                    ),
                  ),
                  Text(sub, style: LTType.inter(size: 11, color: LT.t2)),
                ],
              ),
            ),
            const Ms(LtIcons.chevronRight, size: 18, color: LT.t3),
          ],
        ),
      ),
    );
  }

  /// Autotune EVERY take on the vocal lane, not just the first one.
  ///
  /// A lane can hold several clips (one per overdub) and each is a separate
  /// file. Tuning only `vocalPath` left the other takes dry with no indication
  /// that they had been skipped (audit C16). Each clip keeps its own dry
  /// original so Revert restores the whole lane.
  Future<void> _applyAutotune({
    required double strength,
    required double retuneMs,
  }) async {
    final vid = _vocalId;
    final t = _trackIn(_tracks, vid);
    final clips = t.effectiveClips;
    if (clips.isEmpty) return;
    // blocking progress dialog for the server round-trip. Capture the root
    // navigator BEFORE any await — if this State unmounts mid-flight the
    // barrier dialog must still be popped or the app stays blocked forever.
    final nav = Navigator.of(context, rootNavigator: true);
    var dialogOpen = true;
    final progress = ValueNotifier<int>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: LT.pink),
            if (clips.length > 1) ...[
              const SizedBox(height: 12),
              ValueListenableBuilder<int>(
                valueListenable: progress,
                builder: (c, done, _) => Text(
                  L10n.of(c).ltEditorAutotuneProgress(done + 1, clips.length),
                  style: const TextStyle(color: LT.t2, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    try {
      // (clip, tuned basename, tuned peaks) for every take, computed before
      // any state is touched so a failure part-way leaves the lane untouched.
      final tuned = <(VocalClip, String, List<double>)>[];
      for (final clip in clips) {
        final res = await EngineApi().autotuneVocal(
          LoopStorage.resolveVocal(clip.path),
          keyTonic: _keyRoot,
          scale: _engineScale[_scale] ?? _scale,
          strength: strength,
          retuneMs: retuneMs,
        );
        final wav = parseWav(res.wav);
        if (wav == null) throw Exception('bad audio from server');
        var pcm = wav.sampleRate == 44100
            ? wav.samples
            : resampleLinear(wav.samples, wav.sampleRate, 44100);
        // aligned takes must keep their exact loop length for gapless looping —
        // WORLD resynthesis can drift by a few ms, so trim/pad back to the
        // original take's sample count.
        if (t.vocalAligned) {
          final orig = parseWav(
            await File(LoopStorage.resolveVocal(clip.path)).readAsBytes(),
          );
          if (orig != null && orig.samples.length != pcm.length) {
            final fixed = Float32List(orig.samples.length);
            for (var i = 0; i < fixed.length && i < pcm.length; i++) {
              fixed[i] = pcm[i];
            }
            pcm = fixed;
          }
        }
        final persisted = await LoopStorage.saveVocalBytes(
          encodeWavMono16(pcm, 44100),
          widget.song.id,
          _sec.id,
          suffix: '_tuned',
        );
        if (persisted == null) throw Exception('save failed');
        tuned.add((clip, persisted, peaksFromPcm(pcm)));
        progress.value = tuned.length;
      }
      if (!mounted) return;
      _pushUndo();
      setState(() {
        for (final entry in tuned) {
          final clip = entry.$1;
          clip.origPath ??= clip.path; // keep the dry take for "Original"
          clip.path = entry.$2;
          clip.peaks = entry.$3;
        }
        // legacy single-take fields mirror the first clip
        final first = tuned.first;
        t.vocalOrigPath ??= first.$1.origPath;
        t.vocalPath = first.$2;
        t.clip = first.$3;
      });
      _vocalMix.remove(_sec.id);
      _audio.prepareVocal(LoopStorage.resolveVocal(tuned.first.$2));
    } catch (e) {
      debugPrint('[autotune] failed: $e');
      if (mounted) {
        final message = e is EngineApiException
            ? e.message
            : L10n.of(context).ltEditorAutotuneFailed;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: Duration(milliseconds: 1600),
          ),
        );
      }
    } finally {
      // pop unconditionally via the captured navigator — the `!mounted` early
      // return above also exits through here, so the dialog always closes.
      if (dialogOpen) {
        dialogOpen = false;
        nav.pop(); // progress dialog
      }
      progress.dispose();
    }
  }

  // Open the clip editor (trim/fade/gain + sound processing). Returns the
  // edited vocal TrackData; we swap it in, push undo, and re-prepare playback.
  Future<void> _openVocalEditor() async {
    final vid = _vocalId;
    final t = _trackIn(_tracks, vid);
    if (t.effectiveClips.isEmpty) return;
    final edited = await openVocalEditor(
      context,
      vocal: t,
      bpm: _bpm,
      bars: _sec.bars,
      songId: widget.song.id,
      sectionId: _sec.id,
    );
    if (edited == null || !mounted) return;
    _pushUndo();
    _stopVocal();
    setState(() => _tracks[vid] = edited);
    _vocalMix.remove(_sec.id); // edits change the lane → rebounce
    final first = edited.vocalPath;
    if (first != null) _audio.prepareVocal(LoopStorage.resolveVocal(first));
  }

  /// Restore the dry take on every clip that has one (audit C16 — the whole
  /// lane is tuned, so the whole lane reverts).
  Future<void> _revertAutotune() async {
    final t = _trackIn(_tracks, _vocalId);
    final clips = t.effectiveClips.where((c) => c.origPath != null).toList();
    if (clips.isEmpty) return;
    // re-read the dry peaks before touching state
    final peaksFor = <VocalClip, List<double>>{};
    for (final c in clips) {
      try {
        final wav = parseWav(
          await File(LoopStorage.resolveVocal(c.origPath!)).readAsBytes(),
        );
        if (wav != null) peaksFor[c] = peaksFromPcm(wav.samples);
      } catch (_) {}
    }
    if (!mounted) return;
    _pushUndo();
    setState(() {
      for (final c in clips) {
        c.path = c.origPath!;
        c.origPath = null;
        final p = peaksFor[c];
        if (p != null) c.peaks = p;
      }
      final first = t.effectiveClips.first;
      t.vocalPath = first.path;
      t.vocalOrigPath = null;
      final p = peaksFor[first];
      if (p != null) t.clip = p;
    });
    _vocalMix.remove(_sec.id);
    _audio.prepareVocal(LoopStorage.resolveVocal(t.effectiveClips.first.path));
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
        _litMidis.value = const {};
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
    // Nothing is mutated (and no undo entry pushed) until the engine has
    // answered AND produced notes — a failure leaves the track exactly as it
    // was and offers a retry; no silent generated filler (C12).
    var ok = false;
    try {
      final res = await EngineApi().analyze(audioPath, opts);
      if (!mounted) return;
      final sps = 60 / _bpm / kStepsPerBeat;
      final steps = _steps;
      final t = _activeTrack;
      var count = 0;
      if (drums) {
        final out = <DrumNote>[];
        for (final n in res.notes) {
          // backend loop mode stamps integer step; fall back to seconds→step.
          final step = n.step ?? (n.start / sps).round();
          if (step < 0 || step >= steps) continue;
          final kind = _drumKind(n);
          if (kind == null) continue;
          if (t.drumNotes.any((x) => x.kind == kind && x.step == step)) {
            continue;
          }
          if (out.any((x) => x.kind == kind && x.step == step)) continue;
          out.add(DrumNote(kind: kind, step: step));
        }
        if (out.isEmpty) throw StateError('no drums');
        _pushUndo();
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
        _pushUndo();
        setState(() => t.pitchNotes.addAll(out));
        count = out.length;
      }
      ok = true;
      _toast(L10n.of(context).ltEditorHumAdded(count));
      // Clarity: 분석 성공 + 분기(드럼/멜로딕) 태깅. noteCount 는 이벤트로 분포 확인.
      ClarityService.instance.event('analyze_completed');
      ClarityService.instance.tag('analyze_role', drums ? 'drum' : 'melodic');
    } catch (e) {
      debugPrint('[hum] convert failed: $e');
      if (!mounted) {
        _deleteTempFile(audioPath);
        return;
      }
      // keep the recording for a retry; drop it once the offer goes unanswered
      final ctl = ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar();
      final shown = ctl.showSnackBar(
        SnackBar(
          content: Text(_humErrorMessage(L10n.of(context), e)),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: L10n.of(context).retry,
            onPressed: () => _humConvert(audioPath),
          ),
        ),
      );
      unawaited(shown.closed.then((reason) {
        if (reason != SnackBarClosedReason.action) _deleteTempFile(audioPath);
      }));
    } finally {
      if (ok) _deleteTempFile(audioPath); // temp hum recording (C27)
    }
  }

  /// User-facing reason a hum conversion failed. DioException → status-aware
  /// hints (413 too long, 429 busy, connect timeout = cold server); a run that
  /// simply found no notes says so; anything else is generic.
  String _humErrorMessage(L10n l, Object e) {
    if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 413) return l.ltEditorHumErrTooLong;
      if (code == 429) return l.ltEditorHumErrBusy;
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        return l.ltEditorHumErrWaking;
      }
      return l.ltEditorHumErrGeneric;
    }
    if (e is StateError) return l.ltEditorHumErrNoNotes;
    return l.ltEditorHumErrGeneric;
  }

  /// Best-effort delete of a temp recording handed to us by a modal.
  void _deleteTempFile(String path) {
    unawaited(File(path).delete().then((_) {}, onError: (_) {}));
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

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1400),
      ),
    );
  }

  void _setBars(int b) {
    if (_songSection != null) return;
    _pushUndo();
    setState(() => _sec.bars = b);
  }

  /// Tempo change. While playing, the clock is rebased at the current
  /// playhead so the new tempo takes over smoothly — recomputing elapsed
  /// beats at a new BPM would otherwise jump the playhead (a burst of missed
  /// triggers, or a stall) (C6).
  void _setBpm(int v) {
    if (v == _bpm) return;
    setState(() {
      _bpm = v;
      _dirty = true;
    });
    if (_playing) _startClock();
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
      songVocalPath: _songVocalPath,
      songVocalPeaks: _songVocalPeaks,
      songVocalBpm: _songVocalBpm,
      songVocalBars: _songVocalBars,
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

  /// A brand-new song the user never touched — not in the library yet, no
  /// notes / clips / takes, default title — doesn't earn a library slot (nor
  /// count against the free quota) just for being opened (C15).
  bool _isPristineNew(LoopStore store) {
    if (store.songs.any((s) => s.id == widget.song.id)) return false;
    final title = _title.trim();
    if (title.isNotEmpty && title != 'Untitled loop') return false;
    if (_songVocalPath != null) return false;
    for (final sec in _sections) {
      for (final t in sec.tracks.values) {
        if (t.pitchNotes.isNotEmpty ||
            t.drumNotes.isNotEmpty ||
            t.effectiveClips.isNotEmpty) {
          return false;
        }
      }
    }
    return true;
  }

  // Leaving is in flight (back arrow / system back / edge swipe) — a second
  // request must not save + sweep + pop twice (C4).
  bool _leaving = false;

  Future<void> _backWithSave() async {
    if (_leaving) return;
    _leaving = true;
    final store = context.read<LoopStore>();
    try {
      if (!_isPristineNew(store)) await store.upsert(_snapshot());
      // editor session over → undo stack (the last holder of replaced takes) is
      // gone, so unreferenced vocal files are safe to drop.
      await store.sweepVocals();
    } catch (e) {
      debugPrint('[edit] save on leave failed: $e');
    }
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
    // Fold mutes into the export volume map — the render's only per-lane level
    // control is CC7 from this map (buildMidi has no mute concept), and the
    // vocal mix gain comes from vol['vocal'] too. Muted = volume 0.
    final exportVol = Map.of(_vol);
    for (final e in _mutes.entries) {
      if (e.value) exportVol[e.key] = 0.0;
    }
    await showExportDrawer(
      context,
      title: _title,
      songId: widget.song.id,
      sections: _sections,
      bpm: _bpm,
      swing: _swing,
      vol: exportVol,
      melodyProgram: _instruments['melody'] ?? 0,
      bassProgram: _instruments['bass'] ?? 33,
      melodyDecProgram: _instruments['melodyDec'] ?? 48,
      drumProgram: _instruments['drums'] ?? kDefaultDrumKit,
      extras: extras,
      instruments: Map.of(_instruments),
      songVocalPath: _songVocalPath,
    );
  }

  /// Save indicator 텍스트 — "Saved" (방금) / "Saved · 13:42" (시간 표시) /
  /// "Unsaved" (dirty).
  String _saveLabel(L10n l) {
    if (_savedFlash) return l.ltEditorSaved;
    if (_dirty) return l.ltEditorUnsaved;
    final t = _savedAt;
    if (t == null) return '';
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return l.editSaveAt('$hh:$mm');
  }

  // ── build ─────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final pitched = _isPitched;
    // System back / edge-swipe goes through the same save + sweep as the back
    // arrow (C4) — the route never pops on its own.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _backWithSave();
      },
      child: Scaffold(
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
                      builder:
                          (_, ps, __) => Arrangement(
                            section: _songSection ?? _sec,
                            tracks: _orderedMetas(_songSection ?? _sec),
                            activeId: _activeId,
                            mutes: _mutes,
                            onSelect: (id) => setState(() => _activeId = id),
                            onToggleMute: _toggleMute,
                            // editing only (song-preview is read-only)
                            onAddTrack:
                                _songSection == null ? _openAddTrack : null,
                            onReorder:
                                _songSection == null ? _reorderTracks : null,
                            onMoveClip: _songSection == null ? _moveVocalClip : null,
                            playing: _playing,
                            playStep: _playStep,
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
                          colors: [
                            _meta.color.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                          stops: const [0, 0.6],
                        ),
                      ),
                      child: _surface(),
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  decoration: const BoxDecoration(
                    border: Border(top: BorderSide(color: LT.border)),
                  ),
                  child: TransportBar(
                    playing: _playing,
                    recording: _recording,
                    onPlay: _togglePlay,
                    onStop: _stopAll,
                    onRec: _armRecord,
                    bpm: _bpm,
                    onBpm: _setBpm,
                    metro: _metro,
                    onMetro: (v) {
                      setState(() => _metro = v);
                      LoopPrefs.instance.setMetro(
                        v,
                      ); // keep Settings in sync + persist
                    },
                    countIn: _countIn,
                    onCountIn: (v) => setState(() => _countIn = v),
                    onClear: _clearTrack,
                    swing: _swing,
                    onSwing: (v) => setState(() {
                      _swing = v;
                      _dirty = true;
                    }),
                    bars: _bars,
                    onBars: _setBars,
                    showRecord: trackById(_activeType).kind != TrackKind.vocal,
                  ),
                ),
              ],
            ),
            // Hide the overlay on the final "1" beat (not at 0) so the input
            // surface is already exposed one beat before recording starts —
            // the user can see the pads and play right on the downbeat.
            if (_countDown > 1) _countInOverlay(),
          ],
        ),
      ),
      ),
    );
  }

  Widget _topBar() {
    final l = L10n.of(context);
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
        IconBtn(
          icon: LtIcons.arrowBack,
          size: btnSize,
          tooltip: l.ltEditorBack,
          onTap: _backWithSave,
        ),
        const SizedBox(width: 8),
        const Ms(LtIcons.edit, size: 14, color: LT.t3),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 240),
          child: IntrinsicWidth(
            child: TextField(
              controller: _titleCtl,
              onChanged: (v) {
                _title = v;
                if (!_dirty) setState(() => _dirty = true);
              },
              cursorColor: LT.lime,
              style: LTType.inter(
                size: 14,
                weight: FontWeight.w700,
                color: LT.t1,
              ),
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
                _saveLabel(l),
                key: ValueKey(_saveLabel(l)),
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
        _undoRedoBtn(LtIcons.undo, l.ltEditorUndo, _undo.isNotEmpty, _undoAction),
        const SizedBox(width: 6),
        _undoRedoBtn(LtIcons.redo, l.ltEditorRedo, _redo.isNotEmpty, _redoAction),
        const SizedBox(width: 8),
        IconBtn(
          icon: LtIcons.save,
          size: btnSize,
          tooltip: l.save,
          onTap: _saveNow,
        ),
        const SizedBox(width: 8),
        IconBtn(
          icon: LtIcons.tune,
          size: btnSize,
          tooltip: l.ltMixerTitle,
          onTap: _openMixer,
        ),
        const SizedBox(width: 8),
        Pill(
          label: '$_keyRoot ${ltScaleLabel(l, _scale)}',
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
          tooltip: l.projectOptionExport,
          onTap: _exportOrPaywall,
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: LT.border)),
      ),
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

  Widget _undoRedoBtn(
    IconData icon,
    String tip,
    bool enabled,
    VoidCallback onTap,
  ) {
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      // _topBar 내부 컴팩트 사이즈 (기본 36 → 30).
      child: IconBtn(
        icon: icon,
        size: 30,
        tooltip: tip,
        onTap: enabled ? onTap : null,
      ),
    );
  }

  Widget _surfaceHeader(bool pitched) {
    final hasInstrument =
        _meta.kind == TrackKind.pitched ||
        _meta.kind == TrackKind.bass ||
        _meta.kind == TrackKind.drums;

    final leftGroup = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 트랙 식별 — melody/bass 는 instrument picker pill 이 라벨 역할까지
        // 겸함 (아이콘은 트랙 컬러로 칠해 식별성 유지). 그 외 트랙은 기존
        // 아이콘 + 라벨.
        if (hasInstrument)
          Pill(
            label: instrumentLabel(
              _activeType,
              _instruments[_instrumentTargetId] ?? _meta.defaultProgram,
            ),
            icon: _meta.icon,
            iconColor: _meta.color,
            onTap: _openInstrument,
          )
        else ...[
          Ms(_meta.icon, size: 18, color: _meta.color),
          const SizedBox(width: 8),
          Text(
            _meta.label,
            style: LTType.inter(
              size: 14,
              weight: FontWeight.w800,
              color: LT.t1,
            ),
          ),
        ],
        if (_hasInputToggle) ...[const SizedBox(width: 6), _inputToggle()],
        // chord mode (melody-group pads: melody + melody-fill): pad tap = triad
        if (_meta.group == 'melody' && _inputMode == 'pads') ...[
          const SizedBox(width: 6),
          _chordToggle(),
          const SizedBox(width: 6),
          _powerToggle(),
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
              child: Text(
                upper,
                maxLines: 1,
                style: baseStyle.copyWith(fontSize: minFont),
              ),
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
        if (trackById(_activeType).kind != TrackKind.vocal) ...[
          const SizedBox(width: 8),
          Pill(
              label: L10n.of(context).ltEditorHumToMidi,
              icon: LtIcons.graphicEq,
              onTap: _openHum),
        ],
        const SizedBox(width: 8),
        if (_inputMode == 'grid' && _meta.kind == TrackKind.drums)
          hintSlot(L10n.of(context).ltEditorHintGridDrums)
        else if (_inputMode == 'grid' && pitched)
          hintSlot(L10n.of(context).ltEditorHintGridPitched)
        else
          // Pads 모드의 짧은 hint — 자연 너비 그대로. 빨간 점과 텍스트 간격이
          // hintSlot 의 110dp 고정폭 안에 갇히면 멀어지므로 원래 LtLabel 사용.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 7,
                height: 7,
                decoration: const BoxDecoration(
                  color: LT.danger,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
              LtLabel(L10n.of(context).ltEditorHintPads, color: LT.t3),
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
                child: Text(
                  v == 'pads'
                      ? L10n.of(context).ltEditorModePads
                      : L10n.of(context).ltEditorModeGrid,
                  style: LTType.inter(
                    size: 11,
                    weight: FontWeight.w700,
                    color: _inputMode == v ? LT.bg : LT.t2,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Chord-mode toggle (melody-group pads only): pad tap places a diatonic triad.
  // Independent per track so melody and melody-fill can differ. Enabling chord
  // mode clears power mode (the two are mutually exclusive).
  Widget _chordToggle() => _chordKindToggle(
    label: L10n.of(context).chordModeChord,
    on: _chordOn,
    onTap: () => setState(() {
      final next = !_chordOn;
      _chordMode[_activeId] = next;
      if (next) _powerMode[_activeId] = false;
    }),
  );

  // Power-chord toggle (root + 5th + octave, no third). Mutually exclusive with
  // the chord toggle — enabling it clears chord mode.
  Widget _powerToggle() => _chordKindToggle(
    label: L10n.of(context).ltEditorPowerChord,
    on: _powerOn,
    onTap: () => setState(() {
      final next = !_powerOn;
      _powerMode[_activeId] = next;
      if (next) _chordMode[_activeId] = false;
    }),
  );

  Widget _chordKindToggle({
    required String label,
    required bool on,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: on ? LT.lime : LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.pill),
          border: Border.all(color: on ? LT.lime : LT.border),
        ),
        child: Text(
          label,
          style: LTType.inter(
            size: 11,
            weight: FontWeight.w700,
            color: on ? LT.bg : LT.t2,
          ),
        ),
      ),
    );
  }

  Widget _octaveStepper() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconBtn(
          icon: LtIcons.remove,
          size: 30,
          tooltip: L10n.of(context).ltEditorOctaveDown,
          onTap: () => _setOctave(_octave - 1),
        ),
        SizedBox(
          width: 46,
          child: Text(
            'Oct ${_octave > 0 ? '+' : ''}$_octave',
            textAlign: TextAlign.center,
            style: LTType.mono(size: 11, color: LT.t2),
          ),
        ),
        IconBtn(
          icon: LtIcons.add,
          size: 30,
          tooltip: L10n.of(context).ltEditorOctaveUp,
          onTap: () => _setOctave(_octave + 1),
        ),
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
        child: Text(
          '${w.first.name}–${w.last.name}',
          style: LTType.mono(size: 11, weight: FontWeight.w700, color: LT.t2),
        ),
      ),
    );
  }

  Widget _surface() {
    final kind = _meta.kind;
    final src = _trackIn((_songSection ?? _sec).tracks, _activeId);
    if (kind == TrackKind.drums) {
      // Beat-Fill's pad sounds are user-assignable (per section); the main drums
      // use their fixed kinds. Match by TYPE, not id, so ADDED beat-fill
      // instances (TrackRef type 'beatDec', a distinct id) also get the
      // launchpad UI instead of falling back to the plain drum surface.
      final isFill = _activeType == 'beatDec';
      final kinds = isFill ? _fillKinds : _meta.drumKinds;
      final specs = drumSpecsFor(kinds);
      final map = <String, Set<int>>{};
      for (final n in src.drumNotes) {
        (map[n.kind] ??= <int>{}).add(n.step);
      }
      if (_inputMode == 'grid') {
        return ValueListenableBuilder<double>(
          valueListenable: _playStep,
          builder:
              (_, ps, __) => DrumGrid(
                notes: map,
                onToggle: _toggleDrumCell,
                playStep: ps,
                steps: _steps,
                bars: _bars,
                specs: specs,
              ),
        );
      }
      // Pads mode: Beat-Fill gets the launchpad (6 square pads, no beat grid);
      // the main drums keep the two-thumb + center-grid DrumSurface.
      if (isFill) {
        return ValueListenableBuilder<double>(
          valueListenable: _playStep,
          builder: (_, ps, __) => FillLaunchpad(
            kinds: _fillKinds,
            notes: map,
            playStep: ps,
            steps: _steps,
            onHit: _hitDrum,
            onSwap: _openFillPadPicker,
          ),
        );
      }
      return ValueListenableBuilder<double>(
        valueListenable: _playStep,
        builder:
            (_, ps, __) => DrumSurface(
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
          builder:
              (_, ps, __) => StepGrid(
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
      // Only the pads care which notes are lit, so they subscribe directly
      // instead of the whole editor rebuilding on every 16th (audit C22).
      return ValueListenableBuilder<Set<int>>(
        valueListenable: _litMidis,
        builder: (context, lit, _) => NotePads(
          key: ValueKey('pads-$_activeId'),
          ladder: _activeFullLadder,
          visibleCount: _padCount,
          offset: _windowOffset.clamp(0, _maxWindow),
          litMidis: lit,
          accent: _meta.color,
          onDown: _pitchDown,
          onUp: _pitchUp,
          onSlideStart: _padSlideStart,
          onOffsetChanged: _setWindowOffset,
        ),
      );
    }
    if (kind == TrackKind.vocal) {
      // Base 'vocal' OR an added 'Audio' lane — the surface edits the ACTIVE id.
      final vt = _activeTrack;
      return VocalSurface(
        clip: vt.clip,
        onRecord: _openVocalRecord,
        // "Rec over song" only when the arrangement spans >1 section instance.
        onRecordSong: _sections.fold<int>(0, (a, s) => a + s.repeats) > 1
            ? _openSongVocalRecord
            : null,
        onClearSong: _songVocalPath != null ? _clearSongVocal : null,
        onEdit: vt.effectiveClips.isNotEmpty ? _openVocalEditor : null,
        onAutotune: _openAutotune,
        onRevert: vt.vocalOrigPath != null ? _revertAutotune : null,
        onClear: () {
          _pushUndo();
          _stopVocal();
          setState(() {
            final t = _activeTrack;
            t.clip = null;
            t.clips = null;
            t.vocalPath = null;
            t.vocalOrigPath = null;
            t.vocalAligned = false;
            t.vocalBpm = null;
            t.vocalBars = null;
          });
          _vocalMix.remove(_sec.id);
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
        child: Text(
          '${_meta.label} surface — M3–M4',
          style: LTType.inter(size: 13, color: LT.t3),
        ),
      ),
    );
  }

  Widget _countInOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withValues(alpha: 0.6),
        alignment: Alignment.center,
        child: Text(
          '$_countDown',
          style: LTType.inter(
            size: 96,
            weight: FontWeight.w900,
            color: LT.lime,
          ),
        ),
      ),
    );
  }

  // ── undo / redo ───────────────────────────────────────────────────
  _EditSnapshot _capture() => _EditSnapshot(
    sections: _sections.map((s) => s.deepCopy()).toList(),
    activeIdx: _activeIdx,
    activeId: _activeId,
    keyRoot: _keyRoot,
    scale: _scale,
    bpm: _bpm,
    swing: _swing,
    vol: Map.of(_vol),
    mutes: Map.of(_mutes),
    instruments: Map.of(_instruments),
    title: _title,
    songVocalPath: _songVocalPath,
    songVocalPeaks: _songVocalPeaks,
    songVocalBpm: _songVocalBpm,
    songVocalBars: _songVocalBars,
  );

  /// Snapshot current state before a mutation. [coalesce] merges rapid bursts
  /// (drag-erase, live recording taps) into a single undo step.
  void _pushUndo({bool coalesce = false}) {
    _dirty = true; // every edit passes through here (C24)
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
    // When the undo/redo only changes note content (same arrangement shape) and
    // we're mid-playback, keep the clock running and the playhead where it is —
    // so undo/redo while recording feels seamless instead of jolting to a stop.
    // A structural change (section added/removed, bars/repeats changed) shifts
    // the timeline, so fall back to the safe full stop there.
    final keepPlaying = _playing && _sameArrangement(s);
    if (!keepPlaying && (_playing || _songSection != null)) _stopAll();
    setState(() {
      _sections
        ..clear()
        ..addAll(s.sections.map((x) => x.deepCopy()));
      _activeIdx = s.activeIdx.clamp(0, _sections.length - 1);
      // the restored arrangement may not have the track that was active
      // (undoing "add track") — never leave _activeId dangling (C2).
      _activeId = s.activeId;
      _ensureActiveIdValid();
      _keyRoot = s.keyRoot;
      _scale = kScales.containsKey(s.scale) ? s.scale : 'minor';
      _bpm = s.bpm;
      _swing = s.swing;
      _vol
        ..clear()
        ..addAll(s.vol);
      _mutes
        ..clear()
        ..addAll(s.mutes);
      _instruments
        ..clear()
        ..addAll(s.instruments);
      _title = s.title;
      if (_titleCtl.text != s.title) _titleCtl.text = s.title;
      _songVocalPath = s.songVocalPath;
      _songVocalPeaks = s.songVocalPeaks;
      _songVocalBpm = s.songVocalBpm;
      _songVocalBars = s.songVocalBars;
      if (!keepPlaying) _playStep.value = 0;
    });
    // Play-song preview reads from the flattened display section — rebuild it
    // from the restored arrangement so the running clock plays the right notes.
    if (keepPlaying && _songSection != null) _reflattenSong();
    // re-assert each drum track's kit — pitched programs ride along on every
    // playPitch call, but the drum kit is a sticky synth-side setting.
    _applyDrumKits();
  }

  // True when [s] has the same section/bars/repeats layout as the live song —
  // i.e. only note content differs. Used to decide whether undo/redo can keep
  // playing from the current spot or must stop and reset.
  bool _sameArrangement(_EditSnapshot s) {
    if (s.sections.length != _sections.length) return false;
    for (var i = 0; i < _sections.length; i++) {
      if (s.sections[i].bars != _sections[i].bars ||
          s.sections[i].repeats != _sections[i].repeats) {
        return false;
      }
    }
    return true;
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
    required this.activeId,
    required this.keyRoot,
    required this.scale,
    required this.bpm,
    required this.swing,
    required this.vol,
    required this.mutes,
    required this.instruments,
    required this.title,
    this.songVocalPath,
    this.songVocalPeaks,
    this.songVocalBpm,
    this.songVocalBars,
  });
  final List<Section> sections;
  final int activeIdx;
  final String activeId;
  final String keyRoot, scale, title;
  final int bpm;
  final double swing;
  final Map<String, double> vol;
  final Map<String, bool> mutes;
  final Map<String, int> instruments;
  final String? songVocalPath;
  final List<double>? songVocalPeaks;
  final int? songVocalBpm;
  final int? songVocalBars;
}
