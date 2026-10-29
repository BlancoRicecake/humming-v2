import '../widgets/desktop_workspace.dart';
import '../widgets/desktop_top_bar.dart';
import '../widgets/shortcut_help.dart';
import '../widgets/desktop_instrument.dart';
import '../music/beginner_backing.dart';
import '../widgets/sheets/sample_workbench.dart';

// LoopTap — Editor (the core screen). README §4.
// Vertical stack: top bar · SONG section bar · arrangement strip · surface
// header · track surface · transport bar. A Ticker-driven transport clock
// sweeps a 2/4-bar loop (16 steps/bar), with swing on odd 16ths.
//
// M1: shell + clock + sections + transport wired. Track surfaces land in M2–M4
// (a placeholder fills the surface area for now).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../api/engine_api.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../models/models.dart' as eng;
import '../audio/loop_audio.dart';
import '../audio/vocal_fx_processor.dart';
import '../models/loop_models.dart';
import '../music/hum_map.dart';
import '../music/vocal_midi.dart';
import '../music/melody_review.dart';
import '../music/midi_section_import.dart';
import '../music/drum_note_edit.dart';
import '../music/groove.dart';
import '../music/guitar_stroke.dart';
import '../music/note_random.dart';
import '../music/pan.dart';
import '../music/section_links.dart';
import '../music/pitch_note_edit.dart';
import '../music/pitch_clipboard.dart';
import '../music/audition.dart';
import '../music/guitar_articulation.dart';
import '../music/solo_status.dart';
import '../widgets/solo_status_notice.dart';
import '../music/timeline_view.dart';
import '../widgets/audition_bar.dart';
import '../music/instruments.dart';
import '../music/song_util.dart';
import '../music/soundfont_catalog.dart';
import '../music/theory.dart';
import '../music/wav_codec.dart';
import '../music/wav_export.dart' show bounceVocalClipsStereo, vocalTrackIds;
import '../state/loop_prefs.dart';
import '../state/loop_storage.dart';
import '../state/loop_store.dart';
import '../theme/atoms.dart';
import '../theme/pad_scale.dart';
import '../theme/tokens.dart';
import '../widgets/arrangement.dart';
import '../widgets/save_error.dart';
import '../widgets/guided_hum_panel.dart';
import '../widgets/track_clear_notice.dart';
import '../widgets/section_bar.dart';
import '../widgets/sheets/groove_sheet.dart';
import '../widgets/sheets/hum_modal.dart';
import '../widgets/sheets/paywall_sheet.dart';
import '../widgets/sheets/export_drawer.dart';
import '../widgets/sheets/instrument_sheet.dart';
import '../widgets/sheets/key_sheet.dart';
import '../widgets/sheets/lt_modal.dart';
import '../../audio/headset.dart';
import '../widgets/sheets/mixer_sheet.dart';
import '../widgets/sheets/melody_review_sheet.dart';
import '../widgets/sheets/midi_import_sheet.dart';
import '../widgets/sheets/song_plan_sheet.dart';
import '../widgets/sheets/vocal_record_modal.dart';
import '../widgets/sheets/vocal_editor.dart';
import '../widgets/sheets/vocal_midi_sheet.dart';
import '../widgets/surfaces/drum_surface.dart';
import '../widgets/surfaces/fill_launchpad.dart';
import '../widgets/surfaces/live_pads.dart';
import '../widgets/surfaces/step_grid.dart';
import '../widgets/surfaces/vocal_surface.dart';
import '../widgets/transport_bar.dart';
import '../../services/product_analytics.dart';

class EditScreen extends StatefulWidget {
  const EditScreen({
    super.key,
    required this.song,
    this.guidedStart = false,
    this.guidedEntrySource = 'new_song',
    this.midiFilePicker,
  });
  final String guidedEntrySource;

  /// Test seam for "MIDI passage as new section"; null = the platform picker.
  @visibleForTesting
  final MidiFilePicker? midiFilePicker;
  final bool guidedStart;
  final Song song;

  /// Tests force the desktop (true) or phone (false) layout; null = platform.
  @visibleForTesting
  static bool? debugDesktopOverride;

  @override
  State<EditScreen> createState() => _EditScreenState();
}

// TickerProviderStateMixin (not Single*) — the transport clock disposes and
// re-creates its Ticker on every play/stop, which Single* would assert against.
class _EditScreenState extends State<EditScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final LoopAudio _audio = LoopAudio.instance;
  final PitchClipboard _noteClipboard = PitchClipboard();
  bool _desktopClosing = false;
  bool get _desktop =>
      EditScreen.debugDesktopOverride ??
      (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  /// 편집 확대 applies to the pitched piano roll (docs/specs/grid-usability.md).
  bool get _gridFocused =>
      LoopPrefs.instance.gridFocus.value &&
      _inputMode == 'grid' &&
      (_meta.kind == TrackKind.pitched || _meta.kind == TrackKind.bass);

  /// The timeline folds to one row: desktop collapse, or 편집 확대.
  bool get _timelineFolded =>
      (_desktop && LoopPrefs.instance.timelineCollapsed.value) ||
      _gridFocused;

  void _layoutPrefsChanged() {
    if (mounted) setState(() {});
  }

  /// One-row stand-in for the folded timeline; ▾ brings it back (and ends
  /// 편집 확대).
  Widget _foldedTimeline() {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            Text(
              ko ? '타임라인 접힘' : 'Timeline hidden',
              style: const TextStyle(color: LT.t2, fontSize: 12),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _gridFocused
                    ? (ko ? '편집 확대 중' : 'Editor enlarged')
                    : '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: LT.t3, fontSize: 11),
              ),
            ),
            TextButton.icon(
              key: const ValueKey('timeline-expand'),
              onPressed:
                  () => LoopPrefs.instance.setGridLayout(
                    focus: false,
                    timelineCollapsed: false,
                  ),
              icon: const Icon(Icons.expand_more, size: 16),
              label: Text(
                ko ? '타임라인 펼치기' : 'Show timeline',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
  double _timelineShare = .4;
  double _trackLabelWidth = 220;
  Widget _timelineViewport(Widget Function(TimelineView view) builder) =>
      _desktop
          ? DesktopTimeline(
            steps: _steps,
            labelWidth: _trackLabelWidth,
            onCollapse:
                () => LoopPrefs.instance.setGridLayout(timelineCollapsed: true),
            loopRange: _rangeLoop && _songSection == null ? _playRange : null,
            builder: builder,
          )
          : builder(TimelineView(0, _steps.toDouble()));

  // ── persisted-ish song state ──
  late String _title = widget.song.title;
  // One controller for the title field, owned by the State (C21) — rebuilding
  // it per build reset the cursor on every keystroke.
  late final TextEditingController _titleCtl = TextEditingController(
    text: widget.song.title,
  );
  late String _keyRoot = widget.song.key;
  // unknown scale names (old builds / hand-edited saves) fall back to minor —
  // every kScales lookup below would otherwise `!`-crash (C5).
  late String _scale =
      kScales.containsKey(widget.song.scale) ? widget.song.scale : 'minor';
  late int _bpm = widget.song.bpm;
  late double _swing = widget.song.swing;
  late final Map<String, double> _vol = Map.of(widget.song.vol);
  // mixer-001: track id -> pan p in [-1, 1]; missing = centre.
  late final Map<String, double> _pan = Map.of(widget.song.pan);
  late final Map<String, bool> _mutes = Map.of(widget.song.mutes);
  late final Map<String, bool> _generationLocks = Map.of(
    widget.song.generationLocks,
  );

  // ── sections (each an independent loop × repeats) ──
  // Linked sections (AR-001) share content again after loading.
  late final List<Section> _sections = relinkSections(
    widget.song.sections.map((s) => s.deepCopy()).toList(),
  );
  int _activeIdx = 0;
  BackingStyle? _guidedBacking;
  Section? _guidedPreviewSection;
  int? _guidedPreviewCandidate;
  int? _guidedAppliedCandidate;

  // ── editor runtime ──
  late String _activeId = widget.guidedStart ? 'melody' : 'drums';
  late bool _guided = widget.guidedStart;
  bool _playing = false;
  bool _previewRawMelody = false;
  final Set<String> _solos = {};
  bool _bypassSolo = false;
  bool _rangeLoop = false;
  final Map<String, PlaybackRange> _loopRanges = {};
  int _vocalRevision = 0;
  int _vocalRequest = 0;
  // Bumped by every Play-song start and by _stopAll, so a Play-song whose
  // vocal bounce is still pending can tell it was cancelled / superseded.
  int _songPlayRequest = 0;

  PlaybackRange get _selectedRange {
    final total = stepsForBars(_bars);
    final raw = _loopRanges[_sec.id] ?? PlaybackRange(0, total);
    final start = raw.start.clamp(0, total - 16) ~/ 16 * 16;
    final end = ((raw.end / 16).ceil() * 16).clamp(start + 16, total);
    return PlaybackRange(start, end);
  }

  PlaybackRange get _playRange =>
      _rangeLoop && _songSection == null && !_recording
          ? _selectedRange
          : PlaybackRange(0, _steps);
  bool _audible(String id) =>
      trackIsAudible(id, _mutes, _solos, bypassSolo: _bypassSolo);

  void _silenceTracks() {
    for (final t in _metasFor(_songSection ?? _sec)) {
      if (t.kind == TrackKind.vocal) continue;
      for (final ch in _channelsOf(t)) {
        _audio.stopChannel(ch);
      }
    }
  }

  /// gt-003: stop (and epoch-reset) only the articulation channels of the
  /// playing tracks — every loop wrap does this.
  void _silenceArticulationChannels() {
    for (final t in _metasFor(_songSection ?? _sec)) {
      if (t.kind == TrackKind.vocal) continue;
      for (final ch in _artPlan.channelsOf(t.id)) {
        _audio.stopChannel(ch);
      }
    }
  }

  // ── gt-003 articulations ───────────────────────────────────────────
  /// The song's articulation routing (review ③): recomputed by
  /// [_syncChannelRoles] before playback/audition/export use it, so live,
  /// audition and every export read the same plan.
  ArticulationPlan _artPlan = ArticulationPlan.empty;

  /// Every track's program (base tracks default when unset).
  Map<String, int> get _programMap => {
    for (final t in kPitchedTracks) t.id: _instruments[t.id] ?? t.defaultProgram,
    ..._instruments,
  };

  ArticulationPlan _planFor(List<Section> sections) =>
      ArticulationPlan.build(sections: sections, instruments: _programMap);

  /// A track's own channel plus the articulation channels it owns.
  List<int> _channelsOf(TrackMeta t) => [
    t.channel,
    ..._artPlan.channelsOf(t.id),
  ];

  /// Recompute the plan and give every pooled channel its role (an added
  /// track, an articulation voice, or free). A channel whose role changed is
  /// released (kit/program/pan caches cleared, voices cut) and set up again
  /// for its new owner — drum kit, program, and the owner's pan (CC10).
  void _syncChannelRoles() {
    final plan = _artPlan = _planFor(_sections);
    final roles = <int, String>{};
    final owner = <int, String>{};
    final seen = <String>{};
    for (final sec in _sections) {
      for (final m in _metasFor(sec)) {
        if (m.kind == TrackKind.vocal ||
            !kExtraPitchChannels.contains(m.channel) ||
            !seen.add(m.id)) {
          continue;
        }
        roles[m.channel] =
            '${m.kind == TrackKind.drums ? 'drums' : 'pitched'}:${m.id}';
        owner[m.channel] = m.id;
      }
    }
    for (final r in plan.routes) {
      roles[r.channel] = 'art:${r.trackId}:${r.role.name}';
      owner[r.channel] = r.trackId;
    }
    for (final ch in kExtraPitchChannels) {
      final role = roles[ch] ?? 'free';
      if (!_audio.assignChannelRole(ch, role)) continue;
      final id = owner[ch];
      if (id == null) continue;
      if (role.startsWith('drums:')) {
        _audio.setDrumKitOn(ch, _instruments[id] ?? kDefaultDrumKit);
      } else if (role.startsWith('pitched:')) {
        _audio.setProgram(
          ch,
          _instruments[id] ?? trackById(_typeOf(id)).defaultProgram,
        );
      }
      _audio.setPan(ch, clampPan(_pan[id]));
    }
  }

  /// gt-003: the channel the song would give [role] on the active track if
  /// its notes were [tentative] (apply-time refusal check).
  int? _articulationChannelFor(ArtRole role, List<PitchNote> tentative) {
    final notes = _activeTrack.pitchNotes;
    final saved = List.of(notes);
    try {
      notes
        ..clear()
        ..addAll(tentative);
      return _planFor(_sections).channelFor(_activeId, role);
    } finally {
      notes
        ..clear()
        ..addAll(saved);
    }
  }

  /// One pitched note of track [tk] through the shared realize step
  /// (gt-003). [durSec] is the gate a normal note would get from its start;
  /// [elapsedSteps] (chase / late start) is how much of the note already
  /// passed: the articulation gate counts from the ORIGINAL start, so a
  /// palm/staccato note whose gate already ended stays silent and a running
  /// one plays only its remaining gate. Notes without an articulation take
  /// the pre-G3 call exactly.
  void _playNote(
    TrackMeta tk,
    PitchNote n,
    int midi, {
    required int prog,
    required double vol,
    int? velocity,
    required double durSec,
    double elapsedSteps = 0,
  }) {
    final sps = 60 / _bpm / kStepsPerBeat;
    if (n.articulation == null) {
      _audio.playPitch(
        tk.channel,
        midi,
        program: prog,
        vol: vol,
        velocity: velocity,
        durSec: durSec - elapsedSteps * sps,
      );
      return;
    }
    final ev = realizeArticulation(
      n,
      _artPlan.contextFor(tk.id, _bpm),
      velocity: velocity,
      gateSteps: durSec / sps,
      soundingMidi: midi,
    );
    final gate = (ev.gateSteps - elapsedSteps) * sps;
    if (gate <= 0) return;
    if (ev.channel == null) {
      _audio.playPitch(
        tk.channel,
        ev.key,
        program: prog,
        vol: vol,
        velocity: ev.velocity,
        durSec: gate,
      );
      return;
    }
    _audio.playArticulation(
      channel: ev.channel!,
      program: ev.program!,
      key: ev.key,
      trackChannel: tk.channel,
      soundingMidi: midi,
      trackProgram: prog,
      vol: vol,
      velocity: ev.velocity,
      durSec: gate,
    );
  }

  void _changeLoop({PlaybackRange? range, bool? enabled}) {
    if (_songSection != null || _recording || _countDown > 0) return;
    setState(() {
      if (range != null) _loopRanges[_sec.id] = range.bounded(_steps);
      _rangeLoop = enabled ?? true;
    });
    _restartPhrase();
  }

  void _restartPhrase() {
    if (_songSection != null || _recording || _countDown > 0) return;
    _silenceTracks();
    _stopVocal();
    _freshThisLoop.clear();
    _playStep.value = _playRange.start.toDouble();
    if (_playing) {
      _startClock();
      _startVocalIfAny();
    }
  }

  void _toggleSolo(String id) {
    setState(() {
      if (!_solos.add(id)) _solos.remove(id);
      _bypassSolo = false;
    });
    _refreshAudition();
  }

  void _compareSolo() {
    setState(() => _bypassSolo = !_bypassSolo);
    _refreshAudition(restartPhrase: true);
  }

  void _clearSolo() {
    setState(() {
      _solos.clear();
      _bypassSolo = false;
    });
    _refreshAudition();
  }

  // Pending fractional attacks re-check audibility. Silence sustained notes
  // immediately without interrupting the other tracks or changing saved mutes.
  void _invalidateVocalMix() {
    _vocalRevision++;
    _vocalMix.clear();
  }

  void _refreshAudition({bool restartPhrase = false}) {
    for (final t in _metasFor(_songSection ?? _sec)) {
      if (!_audible(t.id) && t.kind != TrackKind.vocal) {
        for (final ch in _channelsOf(t)) {
          _audio.stopChannel(ch);
        }
      }
    }
    _invalidateVocalMix();
    if (restartPhrase) {
      _restartPhrase();
      return;
    }
    _stopVocal();
    if (!_playing) return;
    if (_songSection == null) {
      _startVocalIfAny();
    } else {
      _refreshSongVocals();
    }
  }

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

  // Per-note chance / velocity variation: the song's seed (null = derived
  // from the id) and the live loop pass the rolls are keyed by.
  late int? _variationSeed = widget.song.variationSeed;
  int get _seed => _variationSeed ?? fnv1a32(widget.song.id);

  // groove-001: the song's own templates, track assignments and Amount.
  late final List<GrooveTemplate> _grooves = List.of(widget.song.grooves);
  late final Map<String, GrooveAssign> _trackGrooves = Map.of(
    widget.song.trackGrooves,
  );
  late double _grooveAmount = widget.song.grooveAmount;
  GrooveContext get _grooveCtx => GrooveContext(
    grooves: List.of(_grooves),
    trackGrooves: Map.of(_trackGrooves),
    amount: _grooveAmount,
    swing: _swing,
  );

  /// Play Song: lanes whose flattened notes already carry groove/Swing.
  Set<String> _songSelfTimed = const {};

  /// Beats (sixteenth steps, velocity) of the last hum/beatbox take, kept in
  /// memory only for "make a groove from the last take".
  List<({double steps, int velocity})>? _lastTakeOnsets;
  int _loopPass = 0;
  bool _skipPassBump = false;
  bool _songVocalActive =
      false; // the live vocal currently IS the song-level take

  // undo / redo — snapshots of the editable song state
  final List<_EditSnapshot> _undo = [];
  final List<_EditSnapshot> _redo = [];
  int _lastUndoMs = 0;

  // transport clock
  Ticker? _ticker;
  double _startStep = 0;
  int _nextAbs = 0;
  final Set<Timer> _playbackTimers = {};

  void _cancelPlaybackTimers() {
    for (final timer in _playbackTimers) {
      timer.cancel();
    }
    _playbackTimers.clear();
  }

  void _playAfter(double seconds, void Function() hit) {
    if (seconds <= 0) {
      hit();
      return;
    }
    late Timer timer;
    timer = Timer(Duration(microseconds: (seconds * 1000000).round()), () {
      _playbackTimers.remove(timer);
      if (mounted && (_playing || _songSection != null)) hit();
    });
    _playbackTimers.add(timer);
  }

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
  List<TrackMeta> _metasFor(Section s) => [
    for (final m in sectionTrackMetas(s.extras))
      m.copyWith(
        label: s.tracks[m.id]?.label,
        drumKinds: s.tracks[m.id]?.drumKinds,
      ),
  ];
  List<TrackMeta> get _editMetas => _metasFor(_sec);
  bool get _ko => Localizations.localeOf(context).languageCode == 'ko';
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
    final byId = {for (final m in _metasFor(s)) m.id: m};
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
  List<Rung> get _melodyFullLadder => buildLadder(
    _keyRoot,
    _scale,
    (_activeIsGuitar ? 2 : 3) + _melodyOctave,
    22,
  );
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

  /// Keep every existing pitch reachable in the grid, including notes moved
  /// outside the pad window or scale. The grid scrolls its own pitch rows.
  // Fixed chromatic rows: recording/pasting a new pitch never remaps a cell.
  List<Rung> get _gridLadder => _gridPitchRows;
  static final List<Rung> _gridPitchRows = [
    for (var midi = 0; midi <= 127; midi++)
      Rung(
        midi: midi,
        name: '${kNoteNames[midi % 12]}${midi ~/ 12 - 1}',
        degree: midi % 12,
        freq: midiToFreq(midi),
        index: midi,
      ),
  ];

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

  /// Fetch the catalog sounds this song needs. Small ones silently; large
  /// ones only after the user agrees, since the GM fallback keeps playing
  /// either way (audit C19b).
  void _prefetchInstruments() {
    final cat = SoundfontCatalog.instance;
    final big = <int>{};
    for (final p in _instruments.values.toSet()) {
      if (!isDynamicSlot(p) || cat.isDownloaded(p)) continue;
      if (cat.mayAutoDownload(p)) {
        cat.ensureDownloaded(p); // fire-and-forget
      } else {
        big.add(p);
      }
    }
    if (big.isEmpty) return;
    // Ask once, after the first frame so a snack bar has a Scaffold.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final l = L10n.of(context);
      final label =
          big.length == 1
              ? (cat.bySlot(big.first)?.label ?? '')
              : '${big.length}';
      final size = big.length == 1 ? cat.sizeLabel(big.first) : null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text(
            size == null
                ? l.ltEditorSoundDownloadAsk(label)
                : l.ltEditorSoundDownloadAskSized(label, size),
          ),
          action: SnackBarAction(
            label: l.ltEditorSoundDownloadNow,
            onPressed: () {
              for (final p in big) {
                SoundfontCatalog.instance.ensureDownloaded(p);
              }
            },
          ),
        ),
      );
    });
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
  bool _guidedSaveTracked = false;
  bool _guidedExitTracked = false;
  late String _guidedEntrySource = widget.guidedEntrySource;

  bool get _hasSongContent =>
      _songVocalPath != null ||
      _sections.any(
        (section) => section.tracks.values.any(
          (track) =>
              track.pitchNotes.isNotEmpty ||
              track.drumNotes.isNotEmpty ||
              track.effectiveClips.isNotEmpty,
        ),
      );

  void _trackGuidedStart(String source) {
    _guidedEntrySource = source;
    _guidedExitTracked = false;
    _guidedSaveTracked = false;
    ProductAnalytics.instance.track(
      ProductEvent.guidedStarted,
      properties: {'feature': 'guided_creation', 'entry_source': source},
    );
  }

  // Only a successful durable save of actual music completes the funnel.
  // Include automatic/back saves so a user who never taps Save is not lost.
  void _trackGuidedSave(String method) {
    if (!_guided || _guidedSaveTracked || !_hasSongContent) return;
    _guidedSaveTracked = true;
    ProductAnalytics.instance.track(
      ProductEvent.guidedSongSaved,
      properties: {
        'feature': 'guided_creation',
        'entry_source': _guidedEntrySource,
        'save_method': method,
      },
    );
  }

  void _trackGuidedExit(String reason) {
    if (!_guided || _guidedExitTracked) return;
    _guidedExitTracked = true;
    ProductAnalytics.instance.track(
      ProductEvent.guidedExited,
      properties: {
        'feature': 'guided_creation',
        'entry_source': _guidedEntrySource,
        'stage':
            _guidedSaveTracked
                ? 'saved'
                : _guidedAppliedCandidate != null
                ? 'backing'
                : _hasSongContent
                ? 'music'
                : 'empty',
        'exit_reason': reason,
      },
    );
  }

  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    LoopPrefs.instance.gridFocus.addListener(_layoutPrefsChanged);
    LoopPrefs.instance.timelineCollapsed.addListener(_layoutPrefsChanged);
    if (widget.guidedStart) {
      _trackGuidedStart(widget.guidedEntrySource);
    }
    // apply this song's chosen instruments (per pitched channel), then warm the synth
    _audio.setPrograms({
      for (final t in kPitchedTracks)
        t.channel: _instruments[t.id] ?? t.defaultProgram,
    });
    _applyDrumKits();
    _applyPans();
    _audio.prewarm();
    // Pre-download the runtime-catalog instruments this song uses so live
    // playback + export resolve the real SF2 (else they fall back to GM until
    // fetched). Small fonts go in the background; a large one (200-400MB) asks
    // first rather than spending the user's data plan silently (audit C19b).
    _prefetchInstruments();
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
    _desktopClosing = true;
    WidgetsBinding.instance.removeObserver(this);
    LoopPrefs.instance.gridFocus.removeListener(_layoutPrefsChanged);
    LoopPrefs.instance.timelineCollapsed.removeListener(_layoutPrefsChanged);
    _titleCtl.dispose();
    _autosaveTimer?.cancel();
    _flashTimer?.cancel();
    for (final t in _strumTimers) {
      t.cancel();
    }
    _noteClipboard.dispose();
    _ticker?.dispose();
    _cancelPlaybackTimers();
    _vocalRequest++;
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
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    if (_playing || _songSection != null || _countDown > 0) _stopAll();
    // The OS may kill a backgrounded app without warning — don't wait for the
    // next 12s autosave tick to persist the latest edits.
    if (_dirty) _autoSaveTick();
  }

  Future<void> _autoSaveTick() async {
    if (!mounted || _leaving) return;
    try {
      final store = context.read<LoopStore>();
      // an untouched brand-new song doesn't earn a library slot yet (C15)
      if (_isPristineNew(store)) return;
      await store.upsert(_snapshot());
      _trackGuidedSave('autosave');
      if (!mounted) return;
      _saveErrorShown = false;
      setState(() {
        _dirty = false;
        _savedAt = DateTime.now();
      });
    } catch (_) {
      _handleSaveFailure(); // Keep edits for the next save attempt.
    }
  }

  // ── transport clock ───────────────────────────────────────────────
  double _swFrac(int a) {
    final s = _playRange.position(a).toInt();
    return (s % 2 == 1) ? _swing * 0.5 : 0;
  }

  void _onTick(Duration elapsed) {
    final range = _playRange;
    final abs =
        _startStep + elapsed.inMicroseconds / 1e6 * (_bpm / 60) * kStepsPerBeat;
    if (abs - _nextAbs > range.length) {
      _nextAbs = abs.ceil();
      _freshThisLoop.clear();
      _cancelPlaybackTimers();
      _silenceTracks();
      _playStep.value = range.position(abs);
      if (_songSection == null) {
        _stopVocal();
        _startVocalIfAny();
      }
    }
    while (abs >= _nextAbs + _swFrac(_nextAbs)) {
      final st = range.position(_nextAbs).toInt();
      if (st == range.start) {
        // a new loop pass (not the very first step when starting at the top)
        if (_skipPassBump) {
          _skipPassBump = false;
        } else {
          _loopPass++;
        }
        _freshThisLoop.clear();
        _cancelPlaybackTimers();
        // Cleanup first, then plan sync, P1 onsets and chase, then the
        // trigger below: a voice started at the wrap is never cut by it.
        // A range loop silences every channel of its tracks; a plain wrap
        // only the gt-003 articulation channels (G0–G2 tracks unchanged).
        final rangeWrap = _rangeLoop && _songSection == null && !_recording;
        if (rangeWrap) {
          _silenceTracks();
        } else {
          _silenceArticulationChannels();
        }
        _syncChannelRoles();
        // P1: strings of a converted hit stored before the range start but
        // sounding inside it (once per pass, after the timer reset above)
        _scheduleLaterCellOnsets(
          from: range.start.toDouble(),
          firstCell: range.start,
          now: range.position(abs),
        );
        if (rangeWrap) {
          _chasePitched(range.position(abs), before: range.start.toDouble());
        }
        if (_vocalRestartAtWrap && _songSection == null) {
          _vocalRestartAtWrap = false;
          _stopVocal();
          _startVocalIfAny(atStep: range.position(abs));
        } else if (_vocalPlaying &&
            !_vocalLoopNative &&
            (_songSection == null || _songVocalActive)) {
          _audio.seekVocal(
            Duration(
              microseconds:
                  (range.position(abs) * 60 / _bpm / kStepsPerBeat * 1e6)
                      .round(),
            ),
          );
        }
      }
      _trigger(st, lateSteps: abs - _nextAbs - _swFrac(_nextAbs));
      _nextAbs++;
    }
    _playStep.value = range.position(abs);
  }

  Map<String, TrackData> get _effectiveTracks =>
      _songSection?.tracks ?? _guidedPreviewSection?.tracks ?? _tracks;

  void _trigger(int step, {double lateSteps = 0}) {
    _syncChannelRoles();
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
    final playing = _songSection ?? _guidedPreviewSection ?? _sec;
    final grooves = _grooveCtx;
    for (final tk in _metasFor(playing)) {
      if (!_audible(tk.id)) continue;
      final data = T[tk.id];
      if (data == null) continue;
      // groove-001: a grooved lane schedules each note at its grooved time
      // instead of following the clock's Swing.
      final timing = _liveTiming(playing, tk.id, grooves);
      if (timing != null && tk.kind != TrackKind.vocal) {
        _triggerGrooved(tk, data, step, lateSteps, timing, litM);
        continue;
      }
      if (tk.kind == TrackKind.pitched || tk.kind == TrackKind.bass) {
        final prog = _instruments[tk.id] ?? tk.defaultProgram;
        final vol = _vol[tk.id] ?? 0.85;
        // chance / velocity variation for this pass (Play Song notes arrive
        // already rolled, so this is a no-op for them)
        PitchNote? realize(PitchNote n) => _realize(n, tk.id);
        final due = [
          for (final n in data.pitchNotes.where((n) => n.step == step))
            if (!_freshThisLoop.contains('${tk.id}:${n.midi}:$step') &&
                realize(n) != null)
              n,
        ];
        int previewMidi(PitchNote n) =>
            _previewRawMelody && tk.id == 'melody'
                ? (n.sourceMidi ?? n.midi)
                : n.midi;
        // gt-001: hits holding converted (stroke-tagged) notes never take
        // the legacy strum; strum pairs are index-stable (no pitch-keyed map).
        final strum = liveLegacyStrum(
          due,
          guitar: isGuitarProgram(prog),
          midiOf: previewMidi,
        );
        if (strum != null) {
          // strum the chord on playback the same way the live pad does
          for (final s in strum) {
            final note = s.note;
            void hit() {
              // A note muted/edited after scheduling is a new object, so the
              // identity check also drops it right before it would sound.
              if (!_audible(tk.id) ||
                  realize(note) == null ||
                  _effectiveTracks[tk.id]?.pitchNotes.contains(note) != true) {
                return;
              }
              _playNote(
                tk,
                note,
                s.midi,
                prog: prog,
                vol: vol * s.velScale,
                durSec: _playRange.gateSeconds(
                  step + s.delayMs / 1000 / sps,
                  dsec(note.dur),
                  sps,
                ),
              );
            }

            if (s.delayMs / 1000 >= (_playRange.end - step - lateSteps) * sps) {
              continue;
            }
            // Validate scheduled strum notes again after a possible grid edit.
            if (s.delayMs <= 0) {
              hit();
            } else {
              _playAfter(s.delayMs / 1000, hit);
            }
          }
        } else {
          for (final n in due) {
            _playAfter(math.max(0, n.offsetSteps - lateSteps) * sps, () {
              // A note moved/deleted/muted after scheduling must not sound at
              // its old time while the loop is running.
              // Re-roll right before sounding: a chance/variation edit made
              // after scheduling is honored.
              final played = realize(n);
              if (!_audible(tk.id) ||
                  played == null ||
                  _effectiveTracks[tk.id]?.pitchNotes.contains(n) != true) {
                return;
              }
              final gate = _playRange.gateSeconds(
                math.max(n.startSteps, step + lateSteps),
                // gt-003: an articulated note gates from its own length
                // (as the export), never the legacy pad gate
                n.durationSteps == null && n.articulation == null
                    ? dsec(n.dur)
                    : n.soundingSteps * sps,
                sps,
              );
              if (gate <= 0) return;
              _playNote(
                tk,
                n,
                previewMidi(n),
                prog: prog,
                vol: vol,
                velocity: played.velocity,
                durSec: gate,
              );
            });
          }
        }
        // glow only the ACTIVE track's pads — otherwise a melody note would
        // light a same-pitch pad on melody-fill/bass while they're showing.
        if (tk.id == _activeId) {
          for (final n in due) {
            litM.add(previewMidi(n));
          }
        }
      } else if (tk.kind == TrackKind.drums) {
        // muted hits and failed chance rolls never reach the synth
        for (final hit in soundingDrumHits(
          data.drumNotes,
          step,
          seed: _seed,
          sectionId: (_songSection ?? _guidedPreviewSection ?? _sec).id,
          trackId: tk.id,
          pass: _loopPass,
        )) {
          final n = hit.note;
          if (_freshThisLoop.contains('${tk.id}:${n.kind}:$step')) continue;
          _playAfter(math.max(0, n.offsetSteps - lateSteps) * sps, () {
            // re-roll right before sounding: a later chance/mute edit is a
            // new object and drops out through the identity check
            final played = _realizeDrum(n, tk.id);
            if (!_audible(tk.id) ||
                played == null ||
                _effectiveTracks[tk.id]?.drumNotes.contains(n) != true ||
                !_playRange.contains(step + lateSteps)) {
              return;
            }
            _audio.playDrum(
              n.kind,
              channel: tk.channel,
              vol: _vol[tk.id] ?? 1,
              velocity: played.velocity,
            );
          });
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

  /// What [n] on track [trackId] plays this pass (null = silent this pass).
  PitchNote? _realize(PitchNote n, String trackId) => realizePitchNote(
    n,
    seed: _seed,
    sectionId: (_songSection ?? _guidedPreviewSection ?? _sec).id,
    trackId: trackId,
    pass: _loopPass,
  );

  /// Live groove timing for [trackId] while [playing] sounds: the note's
  /// effective start (loop steps) and velocity, or null when the clock's
  /// Swing applies. Play Song notes arrive with their groove already baked.
  ({double start, int? velocity}) Function(double start, int? velocity)?
  _liveTiming(Section playing, String trackId, GrooveContext grooves) {
    if (_songSection != null) {
      if (!_songSelfTimed.contains(trackId)) return null;
      return (start, velocity) => (start: start, velocity: velocity);
    }
    final g = grooves.resolve(playing, trackId);
    if (g == null) return null;
    return (start, velocity) => applyGroove(
      start,
      velocity,
      g.template,
      g.assign,
      amount: grooves.amount,
    );
  }

  /// Trigger step [step] of a grooved lane: every note whose grooved start
  /// falls in this step's slot (see [liveGrooveSlot] — notes pulled early are
  /// picked up one step ahead) is scheduled after the trigger.
  void _triggerGrooved(
    TrackMeta tk,
    TrackData data,
    int step,
    double lateSteps,
    ({double start, int? velocity}) Function(double start, int? velocity)
    timing,
    Set<int> lit,
  ) {
    final sps = 60 / _bpm / kStepsPerBeat;
    final trig = step + swingOffset(step, _swing);
    // a note pulled ahead of a loop range's first step fires at that step
    bool due(int cell, double start) {
      var k = liveGrooveSlot(start, _swing, _steps).trigger;
      if (k < _playRange.start && cell >= _playRange.start) {
        k = _playRange.start;
      }
      return k == step;
    }
    if (tk.kind == TrackKind.drums) {
      for (final n in data.drumNotes) {
        final g = timing(n.startSteps, n.velocity);
        if (!due(n.step, g.start) ||
            _freshThisLoop.contains('${tk.id}:${n.kind}:${n.step}')) {
          continue;
        }
        final base =
            g.velocity == n.velocity ? n : n.copyWith(velocity: g.velocity);
        if (_realizeDrum(base, tk.id) == null) continue;
        _playAfter(math.max(0, g.start - trig - lateSteps) * sps, () {
          final played = _realizeDrum(base, tk.id);
          if (!_audible(tk.id) ||
              played == null ||
              _effectiveTracks[tk.id]?.drumNotes.contains(n) != true ||
              !_playRange.contains(n.step)) {
            return;
          }
          _audio.playDrum(
            n.kind,
            channel: tk.channel,
            vol: _vol[tk.id] ?? 1,
            velocity: played.velocity,
          );
        });
      }
      return;
    }
    final prog = _instruments[tk.id] ?? tk.defaultProgram;
    final vol = _vol[tk.id] ?? 0.85;
    for (final n in data.pitchNotes) {
      final g = timing(n.startSteps, n.velocity);
      if (!due(n.step, g.start) ||
          _freshThisLoop.contains('${tk.id}:${n.midi}:${n.step}')) {
        continue;
      }
      final base =
          g.velocity == n.velocity ? n : n.copyWith(velocity: g.velocity);
      if (_realize(base, tk.id) == null) continue;
      final midi =
          _previewRawMelody && tk.id == 'melody'
              ? (n.sourceMidi ?? n.midi)
              : n.midi;
      if (tk.id == _activeId) lit.add(midi);
      _playAfter(math.max(0, g.start - trig - lateSteps) * sps, () {
        final played = _realize(base, tk.id);
        if (!_audible(tk.id) ||
            played == null ||
            _effectiveTracks[tk.id]?.pitchNotes.contains(n) != true ||
            // P1: a later-cell string counts where it sounds, not its cell
            !_playRange.contains(onsetInLaterCell(n) ? g.start : n.step)) {
          return;
        }
        final gate = _playRange.gateSeconds(
          math.max(g.start, step + lateSteps),
          n.durationSteps == null && n.articulation == null
              ? (n.dur * sps * 0.95).clamp(0.12, 8)
              : n.soundingSteps * sps,
          sps,
        );
        if (gate <= 0) return;
        _playNote(
          tk,
          n,
          midi,
          prog: prog,
          vol: vol,
          velocity: played.velocity,
          durSec: gate,
        );
      });
    }
  }

  DrumNote? _realizeDrum(DrumNote n, String trackId) => realizeDrumNote(
    n,
    seed: _seed,
    sectionId: (_songSection ?? _guidedPreviewSection ?? _sec).id,
    trackId: trackId,
    pass: _loopPass,
  );

  /// P1 (gt-001): play-start / loop-wrap scheduling for converted strings
  /// whose actual onset lies in a later cell than their stored step
  /// ([onsetInLaterCell]) when this pass starts after that cell. The pass
  /// triggers cells [firstCell].. only, so these notes would otherwise be
  /// skipped; [laterCellOnsets] lists each once, never a note the pass's
  /// own cell triggers reach. [now] is the current play position. Stop and
  /// the next wrap cancel the timers like every other scheduled note.
  void _scheduleLaterCellOnsets({
    required double from,
    required int firstCell,
    required double now,
  }) {
    final sps = 60 / _bpm / kStepsPerBeat;
    final range = _playRange;
    final playing = _songSection ?? _guidedPreviewSection ?? _sec;
    final grooves = _grooveCtx;
    final T = _effectiveTracks;
    for (final tk in _metasFor(playing)) {
      if (tk.kind != TrackKind.pitched && tk.kind != TrackKind.bass) continue;
      final data = T[tk.id];
      if (data == null || !_audible(tk.id)) continue;
      final timing = _liveTiming(playing, tk.id, grooves);
      ({double start, int? velocity}) grooved(PitchNote n) =>
          timing!(n.startSteps, n.velocity);
      final pending = laterCellOnsets(
        data.pitchNotes,
        range,
        from: from,
        firstCell: firstCell,
        cellOf:
            timing == null
                ? null
                : (n) {
                  var k =
                      liveGrooveSlot(grooved(n).start, _swing, _steps).trigger;
                  if (k < range.start && n.step >= range.start) k = range.start;
                  return k;
                },
        onsetOf: timing == null ? null : (n) => grooved(n).start,
      );
      final prog = _instruments[tk.id] ?? tk.defaultProgram;
      final vol = _vol[tk.id] ?? 0.85;
      for (final p in pending) {
        final n = p.note;
        if (_freshThisLoop.contains('${tk.id}:${n.midi}:${n.step}')) continue;
        final g = timing == null ? null : grooved(n);
        final base =
            g == null || g.velocity == n.velocity
                ? n
                : n.copyWith(velocity: g.velocity);
        if (_realize(base, tk.id) == null) continue;
        // a plain lane's cell fires on the clock's Swing, then the offset
        final at = g == null ? p.onset + swingOffset(n.step, _swing) : p.onset;
        _playAfter(math.max(0, at - now) * sps, () {
          final played = _realize(base, tk.id);
          if (!_audible(tk.id) ||
              played == null ||
              _effectiveTracks[tk.id]?.pitchNotes.contains(n) != true) {
            return;
          }
          final gate = _playRange.gateSeconds(
            p.onset,
            n.durationSteps == null && n.articulation == null
                ? (n.dur * sps * 0.95).clamp(0.12, 8)
                : n.soundingSteps * sps,
            sps,
          );
          if (gate <= 0) return;
          _playNote(
            tk,
            n,
            _previewRawMelody && tk.id == 'melody'
                ? (n.sourceMidi ?? n.midi)
                : n.midi,
            prog: prog,
            vol: vol,
            velocity: played.velocity,
            durSec: gate,
            // gt-003: an onset already behind the play position plays only
            // what is left of its articulation gate
            elapsedSteps: n.articulation == null ? 0 : math.max(0, now - at),
          );
        });
      }
    }
  }

  // Chase held notes when a phrase begins in the middle of a sustained chord.
  // This is only a playback gate; the imported notes are never split/rewritten.
  void _chasePitched(double position, {double? before}) {
    final sps = 60 / _bpm / kStepsPerBeat;
    for (final tk in _metasFor(_songSection ?? _guidedPreviewSection ?? _sec)) {
      if (!_audible(tk.id) ||
          (tk.kind != TrackKind.pitched && tk.kind != TrackKind.bass)) {
        continue;
      }
      for (final gate in chasedPitchGates(
        [
          for (final n in _effectiveTracks[tk.id]?.pitchNotes ?? <PitchNote>[])
            if (_realize(n, tk.id) case final played?) played,
        ],
        _playRange,
        position,
        before: before,
      )) {
        final n = gate.note;
        // gt-003: the articulation gate counts from the note's original
        // start; [_playNote] subtracts what already passed (silent when the
        // gate already ended). A normal note keeps its pre-G3 gate exactly.
        final elapsed = n.articulation == null ? 0.0 : position - n.startSteps;
        _playNote(
          tk,
          n,
          _previewRawMelody && tk.id == 'melody'
              ? (n.sourceMidi ?? n.midi)
              : n.midi,
          prog: _instruments[tk.id] ?? tk.defaultProgram,
          vol: _vol[tk.id] ?? .85,
          velocity: n.velocity,
          durSec: (gate.steps + elapsed) * sps,
          elapsedSteps: elapsed,
        );
      }
    }
  }

  void _startClock() {
    // gt-003: the latest plan before the chase and the first trigger
    _syncChannelRoles();
    _cancelPlaybackTimers();
    _ticker?.dispose();
    final range = _playRange;
    if (!range.contains(_playStep.value)) {
      _playStep.value = range.start.toDouble();
    }
    _freshThisLoop.clear();
    _startStep = _playStep.value;
    _nextAbs = _startStep.ceil();
    _loopPass = 0;
    _skipPassBump = range.position(_nextAbs).toInt() == range.start;
    _chasePitched(_startStep);
    // P1: a pass starting at the range start schedules these in the wrap
    // branch of _onTick (which resets the timers first)
    if (!_skipPassBump) {
      _scheduleLaterCellOnsets(
        from: _startStep,
        firstCell: range.position(_nextAbs).toInt(),
        now: _startStep,
      );
    }
    // Ticker.elapsed starts at ~0 on start(), so it doubles as our clock base.
    _ticker = createTicker(_onTick)..start();
  }

  void _stopClock() {
    _cancelPlaybackTimers();
    _ticker?.dispose();
    _ticker = null;
  }

  /// Scrub the playhead to [step] (arrangement drag). While playing, rebase the
  /// clock so playback continues from the new position; song-preview is read-only.
  void _seekTo(double step) {
    if (_songSection != null) return;
    final s = step.clamp(_playRange.start.toDouble(), _playRange.end - .000001);
    _playStep.value = s;
    if (_playing) {
      _silenceTracks();
      _stopVocal();
      _startVocalIfAny(atStep: s);
      _freshThisLoop.clear();
      _startClock(); // rebase elapsed to the new position
    }
  }

  // ── add-track ─────────────────────────────────────────────────────
  /// Append a new instance of [type] (one of the base track ids) to EVERY
  /// section so the track set stays consistent across the song, then select it.
  void _addTrack(String type) {
    if (trackById(type).kind != TrackKind.vocal &&
        _sec.extras
                .where((e) => trackById(e.type).kind != TrackKind.vocal)
                .length >=
            kExtraPitchChannels.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Independent instrument limit reached.')),
      );
      return;
    }
    _pushUndo();
    final id = '${type}_x${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      for (final s in _sections) {
        s.extras.add(TrackRef(id, type));
        // linked sections share one map: never overwrite a lane already added
        s.tracks.putIfAbsent(id, TrackData.new);
      }
      _instruments[id] = trackById(type).defaultProgram;
      _activeId = id;
      _inputModes[id] = 'pads';
    });
    // gt-003: the new track may take a channel an articulation voice used
    _syncChannelRoles();
    // a new drum track needs its kit selected on its freshly-allocated channel
    if (trackById(type).kind == TrackKind.drums) {
      final m = _editMetas.firstWhere((t) => t.id == id);
      _audio.setDrumKitOn(m.channel, _instruments[id] ?? kDefaultDrumKit);
    }
    _applyPans(); // the new track's channel starts centred
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
        _applyPans();
        _startClock();
        if (_songSection == null) {
          _startVocalIfAny();
        } else {
          _refreshSongVocals();
        }
      } else {
        _stopClock();
        _silenceTracks();
        _stopVocal();
      }
    });
  }

  void _stopAll() {
    _stopClock();
    _audio.stopAll();
    _vocalRequest++;
    _songPlayRequest++;
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
      _playStep.value = _playRange.start.toDouble();
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
      if (_rangeLoop && _songSection == null) {
        _toast(
          Localizations.localeOf(context).languageCode == 'ko'
              ? '녹음은 전체 구간에서 진행합니다. 비교용 구간 반복을 해제했습니다.'
              : 'Recording uses the full section. Audition range loop turned off.',
        );
      }
      if (_rangeLoop && _songSection == null) {
        _changeLoop(enabled: false);
      }
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
    if (_playing || _songSection != null || _countDown > 0) _stopAll();
    setState(() {
      _activeIdx = idx;
      _ensureActiveIdValid();
      _playStep.value = _playRange.start.toDouble();
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
          ..linkId =
              null // plain Duplicate is independent (AR-001)
          ..autoName =
              true // a duplicate gets a fresh position letter
          ..name = _nextSectionName();
    setState(() {
      _sections.insert(idx + 1, copy);
      _relabelSections();
      _activeIdx = idx + 1;
      _playStep.value = 0;
    });
  }

  /// AR-001 linked duplicate: a new section after [idx] sharing its content.
  void _duplicateSectionLinked(int idx) {
    if (_songSection != null) return;
    _pushUndo();
    if (_playing) _stopAll();
    final copy = duplicateLinked(
      _sections[idx],
      'sec${DateTime.now().millisecondsSinceEpoch}',
    )
      ..autoName = true
      ..name = _nextSectionName();
    setState(() {
      _sections.insert(idx + 1, copy);
      _relink();
      _relabelSections();
      _activeIdx = idx + 1;
      _playStep.value = 0;
    });
  }

  /// AR-001 Make unique: [idx] keeps a copy of the current content and
  /// leaves its link group (its vocal clips still point at the same files).
  /// MIDI passage → a new unlinked section right after [idx]
  /// (docs/specs/midi-section-import.md). Tempo, key/scale, swing, existing
  /// instruments and mix stay as they are; one undo step covers the section
  /// and any new track (refs, empty lanes, program).
  Future<void> _importMidiSection(int idx) async {
    if (_songSection != null) return;
    final result = await pickMidiSection(
      context,
      target: MidiSectionTarget(
        sections: _sections,
        currentIdx: idx,
        instruments: _programMap,
        keyRoot: _keyRoot,
        scale: _scale,
        bpm: _bpm,
      ),
      picker: widget.midiFilePicker,
    );
    if (result == null || !mounted || _songSection != null) return;
    _pushUndo();
    if (_playing) _stopAll();
    setState(() {
      applyMidiSection(_sections, idx, result, _instruments);
      for (final e in result.newTracks) {
        _inputModes[e.id] = 'pads';
      }
      _activeIdx = idx + 1;
      _ensureActiveIdValid();
      _playStep.value = 0;
    });
    // new tracks take free channels (never an articulation voice's)
    _syncChannelRoles();
    if (result.newTracks.isNotEmpty) {
      _applyDrumKits();
      _applyPans();
    }
    _toast(
      _ko
          ? "섹션 '${result.section.name}' 추가 · 노트 ${result.notes} · 건너뜀 ${result.skipped} · 스케일 밖 ${result.outOfScale}"
          : "Added section '${result.section.name}' · ${result.notes} notes · ${result.skipped} skipped · ${result.outOfScale} out of scale",
    );
  }

  void _makeUnique(int idx) {
    if (_sections[idx].linkId == null || _songSection != null) return;
    _pushUndo();
    if (_playing) _stopAll();
    setState(() {
      _sections[idx] = makeUnique(_sections[idx]);
      _relink();
      _relabelSections();
    });
  }

  void _relink() {
    final next = relinkSections(_sections);
    _sections
      ..clear()
      ..addAll(next);
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
      _relink(); // a group left with one section is no longer linked
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
                  Icons.link,
                  _ko ? '연결 복제' : 'Linked duplicate',
                  () {
                    Navigator.of(context).pop();
                    _duplicateSectionLinked(idx);
                  },
                  key: const ValueKey('section-dup-linked'),
                ),
                _menuRow(
                  Icons.library_music,
                  _ko ? 'MIDI 구간을 새 섹션으로' : 'MIDI passage as new section',
                  _songSection == null
                      ? () {
                        Navigator.of(context).pop();
                        _importMidiSection(idx);
                      }
                      : null,
                  key: const ValueKey('section-midi-import'),
                ),
                if (_sections[idx].linkId != null)
                  _menuRow(
                    Icons.link_off,
                    _ko ? '독립시키기' : 'Make unique',
                    () {
                      Navigator.of(context).pop();
                      _makeUnique(idx);
                    },
                    key: const ValueKey('section-make-unique'),
                  ),
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

  Widget _menuRow(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    Key? key,
  }) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: GestureDetector(
        key: key,
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
    // Leaving single-section play: stop its clock + section vocal first so the
    // two never overlap (and so the `_playing` check below means "restarted").
    if (_playing || _countDown > 0) _stopAll();
    // Stop / another Play / Play-song during the bounce supersedes this start.
    final request = ++_songPlayRequest;
    bool superseded() =>
        !mounted ||
        request != _songPlayRequest ||
        _playing ||
        _countDown > 0 ||
        _songSection != null;
    // Bounce each section's vocal lanes once (cached), then schedule that mix at
    // every section instance — so the full-song preview hears all takes/Audio
    // lanes/trims, matching export (not just the first raw take). Re-run
    // (cached sections return at once) if a vocal edit or a new section landed
    // during the awaits, so the schedule matches what's on screen.
    final mixBySec = <String, String?>{};
    var revision = -1;
    while (revision != _vocalRevision ||
        _sections.any((s) => !mixBySec.containsKey(s.id))) {
      revision = _vocalRevision;
      mixBySec.clear();
      for (final sec in List.of(_sections)) {
        final file = await _sectionVocalFile(sec);
        if (superseded()) return;
        mixBySec[sec.id] = file;
      }
    }
    // Flatten AFTER the awaits so edits made meanwhile are what plays. The
    // song's variation seed makes Play Song sound exactly like the export.
    final flat = flattenSong(
      _sections,
      variationSeed: _seed,
      groove: _grooveCtx,
    );
    _songSelfTimed = flat.selfTimed;
    final disp = _songDisplay(flat);
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
    _applyPans(); // song display may allocate added tracks' channels anew
    // A song-level take plays from step 0 and REPLACES the per-section vocals;
    // otherwise fall back to the per-section schedule.
    if (_songVocalPath != null) {
      _songVocalSched = null;
      final native = _songVocalBpm == _bpm && _songVocalBars == _songTotalBars;
      _vocalLoopNative = native;
      _vocalPlaying = _audible('vocal');
      _vocalIsMix = false;
      _songVocalActive = true;
      if (_vocalPlaying) {
        _audio.playVocal(
          LoopStorage.resolveVocal(_songVocalPath!),
          vol: _vol['vocal'] ?? 0.85,
          loop: native,
          balance: _pan['vocal'] ?? 0,
        );
      }
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
    final flat = flattenSong(
      _sections,
      variationSeed: _seed,
      groove: _grooveCtx,
    );
    _songSelfTimed = flat.selfTimed;
    _fillSongTracks(s, flat);
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
    disp.tracks['vocal'] =
        _songVocalPeaks != null
            ? TrackData(clip: _songVocalPeaks)
            : (_sec.tracks['vocal']?.deepCopy() ?? TrackData());
  }

  // Re-assert every drum track's kit on its channel: base drums on ch9, beat-fill
  // on ch10, and each added drum track on its own channel — every drum track owns
  // an independent kit. The drum kit is a sticky synth-side selection, so this
  // runs on open / undo-restore / after adding a track.
  void _applyDrumKits() {
    _audio.setDrumKitOn(
      LoopAudio.drumChannel,
      _instruments['drums'] ?? kDefaultDrumKit,
    );
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
        _audio.playDrum(
          kind,
          channel: _meta.channel,
          vol: _vol[_activeId] ?? 1,
        );
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
        onPreview:
            (k) => _audio.playDrum(
              k,
              channel: _meta.channel,
              vol: _vol[_activeId] ?? 1,
            ),
      ),
    );
    if (picked == null || picked == current) return;
    _pushUndo();
    setState(() {
      _sec.fillKinds[padIndex] = picked;
      // Remap the swapped-away sound's notes → the new sound, deduping any
      // (kind, step) collision with notes the new sound already had. Operate on
      // the ACTIVE beat-fill track (could be an added instance, not 'beatDec').
      // copyWith keeps each hit's velocity, timing, chance and mute.
      final track = _activeTrack;
      final remapped = remapDrumKind(track.drumNotes, current, picked);
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
  List<int> _chordMidis(int rootMidi) => padChordMidis(
    rootMidi,
    melodyGroup: _meta.group == 'melody',
    chordOn: _chordOn,
    powerOn: _powerOn,
    // Guitar gets the spread barre/open (or low power) voicing; either way
    // the voiced notes are what gets stored on release, so playback/export
    // stay in sync.
    guitar: _activeIsGuitar,
    key: _keyRoot,
    scale: _scale,
  );

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
        void hit() =>
            _audio.noteOnLive(ch, s.midi, program: prog, vol: vol * s.velScale);
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
    final tgt = _recTarget(
      p.step,
    ); // p.step is the played step (global in song mode)
    if (tgt == null) return; // song-mode playhead/active track didn't resolve
    _pushUndo(coalesce: true);
    for (final m in midis) {
      _placePitched(
        tgt.tracks,
        _activeId,
        _rungFor(m, n),
        tgt.step,
        tgt.step + dur - 1,
      );
      // heard live now → don't let the clock replay it this loop pass (the clock
      // checks the played/global step).
      _freshThisLoop.add('$_activeId:$m:${p.step}');
    }
    if (_songSection != null) _reflattenSong(); // so it plays on the next pass
  }

  /// Place [a,b] without replacing the expression of existing MIDI notes.
  /// [tracks] is the active section or the section under a song-mode overdub.
  void _placePitched(
    Map<String, TrackData> tracks,
    String id,
    Rung n,
    int a,
    int b,
  ) {
    final notes = _trackIn(tracks, id).pitchNotes;
    final edited = paintPitchSpan(
      notes,
      PitchNote(
        midi: n.midi,
        freq: n.freq,
        step: math.min(a, b),
        dur: (a - b).abs() + 1,
      ),
    );
    if (identical(edited, notes)) return;
    setState(() {
      notes
        ..clear()
        ..addAll(edited);
    });
  }

  void _previewGridNote(Rung n, {double duration = .25}) {
    // The transport owns scheduled voices while playing; auditioning the same
    // channel/key here would replace its release timer and truncate the loop.
    if (_playing) return;
    _audio.playPitch(
      _meta.channel,
      n.midi,
      program: _instruments[_activeId] ?? _meta.defaultProgram,
      vol: _vol[_activeId] ?? .85,
      durSec: duration,
    );
  }

  /// gt-003 grid audition of an existing articulated note: the same realize
  /// step and plan as playback (palm/harmonic tone on its channel).
  void _previewGridPitchNote(PitchNote n) {
    if (_playing) return;
    _syncChannelRoles();
    _playNote(
      _meta,
      n,
      n.midi,
      prog: _instruments[_activeId] ?? _meta.defaultProgram,
      vol: _vol[_activeId] ?? .85,
      velocity: n.velocity,
      // the note's own length, then the articulation cap (as playback)
      durSec: n.soundingSteps * 60 / _bpm / kStepsPerBeat,
    );
  }

  // grid place/erase work on the active pitched track (melody / melody-fill / bass)
  void _gridPlace(Rung n, int a, int b) {
    if (_songSection != null) return;
    _pushUndo(coalesce: true);
    // preview sound length matches the drawn note length
    final sps = 60 / _bpm / kStepsPerBeat;
    final durSec = (((a - b).abs() + 1) * sps * 0.95).clamp(0.12, 8.0);
    _previewGridNote(n, duration: durSec);
    _placePitched(_tracks, _activeId, n, a, b);
  }

  // Erase only the touched CELL (one step), not the whole note: split the note
  // into its before/after remainders so a long note keeps its other steps.
  void _gridErase(Rung n, int step) {
    if (_songSection != null) return;
    final notes = _activeTrack.pitchNotes;
    final edited = erasePitchCell(notes, n.midi, step);
    if (identical(edited, notes)) return;
    _pushUndo(coalesce: true);
    setState(() {
      notes
        ..clear()
        ..addAll(edited);
    });
  }

  /// Drum-grid selection edits (drums-001): same contract as
  /// [_gridEditNotes] — one completed gesture/command = one undo step.
  bool _drumEditNotes(List<DrumNote> before, List<DrumNote> after) {
    if (_songSection != null) return false;
    final notes = _activeTrack.drumNotes;
    if (!listEquals(notes, before) || listEquals(before, after)) return false;
    _pushUndo();
    _lastUndoMs = 0;
    setState(() {
      notes
        ..clear()
        ..addAll(after);
    });
    return true;
  }

  bool _gridEditNotes(List<PitchNote> before, List<PitchNote> after) {
    if (_songSection != null) return false;
    final notes = _activeTrack.pitchNotes;
    if (!listEquals(notes, before) || listEquals(before, after)) return false;
    _pushUndo(); // one completed drag/slider gesture = one undo transaction
    _lastUndoMs = 0;
    setState(() {
      notes
        ..clear()
        ..addAll(after);
    });
    return true;
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
        _invalidateVocalMix();
      }
    });
    // Offer an immediate undo — clearing has no confirm dialog (keeps the flow
    // fast), so a one-tap recovery path catches accidental clears.
    showTrackClearNotice(
      context,
      message: L10n.of(context).ltEditorTrackCleared,
      undoLabel: L10n.of(context).ltEditorUndo,
      onUndo: _undoAction,
    );
  }

  // ── vocal playback (item 7) ───────────────────────────────────────
  /// Returns true when the take was persisted and committed to the track.
  Future<bool> _commitVocal(
    List<double> wf,
    String? path, {
    bool aligned = false,
    int? durationSteps,
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
      final lane =
          t.clips ??
          (t.vocalPath != null ? List.of(t.effectiveClips) : <VocalClip>[]);
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
      if (startStep >= secSteps ||
          (durationSteps != null && startStep + durationSteps > secSteps)) {
        startStep = 0;
        laneWasFull = true;
      }
      final clip = VocalClip(
        path: persisted,
        startStep: startStep,
        durSteps: durationSteps ?? (aligned ? secSteps : -1),
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
    _invalidateVocalMix(); // section mix is stale → rebounce on next play
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
  Future<void> _startVocalIfAny({double? atStep}) async {
    if (_songSection != null || !_playing) return;
    final request = ++_vocalRequest;
    final sec = _sec;
    final file = await _sectionVocalFile(sec);
    if (!mounted ||
        !_playing ||
        request != _vocalRequest ||
        !identical(_sec, sec) ||
        file == null) {
      return;
    }
    _vocalIsMix = _isMixFile(file);
    _vocalLoopNative =
        !(_rangeLoop && !_recording) &&
        (_vocalIsMix ||
            (_tracks['vocal']?.vocalIsAligned(_bpm, _bars) ?? false));
    _vocalPlaying = true;
    // Re-read the clock after bouncing, rather than playing a stale t=0 take.
    final step =
        atStep == null
            ? _playStep.value
            : _playRange.position(math.max(atStep, _playStep.value));
    _audio.playVocal(
      LoopStorage.resolveVocal(file),
      vol: _vocalFileVol(file),
      loop: _vocalLoopNative,
      position: _stepTime(step),
    );
  }

  Duration _stepTime(double step) =>
      Duration(microseconds: (step * 60 / _bpm / kStepsPerBeat * 1e6).round());

  Future<void> _refreshSongVocals() async {
    final request = ++_vocalRequest;
    if (_songVocalActive) {
      if (_songVocalPath != null && _audible('vocal')) {
        _vocalPlaying = true;
        _vocalLoopNative =
            _songVocalBpm == _bpm && _songVocalBars == _songTotalBars;
        _audio.playVocal(
          LoopStorage.resolveVocal(_songVocalPath!),
          vol: _vol['vocal'] ?? .85,
          loop: _vocalLoopNative,
          position: _stepTime(_playStep.value),
          balance: _pan['vocal'] ?? 0,
        );
      }
      return;
    }
    // Remove the old schedule immediately; it contains the previous mix.
    _songVocalSched = {};
    final schedule = <int, String?>{};
    var offset = 0;
    for (final sec in _sections) {
      final file = await _sectionVocalFile(sec);
      if (!mounted ||
          !_playing ||
          _songSection == null ||
          request != _vocalRequest) {
        return;
      }
      for (var r = 0; r < sec.repeats; r++) {
        schedule[offset] = file;
        offset += stepsForBars(sec.bars);
      }
    }
    _songVocalSched = schedule;
    final step = _playStep.value;
    final boundary = schedule.keys.where((k) => k <= step).last;
    final file = schedule[boundary];
    if (file != null) {
      _vocalPlaying = true;
      _vocalIsMix = _isMixFile(file);
      _audio.playVocal(
        LoopStorage.resolveVocal(file),
        vol: _vocalFileVol(file),
        position: _stepTime(step - boundary),
      );
    }
  }

  static bool _isMixFile(String name) => name.startsWith('_mix_');

  /// Player volume for a vocal file: a bounced section mix already has every
  /// lane's mixer level baked in (unity here); a raw single take is the base
  /// Vocal lane, so its level is applied by the player.
  double _vocalFileVol(String name) =>
      _isMixFile(name) ? 1.0 : (_vol['vocal'] ?? 0.85);

  /// The cached playable vocal basename for [sec] (the lane mix, or a raw single
  /// take). '' is cached for "nothing to play". Cleared on record/edit/mute.
  final Map<String, Future<String?>> _vocalMixPending = {};

  Future<String?> _sectionVocalFile(Section sec) async {
    final cached = _vocalMix[sec.id];
    if (cached != null) return cached.isEmpty ? null : cached;
    final revision = _vocalRevision;
    final key = '${sec.id}:$revision';
    final pending = _vocalMixPending[key];
    if (pending != null) return pending;
    Future<String?> bounce() async {
      final f = (await _bounceSectionVocal(sec)) ?? '';
      if (revision != _vocalRevision) return null;
      _vocalMix[sec.id] = f;
      return f.isEmpty ? null : f;
    }

    final operation = _vocalMixPending[key] = bounce();
    try {
      return await operation;
    } finally {
      _vocalMixPending.remove(key);
    }
  }

  /// Bounce all of [sec]'s vocal-kind lanes (base Vocal + added Audio lanes,
  /// skipping muted ones) into one loop-length WAV and return its basename, so
  /// multiple takes / lanes / trims play live. Returns null when there's nothing
  /// to play; a single untouched take returns its own path (no mix written).
  Future<String?> _bounceSectionVocal(Section sec) async {
    // Each lane's mixer level is baked into its clips' gain so added Audio
    // lanes get their own volume (C8); muted / zero lanes are left out — so
    // muting the base Vocal never silences the other lanes.
    final revision = _vocalRevision;
    final clips = <VocalClip>[];
    final pans = <double>[]; // mixer-001: each clip's lane pan
    var baseLaneOnly = true;
    var anyPanned = false;
    for (final vid in vocalTrackIds(sec)) {
      if (!_audible(vid)) continue;
      final laneVol = _vol[vid] ?? 0.85;
      if (laneVol <= 0) continue;
      final lane = sec.tracks[vid]?.effectiveClips ?? const <VocalClip>[];
      if (lane.isEmpty) continue;
      if (vid != 'vocal') baseLaneOnly = false;
      final p = clampPan(_pan[vid]);
      if (p != 0) anyPanned = true;
      for (final c in lane) {
        clips.add(c.copy()..gain = c.gain * laneVol);
        pans.add(p);
      }
    }
    if (clips.isEmpty) return null;
    // A panned lane always bounces (the raw file can't carry the pan).
    if (clips.length == 1 && baseLaneOnly && !anyPanned) {
      final c = sec.tracks['vocal']!.effectiveClips.first;
      final untouched =
          c.startStep == 0 &&
          c.trimStart == 0 &&
          c.trimEnd == -1 &&
          c.fadeInMs == 0 &&
          c.fadeOutMs == 0 &&
          c.gain == 1.0;
      if (untouched) {
        return c.path; // play the raw take directly (level via the player)
      }
    }
    final sources = <String, ({Float32List pcm, int sampleRate})>{};
    for (final c in clips) {
      if (sources.containsKey(c.path)) continue;
      try {
        final wav = parseWav(
          await File(LoopStorage.resolveVocal(c.path)).readAsBytes(),
        );
        if (wav != null) {
          sources[c.path] = (pcm: wav.samples, sampleRate: wav.sampleRate);
        }
      } catch (_) {}
    }
    if (sources.isEmpty) return null;
    final minLen =
        (stepsForBars(sec.bars) * 60 / _bpm / kStepsPerBeat * 44100).round();
    final lane = bounceVocalClipsStereo(
      clips,
      sec.bars,
      _bpm,
      sources,
      minLen: minLen,
      pans: pans,
    );
    if (lane.left.isEmpty) return null;
    // Version the file so an obsolete asynchronous bounce cannot overwrite
    // the mix currently being auditioned. Unreferenced WAVs are storage-swept.
    final name = '_mix_${widget.song.id}_${sec.id}_$revision.wav';
    // Overlapping lanes/takes can sum past full scale: the stereo encoder
    // pulls a peak above the export headroom back down instead of
    // hard-clipping, like the full mix. Stereo so lane pans are heard.
    await File(
      LoopStorage.resolveVocal(name),
    ).writeAsBytes(encodeWavStereo16(lane.left, lane.right, 44100));
    return name;
  }

  void _stopVocal() {
    _vocalRequest++;
    _vocalPlaying = false;
    _vocalLoopNative = false;
    _audio.stopVocal();
  }

  // mute/volume go through here so the live vocal player follows the mixer
  void _toggleMute(String id) {
    _pushUndo();
    setState(() => _mutes[id] = !(_mutes[id] ?? false));
    _refreshAudition();
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
    _invalidateVocalMix(); // position changed → rebounce on next play
  }

  void _setVol(String id, double v) {
    // Coalesce the drag stream into one undo entry per gesture (500ms window).
    _pushUndo(coalesce: true);
    setState(() => _vol[id] = v);
    if (trackById(_typeOf(id)).kind != TrackKind.vocal) return;
    // Lane levels are baked into all section mixes.
    _vocalRevision++;
    _vocalMix.clear();
    if (!_vocalPlaying) return;
    if (id == 'vocal' && (!_vocalIsMix || _songVocalActive)) {
      _audio.setVocalVolume(v); // raw take / song-level take: live
    } else if (_songSection == null) {
      _vocalRestartAtWrap = true; // mix: swap in the rebounce at the loop start
    }
  }

  // ── pan (mixer-001) ──────────────────────────────────────────────
  /// Drag stream from the mixer: one undo entry per gesture (coalesced).
  void _setPan(String id, double p) {
    _pushUndo(coalesce: true);
    _changePan(id, p);
  }

  /// Double-tap / Alt+click: back to centre as its own undo step.
  void _resetPan(String id) {
    if (clampPan(_pan[id]) == 0) return;
    _pushUndo();
    _changePan(id, 0);
  }

  void _changePan(String id, double p) {
    final v = clampPan(p);
    setState(() {
      if (v == 0) {
        _pan.remove(id);
      } else {
        _pan[id] = v;
      }
    });
    if (trackById(_typeOf(id)).kind != TrackKind.vocal) {
      _applyPans();
      return;
    }
    // Vocal lanes: the pan is baked into the section mix → rebounce.
    _vocalRevision++;
    _vocalMix.clear();
    if (!_vocalPlaying) return;
    if (id == 'vocal' && _songVocalActive) {
      _audio.setVocalBalance(v); // song-level take: player balance, live
    } else if (_songSection == null) {
      _vocalRestartAtWrap = true; // swap in the rebounce at the loop start
    }
  }

  /// Send every synth track's pan to its channel (tracks share no channels:
  /// drums ch9, Beat-Fill ch10, added tracks their own). Channels no track
  /// uses go back to centre; the metronome channel is never panned.
  void _applyPans() {
    _syncChannelRoles();
    final byChannel = <int, double>{
      for (var ch = 0; ch < 16; ch++)
        if (ch != LoopAudio.clickChannel) ch: 0,
    };
    for (final m in _metasFor(_songSection ?? _sec)) {
      if (m.kind == TrackKind.vocal) continue;
      byChannel[m.channel] = clampPan(_pan[m.id]);
    }
    // gt-003: an articulation channel mirrors its owner track's pan; only
    // channels nobody uses go back to centre
    for (final r in _artPlan.routes) {
      byChannel[r.channel] = clampPan(_pan[r.trackId]);
    }
    for (final e in byChannel.entries) {
      _audio.setPan(e.key, e.value);
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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(L10n.of(context).ltEditorSoundDownloadFailed),
                  duration: const Duration(milliseconds: 1800),
                ),
              );
              return;
            }
            _applyInstrument(id, ch, program);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(L10n.of(context).ltEditorSoundReady),
                duration: const Duration(milliseconds: 1300),
              ),
            );
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
      _audio.playPitch(
        ch,
        preview,
        program: program,
        vol: _vol[id] ?? 0.85,
        durSec: 0.5,
      );
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
      solos: _solos,
      onToggleSolo: _toggleSolo,
      onGroove: _songSection == null ? _openGrooveSheet : null,
      grooveLabel: (id) {
        final a = _trackGrooves[id];
        return a == null ? null : findGroove(a.grooveId, _grooves)?.name;
      },
      pan: _pan,
      onPan: _setPan,
      onPanReset: _resetPan,
    );
  }

  /// groove-001: the groove sheet for [trackId] (default: the active track).
  Future<void> _openGrooveSheet([String? trackId]) async {
    if (_songSection != null) return; // editing disabled while previewing
    final id = trackId ?? _activeId;
    final meta = _editMetas.where((m) => m.id == id).firstOrNull;
    if (meta == null || meta.kind == TrackKind.vocal) return;
    await showGrooveSheet(context, _EditorGrooveHost(this, id, meta.label));
  }

  /// A groove edit: one undo step ([coalesce] for slider drags), then make
  /// Play Song pick it up (single-section playback reads it every step).
  void _grooveEdit(VoidCallback change, {bool coalesce = false}) {
    _pushUndo(coalesce: coalesce);
    setState(change);
    if (_songSection != null) _reflattenSong();
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
    final flat = flattenSong(
      _sections,
      variationSeed: _seed,
      groove: _grooveCtx,
    );
    _songSelfTimed = flat.selfTimed;
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
      builder:
          (_) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(color: LT.pink),
                if (clips.length > 1) ...[
                  const SizedBox(height: 12),
                  ValueListenableBuilder<int>(
                    valueListenable: progress,
                    builder:
                        (c, done, _) => Text(
                          L10n.of(
                            c,
                          ).ltEditorAutotuneProgress(done + 1, clips.length),
                          style: const TextStyle(color: LT.t2, fontSize: 12),
                        ),
                  ),
                ],
              ],
            ),
          ),
    );
    try {
      final renderer = vocalFxRenderer(widget.song.id, _sec.id);
      final tuned = <VocalClip>[];
      for (final clip in clips) {
        tuned.add(
          await renderer.render(
            clip,
            [
              ...clip.fx,
              FxNode(
                type: 'autotune',
                params: {
                  'keyTonic': _keyRoot,
                  'scale': _engineScale[_scale] ?? _scale,
                  'strength': strength,
                  'retuneMs': retuneMs,
                  'preserveLength': t.vocalAligned,
                },
              ),
            ],
            bpm: _bpm,
            bars: _bars,
          ),
        );
        progress.value = tuned.length;
      }
      if (!mounted) return;
      _pushUndo();
      setState(() {
        t.clips = tuned;
        t.vocalOrigPath = tuned.first.origPath;
        t.vocalPath = tuned.first.path;
        t.clip = tuned.first.peaks;
      });
      _invalidateVocalMix();
      _audio.prepareVocal(LoopStorage.resolveVocal(tuned.first.path));
    } catch (e) {
      debugPrint('[autotune] failed: $e');
      if (mounted) {
        final message =
            e is EngineApiException
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

  bool _vocalConversionOpen = false;

  Future<void> _convertDroppedClip(
    VocalClipDrag source,
    String targetId,
  ) async {
    if (_vocalConversionOpen || _songSection != null) return;
    final section = _sec;
    final clips = section.tracks[source.trackId]?.effectiveClips;
    if (clips == null ||
        source.clipIndex >= clips.length ||
        clips[source.clipIndex].path != source.clip.path) {
      return;
    }
    final target = _editMetas.where((m) => m.id == targetId).firstOrNull;
    if (target == null || target.kind != TrackKind.pitched) return;
    _vocalConversionOpen = true;
    _stopAll();
    try {
      final conversion = await showVocalMidiSheet(
        context,
        clip: clips[source.clipIndex],
        bpm: _bpm,
        bars: section.bars,
        keyRoot: _keyRoot,
        scale: _scale,
        swing: _swing,
        initialProgram: _instruments[targetId] ?? target.defaultProgram,
      );
      if (!mounted || conversion == null || !identical(section, _sec)) return;
      _pushUndo();
      setState(() {
        final id = 'melody_x${DateTime.now().microsecondsSinceEpoch}';
        addVocalMidiTrack(_sections, section.id, id, conversion);
        _instruments[id] = conversion.program;
        _activeId = id;
        _inputModes[id] = 'grid';
      });
    } finally {
      _vocalConversionOpen = false;
    }
  }

  // Open the clip editor (trim/fade/gain + sound processing). Returns the
  // edited vocal TrackData; we swap it in, push undo, and re-prepare playback.
  Future<void> _openVocalEditor({bool convertImmediately = false}) async {
    _stopAll();
    final section = _sec;
    final vid = _vocalId;
    final t = _trackIn(_tracks, vid);
    if (t.effectiveClips.isEmpty) return;
    final edited = await openVocalEditor(
      context,
      vocal: t,
      bpm: _bpm,
      bars: _sec.bars,
      songId: widget.song.id,
      sectionId: section.id,
      keyRoot: _keyRoot,
      scale: _scale,
      swing: _swing,
      convertImmediately: convertImmediately,
    );
    if (edited == null || !mounted || !identical(section, _sec)) return;
    _pushUndo();
    _stopVocal();
    setState(() {
      _tracks[vid] = edited.vocal;
      final conversion = edited.converted;
      if (conversion != null) {
        final id = addVocalMidiTrack(
          _sections,
          section.id,
          'melody_x${DateTime.now().microsecondsSinceEpoch}',
          conversion,
          useEmptyMelodyLane: _guided,
        );
        _instruments[id] = conversion.program;
        _activeId = id;
        _inputModes[id] = 'grid';
        if (_guided && id != 'melody') {
          _trackGuidedExit('editor');
          _guided = false;
        }
      }
    });
    _invalidateVocalMix(); // edits change the lane → rebounce
    final first = edited.vocal.vocalPath;
    if (first != null) _audio.prepareVocal(LoopStorage.resolveVocal(first));
  }

  /// Restore the dry take on every clip that has one (audit C16 — the whole
  /// lane is tuned, so the whole lane reverts).
  bool _vocalRestoreBusy = false;
  Future<void> _revertAutotune() async {
    if (_vocalRestoreBusy) return;
    final section = _sec;
    final vid = _vocalId;
    final t = _trackIn(_tracks, vid);
    final clips = t.effectiveClips;
    if (!clips.any((c) => c.origPath != null || c.fxSourcePath != null)) return;
    final before = jsonEncode(t.toJson());
    final bpm = _bpm;
    _vocalRestoreBusy = true;
    _stopAll();
    try {
      final renderer = vocalFxRenderer(widget.song.id, section.id);
      final restored = <VocalClip>[];
      // Load every original before the single undoable commit. One missing
      // file must not leave a half-restored lane or erase its history.
      for (final c in clips) {
        restored.add(
          c.origPath != null || c.fxSourcePath != null
              ? await renderer.restoreOriginal(c, bpm: bpm, bars: section.bars)
              : c.copy(),
        );
      }
      if (!mounted ||
          !identical(section, _sec) ||
          !identical(t, _tracks[vid]) ||
          _bpm != bpm ||
          jsonEncode(t.toJson()) != before) {
        return;
      }
      _pushUndo();
      setState(() {
        t.clips = restored;
        t.vocalPath = restored.first.path;
        t.vocalOrigPath = restored.first.origPath;
        t.clip = restored.first.peaks;
      });
      _invalidateVocalMix();
      _audio.prepareVocal(LoopStorage.resolveVocal(restored.first.path));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).ltVocalEditorProcessFailed)),
        );
      }
    } finally {
      _vocalRestoreBusy = false;
    }
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

  void _startMelodyPreview({required bool raw}) {
    _stopAll();
    setState(() => _previewRawMelody = raw);
    _togglePlay();
  }

  Future<void> _reviewMelody() async {
    _stopAll();
    await showMelodyReviewSheet(
      context,
      notes: () => _tracks['melody']?.pitchNotes ?? const [],
      onOctaveDown:
          (index) => _editMelody((notes) => shiftNoteOctave(notes, index, -1)),
      onOctaveUp:
          (index) => _editMelody((notes) => shiftNoteOctave(notes, index, 1)),
      onSplit:
          (index) => _editMelody((notes) => splitNoteAtMidpoint(notes, index)),
      onMerge: (index) => _editMelody((notes) => mergeWithNext(notes, index)),
    );
  }

  void _editMelody(List<PitchNote> Function(List<PitchNote>) transform) {
    final track = _tracks['melody'];
    if (track == null) return;
    _pushUndo();
    final edited = transform(track.pitchNotes);
    setState(() {
      track.pitchNotes
        ..clear()
        ..addAll(edited);
      _dirty = true;
      _previewRawMelody = false;
    });
  }

  Future<void> _humConvert(String audioPath) async {
    final drums = _meta.kind == TrackKind.drums;
    // The request is built for THIS section/lane/tempo/key; if any of them
    // changes during the network wait, the result no longer fits — offer a
    // retry (against the new target) instead of writing it somewhere else.
    final section = _sec;
    final activeId = _activeId;
    final track = _activeTrack;
    final bpm = _bpm;
    final bars = _bars;
    final keyRoot = _keyRoot;
    final scale = _scale;
    bool targetChanged() =>
        !identical(_sec, section) ||
        _activeId != activeId ||
        !identical(_activeTrack, track) ||
        _bpm != bpm ||
        _bars != bars ||
        _keyRoot != keyRoot ||
        _scale != scale ||
        _songSection != null;
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
      if (targetChanged()) throw const _HumTargetChanged();
      final sps = 60 / bpm / kStepsPerBeat;
      // remembered (not saved) for "make a groove from the last take"
      _lastTakeOnsets = [
        for (final n in res.notes) (steps: n.start / sps, velocity: n.velocity),
      ];
      final steps = _steps;
      final t = track;
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
        final ladder = _padWindow;
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
          var sourceMidi = n.pitchOriginal + shift;
          while (sourceMidi < ladder.first.midi - 6) {
            sourceMidi += 12;
          }
          while (sourceMidi > ladder.last.midi + 6) {
            sourceMidi -= 12;
          }
          out.add(
            PitchNote(
              midi: r.midi,
              freq: r.freq,
              step: step,
              dur: dur,
              sourceMidi: sourceMidi,
              confidence: n.confidence.clamp(0, 1),
              assisted: n.assisted || sourceMidi != r.midi,
              locked:
                  _activeId == 'melody' && (_generationLocks['melody'] ?? true),
            ),
          );
        }
        if (out.isEmpty) throw StateError('no notes');
        _pushUndo();
        setState(() => t.pitchNotes.addAll(out));
        count = out.length;
      }
      ok = true;
      _toast(L10n.of(context).ltEditorHumAdded(count));
      // Clarity: 분석 성공 + 분기(드럼/멜로딕) 태깅. noteCount 는 이벤트로 분포 확인.
      ProductAnalytics.instance.track(
        ProductEvent.analyzeCompleted,
        properties: {
          'feature': _guided ? 'guided_creation' : 'editor',
          'role': drums ? 'drum' : 'melodic',
        },
      );
      if (_guided) {
        ProductAnalytics.instance.track(
          ProductEvent.guidedConversionCompleted,
          properties: const {'feature': 'guided_creation'},
        );
      }
    } catch (e) {
      // a moved target isn't an engine failure — keep it out of the metric.
      if (e is! _HumTargetChanged) _trackAnalyzeFailure(e);
      debugPrint('[hum] convert failed: $e');
      if (!mounted) {
        _deleteTempFile(audioPath);
        return;
      }
      // keep the recording for a retry; drop it once the offer goes unanswered
      final ctl = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
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
      unawaited(
        shown.closed.then((reason) {
          if (reason != SnackBarClosedReason.action) _deleteTempFile(audioPath);
        }),
      );
    } finally {
      if (ok) _deleteTempFile(audioPath); // temp hum recording (C27)
    }
  }

  void _trackAnalyzeFailure(Object e) {
    var reason = 'unknown';
    if (e is StateError) {
      reason = 'no_notes';
    } else if (e is DioException) {
      final code = e.response?.statusCode;
      if (code == 413) {
        reason = 'too_long';
      } else if (code == 429) {
        reason = 'busy';
      } else if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        reason = 'connection';
      } else {
        reason = 'server';
      }
    }
    ProductAnalytics.instance.track(
      ProductEvent.analyzeFailed,
      properties: {
        'feature': _guided ? 'guided_creation' : 'editor',
        'error_code': reason,
      },
    );
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
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
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
    if (_songSection != null || _recording || _countDown > 0) return;
    _pushUndo();
    // linked sections keep one length (their notes are shared)
    final group = linkedIndices(_sections, _activeIdx).toList();
    setState(() {
      for (final i in group) {
        _sections[i].bars = b;
      }
    });
    for (final i in group) {
      _loopRanges.remove(_sections[i].id);
    }
    _loopRanges[_sec.id] = _selectedRange;
    _restartPhrase();
  }

  /// Tempo change. While playing, the clock is rebased at the current
  /// playhead so the new tempo takes over smoothly — recomputing elapsed
  /// beats at a new BPM would otherwise jump the playhead (a burst of missed
  /// triggers, or a stall) (C6).
  void _setBpm(int v) {
    if (v == _bpm) return;
    _pushUndo(coalesce: true); // one undo entry per ± hold / drag
    setState(() {
      _bpm = v;
      _dirty = true;
    });
    _vocalRevision++;
    _vocalMix.clear();
    if (_playing) {
      _silenceTracks();
      _startClock();
      _stopVocal();
      if (_songSection == null) {
        _startVocalIfAny();
      } else {
        _refreshSongVocals();
      }
    }
  }

  Section _backingCandidate(BackingStyle style, int variant) =>
      withBeginnerBacking(
        _sec,
        _keyRoot,
        _scale,
        style,
        chordVariant: variant,
        melodyLocked: _generationLocks['melody'] ?? true,
        lockedTracks: _generationLocks,
      );

  void _chooseBackingMood(BackingStyle style) {
    _stopAll();
    setState(() {
      _guidedBacking = style;
      _guidedPreviewSection = null;
      _guidedPreviewCandidate = null;
      _guidedAppliedCandidate = null;
    });
  }

  void _previewBacking(int variant) {
    final style = _guidedBacking;
    if (style == null) return;
    if (_playing && _guidedPreviewCandidate == variant) {
      _stopAll();
      setState(() => _guidedPreviewSection = null);
      return;
    }
    _stopAll();
    setState(() {
      _guidedPreviewSection = _backingCandidate(style, variant);
      _guidedPreviewCandidate = variant;
    });
    ProductAnalytics.instance.track(
      ProductEvent.guidedBackingPreviewed,
      properties: {
        'feature': 'guided_backing',
        'backing_style': style.name,
        'candidate': variant + 1,
      },
    );
    _togglePlay();
  }

  void _applyBacking(int variant) {
    final style = _guidedBacking;
    if (style == null) return;
    _stopAll();
    final candidate = _backingCandidate(style, variant);
    _pushUndo();
    setState(() {
      final current = _sections[_activeIdx];
      if (current.linkId == null) {
        _sections[_activeIdx] = candidate;
      } else {
        // linked: write the backing into the shared content
        current.tracks
          ..clear()
          ..addAll(candidate.tracks);
        current.fillKinds.setAll(0, candidate.fillKinds);
        for (final i in linkedIndices(_sections, _activeIdx)) {
          _sections[i].bars = candidate.bars;
        }
      }
      _guidedPreviewSection = null;
      _guidedPreviewCandidate = variant;
      _guidedAppliedCandidate = variant;
    });
    ProductAnalytics.instance.track(
      ProductEvent.guidedBackingApplied,
      properties: {
        'feature': 'guided_backing',
        'backing_style': style.name,
        'candidate': variant + 1,
      },
    );
    _togglePlay();
  }

  void _listenGuided() {
    if (_playing) {
      _stopAll();
      setState(() => _guidedPreviewSection = null);
      return;
    }
    setState(() => _guidedPreviewSection = null);
    _togglePlay();
  }

  Future<void> _openSongPlan() async {
    _stopAll();
    await showLtModal<void>(
      context,
      width: 620,
      child: StatefulBuilder(
        builder:
            (context, refresh) => SongPlanSheet(
              sections: _sections,
              activeIndex: _activeIdx,
              locks: _generationLocks,
              onSelect: (index) {
                _switchSection(index);
                refresh(() {});
              },
              onDuplicate: (index) {
                _duplicateSection(index);
                refresh(() {});
              },
              onMove: (index, direction) {
                _moveSection(index, direction);
                refresh(() {});
              },
              onRepeats: (index, repeats) {
                _setRepeats(index, repeats);
                refresh(() {});
              },
              onLock: (track, locked) {
                _pushUndo();
                setState(() => _generationLocks[track] = locked);
                refresh(() {});
              },
            ),
      ),
    );
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
      pan: _savedPan(),
      mutes: Map.of(_mutes),
      instruments: Map.of(_instruments),
      generationLocks: Map.of(_generationLocks),
      sections: _sections.map((s) => s.deepCopy()).toList(),
      updatedAt: DateTime.now(),
      wave: buildWave(flat),
      songVocalPath: _songVocalPath,
      songVocalPeaks: _songVocalPeaks,
      songVocalBpm: _songVocalBpm,
      songVocalBars: _songVocalBars,
      variationSeed: _variationSeed,
      grooves: List.of(_grooves),
      trackGrooves: Map.of(_trackGrooves),
      grooveAmount: _grooveAmount,
    );
  }

  /// Pans of tracks that still exist (a removed track's key is dropped).
  Map<String, double> _savedPan() {
    final ids = <String>{
      for (final t in kTracks) t.id,
      for (final s in _sections) ...s.extras.map((e) => e.id),
    };
    return {
      for (final e in _pan.entries)
        if (ids.contains(e.key) && e.value != 0) e.key: e.value,
    };
  }

  Future<void> _saveNow() async {
    try {
      await context.read<LoopStore>().upsert(_snapshot());
      _trackGuidedSave('manual');
    } catch (_) {
      ProductAnalytics.instance.track(
        _guided ? ProductEvent.guidedSongFailed : ProductEvent.songSaveFailed,
        properties: {
          'feature': _guided ? 'guided_creation' : 'editor',
          'error_code': 'local_save',
        },
      );
      _handleSaveFailure();
      return;
    }
    if (!mounted) return;
    _saveErrorShown = false;
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
  bool _saveErrorShown = false;

  void _handleSaveFailure() {
    if (!mounted) return;
    setState(() {
      _dirty = true;
      _savedFlash = false;
    });
    if (!_saveErrorShown) showSongSaveError(context);
    _saveErrorShown = true;
  }

  Future<void> _backWithSave() async {
    if (_leaving) return;
    _leaving = true;
    final store = context.read<LoopStore>();
    try {
      if (!_isPristineNew(store)) {
        await store.upsert(_snapshot());
        _trackGuidedSave('back');
      }
      // editor session over → undo stack (the last holder of replaced takes) is
      // gone, so unreferenced vocal files are safe to drop.
      await store.sweepVocals();
    } catch (e) {
      debugPrint('[edit] save on leave failed: $e');
      _leaving = false;
      _handleSaveFailure();
      return; // Keep the editor and its undo history available for retry.
    }
    if (mounted) {
      _trackGuidedExit('back');
      Navigator.of(context).pop();
    }
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
    _syncChannelRoles(); // gt-003: the plan live playback uses
    await showExportDrawer(
      context,
      title: _title,
      songId: widget.song.id,
      sections: _sections,
      bpm: _bpm,
      swing: _swing,
      vol: exportVol,
      pan: _savedPan(),
      melodyProgram: _instruments['melody'] ?? 0,
      bassProgram: _instruments['bass'] ?? 33,
      melodyDecProgram: _instruments['melodyDec'] ?? 48,
      drumProgram: _instruments['drums'] ?? kDefaultDrumKit,
      extras: extras,
      instruments: Map.of(_instruments),
      songVocalPath: _songVocalPath,
      variationSeed: _seed,
      onNewVariation: _newVariation,
      groove: _grooveCtx,
      articulations: _artPlan,
    );
  }

  /// "Another variation": re-roll the song's chance/velocity seed (undoable).
  int _newVariation() {
    _pushUndo();
    var next = DateTime.now().microsecondsSinceEpoch & 0x7FFFFFFF;
    if (next == _seed) next = (next + 1) & 0x7FFFFFFF;
    setState(() => _variationSeed = next);
    if (_songSection != null) _reflattenSong();
    return next;
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
    return DesktopCommands(
      enabled: _desktop,
      play: _togglePlay,
      record: () {
        if (!_guided && _meta.kind != TrackKind.vocal) _armRecord();
      },
      save: _saveNow,
      undo: _undoAction,
      redo: _redoAction,
      groove: () => _openGrooveSheet(),
      // ui-001 stage 1. Not while recording / counting in (the audition bar's
      // range controls are locked then too), nor during a song preview.
      rangeLoop: () {
        if (_recording || _countDown > 0 || _songSection != null) return;
        _changeLoop(enabled: !_rangeLoop);
      },
      mixer: () {
        if (_recording || _countDown > 0) return;
        _openMixer();
      },
      help: () {
        if (_recording || _countDown > 0) return;
        showShortcutHelp(context);
      },
      duplicateLinked: () {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
          return; // typing in a text field
        }
        _duplicateSectionLinked(_activeIdx);
      },
      child: PopScope(
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
                if (_guided)
                  Positioned.fill(
                    child: GuidedHumPanel(
                      hasNotes: _tracks.values.any(
                        (t) =>
                            t.pitchNotes.isNotEmpty ||
                            t.drumNotes.isNotEmpty ||
                            t.effectiveClips.isNotEmpty,
                      ),
                      hasMelody:
                          _tracks['melody']?.pitchNotes.isNotEmpty ?? false,
                      playing: _playing,
                      saved: !_dirty && _savedAt != null,
                      onBack: _backWithSave,
                      onRecord: () {
                        setState(() => _activeId = 'melody');
                        _openHum();
                      },
                      onRecordVocal: () {
                        setState(() => _activeId = 'vocal');
                        _openVocalRecord();
                      },
                      onConvertVocal:
                          (_tracks['vocal']?.effectiveClips.isNotEmpty ?? false)
                              ? () {
                                setState(() => _activeId = 'vocal');
                                _openVocalEditor(convertImmediately: true);
                              }
                              : null,
                      onExport: _exportOrPaywall,
                      onSample: () async {
                        _stopAll();
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder:
                                (_) => SampleWorkbench(
                                  bpm: _bpm,
                                  bars: _bars,
                                  onAdd:
                                      (peaks, path, steps) => _commitVocal(
                                        peaks,
                                        path,
                                        durationSteps: steps,
                                      ),
                                ),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                      backingStyle: _guidedBacking,
                      previewCandidate: _guidedPreviewCandidate,
                      appliedCandidate: _guidedAppliedCandidate,
                      lowConfidenceCount:
                          uncertainNoteIndices(
                            _tracks['melody']?.pitchNotes ?? const [],
                          ).length,
                      previewingOriginal: _previewRawMelody,
                      melodyLocked: _generationLocks['melody'] ?? true,
                      onPreviewOriginal: () => _startMelodyPreview(raw: true),
                      onPreviewCorrected: () => _startMelodyPreview(raw: false),
                      onReviewMelody: _reviewMelody,
                      onBacking: _chooseBackingMood,
                      onPreviewBacking: _previewBacking,
                      onApplyBacking: _applyBacking,
                      onSongPlan: _openSongPlan,
                      onUndo:
                          _undo.isNotEmpty
                              ? () {
                                _undoAction();
                                setState(() {
                                  _guidedBacking = null;
                                  _guidedPreviewSection = null;
                                  _guidedPreviewCandidate = null;
                                  _guidedAppliedCandidate = null;
                                });
                              }
                              : null,
                      onListen: _listenGuided,
                      onInstrument: _openInstrument,
                      onSave: _saveNow,
                      onEdit: () {
                        _stopAll();
                        _trackGuidedExit('editor');
                        setState(() => _guided = false);
                      },
                    ),
                  )
                else
                  Column(
                    children: [
                      // ui-001 stage 1: desktop = one 52 px top bar with the
                      // transport; phone/tablet keep _topBar + TransportBar.
                      if (_desktop) _desktopTopBar() else _topBar(),
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
                      if (_timelineFolded)
                        _foldedTimeline()
                      else
                      Expanded(
                        flex: _desktop ? (_timelineShare * 1000).round() : 2,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                          // Arrangement owns a listenable playhead. Rebuilding
                          // every lane for each clock tick wastes input frames.
                          child: _timelineViewport(
                            (view) => Arrangement(
                              view: view,
                              labelWidth: _desktop ? _trackLabelWidth : 140,
                              onLabelWidthChanged:
                                  _desktop
                                      ? (width) => setState(() {
                                        _trackLabelWidth = width.clamp(
                                          180.0,
                                          360.0,
                                        );
                                      })
                                      : null,
                              instrumentNames: {
                                for (final m in _metasFor(_songSection ?? _sec))
                                  m.id:
                                      m.kind == TrackKind.vocal
                                          ? 'Audio'
                                          : instrumentLabel(
                                            m.kind == TrackKind.drums
                                                ? 'drums'
                                                : 'melody',
                                            _instruments[m.id] ??
                                                m.defaultProgram,
                                          ),
                              },
                              section: _songSection ?? _sec,
                              tracks: _orderedMetas(_songSection ?? _sec),
                              activeId: _activeId,
                              mutes: _mutes,
                              solos: _solos,
                              bypassSolo: _bypassSolo,
                              onToggleSolo: _toggleSolo,
                              loopRange:
                                  _rangeLoop && _songSection == null
                                      ? _playRange
                                      : null,
                              onSelect: (id) => setState(() => _activeId = id),
                              onToggleMute: _toggleMute,
                              // editing only (song-preview is read-only)
                              onAddTrack:
                                  _songSection == null ? _openAddTrack : null,
                              onReorder:
                                  _songSection == null ? _reorderTracks : null,
                              onMoveClip:
                                  _songSection == null ? _moveVocalClip : null,
                              onConvertClip:
                                  _desktop && _songSection == null
                                      ? _convertDroppedClip
                                      : null,
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
                      if (_desktop && !_timelineFolded)
                        DesktopSplitHandle(
                          onDelta:
                              (delta) => setState(
                                () =>
                                    _timelineShare = (_timelineShare +
                                            delta /
                                                math.max(
                                                  200,
                                                  MediaQuery.sizeOf(
                                                        context,
                                                      ).height -
                                                      200,
                                                ))
                                        .clamp(.25, .70),
                              ),
                          onReset: () => setState(() => _timelineShare = .4),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: AuditionBar(
                          bars: _bars,
                          range: _selectedRange,
                          looping: _rangeLoop && _songSection == null,
                          soloCount: _solos.length,
                          bypassSolo: _bypassSolo,
                          enabled:
                              _songSection == null &&
                              !_recording &&
                              _countDown == 0,
                          onRange: (r) => _changeLoop(range: r),
                          onLoop: () => _changeLoop(enabled: !_rangeLoop),
                          onCompare: _compareSolo,
                          onClearSolo: _clearSolo,
                          onRestart: _restartPhrase,
                        ),
                      ),
                      SoloStatusNotice(
                        issues: soloIssues(
                          tracks: _effectiveTracks,
                          metas: _metasFor(_songSection ?? _sec),
                          solos: _solos,
                          mutes: _mutes,
                          volumes: _vol,
                          range: _playRange,
                          steps: _steps,
                          bypass: _bypassSolo,
                        ),
                        onOpenVelocity:
                            _songSection == null
                                ? (id) => setState(() {
                                  _activeId = id;
                                  _inputModes[id] = 'grid';
                                })
                                : null,
                      ),
                      _surfaceHeader(pitched),
                      Expanded(
                        flex:
                            _desktop
                                ? ((1 - _timelineShare) * 1000).round()
                                : 3,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(
                                LTRadius.card,
                              ),
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
                            child: _desktopSurface(),
                          ),
                        ),
                      ),
                      if (!_desktop)
                      Container(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        decoration: const BoxDecoration(
                          border: Border(top: BorderSide(color: LT.border)),
                        ),
                        child: TransportBar(
                          rangeLoop: _rangeLoop && _songSection == null,
                          onLoop: () => _changeLoop(enabled: !_rangeLoop),
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
                          onSwing: (v) {
                            _pushUndo(coalesce: true);
                            setState(() => _swing = v);
                          },
                          bars: _bars,
                          onBars: _setBars,
                          showRecord:
                              trackById(_activeType).kind != TrackKind.vocal,
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
      ),
    );
  }

  /// ui-001 stage 1: the desktop top bar. Same handlers as [_topBar] and the
  /// phone [TransportBar]; the save button is gone (12 s autosave + Ctrl+S),
  /// mixer and guided start moved to the more menu.
  Widget _desktopTopBar() {
    final l = L10n.of(context);
    return DesktopTopBar(
      titleController: _titleCtl,
      onTitleChanged: (v) {
        final wasDirty = _dirty;
        _pushUndo(coalesce: true); // one undo entry per typing burst
        _title = v;
        if (!wasDirty) setState(() {});
      },
      dirty: _dirty,
      savedAt: _savedAt,
      savedFlash: _savedFlash,
      onBack: _backWithSave,
      metro: _metro,
      onMetro: (v) {
        setState(() => _metro = v);
        LoopPrefs.instance.setMetro(v); // keep Settings in sync + persist
      },
      countIn: _countIn,
      onCountIn: (v) => setState(() => _countIn = v),
      rangeLoop: _rangeLoop && _songSection == null,
      onLoop: () => _changeLoop(enabled: !_rangeLoop),
      playing: _playing,
      recording: _recording,
      showRecord: trackById(_activeType).kind != TrackKind.vocal,
      onPlay: _togglePlay,
      onStop: _stopAll,
      onRec: _armRecord,
      playhead: _playStep,
      bpm: _bpm,
      onBpm: _setBpm,
      keyLabel: '$_keyRoot ${ltScaleLabel(l, _scale)}',
      onKey: _openKey,
      swing: _swing,
      onSwing: (v) {
        _pushUndo(coalesce: true);
        setState(() => _swing = v);
      },
      bars: _bars,
      onBars: _setBars,
      canUndo: _undo.isNotEmpty,
      canRedo: _redo.isNotEmpty,
      onUndo: _undoAction,
      onRedo: _redoAction,
      onMixer: _openMixer,
      onGuide: () {
        _stopAll();
        setState(() {
          _activeId = 'melody';
          _guided = true;
          _trackGuidedStart('editor');
        });
      },
      onClear: _clearTrack,
      onShortcuts: () => showShortcutHelp(context),
      onExport: _exportOrPaywall,
      pro: context.select<LoopStore, bool>((s) => s.proActive),
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
                final wasDirty = _dirty;
                _pushUndo(coalesce: true); // one undo entry per typing burst
                _title = v;
                if (!wasDirty) setState(() {});
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
        IconBtn(
          icon: Icons.auto_awesome,
          size: btnSize,
          tooltip: l.ltGuidedStart,
          onTap: () {
            _stopAll();
            setState(() {
              _activeId = 'melody';
              _guided = true;
              _trackGuidedStart('editor');
            });
          },
        ),
        const SizedBox(width: 8),
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
        _undoRedoBtn(
          LtIcons.undo,
          l.ltEditorUndo,
          _undo.isNotEmpty,
          _undoAction,
        ),
        const SizedBox(width: 6),
        _undoRedoBtn(
          LtIcons.redo,
          l.ltEditorRedo,
          _redo.isNotEmpty,
          _redoAction,
        ),
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
    final focusable =
        _inputMode == 'grid' &&
        (_meta.kind == TrackKind.pitched || _meta.kind == TrackKind.bass);
    final wide = MediaQuery.sizeOf(context).width >= 700;
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
        // 편집 확대: the piano roll takes the timeline's / key hints' space
        // (a labelled pill when there is room; narrow screens get an icon
        // at the front of the grid's tool row instead)
        if (focusable && wide) ...[
          const SizedBox(width: 6),
          KeyedSubtree(
            key: const ValueKey('grid-focus'),
            child: _chordKindToggle(
              label:
                  Localizations.localeOf(context).languageCode == 'ko'
                      ? (_gridFocused ? '편집 확대 끄기' : '편집 확대')
                      : (_gridFocused ? 'Exit enlarged' : 'Enlarge editor'),
              on: _gridFocused,
              onTap:
                  () => LoopPrefs.instance.setGridLayout(
                    focus: !LoopPrefs.instance.gridFocus.value,
                  ),
            ),
          ),
        ],
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
            onTap: _openHum,
          ),
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
    onTap:
        () => setState(() {
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
    onTap:
        () => setState(() {
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

  Widget _desktopSurface() {
    final surface = _surface();
    if (!_desktop || _meta.kind == TrackKind.vocal) {
      return surface;
    }
    final pitched = _isPitched;
    final rungs = pitched ? _padWindow : <Rung>[];
    final specs =
        pitched
            ? <DrumSpec>[]
            : drumSpecsFor(
              _activeTrack.drumKinds ??
                  (_activeType == 'beatDec' ? _fillKinds : _meta.drumKinds),
            );
    final identity =
        '$_activeId:$_activeIdx:$_keyRoot:$_scale:$_octave:$_windowOffset:$_activeProgram:$_chordOn:$_powerOn';
    return DesktopInstrument(
      // grid editors own their keyboard focus (selection shortcuts)
      capturePointerFocus: _inputMode != 'grid',
      // 편집 확대: the roll takes the key-hint row's space (keys still play)
      showKeyHints: !_gridFocused,
      group: pitched ? 'piano' : 'drums',
      identity: identity,
      labels:
          pitched
              ? rungs.map((r) => r.name).toList()
              : specs.map((s) => drumLabel(L10n.of(context), s.kind)).toList(),
      onDown: (index) {
        if (!pitched) {
          _hitDrum(specs[index].kind);
          return () {};
        }
        final rung = rungs[index];
        final track = _activeId;
        final section = _activeIdx;
        final ch = _meta.channel;
        final midis = _chordMidis(rung.midi);
        _pitchDown(rung);
        return () {
          for (final timer in _strumTimers) {
            timer.cancel();
          }
          _strumTimers.clear();
          for (final midi in midis) {
            _audio.noteOffLive(ch, midi);
          }
          if (mounted &&
              !_desktopClosing &&
              track == _activeId &&
              section == _activeIdx &&
              identity ==
                  '$_activeId:$_activeIdx:$_keyRoot:$_scale:$_octave:$_windowOffset:$_activeProgram:$_chordOn:$_powerOn') {
            _pitchUp(rung);
          } else {
            _pending.remove(rung.midi);
          }
        };
      },
      child: surface,
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
      final isFill = _activeType == 'beatDec' && src.drumKinds == null;
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
                key: ValueKey('drum-grid-$_activeId-$_activeIdx'),
                notes: src.drumNotes,
                onToggle: _toggleDrumCell,
                onEdit: _drumEditNotes,
                enabled: _songSection == null,
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
          builder:
              (_, ps, __) => FillLaunchpad(
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
                key: ValueKey('grid-$_activeId-$_activeIdx'),
                ladder: _gridLadder,
                focusMidi: (_padWindow.first.midi + 5).clamp(0, 127),
                clipboard: _noteClipboard,
                onPreview: _previewGridNote,
                onPreviewNote: _previewGridPitchNote,
                articulationChannel: _articulationChannelFor,
                articulationShort: _planFor(_sections).shortRoles(_activeId),
                notes: notes,
                onPlace: _gridPlace,
                onErase: _gridErase,
                onEdit: _gridEditNotes,
                scaleRoot: _keyRoot,
                scaleName: _scale,
                guitar: _activeIsGuitar,
                bpm: _bpm,
                // gt-002: the hint about choke drift under a groove
                grooved: _grooveCtx.resolve(_sec, _activeId) != null,
                initialEditMode: src.label != null,
                // narrow screens: 편집 확대 lives in the tool row (the header
                // has no room for it)
                focusToggle: MediaQuery.sizeOf(context).width < 700,
                enabled: _songSection == null,
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
        builder:
            (context, lit, _) => NotePads(
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
        onRecordSong:
            _sections.fold<int>(0, (a, s) => a + s.repeats) > 1
                ? _openSongVocalRecord
                : null,
        onClearSong: _songVocalPath != null ? _clearSongVocal : null,
        onEdit: vt.effectiveClips.isNotEmpty ? _openVocalEditor : null,
        onConvert:
            vt.effectiveClips.isNotEmpty
                ? () => _openVocalEditor(convertImmediately: true)
                : null,
        onAutotune: _openAutotune,
        onRevert:
            vt.effectiveClips.any(
                  (c) => c.origPath != null || c.fxSourcePath != null,
                )
                ? _revertAutotune
                : null,
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
          _invalidateVocalMix();
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
    pan: Map.of(_pan),
    mutes: Map.of(_mutes),
    instruments: Map.of(_instruments),
    generationLocks: Map.of(_generationLocks),
    title: _title,
    songVocalPath: _songVocalPath,
    songVocalPeaks: _songVocalPeaks,
    songVocalBpm: _songVocalBpm,
    songVocalBars: _songVocalBars,
    variationSeed: _variationSeed,
    grooves: List.of(_grooves),
    trackGrooves: Map.of(_trackGrooves),
    grooveAmount: _grooveAmount,
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
    final bpmChanged = s.bpm != _bpm;
    if (!keepPlaying && (_playing || _songSection != null)) _stopAll();
    setState(() {
      _sections
        ..clear()
        // snapshots are deep copies: re-share linked sections' content
        ..addAll(relinkSections(s.sections.map((x) => x.deepCopy()).toList()));
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
      _pan
        ..clear()
        ..addAll(s.pan);
      _mutes
        ..clear()
        ..addAll(s.mutes);
      _instruments
        ..clear()
        ..addAll(s.instruments);
      _generationLocks
        ..clear()
        ..addAll(s.generationLocks);
      _title = s.title;
      if (_titleCtl.text != s.title) _titleCtl.text = s.title;
      _songVocalPath = s.songVocalPath;
      _songVocalPeaks = s.songVocalPeaks;
      _songVocalBpm = s.songVocalBpm;
      _songVocalBars = s.songVocalBars;
      _variationSeed = s.variationSeed;
      _grooves
        ..clear()
        ..addAll(s.grooves);
      _trackGrooves
        ..clear()
        ..addAll(s.trackGrooves);
      _grooveAmount = s.grooveAmount;
      if (!keepPlaying) _playStep.value = 0;
    });
    // Play-song preview reads from the flattened display section — rebuild it
    // from the restored arrangement so the running clock plays the right notes.
    if (keepPlaying && _songSection != null) _reflattenSong();
    if (bpmChanged) {
      // Same as _setBpm: the running clock must be rebased on the new tempo,
      // or _onTick scales the old elapsed time and the playhead jumps.
      _vocalRevision++;
      _vocalMix.clear();
      if (keepPlaying) {
        _silenceTracks();
        _startClock();
        _stopVocal();
        if (_songSection == null) {
          _startVocalIfAny();
        } else {
          _refreshSongVocals();
        }
      }
    }
    _solos.removeWhere((id) => !_editMetas.any((t) => t.id == id));
    _refreshAudition();
    // re-assert each drum track's kit — pitched programs ride along on every
    // playPitch call, but the drum kit is a sticky synth-side setting.
    _applyDrumKits();
    _applyPans(); // pan is sticky synth-side too (CC10)
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
    // A new gesture after undo must not coalesce into the preceding edit.
    _lastUndoMs = 0;
    _redo.add(_capture());
    _restore(_undo.removeLast());
  }

  void _redoAction() {
    if (_redo.isEmpty) return;
    _lastUndoMs = 0;
    _undo.add(_capture());
    _restore(_redo.removeLast());
  }
}

/// The editor behind the groove sheet: every change is an undo step.
class _EditorGrooveHost implements GrooveSheetHost {
  _EditorGrooveHost(this.s, this.trackId, this.trackLabel);
  final _EditScreenState s;
  final String trackId;
  @override
  final String trackLabel;

  @override
  List<GrooveTemplate> get songGrooves => List.of(s._grooves);
  @override
  double get amount => s._grooveAmount;
  @override
  GrooveAssign? get trackGroove => s._trackGrooves[trackId];
  @override
  bool get hasSectionOverride => s._sec.grooveOverrides.containsKey(trackId);
  @override
  GrooveAssign? get sectionGroove => s._sec.grooveOverrides[trackId];
  @override
  int get defaultLength => s._sec.bars <= 1 ? 16 : 32;
  @override
  bool get hasTake => s._lastTakeOnsets?.isNotEmpty ?? false;
  bool get _ko => Localizations.localeOf(s.context).languageCode == 'ko';

  @override
  void assign(GrooveAssign? a, {required bool section, bool coalesce = false}) =>
      s._grooveEdit(() {
        if (section) {
          s._sec.grooveOverrides[trackId] = a;
        } else if (a == null) {
          s._trackGrooves.remove(trackId);
        } else {
          s._trackGrooves[trackId] = a;
        }
      }, coalesce: coalesce);

  @override
  void clearSectionOverride() =>
      s._grooveEdit(() => s._sec.grooveOverrides.remove(trackId));

  @override
  void setAmount(double v, {bool coalesce = false}) => s._grooveEdit(
    () => s._grooveAmount = v.clamp(0.0, 1.3).toDouble(),
    coalesce: coalesce,
  );

  String _nextName() {
    var i = 1;
    final base = _ko ? '내 그루브' : 'My groove';
    while (s._grooves.any((g) => g.name == '$base $i')) {
      i++;
    }
    return '$base $i';
  }

  String? _add(
    List<({double steps, int velocity})> beats,
    int length,
    String origin,
  ) {
    final t = extractGroove(
      beats,
      length: length,
      name: _nextName(),
      id: 'g${DateTime.now().microsecondsSinceEpoch}',
      sectionSteps: stepsForBars(s._sec.bars),
      origin: origin,
    );
    if (t == null) return _ko ? '박이 너무 적어요.' : 'Too few beats.';
    s._grooveEdit(() {
      s._grooves.add(t);
      s._trackGrooves[trackId] = GrooveAssign(grooveId: t.id);
    });
    return null;
  }

  @override
  String? extractFromTake(int length) =>
      _add(s._lastTakeOnsets ?? const [], length, 'take');

  @override
  String? extractFromTrack(int length) {
    final data = s._sec.tracks[trackId];
    if (data == null) return _ko ? '박이 너무 적어요.' : 'Too few beats.';
    return _add([
      for (final n in data.pitchNotes)
        if (!n.muted) (steps: n.startSteps, velocity: n.velocity ?? 100),
      for (final n in data.drumNotes)
        if (!n.muted) (steps: n.startSteps, velocity: n.velocity ?? 100),
    ], length, 'track');
  }

  @override
  void rename(String id, String name) => s._grooveEdit(() {
    final i = s._grooves.indexWhere((g) => g.id == id);
    if (i >= 0) s._grooves[i] = s._grooves[i].copyWith(name: name);
  });
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
    this.pan = const {},
    required this.mutes,
    required this.instruments,
    required this.generationLocks,
    required this.title,
    this.songVocalPath,
    this.songVocalPeaks,
    this.songVocalBpm,
    this.songVocalBars,
    this.variationSeed,
    this.grooves = const [],
    this.trackGrooves = const {},
    this.grooveAmount = 1.0,
  });
  final List<Section> sections;
  final int activeIdx;
  final String activeId;
  final String keyRoot, scale, title;
  final int bpm;
  final double swing;
  final Map<String, double> vol;
  final Map<String, double> pan;
  final Map<String, bool> generationLocks;
  final Map<String, bool> mutes;
  final Map<String, int> instruments;
  final String? songVocalPath;
  final List<double>? songVocalPeaks;
  final int? songVocalBpm;
  final int? songVocalBars;
  final int? variationSeed;
  final List<GrooveTemplate> grooves;
  final Map<String, GrooveAssign> trackGrooves;
  final double grooveAmount;
}

/// Thrown inside _humConvert when the section/lane/tempo/key the hum was
/// analysed for changed during the engine call; surfaces as a retryable miss.
class _HumTargetChanged implements Exception {
  const _HumTargetChanged();
  @override
  String toString() => 'hum target changed during analysis';
}
