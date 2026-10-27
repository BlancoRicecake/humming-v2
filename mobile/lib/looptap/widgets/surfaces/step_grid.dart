// Pitched grid: legacy drawing plus selection-based, atomic MIDI edits.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/loop_models.dart';
import '../../music/arpeggiate.dart';
import '../../music/guitar_articulation.dart';
import '../../music/guitar_stroke.dart';
import '../../music/guitar_strings.dart';
import '../../music/guitar_sustain.dart';
import '../../music/pitch_note_edit.dart';
import '../../music/pitch_clipboard.dart';
import '../../music/theory.dart';
import '../../state/loop_prefs.dart';
import '../../theme/tokens.dart';
import '../sheets/arp_sheet.dart';
import '../sheets/chord_type_sheet.dart';
import '../sheets/guitar_stroke_panel.dart';
import '../sheets/note_tool_sheets.dart';
import 'pitch_grid_surface.dart';
import 'velocity_lane.dart';

class StepGrid extends StatefulWidget {
  const StepGrid({
    super.key,
    required this.ladder,
    required this.notes,
    required this.onPlace,
    required this.onErase,
    required this.playStep,
    required this.accent,
    required this.steps,
    required this.bars,
    this.windowOffset = 0,
    this.maxOffset = 0,
    this.onWindowChanged,
    this.onEdit,
    this.initialEditMode = false,
    this.focusToggle = false,
    this.enabled = true,
    this.clipboard,
    this.focusMidi,
    this.onPreview,
    this.scaleRoot,
    this.scaleName,
    this.guitar = false,
    this.bpm = 120,
    this.grooved = false,
    this.onPreviewNote,
    this.articulationChannel,
    this.articulationShort = const [],
  });
  final List<Rung> ladder;
  final List<PitchNote> notes;
  final void Function(Rung rung, int a, int b) onPlace;
  final void Function(Rung rung, int step) onErase;

  /// Parent validates the source snapshot and records one undo transaction.
  final bool Function(List<PitchNote> before, List<PitchNote> after)? onEdit;
  final double playStep;
  final Color accent;
  final int steps, bars, windowOffset, maxOffset;
  final ValueChanged<int>? onWindowChanged;
  final bool initialEditMode, enabled;

  /// Show the 편집 확대 (LoopPrefs.gridFocus) icon at the front of the tool
  /// row (narrow screens; wide editors put it in their header).
  final bool focusToggle;
  final PitchClipboard? clipboard;
  final int? focusMidi;
  final ValueChanged<Rung>? onPreview;

  /// The song's key root (e.g. 'A') and scale id (a [kScales] key) for the
  /// scale tools. Null or 'chromatic' disables Fit to scale / Scale snap.
  final String? scaleRoot, scaleName;

  /// The track plays a guitar: chord stamps use the pad guitar voicings,
  /// and the guitar stroke control (gt-001) and its ↓/↑ marks show.
  final bool guitar;

  /// Song tempo: converts the stroke spread (ms) into steps.
  final int bpm;

  /// gt-002: the track plays with a groove (the guitar panel shows the
  /// choke-drift hint).
  final bool grooved;

  /// gt-003: audition of an existing articulated note (tapping it), through
  /// the same realize step as playback. Normal notes keep [onPreview].
  final ValueChanged<PitchNote>? onPreviewNote;

  /// gt-003: the articulation channel the song would give [role] on this
  /// track with the tentative notes (null = none left: the apply is
  /// refused). Null callback = no check.
  final int? Function(ArtRole role, List<PitchNote> tentative)?
  articulationChannel;

  /// gt-003: roles this track needs but has no channel for ("채널 부족").
  final List<ArtRole> articulationShort;
  @override
  State<StepGrid> createState() => _StepGridState();
}

class _StepGridState extends State<StepGrid> {
  final _focus = FocusNode(debugLabel: 'MIDI note editor');
  final _toolScroll = ScrollController(), _inspectorScroll = ScrollController();
  late bool _editing = widget.initialEditMode;
  bool _snap = true, _multiple = false, _resizing = false;
  bool _area = false, _erasing = false;
  bool get _showVelocity => LoopPrefs.instance.gridVelocityLane.value;

  /// Horizontal zoom/pan shared by the roll, its ruler and the velocity lane.
  late final PitchGridView _view = PitchGridView(widget.steps);
  final PitchClipboard _localClipboard = PitchClipboard();
  PitchClipboard get _clipboard => widget.clipboard ?? _localClipboard;
  int _pasteStep = 0;
  PitchNote? _velocityAnchor;
  Set<PitchNote> _selected = {}, _boxBase = {};
  late List<PitchNote> _known;
  List<PitchNote>? _base, _preview;
  GridPointer? _origin;
  PitchNote? _anchor;
  Rect? _marquee;
  int? _velocityDraft, _deviationDraft;
  double? _chanceDraft;

  /// Velocity lane shows chance instead of velocity.
  bool _chanceLane = false;

  /// Chord stamp mode (harmony-001): drawing places a chord, not one note.
  bool _chordStamp = false;

  /// gt-002: show string numbers and flag notes without a string (turned
  /// on by an assignment, toggled in the expanded guitar panel).
  bool _stringView = false;
  bool get _showStrings => widget.guitar && _stringView;

  /// Sounding notes without a string while the string view is on (an
  /// unassignable note, or one a pitch edit made unplayable on its string).
  Set<PitchNote> get _unassigned =>
      _showStrings
          ? {
            for (final n in widget.notes)
              if (!n.muted && n.guitarString == null) n,
          }
          : const {};
  bool get _ko => Localizations.localeOf(context).languageCode == 'ko';
  List<PitchNote> get _editable =>
      widget.notes.where((n) => _selected.contains(n) && !n.locked).toList();
  bool get _canEdit => widget.enabled && _editable.isNotEmpty;
  double get _nudge => _snap ? 1 : .1;

  /// Whole-track commands (fit, quantize, legato, humanize) act on the
  /// selection, or on every note of the track when nothing is selected.
  Set<PitchNote> get _scope =>
      _selected.isEmpty ? widget.notes.toSet() : _selected;
  bool get _canScope =>
      widget.enabled && widget.notes.any((n) => _scope.contains(n) && !n.locked);

  /// A real (non-chromatic) song scale the scale tools can use.
  bool get _hasScale =>
      widget.scaleRoot != null &&
      kNoteNames.contains(widget.scaleRoot) &&
      widget.scaleName != 'chromatic' &&
      kScales.containsKey(widget.scaleName);
  bool get _scaleSnap => _hasScale && LoopPrefs.instance.scaleSnap.value;

  @override
  void initState() {
    super.initState();
    _known = List.of(widget.notes);
    _clipboard.addListener(_clipboardChanged);
  }

  void _clipboardChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _clipboard.removeListener(_clipboardChanged);
    _localClipboard.dispose();
    _view.dispose();
    _toolScroll.dispose();
    _inspectorScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(StepGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clipboard != widget.clipboard) {
      (oldWidget.clipboard ?? _localClipboard).removeListener(
        _clipboardChanged,
      );
      _clipboard.addListener(_clipboardChanged);
    }
    _view.steps = widget.steps;
    if (!listEquals(_known, widget.notes) ||
        oldWidget.steps != widget.steps ||
        !listEquals(
          oldWidget.ladder.map((r) => r.midi).toList(),
          widget.ladder.map((r) => r.midi).toList(),
        ) ||
        !widget.enabled) {
      _resetGesture();
      _selected.removeWhere((n) => !widget.notes.contains(n));
    }
    _known = List.of(widget.notes);
  }

  void _resetGesture() {
    _origin = null;
    _anchor = null;
    _base = null;
    _preview = null;
    _marquee = null;
    _velocityDraft = null;
    _chanceDraft = null;
    _deviationDraft = null;
    _velocityAnchor = null;
  }

  void _cancel() => setState(_resetGesture);

  PitchNote? _at(GridPointer p) {
    final row =
        widget.notes.where((n) => n.midi == p.rung.midi).toList().reversed;
    for (final n in row) {
      if (p.position >= n.startSteps && p.position < n.endSteps) return n;
    }
    // Short imported notes still have a usable pointer target.
    final unit = p.unitFor(widget.steps);
    for (final n in row) {
      if (_selected.contains(n) &&
          (p.position - n.endSteps).abs() * unit <= 8) {
        return n;
      }
      if (n.soundingSteps * unit < 10 &&
          (p.position - (n.startSteps + n.endSteps) / 2).abs() * unit <= 5) {
        return n;
      }
    }
    return null;
  }

  void _start(GridPointer p) {
    if (!widget.enabled) return;
    _focus.requestFocus();
    final additive =
        _multiple ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final note = _area ? null : _at(p);
    _pasteStep = p.position.floor().clamp(0, widget.steps - 1);
    if (note != null) {
      if (note.articulation != null && widget.onPreviewNote != null) {
        widget.onPreviewNote!(note);
      } else {
        widget.onPreview?.call(p.rung);
      }
    }
    setState(() {
      _resetGesture();
      _base = List.of(widget.notes);
      _origin = p;
      _boxBase = additive ? Set.of(_selected) : {};
      if (note == null) {
        if (!additive) _selected.clear();
        return;
      }
      final already = _selected.contains(note);
      if (additive && already) {
        _selected.remove(note);
        _resetGesture();
        return;
      }
      if (!already && !additive) _selected.clear();
      _selected.add(note);
      _anchor = note;
      final unit = p.unitFor(widget.steps);
      _resizing =
          already &&
          note.soundingSteps * unit > 12 &&
          (p.position - note.endSteps).abs() * unit <= 8;
    });
  }

  void _move(GridPointer p) {
    final origin = _origin, base = _base;
    if (origin == null || base == null) return;
    if ((p.local - origin.local).distance < 4 &&
        _preview == null &&
        _marquee == null) {
      return;
    }
    setState(() {
      if (_anchor == null) {
        final rect = Rect.fromPoints(origin.local, p.local);
        _marquee = rect;
        final rows = widget.ladder.reversed.toList();
        // the roll's own axis: zoom/pan and the gutter never skew selection
        final axis =
            p.axis ??
            PitchGridAxis(steps: widget.steps, rows: rows.length, size: p.size);
        final rowOf = {for (var r = 0; r < rows.length; r++) rows[r].midi: r};
        _selected = {
          ..._boxBase,
          for (final n in base)
            if (rowOf[n.midi] case final row?)
              if (rect.overlaps(
                Rect.fromLTWH(
                  axis.x(n.startSteps),
                  axis.y(row),
                  n.soundingSteps * axis.pxPerStep,
                  axis.rowHeight,
                ),
              ))
                n,
        };
      } else {
        final raw = p.position - origin.position;
        final delta = _snap ? raw.roundToDouble() : raw;
        _preview =
            _resizing
                ? resizePitchNotes(
                  base,
                  _selected,
                  deltaSteps: delta,
                  steps: widget.steps,
                )
                : movePitchNotes(
                  base,
                  _selected,
                  deltaSteps: delta,
                  semitones: p.rung.midi - origin.rung.midi,
                  steps: widget.steps,
                );
      }
    });
  }

  void _finish() {
    final base = _base, preview = _preview;
    if (base != null && preview != null) {
      _commit(base, preview);
    } else {
      _cancel();
    }
  }

  void _commit(
    List<PitchNote> before,
    List<PitchNote> after, {
    Set<PitchNote>? selection,
  }) {
    if (listEquals(before, after)) {
      _cancel();
      return;
    }
    final next =
        selection ??
        {
          for (var i = 0; i < before.length && i < after.length; i++)
            if (_selected.contains(before[i])) after[i],
        };
    final accepted = widget.onEdit?.call(before, after) ?? false;
    setState(() {
      _resetGesture();
      if (accepted) _selected = next;
    });
    // gt-003: a pitch edit that left a tone approximation's range cleared
    // it (the note is normal now) — say so
    if (accepted && before.length == after.length) {
      var cleared = 0;
      for (var i = 0; i < before.length; i++) {
        if (before[i].articulation != null &&
            after[i].articulation == null &&
            before[i].midi != after[i].midi) {
          cleared++;
        }
      }
      if (cleared > 0) {
        _snack(
          _ko
              ? '음높이가 연주법 지원 범위를 벗어나 일반으로 바뀐 노트 $cleared개'
              : '$cleared notes left their technique range and are normal now.',
        );
      }
    }
  }

  bool _startVelocity(PitchNote note) {
    if (!widget.enabled || widget.onEdit == null) return false;
    _focus.requestFocus();
    setState(() {
      _resetGesture();
      if (!_selected.contains(note)) _selected = {note};
      if (!note.locked) {
        _base = List.of(widget.notes);
        _velocityAnchor = note;
      }
    });
    return !note.locked;
  }

  void _moveVelocity(int delta) {
    final base = _base, anchor = _velocityAnchor;
    if (base == null || anchor == null) return;
    setState(() {
      if (_chanceLane) {
        _preview = shiftPitchChance(base, _selected, delta / 127);
        _chanceDraft = (anchor.chance + delta / 127).clamp(0.0, 1.0);
        return;
      }
      _preview = shiftPitchVelocities(base, _selected, delta);
      _velocityDraft = ((anchor.velocity ?? 100) + delta).clamp(1, 127);
    });
  }

  void _shift(double time, int pitch) => _commit(
    List.of(widget.notes),
    movePitchNotes(
      widget.notes,
      _selected,
      deltaSteps: time,
      semitones: pitch,
      steps: widget.steps,
    ),
  );
  /// Semitone move; with Scale snap on, each note steps to its next scale
  /// pitch instead.
  void _semitone(int dir) {
    if (!_scaleSnap) {
      _shift(0, dir);
      return;
    }
    _commit(
      List.of(widget.notes),
      movePitchNotesInScale(
        widget.notes,
        _selected,
        root: widget.scaleRoot!,
        scale: widget.scaleName!,
        dir: dir,
      ),
    );
  }

  void _fitScale() {
    if (!_hasScale) return;
    _commit(
      List.of(widget.notes),
      fitPitchNotesToScale(
        widget.notes,
        _scope,
        widget.scaleRoot!,
        widget.scaleName!,
      ),
    );
  }

  /// The chord stamp's scale (pentatonic → natural minor; null = none).
  String? get _chordScale => chordScaleFor(widget.scaleName);
  ChordType get _chordType => effectiveChordType(
    ChordType.byName(LoopPrefs.instance.chordType.value),
    widget.scaleName,
  );

  Rung _rungFor(int midi) => widget.ladder.firstWhere(
    (r) => r.midi == midi,
    orElse:
        () => Rung(
          midi: midi,
          name: '${kNoteNames[midi % 12]}${midi ~/ 12 - 1}',
          degree: midi % 12,
          freq: midiToFreq(midi),
          index: midi,
        ),
  );

  /// Bottom-up chord stamp: the drawn span becomes a chord rooted on [rung]
  /// (one edit, one undo step), auditioned once.
  void _stampAt(Rung rung, int a, int b) {
    final midis = chordMidis(
      _chordType,
      rung.midi,
      key: widget.scaleRoot ?? 'C',
      scale: _chordScale ?? 'major',
      inversion: LoopPrefs.instance.chordInversion.value,
      guitar: widget.guitar,
    );
    final edit = stampChordAt(
      widget.notes,
      PitchNote(
        midi: rung.midi,
        freq: rung.freq,
        step: math.min(a, b),
        dur: (a - b).abs() + 1,
      ),
      midis,
    );
    if (identical(edit.notes, widget.notes)) return;
    for (final m in midis) {
      if (m >= 0 && m <= 127) widget.onPreview?.call(_rungFor(m));
    }
    _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
  }

  /// Top-down chord stamp under the selected melody notes.
  void _stampBelow() {
    final edit = stampChordsBelow(
      widget.notes,
      _selected,
      _chordType,
      key: widget.scaleRoot ?? 'C',
      scale: _chordScale,
    );
    if (!identical(edit.notes, widget.notes) && edit.selection.isNotEmpty) {
      final first = edit.selection
          .map((n) => n.startSteps)
          .reduce(math.min);
      for (final n in edit.selection) {
        if (n.startSteps == first) widget.onPreview?.call(_rungFor(n.midi));
      }
    }
    _commitEdit(edit, _ko ? '추가할 음이 없습니다.' : 'No notes to add.');
  }

  Future<void> _chordSheet() async {
    await showChordTypeSheet(context, chromatic: _chordScale == null);
    if (!mounted) return;
    setState(() {});
    _focus.requestFocus();
  }

  void _toggleChordStamp() => setState(() {
    _chordStamp = !_chordStamp;
    if (_chordStamp) {
      _editing = false;
      _erasing = false;
      _area = false;
      _resetGesture();
    }
  });

  /// Drawing with Scale snap on lands an out-of-scale row on the nearest
  /// scale pitch (ties go down).
  void _place(Rung rung, int a, int b) {
    if (_scaleSnap &&
        !inScale(rung.midi, widget.scaleRoot!, widget.scaleName!)) {
      final m = nearestInScale(
        rung.midi,
        widget.scaleRoot!,
        widget.scaleName!,
      );
      rung = widget.ladder.firstWhere(
        (r) => r.midi == m,
        orElse:
            () => Rung(
              midi: m,
              name: '${kNoteNames[m % 12]}${m ~/ 12 - 1}',
              degree: m % 12,
              freq: midiToFreq(m),
              index: m,
            ),
      );
    }
    if (_chordStamp && widget.onEdit != null) {
      _stampAt(rung, a, b);
      return;
    }
    widget.onPlace(rung, a, b);
  }

  /// One commit; warns (without merging) when same-pitch notes now stack on
  /// the same start.
  void _commitWarnStacks(List<PitchNote> after) {
    final before = List<PitchNote>.of(widget.notes);
    if (identical(after, widget.notes)) {
      _cancel();
      return;
    }
    final stacked =
        stackedPitchNoteCount(after) - stackedPitchNoteCount(before);
    _commit(before, after);
    if (stacked > 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            _ko
                ? '같은 음·같은 시작 노트 $stacked개가 겹쳤습니다 (합치지 않음).'
                : '$stacked same-pitch notes now share a start (not merged).',
          ),
        ),
      );
    }
  }

  void _quantize() {
    final prefs = LoopPrefs.instance;
    _commitWarnStacks(
      quantizePitchNotes(
        widget.notes,
        _scope,
        grid: QuantizeGrid.byName(prefs.quantizeGrid.value).steps,
        strength: prefs.quantizeStrength.value / 100,
        ends: prefs.quantizeEnds.value,
        steps: widget.steps,
      ),
    );
  }

  Future<void> _quantizeSettings() async {
    final apply = await showQuantizeSheet(context, canApply: _canScope);
    if (!mounted) return;
    setState(() {});
    if (apply) _quantize();
    _focus.requestFocus();
  }

  /// Commit a note-count-changing edit with its explicit selection; tell the
  /// user when there was nothing to do.
  void _commitEdit(PitchNoteEdit edit, String nothing) {
    if (identical(edit.notes, widget.notes)) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(nothing)));
      return;
    }
    _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
  }

  String get _noSplit => _ko ? '자를 노트가 없습니다.' : 'No notes to split.';

  void _splitAtPlayhead() {
    final at = _snap ? widget.playStep.roundToDouble() : widget.playStep;
    _commitEdit(splitPitchNotesAt(widget.notes, _selected, at), _noSplit);
  }

  void _splitMiddle() => _commitEdit(
    splitPitchNotesEach(widget.notes, _selected, (n) {
      final mid = (n.startSteps + n.endSteps) / 2;
      return _snap ? mid.roundToDouble() : mid;
    }),
    _noSplit,
  );

  void _chop({int? parts, double? grid}) => _commitEdit(
    chopPitchNotes(widget.notes, _selected, parts: parts, grid: grid),
    _noSplit,
  );

  void _glue() => _commitEdit(
    gluePitchNotes(widget.notes, _selected),
    _ko ? '붙일 노트가 없습니다.' : 'No notes to glue.',
  );

  /// Split / Chop sheet: playhead, middle, N equal parts or a grid.
  Future<void> _splitSheet() async {
    var parts = 2;
    final action = await showModalBottomSheet<VoidCallback>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setSheet) {
              Widget choice(String key, String label, VoidCallback run) =>
                  OutlinedButton(
                    key: ValueKey(key),
                    onPressed: () => Navigator.of(context).pop(run),
                    child: Text(label),
                  );
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_ko ? '자르기' : 'Split'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        choice(
                          'split-playhead',
                          _ko ? '재생 위치에서' : 'At playhead',
                          _splitAtPlayhead,
                        ),
                        choice(
                          'split-middle',
                          _ko ? '가운데에서' : 'At middle',
                          _splitMiddle,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text(_ko ? '$parts등분' : '$parts parts'),
                        Expanded(
                          child: Slider(
                            key: const ValueKey('chop-parts'),
                            min: 2,
                            max: 16,
                            divisions: 14,
                            value: parts.toDouble(),
                            onChanged: (v) => setSheet(() => parts = v.round()),
                          ),
                        ),
                        choice(
                          'chop-parts-apply',
                          _ko ? '나누기' : 'Chop',
                          () => _chop(parts: parts),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in const [
                          QuantizeGrid.quarter,
                          QuantizeGrid.eighth,
                          QuantizeGrid.sixteenth,
                          QuantizeGrid.thirtySecond,
                        ])
                          choice(
                            'chop-grid-${g.name}',
                            g.label,
                            () => _chop(grid: g.steps),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
    );
    if (!mounted) return;
    action?.call();
    _focus.requestFocus();
  }

  /// Humanize once with the saved settings and a fresh seed. The result is
  /// stored, so undo/redo replay exactly this roll.
  void _humanize() {
    final prefs = LoopPrefs.instance;
    _commit(
      List.of(widget.notes),
      humanizePitchNotes(
        widget.notes,
        _scope,
        timingSteps: prefs.humanizeTiming.value,
        velocityRange: prefs.humanizeVelocity.value,
        seed: DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF,
        steps: widget.steps,
      ),
    );
  }

  Future<void> _humanizeSettings() async {
    final apply = await showHumanizeSheet(context, canApply: _canScope);
    if (!mounted) return;
    if (apply) _humanize();
    _focus.requestFocus();
  }

  /// Arpeggiate the selected chords with the saved settings (one undo step).
  void _arpeggiate() => _commitEdit(
    arpeggiatePitchNotes(
      widget.notes,
      _selected,
      currentArpSettings(),
      seed: DateTime.now().microsecondsSinceEpoch & 0xFFFFFFFF,
      steps: widget.steps,
    ),
    _ko ? '펼칠 코드가 없습니다.' : 'No chords to arpeggiate.',
  );

  Future<void> _arpSettings() async {
    final apply = await showArpSheet(context, canApply: _canEdit);
    if (!mounted) return;
    setState(() {});
    if (apply) _arpeggiate();
    _focus.requestFocus();
  }

  void _legato() => _commit(
    List.of(widget.notes),
    legatoPitchNotes(widget.notes, _scope, steps: widget.steps),
  );

  /// gt-001 guitar stroke: one conversion = one undo step.
  void _commitStroke(GuitarStrokeEdit edit) {
    if (identical(edit.notes, widget.notes)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            _ko ? '변환할 화음이 없습니다.' : 'No chords to convert.',
          ),
        ),
      );
      return;
    }
    _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
    _focus.requestFocus();
  }

  void _stroke(StrokeDir dir) => _commitStroke(
    applyGuitarStroke(
      widget.notes,
      _selected,
      currentStrokeSpec(dir),
      bpm: widget.bpm,
    ),
  );

  void _strokePattern(StrokePattern pattern) {
    if (LoopPrefs.instance.strokePattern.value != pattern.id) {
      LoopPrefs.instance.setStroke(pattern: pattern.id);
    }
    _commitStroke(
      applyStrokePattern(
        widget.notes,
        _selected,
        pattern,
        down: currentStrokeSpec(StrokeDir.down),
        up: currentStrokeSpec(StrokeDir.up),
        bpm: widget.bpm,
      ),
    );
  }

  bool get _canRevertStroke =>
      widget.enabled &&
      widget.notes.any(
        (n) => n.stroke != null && !n.locked && _scope.contains(n),
      );

  void _revertStroke() => _commitStroke(revertGuitarStroke(widget.notes, _selected));

  Future<void> _strokePanel() async {
    final result = await showGuitarStrokePanel(
      context,
      canApply: _canScope,
      canRevert: _canRevertStroke,
      canAssign: _canScope,
      canRing: _canRing,
      canRevertRing: _canRevertRing,
      canChooseString: _canEdit,
      playableStrings: playableStringsFor(_editable),
      stringView: _stringView,
      grooved: widget.grooved,
      selectedCount: _selected.length,
      canArticulate: _canScope,
      articulationResult: _articulationResult,
      articulationShort: widget.articulationShort,
      naturalHarmonicInfo: _naturalHarmonicInfo,
      canSustain: _canScope,
      sustainResult: _sustainResult,
    );
    if (!mounted) return;
    setState(() {});
    switch (result?.action) {
      case GuitarStrokeAction.down:
        _stroke(StrokeDir.down);
      case GuitarStrokeAction.up:
        _stroke(StrokeDir.up);
      case GuitarStrokeAction.pattern:
        _strokePattern(strokePatternById(LoopPrefs.instance.strokePattern.value));
      case GuitarStrokeAction.revert:
        _revertStroke();
      case GuitarStrokeAction.assignStrings:
        _assignStrings();
      case GuitarStrokeAction.ring:
        _ring();
      case GuitarStrokeAction.revertRing:
        _revertRing();
      case GuitarStrokeAction.toggleStringView:
        setState(() => _stringView = !_stringView);
      case GuitarStrokeAction.setString:
        _setString(result!.string);
      case GuitarStrokeAction.autoString:
        _setString(null);
      case GuitarStrokeAction.articulation:
        _articulate(result!.kind);
      case GuitarStrokeAction.sustain:
        _sustain();
      case null:
        break;
    }
    _focus.requestFocus();
  }

  void _snack(String text) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(text)));

  /// gt-003: the last 연주법 apply's counts (shown in the panel).
  String? _articulationResult;

  /// gt-003 "연주법": one apply = one undo. New applies snapshot the
  /// LoopPrefs defaults; refused notes are counted, never changed.
  void _articulate(ArticulationKind? kind) {
    final prefs = LoopPrefs.instance;
    final value =
        kind == null
            ? null
            : newArticulation(
              kind,
              staccatoMs: prefs.articulationStaccatoMs.value,
              palmMs: prefs.articulationPalmMs.value,
              palmVelScale: prefs.articulationPalmVelocity.value / 100,
            );
    final edit = applyArticulation(
      widget.notes,
      _selected,
      value,
      channelFor: widget.articulationChannel,
    );
    final line =
        _ko
            ? '적용 ${edit.applied}, 지원 범위 밖 ${edit.outOfRange}, '
                '채널 부족 ${edit.noChannel}'
            : 'Applied ${edit.applied}, out of range ${edit.outOfRange}, '
                'no channel ${edit.noChannel}';
    setState(() => _articulationResult = line);
    if (!identical(edit.notes, widget.notes)) {
      _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
    }
    _snack(line);
  }

  /// gt-003 display-only natural-harmonic info for the notes in scope that
  /// carry (or could carry) the harmonic tone, from their G2 strings.
  String? get _naturalHarmonicInfo {
    final notes = [
      for (final n in widget.notes)
        if (_scope.contains(n) &&
            (n.articulation?.kind == ArticulationKind.harmonicTone ||
                articulationFits(ArticulationKind.harmonicTone, n.midi)))
          n,
    ];
    if (notes.isEmpty) return null;
    final spots = <String>{
      for (final n in notes)
        if (naturalHarmonicPosition(n) case final p?)
          _ko ? '${p.string}번 줄 ${p.fret}프렛' : 'string ${p.string} fret ${p.fret}',
    };
    if (spots.isEmpty) {
      return _ko
          ? '자연 하모닉스 위치 아님/미확인 (음색 근사는 가능)'
          : 'Not a natural-harmonic position / unknown (the tone '
              'approximation still applies)';
    }
    final list = spots.take(3).join(', ');
    return _ko
        ? '자연 하모닉스 위치: $list (정보만 표시)'
        : 'Natural-harmonic position: $list (information only)';
  }

  /// gt-002 "줄 배정": one edit = one undo; reports the unassignable count
  /// (those notes are flagged on the grid, never moved).
  void _assignStrings() {
    final edit = assignStrings(widget.notes, _selected);
    setState(() => _stringView = true);
    final bad = edit.unassignable.length;
    if (!identical(edit.notes, widget.notes)) {
      _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
    }
    _snack(
      bad == 0
          ? (_ko ? '줄을 배정했습니다.' : 'Strings assigned.')
          : (_ko
              ? '줄을 배정하지 못한 노트 $bad개 (옮기지 않고 표시했습니다).'
              : '$bad notes could not be placed (marked, not moved).'),
    );
    _focus.requestFocus();
  }

  bool get _canRing =>
      widget.enabled &&
      widget.notes.any(
        (n) =>
            _scope.contains(n) &&
            !n.locked &&
            !n.muted &&
            n.guitarString != null,
      );

  bool get _canRevertRing =>
      widget.enabled &&
      widget.notes.any(
        (n) => _scope.contains(n) && !n.locked && n.ringBaseDur != null,
      );

  /// gt-002 "울림 아르페지오" over the selection (or the whole track up to
  /// the section end): one edit = one undo.
  void _ring() {
    final edit = applyRing(
      widget.notes,
      _selected,
      rangeEnd: ringRangeEnd(widget.notes, _selected, widget.steps),
    );
    if (identical(edit.notes, widget.notes)) {
      _snack(
        _ko
            ? '울릴 노트가 없습니다. 먼저 줄을 배정하세요.'
            : 'Nothing to ring. Assign strings first.',
      );
      return;
    }
    _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
    _focus.requestFocus();
  }

  /// gt-004: the last "줄별 울림 유지" result (shown in the panel).
  String? _sustainResult;

  /// gt-004 "줄별 울림 유지" over the selection (or the whole track): one
  /// edit = one undo, including the automatic strings it writes. Nothing
  /// extended = a hint and no edit.
  void _sustain() {
    final r = applyStrokeSustain(
      widget.notes,
      _selected,
      sectionSteps: widget.steps,
    );
    final summary = r.summary(ko: _ko);
    final line =
        r.extended > 0
            ? summary
            : (_ko
                ? '이어 줄 음이 없습니다. 스트로크를 적용한 같은 화음을 같은 줄에서 '
                    '다시 칠 때만 이어집니다. $summary'
                : 'Nothing to extend. Only stroked chords struck again with '
                    'the same notes on the same strings are joined. $summary');
    setState(() => _sustainResult = line);
    if (r.extended > 0) {
      _commit(List.of(widget.notes), r.notes, selection: r.selection);
    }
    _snack(line);
    _focus.requestFocus();
  }

  void _revertRing() {
    final edit = revertRing(widget.notes, _selected);
    if (identical(edit.notes, widget.notes)) return;
    _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
    _focus.requestFocus();
  }

  /// Manual string choice (null = back to automatic); refused notes are
  /// reported.
  void _setString(int? string) {
    final edit = setGuitarString(widget.notes, _selected, string);
    if (!identical(edit.notes, widget.notes)) {
      setState(() => _stringView = true);
      _commit(List.of(widget.notes), edit.notes, selection: edit.selection);
    }
    if (edit.refused > 0) {
      _snack(
        _ko
            ? '$string번 줄에 놓을 수 없는 노트 ${edit.refused}개는 바꾸지 않았습니다 '
                '(그 줄에서 낼 수 없는 음이거나 같은 화음의 다른 노트가 쓰는 줄).'
            : '${edit.refused} notes kept their string: string $string cannot '
                'play them, or another note of the chord uses it.',
      );
    }
  }

  void _length(double amount) => _commit(
    List.of(widget.notes),
    resizePitchNotes(
      widget.notes,
      _selected,
      deltaSteps: amount,
      steps: widget.steps,
    ),
  );
  void _delete() => _commit(
    List.of(widget.notes),
    deletePitchNotes(widget.notes, _selected),
    selection: {},
  );

  /// Mute unless every editable selected note is already muted (then unmute).
  bool get _allMuted => _editable.isNotEmpty && _editable.every((n) => n.muted);
  void _toggleMute() => _commit(
    List.of(widget.notes),
    setPitchNotesMuted(widget.notes, _selected, !_allMuted),
  );
  void _duplicate() {
    final before = List<PitchNote>.of(widget.notes);
    final after = duplicatePitchNotes(before, _selected, widget.steps);
    if (identical(after, before)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            _ko
                ? '이 구간에는 복제할 공간이 부족합니다.'
                : 'Not enough room to duplicate in this section.',
          ),
        ),
      );
      return;
    }
    _commit(before, after, selection: after.skip(before.length).toSet());
  }

  void _copy() {
    final selected = widget.notes.where(_selected.contains).toList();
    _clipboard.copy(selected);
    if (selected.isNotEmpty) {
      setState(
        () =>
            _pasteStep = selected
                .map((n) => n.endSteps.ceil())
                .reduce((a, b) => a > b ? a : b),
      );
    }
    _focus.requestFocus();
  }

  void _paste() {
    final before = List<PitchNote>.of(widget.notes);
    final copies = _clipboard.paste(atStep: _pasteStep, steps: widget.steps);
    if (copies.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            _ko
                ? '붙여넣을 공간이 부족합니다. 더 앞쪽의 빈 곳을 눌러주세요.'
                : 'Not enough room. Click an earlier empty position.',
          ),
        ),
      );
      return;
    }
    setState(() {
      _editing = true;
      _erasing = false;
    });
    _commit(before, [...before, ...copies], selection: copies.toSet());
    _focus.requestFocus();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final command =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    // Ctrl/Cmd+Shift+C toggles chord stamp mode in any tool.
    if (command &&
        shift &&
        event.logicalKey == LogicalKeyboardKey.keyC &&
        widget.enabled &&
        !HardwareKeyboard.instance.isAltPressed &&
        event is KeyDownEvent &&
        ModalRoute.of(context)?.isCurrent != false) {
      _toggleChordStamp();
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isAltPressed ||
        (!_editing &&
            !(command && event.logicalKey == LogicalKeyboardKey.keyV)) ||
        !widget.enabled ||
        event is KeyUpEvent ||
        ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _resetGesture();
        _selected.clear();
      });
      return KeyEventResult.handled;
    }
    if (_base != null) return KeyEventResult.ignored;
    if (command && shift && key == LogicalKeyboardKey.keyA) {
      // Ctrl/Cmd+Shift+A: arpeggiate (plain A is a desktop piano key)
      if (event is KeyDownEvent && _canEdit) _arpeggiate();
    } else if (command && key == LogicalKeyboardKey.keyA) {
      setState(() => _selected = widget.notes.toSet());
    } else if (command &&
        key == LogicalKeyboardKey.keyC &&
        _selected.isNotEmpty) {
      if (event is KeyDownEvent) _copy();
    } else if (command &&
        key == LogicalKeyboardKey.keyV &&
        !_clipboard.isEmpty) {
      if (event is KeyDownEvent) _paste();
    } else if (command &&
        !shift &&
        key == LogicalKeyboardKey.keyD &&
        _canEdit) {
      // (Ctrl/Cmd+Shift+D is the editor's linked section duplicate)
      if (event is KeyDownEvent) _duplicate();
    } else if (command && key == LogicalKeyboardKey.keyE && _canEdit) {
      if (event is KeyDownEvent) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          _splitSheet();
        } else {
          _splitAtPlayhead();
        }
      }
    } else if (command && key == LogicalKeyboardKey.keyJ && _canEdit) {
      if (event is KeyDownEvent) _glue();
    } else if (command &&
        shift &&
        widget.guitar &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      // gt-001: Ctrl/Cmd+Shift+↓/↑ = down/up stroke on guitar tracks; takes
      // precedence over the chance lane's Ctrl/Cmd+↑/↓ (arrows are never
      // desktop instrument keys).
      if (event is KeyDownEvent && _canScope) {
        _stroke(
          key == LogicalKeyboardKey.arrowDown ? StrokeDir.down : StrokeDir.up,
        );
      }
    } else if (command &&
        shift &&
        widget.guitar &&
        key == LogicalKeyboardKey.keyG) {
      // gt-002: Ctrl/Cmd+Shift+G = assign strings (the workspace's groove
      // shortcut is Ctrl/Cmd+G without Shift)
      if (event is KeyDownEvent && _canScope) _assignStrings();
    } else if (command &&
        shift &&
        widget.guitar &&
        key == LogicalKeyboardKey.keyI) {
      // gt-002: Ctrl/Cmd+Shift+I = ringing arpeggio (I is not bound
      // elsewhere; Ctrl/Cmd keeps it off the desktop instrument)
      if (event is KeyDownEvent && _canRing) _ring();
    } else if (command &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown) &&
        _chanceLane &&
        _canEdit) {
      _commit(
        List.of(widget.notes),
        shiftPitchChance(
          widget.notes,
          _selected,
          key == LogicalKeyboardKey.arrowUp ? .1 : -.1,
        ),
      );
    } else if (command && key == LogicalKeyboardKey.keyL && _canScope) {
      if (event is KeyDownEvent) _legato();
    } else if (command && key == LogicalKeyboardKey.keyU && _canScope) {
      if (event is KeyDownEvent) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          _quantizeSettings();
        } else {
          _quantize();
        }
      }
    } else if (command &&
        key == LogicalKeyboardKey.keyH &&
        HardwareKeyboard.instance.isShiftPressed &&
        _canScope) {
      // Ctrl/Cmd+Shift+H: plain H/K belong to the desktop QWERTY piano, whose
      // global handler only steps aside for Ctrl/Cmd (and Cmd+H hides macOS apps).
      if (event is KeyDownEvent) _humanize();
    } else if (command && key == LogicalKeyboardKey.keyK && _hasScale && _canScope) {
      if (event is KeyDownEvent) _fitScale();
    } else if (command) {
      return KeyEventResult.ignored;
    } else if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        _canEdit) {
      _delete();
    } else if (key == LogicalKeyboardKey.keyM &&
        !HardwareKeyboard.instance.isShiftPressed &&
        _canEdit) {
      if (event is KeyDownEvent) _toggleMute();
    } else if (key == LogicalKeyboardKey.keyC && shift) {
      // C stamps a chord under the selection, Shift+C picks the kind (C is
      // outside the desktop QWERTY piano row).
      if (event is KeyDownEvent) _chordSheet();
    } else if (key == LogicalKeyboardKey.keyC &&
        widget.enabled &&
        _selected.isNotEmpty) {
      if (event is KeyDownEvent) _stampBelow();
    } else if ((key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight) &&
        _canEdit) {
      final amount = key == LogicalKeyboardKey.arrowLeft ? -_nudge : _nudge;
      if (HardwareKeyboard.instance.isShiftPressed) {
        _length(amount);
      } else {
        _shift(amount, 0);
      }
    } else if ((key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown) &&
        _canEdit) {
      final dir = key == LogicalKeyboardKey.arrowUp ? 1 : -1;
      if (HardwareKeyboard.instance.isShiftPressed) {
        _shift(0, 12 * dir);
      } else {
        _semitone(dir);
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Widget _button(
    String key,
    String label,
    VoidCallback? action, {
    bool active = false,
    VoidCallback? onLongPress,
  }) => TextButton(
    key: ValueKey(key),
    onPressed: widget.enabled ? action : null,
    onLongPress: widget.enabled ? onLongPress : null,
    style: TextButton.styleFrom(
      minimumSize: const Size(32, 32),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      foregroundColor: active ? LT.bg : LT.t2,
      backgroundColor: active ? widget.accent : null,
      // the app font (styleFrom replaces, not merges, the label style)
      textStyle: TextStyle(
        fontSize: 11,
        fontFamily: Theme.of(context).textTheme.bodyMedium?.fontFamily,
      ),
    ),
    child: Text(label),
  );
  Widget _scrollRow(ScrollController controller, List<Widget> children) =>
      SizedBox(
        height: 40,
        child: Scrollbar(
          controller: controller,
          thumbVisibility: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: SingleChildScrollView(
            controller: controller,
            scrollDirection: Axis.horizontal,
            child: Row(children: children),
          ),
        ),
      );

  List<Widget> _toolItems() => [
    if (widget.focusToggle)
      Tooltip(
        message: _ko ? '편집 확대' : 'Enlarge editor',
        child: IconButton(
          key: const ValueKey('grid-focus'),
          visualDensity: VisualDensity.compact,
          isSelected: LoopPrefs.instance.gridFocus.value,
          color: LT.t2,
          selectedIcon: Icon(Icons.close_fullscreen, color: widget.accent),
          onPressed: () {
            final prefs = LoopPrefs.instance;
            prefs.setGridLayout(focus: !prefs.gridFocus.value);
          },
          icon: const Icon(Icons.open_in_full, size: 18),
        ),
      ),
    // Beginners find the guitar tools here in both Draw and Select modes; it
    // opens the same panel as the inspector's ▸ (nothing selected = whole track).
    if (widget.guitar)
      _button(
        'note-guitar-tools',
        _ko ? '기타 연주' : 'Guitar',
        widget.enabled ? _strokePanel : null,
      ),
    _button(
      'note-draw',
      _ko ? '입력' : 'Draw',
      () => setState(() {
        _editing = false;
        _erasing = false;
        _area = false;
        _resetGesture();
        _selected.clear();
      }),
      active: !_editing && !_erasing,
    ),
    _button(
      'note-select',
      _ko ? '선택 편집' : 'Select',
      () => setState(() {
        _editing = true;
        _area = false;
        _erasing = false;
        _resetGesture();
      }),
      active: _editing && !_area,
    ),
    _button(
      'note-area',
      _ko ? '영역 선택' : 'Area select',
      () => setState(() {
        _editing = true;
        _area = true;
        _erasing = false;
        _resetGesture();
      }),
      active: _area,
    ),
    _button(
      'note-erase',
      _ko ? '지우개' : 'Eraser',
      () => setState(() {
        _editing = false;
        _erasing = true;
        _area = false;
        _resetGesture();
        _selected.clear();
      }),
      active: _erasing,
    ),
    _button('note-copy', _ko ? '복사' : 'Copy', _selected.isEmpty ? null : _copy),
    _button(
      'note-paste',
      _ko ? '붙여넣기' : 'Paste',
      _clipboard.isEmpty
          ? null
          : () {
            setState(() {
              _editing = true;
              _erasing = false;
            });
            _paste();
          },
    ),

    if (_editing) ...[
      _button(
        'note-snap',
        _snap ? (_ko ? '격자 맞춤' : 'Grid snap') : (_ko ? '자유 이동' : 'Free move'),
        () => setState(() => _snap = !_snap),
        active: _snap,
      ),
      _button(
        'note-multiple',
        _ko ? '여러 개' : 'Multi',
        () => setState(() => _multiple = !_multiple),
        active: _multiple,
      ),
      _button(
        'note-select-all',
        _ko ? '전체 선택' : 'Select all',
        () => setState(() => _selected = widget.notes.toSet()),
      ),
      const SizedBox(width: 8),
      Text(
        _selected.isEmpty
            ? (_ko
                ? '노트 클릭 · 빈 곳을 끌어 범위 선택'
                : 'Click notes · drag empty space to select')
            : _editable.isEmpty
            ? (_ko ? '잠긴 노트' : 'Locked notes')
            : (_ko
                ? '${_selected.length}개 선택'
                : '${_selected.length} selected'),
        style: const TextStyle(fontSize: 11, color: LT.t2),
      ),
    ],
    _button(
      'note-scale-snap',
      _ko ? '스케일 맞춤' : 'Scale snap',
      _hasScale
          ? () {
            final prefs = LoopPrefs.instance;
            prefs.setScaleSnap(!prefs.scaleSnap.value);
            setState(() {});
          }
          : null,
      active: _scaleSnap,
    ),
    _button(
      'grid-chord-stamp',
      _ko ? '코드 찍기' : 'Chord stamp',
      _toggleChordStamp,
      active: _chordStamp,
      onLongPress: _chordSheet,
    ),
    // Layout toggles (UI prefs only, docs/specs/grid-usability.md). 편집 확대
    // itself sits in the editor header next to Pads/Grid.
    _button(
      'note-velocity-toggle',
      _ko ? '강약 막대' : 'Velocity lane',
      () {
        setState(_resetGesture);
        LoopPrefs.instance.setGridLayout(velocityLane: !_showVelocity);
      },
      active: _showVelocity,
    ),
    if (_editing)
      _button(
        'note-tools-more',
        LoopPrefs.instance.gridToolsExpanded.value
            ? (_ko ? '도구 한 줄로 ▴' : 'One tool row ▴')
            : (_ko ? '도구 두 줄로 ▾' : 'Two tool rows ▾'),
        () {
          final prefs = LoopPrefs.instance;
          prefs.setGridLayout(toolsExpanded: !prefs.gridToolsExpanded.value);
        },
        active: LoopPrefs.instance.gridToolsExpanded.value,
      ),
    _divider(),
  ];
  Widget _divider() => Container(
    width: 1,
    height: 20,
    margin: const EdgeInsets.symmetric(horizontal: 4),
    color: LT.border,
  );
  Widget _tools() => _scrollRow(_toolScroll, _toolItems());

  List<Widget> _inspectorItems() {
    final values = _editable.map((n) => n.velocity).toSet();
    final strength =
        _velocityDraft ??
        (_editable.isEmpty
            ? 100
            : (_editable.map((n) => n.velocity ?? 100).reduce((a, b) => a + b) /
                    _editable.length)
                .round());
    final valueLabel =
        _velocityDraft?.toString() ??
        (values.length == 1
            ? values.single?.toString() ?? (_ko ? '기본' : 'Default')
            : '—');
    final allLocked = _selected.isNotEmpty && _selected.every((n) => n.locked);
    final quantizeLabel =
        QuantizeGrid.byName(LoopPrefs.instance.quantizeGrid.value).label;
    final chance =
        _chanceDraft ??
        (_editable.isEmpty
            ? 1.0
            : _editable.map((n) => n.chance).reduce((a, b) => a + b) /
                _editable.length);
    final deviation =
        _deviationDraft ??
        (_editable.isEmpty
            ? 0
            : (_editable
                        .map((n) => n.velocityDeviation)
                        .reduce((a, b) => a + b) /
                    _editable.length)
                .round());
    return [
      _button(
        'note-time-left',
        '←',
        _canEdit ? () => _shift(-_nudge, 0) : null,
      ),
      _button(
        'note-time-right',
        '→',
        _canEdit ? () => _shift(_nudge, 0) : null,
      ),
      _button('note-pitch-down', '♭', _canEdit ? () => _semitone(-1) : null),
      _button('note-pitch-up', '♯', _canEdit ? () => _semitone(1) : null),
      _button(
        'note-octave-down',
        _ko ? '옥타브 −' : 'Octave −',
        _canEdit ? () => _shift(0, -12) : null,
      ),
      _button(
        'note-octave-up',
        _ko ? '옥타브 +' : 'Octave +',
        _canEdit ? () => _shift(0, 12) : null,
      ),
      _button(
        'note-length-down',
        _ko ? '길이 −' : 'Length −',
        _canEdit ? () => _length(-_nudge) : null,
      ),
      _button(
        'note-length-up',
        _ko ? '길이 +' : 'Length +',
        _canEdit ? () => _length(_nudge) : null,
      ),
      Text(
        '${_ko ? '강약' : 'Velocity'} $valueLabel',
        style: const TextStyle(fontSize: 11, color: LT.t2),
      ),
      SizedBox(
        width: 130,
        child: Slider(
          key: const ValueKey('note-velocity'),
          min: 1,
          max: 127,
          divisions: 126,
          value: strength.toDouble().clamp(1, 127),
          activeColor: widget.accent,
          onChangeStart:
              !_canEdit ? null : (_) => _base = List.of(widget.notes),
          onChanged:
              !_canEdit
                  ? null
                  : (value) => setState(() {
                    _velocityDraft = value.round();
                    _preview = setPitchVelocity(
                      _base ?? widget.notes,
                      _selected,
                      value.round(),
                    );
                  }),
          onChangeEnd: !_canEdit ? null : (_) => _finish(),
        ),
      ),
      _button(
        'note-fit-scale',
        _ko ? '스케일에 맞추기' : 'Fit to scale',
        _hasScale && _canScope ? _fitScale : null,
      ),
      _button(
        'note-quantize',
        '${_ko ? '퀀타이즈' : 'Quantize'} $quantizeLabel',
        _canScope ? _quantize : null,
        onLongPress: _quantizeSettings,
      ),
      _button('note-quantize-settings', '⚙', _quantizeSettings),
      _button(
        'note-split',
        _ko ? '자르기' : 'Split',
        _canEdit ? _splitSheet : null,
      ),
      _button('note-glue', _ko ? '붙이기' : 'Glue', _canEdit ? _glue : null),
      _button(
        'note-humanize',
        _ko ? '휴머나이즈' : 'Humanize',
        _canScope ? _humanize : null,
        onLongPress: _humanizeSettings,
      ),
      _button('note-humanize-settings', '⚙', _humanizeSettings),
      _button(
        'note-chord-stamp',
        '${_ko ? '코드 깔기' : 'Chord below'} '
            '${_ko ? _chordType.labelKo : _chordType.label}',
        widget.enabled && _selected.isNotEmpty ? _stampBelow : null,
        onLongPress: _chordSheet,
      ),
      if (widget.guitar) ...[
        Text(
          _ko ? '기타 스트로크' : 'Guitar stroke',
          style: const TextStyle(fontSize: 11, color: LT.t2),
        ),
        _button(
          'stroke-down',
          '↓',
          _canScope ? () => _stroke(StrokeDir.down) : null,
        ),
        _button(
          'stroke-up',
          '↑',
          _canScope ? () => _stroke(StrokeDir.up) : null,
        ),
        for (final p in kStrokePatterns.skip(1))
          _button(
            'stroke-pattern-${p.id}',
            p.label,
            _canScope ? () => _strokePattern(p) : null,
            active: LoopPrefs.instance.strokePattern.value == p.id,
          ),
        _button('stroke-more', '▸', _strokePanel),
        if (_unassigned.isNotEmpty)
          _button(
            'guitar-unassigned-count',
            _ko
                ? '줄 없음 ${_unassigned.length}'
                : 'No string ${_unassigned.length}',
            () => setState(() => _selected = Set.of(_unassigned)),
          ),
      ],
      _button(
        'note-arpeggiate',
        _ko ? '펼치기' : 'Arpeggiate',
        _canEdit ? _arpeggiate : null,
        onLongPress: _arpSettings,
      ),
      _button('note-arpeggiate-settings', '⚙', _arpSettings),
      _button(
        'note-legato',
        _ko ? '이어 붙이기' : 'Legato',
        _canScope ? _legato : null,
      ),
      Text(
        '${_ko ? '확률' : 'Chance'} ${(chance * 100).round()}%',
        style: const TextStyle(fontSize: 11, color: LT.t2),
      ),
      SizedBox(
        width: 110,
        child: Slider(
          key: const ValueKey('note-chance'),
          min: 0,
          max: 100,
          divisions: 100,
          value: (chance * 100).clamp(0, 100).toDouble(),
          activeColor: widget.accent,
          onChangeStart:
              !_canEdit ? null : (_) => _base = List.of(widget.notes),
          onChanged:
              !_canEdit
                  ? null
                  : (value) => setState(() {
                    _chanceDraft = value.round() / 100;
                    _preview = setPitchChance(
                      _base ?? widget.notes,
                      _selected,
                      value.round() / 100,
                    );
                  }),
          onChangeEnd: !_canEdit ? null : (_) => _finish(),
        ),
      ),
      Text(
        '${_ko ? '세기 변화' : 'Variation'} '
        '${deviation > 0 ? '+' : ''}$deviation',
        style: const TextStyle(fontSize: 11, color: LT.t2),
      ),
      SizedBox(
        width: 110,
        child: Slider(
          key: const ValueKey('note-velocity-deviation'),
          min: -64,
          max: 64,
          divisions: 128,
          value: deviation.toDouble().clamp(-64, 64),
          activeColor: widget.accent,
          onChangeStart:
              !_canEdit ? null : (_) => _base = List.of(widget.notes),
          onChanged:
              !_canEdit
                  ? null
                  : (value) => setState(() {
                    _deviationDraft = value.round();
                    _preview = setPitchVelocityDeviation(
                      _base ?? widget.notes,
                      _selected,
                      value.round(),
                    );
                  }),
          onChangeEnd: !_canEdit ? null : (_) => _finish(),
        ),
      ),
      _button(
        'note-duplicate',
        _ko ? '복제' : 'Duplicate',
        _canEdit ? _duplicate : null,
      ),
      _button('note-delete', _ko ? '삭제' : 'Delete', _canEdit ? _delete : null),
      _button(
        'note-mute',
        _allMuted ? (_ko ? '소리 켜기' : 'Unmute') : (_ko ? '소리 끄기' : 'Mute'),
        _canEdit ? _toggleMute : null,
      ),
      _button(
        'note-lock',
        allLocked ? (_ko ? '잠금 해제' : 'Unlock') : (_ko ? '잠금' : 'Lock'),
        _selected.isEmpty
            ? null
            : () => _commit(
              List.of(widget.notes),
              setPitchNotesLocked(widget.notes, _selected, !allLocked),
            ),
      ),
    ];
  }

  Widget _inspector() => _scrollRow(_inspectorScroll, _inspectorItems());

  @override
  Widget build(BuildContext context) {
    final display = _preview ?? widget.notes;
    final selected =
        _preview == null
            ? _selected
            : {
              for (
                var i = 0;
                i < (_base?.length ?? 0) && i < display.length;
                i++
              )
                if (_selected.contains(_base![i])) display[i],
            };
    final surface = AbsorbPointer(
      absorbing: !widget.enabled,
      child: PitchGridSurface(
        ladder: widget.ladder,
        focusMidi: widget.focusMidi,
        eraseMode: widget.onEdit == null || _erasing,
        onPreview: widget.onPreview,
        notes: display,
        onPlace: _place,
        onErase: widget.onErase,
        playStep: widget.playStep,
        accent: widget.accent,
        steps: widget.steps,
        bars: widget.bars,
        windowOffset: widget.windowOffset,
        maxOffset: widget.maxOffset,
        onWindowChanged: widget.onWindowChanged,
        view: _view,
        onGestureStart: _editing && widget.onEdit != null ? _start : null,
        onGestureMove: _editing && widget.onEdit != null ? _move : null,
        onGestureEnd: _editing && widget.onEdit != null ? _finish : null,
        onGestureCancel: _editing && widget.onEdit != null ? _cancel : null,
        selected: selected,
        marquee: _marquee,
        strokeMarks: widget.guitar,
        stringMarks: _showStrings,
        warnNotes: _unassigned,
      ),
    );
    if (widget.onEdit == null) return surface;
    final prefs = LoopPrefs.instance;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Listener(
        onPointerDown: (_) {
          if (!_editing) _focus.requestFocus();
        },
        child: ListenableBuilder(
          listenable: Listenable.merge([
            prefs.gridFocus,
            prefs.gridToolsExpanded,
            prefs.gridVelocityLane,
          ]),
          builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) {
            final laneHeight = (constraints.maxHeight * .2).clamp(38.0, 64.0);
            // Secondary tools get their own row only when asked for and
            // there is room; otherwise one scrollable row (primary first).
            final twoRows =
                _editing &&
                prefs.gridToolsExpanded.value &&
                !prefs.gridFocus.value &&
                constraints.maxHeight >= 200;
            return Column(
              children: [
                if (_editing && !twoRows)
                  _scrollRow(_toolScroll, [
                    ..._toolItems(),
                    const SizedBox(width: 8),
                    ..._inspectorItems(),
                  ])
                else
                  _tools(),
                Expanded(child: surface),
                if (_showVelocity && constraints.maxHeight >= 96)
                  AnimatedBuilder(
                    animation: _view,
                    builder: (context, _) => VelocityLane(
                    height: laneHeight,
                    notes: display,
                    selected: selected,
                    steps: widget.steps,
                    accent: widget.accent,
                    leftInset: PitchGridAxis.gutterWidth(
                      rail: widget.onWindowChanged != null,
                    ),
                    view: _view.view,
                    enabled: widget.enabled,
                    chanceMode: _chanceLane,
                    onModeChanged:
                        (chance) => setState(() {
                          _chanceLane = chance;
                          _resetGesture();
                        }),
                    onStart: _startVelocity,
                    onDelta: _moveVelocity,
                    onEnd: _finish,
                    onCancel: _cancel,
                  ),
                  ),
                if (twoRows) _inspector(),
              ],
            );
          },
        ),
        ),
      ),
    );
  }
}
