// LoopTap — Drums surface (the signature). README §5.
// A center beat-grid (HH/SN/KK × step cells) flanked by symmetric KICK/SNARE/
// HIHAT pads on BOTH left and right for two-thumb play.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/loop_models.dart';
import '../../music/drum_note_edit.dart';
import '../../music/percussion.dart';
import '../../music/pitch_note_edit.dart' show QuantizeGrid;
import '../../state/loop_prefs.dart';
import '../../theme/atoms.dart';
import '../../theme/pad_scale.dart';
import '../../theme/tokens.dart';
import '../sheets/note_tool_sheets.dart';
import 'drum_velocity_lane.dart';
import 'pad_fx.dart';
import 'grid_chrome.dart';

class DrumSpec {
  const DrumSpec(this.kind, this.short, this.color);
  final String kind;

  /// 2-letter lane/pad code (HH, SN, KK…). A glyph, not prose — never translated.
  final String short;
  final Color color;
}

/// Localized display name for a drum kind. The specs below are `const` (no
/// BuildContext), so the spoken name lives in the ARB and is resolved here from
/// an [L10n] the widget hands in.
String drumLabel(L10n l, String kind) => switch (kind) {
  'hihat' => l.ltDrumHihat,
  'snare' => l.ltDrumSnare,
  'shaker' => l.ltDrumShaker,
  'tambourine' => l.ltDrumTambourine,
  'clap' => l.ltDrumClap,
  'cowbell' => l.ltDrumCowbell,
  'maracas' => l.ltDrumMaracas,
  'claves' => l.ltDrumClaves,
  'rimshot' => l.ltDrumRimshot,
  'woodhi' => l.ltDrumWoodblockHi,
  'woodlo' => l.ltDrumWoodblockLo,
  'ride' => l.ltDrumRide,
  'crash' => l.ltDrumCrash,
  'triangle' => l.ltDrumTriangle,
  _ =>
    percussionMidi(kind) != null
        ? 'MIDI ${percussionMidi(kind)}'
        : l.ltDrumKick,
};

/// All known drum/percussion kinds → display spec. Main kit (HH/SN/KK) plus the
/// beat-fill decoration kit (shaker/tambourine/clap). A track renders the subset
/// named by its `drumKinds` (TrackMeta), so the surface UI is identical and only
/// the three components differ.
// MIRROR of kDrumNote (loop_audio.dart): every kind here must have a note there
// (and in midi_export _drumNote). See [drum_mirror_test].
const Map<String, DrumSpec> kDrumSpecs = {
  'hihat': DrumSpec('hihat', 'HH', LT.blue),
  'snare': DrumSpec('snare', 'SN', LT.lime),
  'kick': DrumSpec('kick', 'KK', LT.amber),
  'shaker': DrumSpec('shaker', 'SH', LT.blue),
  'tambourine': DrumSpec('tambourine', 'TB', LT.lime),
  'clap': DrumSpec('clap', 'CL', LT.amber),
  'cowbell': DrumSpec('cowbell', 'CB', LT.amber),
  'maracas': DrumSpec('maracas', 'MA', LT.blue),
  'claves': DrumSpec('claves', 'CV', LT.lime),
  'rimshot': DrumSpec('rimshot', 'RS', LT.pink),
  'woodhi': DrumSpec('woodhi', 'WH', LT.lime),
  'woodlo': DrumSpec('woodlo', 'WL', LT.amber),
  'ride': DrumSpec('ride', 'RD', LT.blue),
  'crash': DrumSpec('crash', 'CR', LT.pink),
  'triangle': DrumSpec('triangle', 'TR', LT.lime),
};

/// Default main kit (top→bottom = HH/SN/KK).
const List<DrumSpec> kDrums = [
  DrumSpec('hihat', 'HH', LT.blue),
  DrumSpec('snare', 'SN', LT.lime),
  DrumSpec('kick', 'KK', LT.amber),
];

/// Build the spec list for a track's drum kinds (order = display order).
List<DrumSpec> drumSpecsFor(List<String>? kinds) =>
    (kinds == null || kinds.isEmpty)
        ? kDrums
        : [
          for (final k in kinds)
            kDrumSpecs[k] ??
                DrumSpec(k, '${percussionMidi(k) ?? "?"}', LT.amber),
        ];

class DrumSurface extends StatelessWidget {
  const DrumSurface({
    super.key,
    required this.notes, // list of (kind, step)
    required this.onHit,
    required this.playStep,
    required this.steps,
    required this.bars,
    this.specs = kDrums,
  });

  /// kind -> set of active steps.
  final Map<String, Set<int>> notes;
  final ValueChanged<String> onHit;
  final double playStep;
  final int steps;
  final int bars;

  /// The three components shown — main kit or a decoration kit (beat fill).
  final List<DrumSpec> specs;

  Widget _column(String side) {
    return Column(
      children: [
        for (var i = 0; i < specs.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          // Press-only feedback: each pad lights only when YOU tap it (PadFx),
          // never its mirror twin — so two-thumb play stays unambiguous and in sync.
          Expanded(
            child: _DrumPad(
              key: ValueKey('$side${specs[i].kind}'),
              spec: specs[i],
              onHit: onHit,
            ),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Two-thumb symmetric pads kept; pad-column : beat-grid : pad-column = 1:2:1.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 1, child: _column('L')),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: _BeatGrid(
            notes: notes,
            playStep: playStep,
            steps: steps,
            bars: bars,
            specs: specs,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(flex: 1, child: _column('R')),
      ],
    );
  }
}

class _DrumPad extends StatelessWidget {
  const _DrumPad({super.key, required this.spec, required this.onHit});
  final DrumSpec spec;
  final ValueChanged<String> onHit;

  @override
  Widget build(BuildContext context) {
    return PadFx(
      accent: spec.color,
      borderRadius: LTRadius.card,
      idle: LT.surface2,
      onDown: () => onHit(spec.kind),
      builder:
          (active) => LayoutBuilder(
            builder: (ctx, c) {
              // Base sizes scale with the pad box (PadScale); FittedBox below still
              // shrinks to fit very short/narrow pads so labels never overflow.
              final sc = PadScale(math.min(c.maxWidth, c.maxHeight));
              return Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Text(
                          spec.short,
                          style: LTType.inter(
                            size: sc.title,
                            weight: FontWeight.w900,
                            color: active ? LT.bg : LT.t1,
                            letterSpacing: 0.5,
                          ),
                        ),
                        SizedBox(width: sc.gap + 4),
                        Text(
                          drumLabel(L10n.of(context), spec.kind),
                          style: LTType.inter(
                            size: sc.sub,
                            weight: FontWeight.w800,
                            color:
                                active
                                    ? LT.bg.withValues(alpha: 0.67)
                                    : spec.color,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
    );
  }
}

class _BeatGrid extends StatelessWidget {
  const _BeatGrid({
    required this.notes,
    required this.playStep,
    required this.steps,
    required this.bars,
    this.specs = kDrums,
  });
  final Map<String, Set<int>> notes;
  final double playStep;
  final int steps;
  final int bars;
  final List<DrumSpec> specs;

  @override
  Widget build(BuildContext context) {
    final cur = playStep.floor() % steps;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: LT.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LT.border),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              LtLabel(L10n.of(context).ltDrumBeatGrid),
              LtLabel(L10n.of(context).ltDrumGridMeta(bars), color: LT.t3),
            ],
          ),
          const SizedBox(height: 6),
          for (final d in specs)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(
                        d.short,
                        style: LTType.inter(
                          size: 9,
                          weight: FontWeight.w800,
                          color: d.color,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          for (var s = 0; s < steps; s++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 1,
                                ),
                                child: _Cell(
                                  on: notes[d.kind]?.contains(s) ?? false,
                                  beat: s % 4 == 0,
                                  current: s == cur,
                                  color: d.color,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.on,
    required this.beat,
    required this.current,
    required this.color,
  });
  final bool on;
  final bool beat;
  final bool current;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: on ? color : (beat ? LT.surface2 : LT.surface),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color:
              current
                  ? LT.t1.withValues(alpha: 0.33)
                  : (on ? color : LT.border),
          width: current ? 1.5 : 1,
        ),
        boxShadow:
            on
                ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.67),
                    blurRadius: 8,
                  ),
                ]
                : null,
      ),
    );
  }
}

/// Drums Grid mode (README §5 variant): the beat grid ONLY, full-area and
/// editable. Draw mode (default): tap a cell to toggle a hit at (kind, step).
/// Select mode (drums-001): tap / Shift-tap / drag a box to select hits, then
/// move, delete, quantize, humanize, mute and edit velocity / chance in the
/// lane and inspector below. Each edit reaches [onEdit] once (one undo step).
class DrumGrid extends StatefulWidget {
  const DrumGrid({
    super.key,
    required this.notes,
    required this.onToggle,
    required this.playStep,
    required this.steps,
    required this.bars,
    this.specs = kDrums,
    this.onEdit,
    this.enabled = true,
    this.initialSelectMode = false,
    this.chrome,
  });

  /// ui-001 stage 4 (desktop edit view): Draw / Select go to the editor's
  /// tool row and the selection inspector to the Notes tab (this grid's own
  /// items); the grid then shows neither itself. Null = phone layout.
  final GridChrome? chrome;
  final List<DrumNote> notes;
  final void Function(String kind, int step) onToggle;

  /// Parent validates the source snapshot and records one undo transaction.
  final bool Function(List<DrumNote> before, List<DrumNote> after)? onEdit;
  final double playStep;
  final int steps;
  final int bars;
  final List<DrumSpec> specs;
  final bool enabled, initialSelectMode;

  @override
  State<DrumGrid> createState() => _DrumGridState();
}

class _DrumGridState extends State<DrumGrid> {
  final _focus = FocusNode(debugLabel: 'Drum grid editor');
  final _inspectorScroll = ScrollController();
  late bool _select = widget.initialSelectMode && widget.onEdit != null;
  Set<DrumNote> _selected = {}, _boxBase = {};
  late List<DrumNote> _known;
  List<DrumNote>? _base, _preview;
  Offset? _origin;
  Rect? _marquee;
  DrumNote? _velocityAnchor;
  int? _velocityDraft, _deviationDraft;
  double? _chanceDraft;
  String? _focusKind;
  bool _chanceLane = false;
  Size _area = Size.zero;
  double _rowHeight = 1;

  bool get _ko => Localizations.localeOf(context).languageCode == 'ko';
  bool get _editable => widget.enabled && widget.onEdit != null;
  List<DrumNote> get _picked =>
      widget.notes.where(_selected.contains).toList();
  bool get _canEdit => _editable && _picked.isNotEmpty;

  /// Whole-track commands (quantize, humanize) act on the selection, or on
  /// every hit of the track when nothing is selected — like the piano roll.
  Set<DrumNote> get _scope =>
      _selected.isEmpty ? widget.notes.toSet() : _selected;
  bool get _canScope => _editable && widget.notes.any(_scope.contains);

  @override
  void initState() {
    super.initState();
    _known = List.of(widget.notes);
    widget.chrome?.attach(_chromeContent);
  }

  late final GridChromeContent _chromeContent = GridChromeContent(
    tools: _desktopToolItems,
    notes: _notesTab,
    selection: () => _selected,
    onKey: (event) => _key(_focus, event),
  );

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    widget.chrome?.changed();
  }

  @override
  void dispose() {
    widget.chrome?.detach(_chromeContent);
    _inspectorScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(DrumGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(_known, widget.notes) ||
        oldWidget.steps != widget.steps ||
        !widget.enabled) {
      _resetGesture();
      _selected.removeWhere((n) => !widget.notes.contains(n));
    }
    _known = List.of(widget.notes);
    if (oldWidget.chrome != widget.chrome) {
      oldWidget.chrome?.detach(_chromeContent);
      widget.chrome?.attach(_chromeContent);
    }
    widget.chrome?.changed(); // new hits / pruned selection outside too
  }

  void _resetGesture() {
    _base = null;
    _preview = null;
    _origin = null;
    _marquee = null;
    _velocityAnchor = null;
    _velocityDraft = null;
    _chanceDraft = null;
    _deviationDraft = null;
  }

  void _cancel() => setState(_resetGesture);

  void _setSelectMode(bool on) => setState(() {
    _select = on && widget.onEdit != null;
    _resetGesture();
    if (!_select) _selected.clear();
  });

  void _commit(
    List<DrumNote> before,
    List<DrumNote> after, {
    Set<DrumNote>? selection,
  }) {
    if (identical(before, after) || listEquals(before, after)) {
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
  }

  void _apply(List<DrumNote> Function(List<DrumNote> notes) edit) {
    final before = List<DrumNote>.of(widget.notes);
    _commit(before, edit(before));
  }

  // ── pointer: row/position mapping ─────────────────────────────────────
  int _rowAt(double y) =>
      (y / _rowHeight).floor().clamp(0, widget.specs.length - 1);
  double _posAt(double x) =>
      (x / _area.width * widget.steps).clamp(0, widget.steps - 1e-6);
  Rect _hitRect(DrumNote n, int row) {
    final unit = _area.width / widget.steps;
    return Rect.fromLTWH(n.startSteps * unit, row * _rowHeight, unit, _rowHeight);
  }

  DrumNote? _hitAt(Offset p) {
    final row = _rowAt(p.dy);
    final kind = widget.specs[row].kind;
    for (final n in widget.notes.reversed) {
      if (n.kind == kind && _hitRect(n, row).contains(p)) return n;
    }
    return null;
  }

  bool get _additive =>
      HardwareKeyboard.instance.isShiftPressed ||
      HardwareKeyboard.instance.isControlPressed ||
      HardwareKeyboard.instance.isMetaPressed;

  void _tap(Offset p) {
    if (!widget.enabled) return;
    _focus.requestFocus();
    if (!_select) {
      widget.onToggle(widget.specs[_rowAt(p.dy)].kind, _posAt(p.dx).floor());
      return;
    }
    final hit = _hitAt(p);
    setState(() {
      _resetGesture();
      if (hit == null) {
        if (!_additive) _selected.clear();
        return;
      }
      _focusKind = hit.kind;
      if (_additive) {
        if (!_selected.remove(hit)) _selected.add(hit);
      } else {
        _selected = {hit};
      }
    });
  }

  void _boxStart(DragStartDetails d) {
    if (!_select || !widget.enabled) return;
    _focus.requestFocus();
    setState(() {
      _resetGesture();
      _origin = d.localPosition;
      _boxBase = _additive ? Set.of(_selected) : {};
    });
  }

  void _boxMove(DragUpdateDetails d) {
    final origin = _origin;
    if (origin == null) return;
    final rect = Rect.fromPoints(origin, d.localPosition);
    setState(() {
      _marquee = rect;
      _selected = {
        ..._boxBase,
        for (var r = 0; r < widget.specs.length; r++)
          for (final n in widget.notes)
            if (n.kind == widget.specs[r].kind &&
                rect.overlaps(_hitRect(n, r)))
              n,
      };
    });
  }

  void _boxEnd() => setState(() {
    _origin = null;
    _marquee = null;
  });

  // ── commands ──────────────────────────────────────────────────────────
  void _move(double amount) => _apply(
    (n) => moveDrumNotes(n, _selected, deltaSteps: amount, steps: widget.steps),
  );
  void _shiftVelocity(int delta) =>
      _apply((n) => shiftDrumVelocities(n, _selected, delta));
  void _delete() {
    final before = List<DrumNote>.of(widget.notes);
    _commit(before, deleteDrumNotes(before, _selected), selection: {});
  }

  bool get _allMuted => _picked.isNotEmpty && _picked.every((n) => n.muted);
  void _toggleMute() =>
      _apply((n) => setDrumNotesMuted(n, _selected, !_allMuted));

  void _quantize() {
    final prefs = LoopPrefs.instance;
    final before = List<DrumNote>.of(widget.notes);
    final after = quantizeDrumNotes(
      before,
      _scope,
      grid: QuantizeGrid.byName(prefs.quantizeGrid.value).steps,
      strength: prefs.quantizeStrength.value / 100,
      steps: widget.steps,
    );
    if (identical(after, before)) return;
    final stacked = stackedDrumNoteCount(after) - stackedDrumNoteCount(before);
    _commit(before, after);
    if (stacked > 0) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            _ko
                ? '같은 줄·같은 위치 히트 $stacked개가 겹쳤습니다 (합치지 않음).'
                : '$stacked hits now share a row and position (not merged).',
          ),
        ),
      );
    }
  }

  Future<void> _quantizeSettings() async {
    final apply = await showQuantizeSheet(
      context,
      canApply: _canScope,
      showEnds: false,
    );
    if (!mounted) return;
    setState(() {});
    if (apply) _quantize();
    _focus.requestFocus();
  }

  void _humanize() {
    final prefs = LoopPrefs.instance;
    _apply(
      (n) => humanizeDrumNotes(
        n,
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

  // ── velocity lane ─────────────────────────────────────────────────────
  bool _startVelocity(DrumNote note) {
    if (!_editable) return false;
    _focus.requestFocus();
    setState(() {
      _resetGesture();
      if (!_selected.contains(note)) _selected = {note};
      _base = List.of(widget.notes);
      _velocityAnchor = note;
    });
    return true;
  }

  void _moveVelocity(int delta) {
    final base = _base, anchor = _velocityAnchor;
    if (base == null || anchor == null) return;
    setState(() {
      if (_chanceLane) {
        _preview = shiftDrumChance(base, _selected, delta / 127);
        _chanceDraft = (anchor.chance + delta / 127).clamp(0.0, 1.0);
      } else {
        _preview = shiftDrumVelocities(base, _selected, delta);
        _velocityDraft = ((anchor.velocity ?? 100) + delta).clamp(1, 127);
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

  // ── keyboard ──────────────────────────────────────────────────────────
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final hw = HardwareKeyboard.instance;
    final command = hw.isControlPressed || hw.isMetaPressed;
    if (hw.isAltPressed ||
        !_editable ||
        event is KeyUpEvent ||
        ModalRoute.of(context)?.isCurrent == false) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    // Ctrl/Cmd+B: draw ⇄ select. Plain letters on the home row belong to
    // the desktop drum/piano keys, so the toggle needs a modifier.
    if (command && key == LogicalKeyboardKey.keyB) {
      if (event is KeyDownEvent) _setSelectMode(!_select);
      return KeyEventResult.handled;
    }
    if (!_select) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _resetGesture();
        _selected.clear();
      });
      return KeyEventResult.handled;
    }
    if (_base != null) return KeyEventResult.ignored;
    final up = key == LogicalKeyboardKey.arrowUp;
    final vertical = up || key == LogicalKeyboardKey.arrowDown;
    if (command && key == LogicalKeyboardKey.keyA) {
      setState(() => _selected = widget.notes.toSet());
    } else if (command && vertical && _chanceLane && _canEdit) {
      _apply((n) => shiftDrumChance(n, _selected, up ? .1 : -.1));
    } else if (command && key == LogicalKeyboardKey.keyU && _canScope) {
      if (event is KeyDownEvent) {
        if (hw.isShiftPressed) {
          _quantizeSettings();
        } else {
          _quantize();
        }
      }
    } else if (command &&
        key == LogicalKeyboardKey.keyH &&
        hw.isShiftPressed &&
        _canScope) {
      if (event is KeyDownEvent) _humanize();
    } else if (command) {
      return KeyEventResult.ignored;
    } else if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        _canEdit) {
      if (event is KeyDownEvent) _delete();
    } else if (key == LogicalKeyboardKey.keyM &&
        !hw.isShiftPressed &&
        _canEdit) {
      if (event is KeyDownEvent) _toggleMute();
    } else if ((key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight) &&
        _canEdit) {
      final fine = hw.isShiftPressed ? .25 : 1.0;
      _move(key == LogicalKeyboardKey.arrowLeft ? -fine : fine);
    } else if (vertical && _canEdit) {
      final amount = hw.isShiftPressed ? 20 : 5;
      _shiftVelocity(up ? amount : -amount);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  // ── UI ────────────────────────────────────────────────────────────────
  Widget _button(
    String key,
    String label,
    VoidCallback? action, {
    bool active = false,
    VoidCallback? onLongPress,
    Color? color,
  }) {
    final desktop = widget.chrome != null; // ui-001 stage 4: 30 px / 12 px
    return TextButton(
      key: ValueKey(key),
      onPressed: widget.enabled ? action : null,
      onLongPress: widget.enabled ? onLongPress : null,
      style: TextButton.styleFrom(
        minimumSize: desktop ? const Size(30, 30) : const Size(32, 32),
        // desktop: really 30 px tall (no padded 48 px tap target)
        maximumSize: desktop ? const Size(double.infinity, 30) : null,
        tapTargetSize: desktop ? MaterialTapTargetSize.shrinkWrap : null,
        // and no compact desktop density shrinking it below 30
        visualDensity: desktop ? VisualDensity.standard : null,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        foregroundColor: active ? LT.bg : (color ?? LT.t2),
        backgroundColor: active ? LT.lime : null,
        textStyle: TextStyle(fontSize: desktop ? 12 : 11),
      ),
      child: Text(label),
    );
  }

  Widget _drawButton() => _button(
    'drum-draw-mode',
    _ko ? '그리기' : 'Draw',
    () => _setSelectMode(false),
    active: !_select,
  );

  Widget _selectButton() => _button(
    'drum-select-mode',
    _ko ? '선택' : 'Select',
    () => _setSelectMode(true),
    active: _select,
  );

  // ── ui-001 stage 4: the desktop tool row and Notes tab (same widgets) ──
  List<Widget> _desktopToolItems() =>
      widget.onEdit == null ? const [] : [_drawButton(), _selectButton()];

  /// Notes tab (desktop inspector) for the select mode's hits: title + kinds
  /// · position ← → · velocity / chance / variation · quantize and humanize
  /// rows (chevron = the existing settings sheet) · a fixed footer (mute ·
  /// delete). The widgets are [_inspectorItems]' own (same keys, callbacks).
  Widget _notesTab() {
    final l = L10n.of(context);
    final items = _inspectorItems();
    // a slider's key sits on the Slider inside its fixed-width SizedBox
    bool has(Widget w, String key) =>
        w.key == ValueKey(key) || (w is SizedBox && w.child?.key == ValueKey(key));
    Widget k(String key) => items.firstWhere((w) => has(w, key));
    Widget labelOf(String key) => items[items.indexWhere((w) => has(w, key)) - 1];
    Widget slider(String key) => Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [labelOf(key), k(key)]),
    );
    Widget sheetRow(String key, String moreKey, VoidCallback onMore) => Container(
      height: 34,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.only(left: 2),
      decoration: BoxDecoration(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(LTRadius.chip),
        border: Border.all(color: LT.border),
      ),
      child: Row(
        children: [
          Expanded(child: Align(alignment: Alignment.centerLeft, child: k(key))),
          Tooltip(
            message: l.inspectorSettings,
            child: InkResponse(
              key: ValueKey(moreKey),
              radius: 16,
              onTap: widget.enabled ? onMore : null,
              child: const SizedBox(
                width: 32,
                height: 32,
                child: Icon(Icons.chevron_right, size: 16, color: LT.t2),
              ),
            ),
          ),
        ],
      ),
    );
    final kinds = {for (final n in _picked) drumLabel(l, n.kind)};
    return Column(
      key: const ValueKey('drum-notes-tab'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.inspectorSelectedNotes(_selected.length),
                  key: const ValueKey('drum-notes-title'),
                  style: LTType.inter(size: 13, weight: FontWeight.w800, color: LT.t1),
                ),
                if (kinds.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(kinds.join(' · '), style: LTType.mono(size: 11, color: LT.t2)),
                ],
                if (!_select) ...[
                  const SizedBox(height: 8),
                  Text(l.inspectorDrumSelectHint, style: LTType.inter(size: 11, color: LT.t3)),
                ],
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.inspectorPosition, style: LTType.inter(size: 11, weight: FontWeight.w700, color: LT.t3)),
                      Wrap(spacing: 4, children: [k('drum-time-left'), k('drum-time-right')]),
                    ],
                  ),
                ),
                slider('drum-velocity'),
                slider('drum-chance'),
                slider('drum-velocity-deviation'),
                const SizedBox(height: 8),
                sheetRow('drum-quantize', 'drum-quantize-settings', _quantizeSettings),
                sheetRow('drum-humanize', 'drum-humanize-settings', _humanizeSettings),
              ],
            ),
          ),
        ),
        Container(
          key: const ValueKey('drum-notes-footer'),
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: LT.border)),
          ),
          child: Row(
            children: [
              for (final key in const ['drum-mute', 'drum-delete'])
                Expanded(child: Center(child: FittedBox(fit: BoxFit.scaleDown, child: k(key)))),
            ],
          ),
        ),
      ],
    );
  }

  Widget _slider(
    String key,
    double min,
    double max,
    double value,
    void Function(double v) preview,
  ) => SizedBox(
    width: 110,
    child: Slider(
      key: ValueKey(key),
      min: min,
      max: max,
      divisions: (max - min).round(),
      value: value.clamp(min, max),
      onChangeStart: !_canEdit ? null : (_) => _base = List.of(widget.notes),
      onChanged: !_canEdit ? null : (v) => setState(() => preview(v)),
      onChangeEnd: !_canEdit ? null : (_) => _finish(),
    ),
  );

  List<Widget> _inspectorItems() {
    final picked = _picked;
    double mean(num Function(DrumNote n) f, num empty) =>
        picked.isEmpty
            ? empty.toDouble()
            : picked.map(f).reduce((a, b) => a + b) / picked.length;
    final velocity =
        _velocityDraft?.toDouble() ?? mean((n) => n.velocity ?? 100, 100);
    final chance = _chanceDraft ?? mean((n) => n.chance, 1);
    final deviation =
        _deviationDraft ?? mean((n) => n.velocityDeviation, 0).round();
    final quantizeLabel =
        QuantizeGrid.byName(LoopPrefs.instance.quantizeGrid.value).label;
    return [
      _button('drum-time-left', '←', _canEdit ? () => _move(-1) : null),
      _button('drum-time-right', '→', _canEdit ? () => _move(1) : null),
      Text(
        '${_ko ? '세기' : 'Velocity'} ${velocity.round()}',
        style: const TextStyle(fontSize: 11, color: LT.t2),
      ),
      _slider('drum-velocity', 1, 127, velocity, (v) {
        _velocityDraft = v.round();
        _preview = setDrumVelocity(_base ?? widget.notes, _selected, v.round());
      }),
      _button(
        'drum-quantize',
        '${_ko ? '퀀타이즈' : 'Quantize'} $quantizeLabel',
        _canScope ? _quantize : null,
        onLongPress: _quantizeSettings,
      ),
      _button('drum-quantize-settings', '⚙', _quantizeSettings),
      _button(
        'drum-humanize',
        _ko ? '휴머나이즈' : 'Humanize',
        _canScope ? _humanize : null,
        onLongPress: _humanizeSettings,
      ),
      _button('drum-humanize-settings', '⚙', _humanizeSettings),
      Text(
        '${_ko ? '확률' : 'Chance'} ${(chance * 100).round()}%',
        style: const TextStyle(fontSize: 11, color: LT.t2),
      ),
      _slider('drum-chance', 0, 100, chance * 100, (v) {
        _chanceDraft = v.round() / 100;
        _preview = setDrumChance(
          _base ?? widget.notes,
          _selected,
          v.round() / 100,
        );
      }),
      Text(
        '${_ko ? '세기 변화' : 'Variation'} '
        '${deviation > 0 ? '+' : ''}$deviation',
        style: const TextStyle(fontSize: 11, color: LT.t2),
      ),
      _slider('drum-velocity-deviation', -64, 64, deviation.toDouble(), (v) {
        _deviationDraft = v.round();
        _preview = setDrumVelocityDeviation(
          _base ?? widget.notes,
          _selected,
          v.round(),
        );
      }),
      _button(
        'drum-delete',
        _ko ? '삭제' : 'Delete',
        _canEdit ? _delete : null,
        // the desktop footer marks delete with the danger colour
        color: widget.chrome != null ? LT.danger : null,
      ),
      _button(
        'drum-mute',
        _allMuted ? (_ko ? '소리 켜기' : 'Unmute') : (_ko ? '소리 끄기' : 'Mute'),
        _canEdit ? _toggleMute : null,
      ),
    ];
  }

  String get _laneKind {
    final kinds = widget.specs.map((d) => d.kind).toList();
    if (_focusKind != null && kinds.contains(_focusKind)) return _focusKind!;
    for (final n in widget.notes) {
      if (_selected.contains(n) && kinds.contains(n.kind)) return n.kind;
    }
    return kinds.first;
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.playStep.floor() % widget.steps;
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
    final editable = widget.onEdit != null;
    final body = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LT.bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: LT.border),
      ),
      child: LayoutBuilder(
        builder: (context, outer) {
          final roomy = outer.maxHeight >= 220;
          final laneKind = _laneKind;
          final laneSpec = widget.specs.firstWhere((d) => d.kind == laneKind);
          return Column(
            children: [
              Row(
                children: [
                  LtLabel(L10n.of(context).ltDrumBeatGrid),
                  const Spacer(),
                  // ui-001 stage 4: on desktop Draw / Select are in the
                  // editor's tool row
                  if (editable && widget.chrome == null) ...[
                    _drawButton(),
                    _selectButton(),
                    const SizedBox(width: 8),
                  ],
                  LtLabel(
                    _select && _selected.isNotEmpty
                        ? (_ko
                            ? '${_selected.length}개 선택'
                            : '${_selected.length} selected')
                        : L10n.of(context).ltDrumGridMetaEditable(widget.bars),
                    color: LT.t3,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(child: _lanes(display, selected, cur)),
              if (editable && _select && roomy)
                DrumVelocityLane(
                  height: 64,
                  notes: [
                    for (final n in display)
                      if (n.kind == laneKind) n,
                  ],
                  selected: selected,
                  steps: widget.steps,
                  accent: laneSpec.color,
                  leftInset: 52,
                  rowLabel: drumLabel(L10n.of(context), laneKind),
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
              if (editable && _select && widget.chrome == null)
                SizedBox(
                  height: 40,
                  child: Scrollbar(
                    controller: _inspectorScroll,
                    thumbVisibility: true,
                    scrollbarOrientation: ScrollbarOrientation.bottom,
                    child: SingleChildScrollView(
                      controller: _inspectorScroll,
                      scrollDirection: Axis.horizontal,
                      child: Row(children: _inspectorItems()),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
    if (!editable) return body;
    return Focus(
      focusNode: _focus,
      onKeyEvent: _key,
      child: Listener(
        onPointerDown: (_) => _focus.requestFocus(),
        child: body,
      ),
    );
  }

  Widget _lanes(List<DrumNote> display, Set<DrumNote> selected, int cur) =>
      LayoutBuilder(
        builder: (context, c) {
          // Rows fill the height when they fit (3-lane main drums); once there
          // are too many lanes to stay legible (6-lane Beat Fill), they take a
          // min height and the grid scrolls instead of squishing the labels.
          final n = widget.specs.length;
          final minRow = n <= 3 ? 24.0 : 40.0;
          final fits = n * minRow <= c.maxHeight;
          final rowHeight = fits ? c.maxHeight / n : minRow;
          final grid = SizedBox(
            height: rowHeight * n,
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  child: Column(
                    children: [
                      for (final d in widget.specs)
                        SizedBox(height: rowHeight, child: _label(d)),
                    ],
                  ),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, area) {
                      _area = Size(area.maxWidth, rowHeight * n);
                      _rowHeight = rowHeight;
                      return GestureDetector(
                        key: const ValueKey('drum-grid-lanes'),
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (d) => _tap(d.localPosition),
                        onPanStart: _select ? _boxStart : null,
                        onPanUpdate: _select ? _boxMove : null,
                        onPanEnd: _select ? (_) => _boxEnd() : null,
                        onPanCancel: _select ? _boxEnd : null,
                        child: CustomPaint(
                          size: Size(area.maxWidth, rowHeight * n),
                          painter: _DrumGridPainter(
                            specs: widget.specs,
                            notes: List.of(display),
                            selected: Set.of(selected),
                            steps: widget.steps,
                            current: cur,
                            marquee: _marquee,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          );
          if (fits) return grid;
          return SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: grid,
          );
        },
      );

  // Row label; in select mode a tap focuses that row's velocity lane.
  Widget _label(DrumSpec d) => GestureDetector(
    key: ValueKey('drum-row-${d.kind}'),
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _focusKind = d.kind),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, c) {
          final size = (c.maxHeight * 0.7).clamp(10.0, 18.0);
          final focused = _select && d.kind == _laneKind;
          return Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                focused ? '${d.short} •' : d.short,
                style: LTType.inter(
                  size: size,
                  weight: FontWeight.w900,
                  color: d.color,
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
}

/// Cells + hits. Strength = fill opacity, micro timing = position inside the
/// cell, chance < 100% = faded with a % mark, muted = hollow outline,
/// selected = bright border.
class _DrumGridPainter extends CustomPainter {
  _DrumGridPainter({
    required this.specs,
    required this.notes,
    required this.selected,
    required this.steps,
    required this.current,
    required this.marquee,
  });
  final List<DrumSpec> specs;
  final List<DrumNote> notes;
  final Set<DrumNote> selected;
  final int steps, current;
  final Rect? marquee;

  @override
  void paint(Canvas canvas, Size size) {
    if (specs.isEmpty || steps <= 0) return;
    final unit = size.width / steps;
    final rowH = size.height / specs.length;
    for (var r = 0; r < specs.length; r++) {
      final top = r * rowH;
      for (var s = 0; s < steps; s++) {
        final cell = RRect.fromRectAndRadius(
          Rect.fromLTWH(s * unit + 2, top + 4, unit - 4, rowH - 8),
          const Radius.circular(3),
        );
        canvas.drawRRect(
          cell,
          Paint()..color = s % 4 == 0 ? LT.surface2 : LT.surface,
        );
        canvas.drawRRect(
          cell,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = s == current ? 1.5 : 1
            ..color = s == current ? LT.t1.withValues(alpha: 0.33) : LT.border,
        );
      }
      final color = specs[r].color;
      for (final n in notes) {
        if (n.kind != specs[r].kind) continue;
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(
            n.startSteps * unit + 2,
            top + 4,
            unit - 4,
            rowH - 8,
          ),
          const Radius.circular(3),
        );
        final strength = (n.velocity ?? 100) / 127;
        var alpha = .35 + .65 * strength;
        if (n.chance < 1) alpha *= .5;
        if (n.muted) {
          canvas.drawRRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5
              ..color = color.withValues(alpha: alpha),
          );
        } else {
          canvas.drawRRect(rect, Paint()..color = color.withValues(alpha: alpha));
        }
        if (selected.contains(n)) {
          canvas.drawRRect(
            rect.inflate(1),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = LT.t1,
          );
        }
        if (n.chance < 1 && unit >= 18 && rowH >= 18) {
          final tp = TextPainter(
            text: TextSpan(
              text: '${(n.chance * 100).round()}%',
              style: const TextStyle(fontSize: 8, color: LT.t1),
            ),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: unit);
          tp.paint(
            canvas,
            Offset(
              n.startSteps * unit + (unit - tp.width) / 2,
              top + (rowH - tp.height) / 2,
            ),
          );
        }
      }
    }
    final box = marquee;
    if (box != null) {
      canvas.drawRect(box, Paint()..color = LT.t1.withValues(alpha: .08));
      canvas.drawRect(
        box,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = LT.t1.withValues(alpha: .5),
      );
    }
  }

  @override
  bool shouldRepaint(_DrumGridPainter old) =>
      !listEquals(old.notes, notes) ||
      !setEquals(old.selected, selected) ||
      old.steps != steps ||
      old.current != current ||
      old.marquee != marquee ||
      !listEquals(old.specs, specs);
}
