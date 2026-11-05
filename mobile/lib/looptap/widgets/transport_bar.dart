// LoopTap — transport bar (README §4.6, prototype/timeline.jsx TransportBar).
// left: metronome · count-in · loop(always on) · BPM stepper
// center: stop · play(lime) · record(red ring)
// right: SWING slider · 2|4 bars · clear track
import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';
import 'sheets/lt_modal.dart';

class TransportBar extends StatelessWidget {
  const TransportBar({
    super.key,
    required this.playing,
    required this.recording,
    required this.onPlay,
    required this.onStop,
    required this.onRec,
    required this.bpm,
    required this.onBpm,
    required this.metro,
    required this.onMetro,
    required this.countIn,
    required this.onCountIn,
    required this.onClear,
    required this.swing,
    required this.onSwing,
    required this.bars,
    required this.onBars,
    this.showRecord = true,
    this.rangeLoop = false,
    this.onLoop,
  });

  final bool rangeLoop;
  final VoidCallback? onLoop;
  final bool playing;
  final bool recording;
  final VoidCallback onPlay;
  final VoidCallback onStop;
  final VoidCallback onRec;
  final int bpm;
  final ValueChanged<int> onBpm;
  final bool metro;
  final ValueChanged<bool> onMetro;
  final bool countIn;
  final ValueChanged<bool> onCountIn;
  final VoidCallback onClear;
  final double swing; // 0..0.6
  final ValueChanged<double> onSwing;
  final int bars; // 2 | 4
  final ValueChanged<int> onBars;
  final bool
  showRecord; // hidden on the vocal track (it has its own record ring)

  Widget _controls(BuildContext context) {
    final l = L10n.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconBtn(
          icon: LtIcons.stop,
          size: 48,
          tooltip: l.pendingStop,
          onTap: onStop,
        ),
        const SizedBox(width: 8),
        MergeSemantics(
          key: const ValueKey('transport-play'),
          child: IconButton.filled(
            tooltip: playing ? l.ltTransportPause : l.ltTransportPlay,
            onPressed: onPlay,
            style: IconButton.styleFrom(
              backgroundColor: LT.lime,
              foregroundColor: LT.bg,
              minimumSize: const Size(48, 48),
              visualDensity: VisualDensity.standard,
            ),
            icon: Semantics(
              label: playing ? l.ltTransportPause : l.ltTransportPlay,
              child: Ms(
                playing ? LtIcons.pause : LtIcons.playArrow,
                color: LT.bg,
                size: 25,
              ),
            ),
          ),
        ),
        if (showRecord) ...[
          const SizedBox(width: 8),
          MergeSemantics(
            key: const ValueKey('transport-record'),
            child: Semantics(
              toggled: recording,
              child: IconButton(
                tooltip:
                    recording
                        ? l.ltTransportRecordStop
                        : l.ltTransportRecordStart,
                onPressed: onRec,
                style: IconButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  visualDensity: VisualDensity.standard,
                  backgroundColor: recording ? LT.danger : LT.surface2,
                  side: const BorderSide(color: LT.danger, width: 2),
                ),
                icon: Icon(
                  recording ? Icons.stop_rounded : Icons.fiber_manual_record,
                  semanticLabel:
                      recording
                          ? l.ltTransportRecordStop
                          : l.ltTransportRecordStart,
                  color: recording ? LT.t1 : LT.danger,
                  size: 22,
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _settings(BuildContext context) async {
    var currentBpm = bpm;
    var currentMetro = metro;
    var currentCount = countIn;
    var currentSwing = swing;
    var currentBars = bars;
    await showLtModal(
      context,
      width: 440,
      child: StatefulBuilder(
        builder: (context, update) {
          final l = L10n.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.ltTransportSettings,
                style: LTType.inter(size: 18, weight: FontWeight.w800),
              ),
              const SizedBox(height: 12),
              Center(
                child: BpmStepper(
                  bpm: currentBpm,
                  onBpm: (v) {
                    update(() => currentBpm = v);
                    onBpm(v);
                  },
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.metronomeTitle),
                value: currentMetro,
                onChanged: (v) {
                  update(() => currentMetro = v);
                  onMetro(v);
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.ltTransportCountIn),
                value: currentCount,
                onChanged: (v) {
                  update(() => currentCount = v);
                  onCountIn(v);
                },
              ),
              ListTile(
                key: const ValueKey('transport-loop-options'),
                contentPadding: EdgeInsets.zero,
                title: Text(l.ltTransportLoop),
                selected: rangeLoop,
                trailing: const Icon(Icons.chevron_right),
                onTap:
                    onLoop == null
                        ? null
                        : () {
                          Navigator.of(context).pop();
                          onLoop!();
                        },
              ),
              Text('${l.ltTransportSwing} · ${(currentSwing * 100).round()}%'),
              Semantics(
                label: l.ltTransportSwing,
                child: Slider(
                  value: (currentSwing * 100).clamp(0, 60),
                  min: 0,
                  max: 60,
                  label: '${(currentSwing * 100).round()}%',
                  semanticFormatterCallback: (v) => '${v.round()}%',
                  onChanged: (v) {
                    update(() => currentSwing = v / 100);
                    onSwing(v / 100);
                  },
                ),
              ),
              Text(l.ltTransportBars),
              Wrap(
                spacing: 8,
                children: [
                  for (final value in const [1, 2, 4, 8, 16])
                    ChoiceChip(
                      label: Text('$value'),
                      selected: currentBars == value,
                      onSelected: (_) {
                        update(() => currentBars = value);
                        onBars(value);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  onClear();
                },
                child: Text(l.ltTransportClearTrack),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(l.close),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // Keep primary actions at their actual touch size. Secondary settings get
        // a named sheet instead of shrinking controls to fit a narrow landscape.
        if (constraints.maxWidth < 1000 ||
            MediaQuery.textScalerOf(context).scale(14) > 19) {
          return Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: l.ltTransportSettings,
                    child: TextButton.icon(
                      key: const ValueKey('transport-settings'),
                      onPressed: () => _settings(context),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      icon: const Icon(Icons.tune, size: 20),
                      label: Semantics(label: l.ltTransportSettings, child: Text('$bpm BPM')),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _controls(context),
            ],
          );
        }
        return Row(
          children: [
            Expanded(
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconBtn(
                    icon: LtIcons.straighten,
                    active: metro,
                    toggled: metro,
                    tooltip: l.metronomeTitle,
                    onTap: () => onMetro(!metro),
                  ),
                  IconBtn(
                    icon: LtIcons.timer,
                    active: countIn,
                    toggled: countIn,
                    tooltip: l.ltTransportCountIn,
                    onTap: () => onCountIn(!countIn),
                  ),
                  IconBtn(
                    icon: LtIcons.repeat,
                    active: rangeLoop,
                    toggled: rangeLoop,
                    tooltip: l.ltTransportLoop,
                    onTap: onLoop,
                  ),
                  _BpmStepper(bpm: bpm, onBpm: onBpm),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _controls(context),
            const SizedBox(width: 12),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${l.ltTransportSwing} ${(swing * 100).round()}%',
                      style: LTType.inter(size: 12),
                    ),
                    SizedBox(
                      width: 110,
                      child: Semantics(
                        label: l.ltTransportSwing,
                        child: Slider(
                          value: (swing * 100).clamp(0, 60),
                          min: 0,
                          max: 60,
                          semanticFormatterCallback: (v) => '${v.round()}%',
                          onChanged: (v) => onSwing(v / 100),
                        ),
                      ),
                    ),
                    _BarsToggle(bars: bars, onBars: onBars),
                    IconBtn(
                      icon: LtIcons.backspace,
                      tooltip: l.ltTransportClearTrack,
                      onTap: onClear,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

const int _kBpmMin = 40, _kBpmMax = 220;

class _BpmStepper extends StatefulWidget {
  const _BpmStepper({required this.bpm, required this.onBpm});
  final int bpm;
  final ValueChanged<int> onBpm;

  @override
  State<_BpmStepper> createState() => _BpmStepperState();
}

class _BpmStepperState extends State<_BpmStepper> {
  // Local mirror so a fast hold-repeat steps off the freshest value instead of
  // the (next-frame-stale) widget.bpm prop.
  late int _bpm = widget.bpm;

  @override
  void didUpdateWidget(_BpmStepper old) {
    super.didUpdateWidget(old);
    // resync on an external change (loaded song, etc.) that isn't our own step
    if (widget.bpm != old.bpm && widget.bpm != _bpm) _bpm = widget.bpm;
  }

  void _step(int delta) {
    final next = (_bpm + delta).clamp(_kBpmMin, _kBpmMax);
    if (next == _bpm) return;
    setState(() => _bpm = next);
    widget.onBpm(next);
  }

  Future<void> _editDirect() async {
    final v = await _promptBpm(context, _bpm);
    if (!mounted) return; // stepper torn down while the dialog was up
    if (v != null && v != _bpm) {
      setState(() => _bpm = v);
      widget.onBpm(v);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(LTRadius.pill),
        border: Border.all(color: LT.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepBtn('−', (m) => _step(-m)),
          Flexible(
            child: TextButton(
              onPressed: _editDirect,
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(
                '$_bpm BPM',
                textAlign: TextAlign.center,
                style: LTType.mono(
                  size: 15,
                  weight: FontWeight.w700,
                  color: LT.t1,
                ),
              ),
            ),
          ),
          _StepBtn('+', (m) => _step(m)),
        ],
      ),
    );
  }
}

/// ± button: a tap steps once; press-and-hold auto-repeats, getting gradually
/// faster (shorter interval + larger step) the longer it's held.
class _StepBtn extends StatefulWidget {
  const _StepBtn(this.glyph, this.onStep);
  final String glyph;
  final void Function(int magnitude) onStep;

  @override
  State<_StepBtn> createState() => _StepBtnState();
}

class _StepBtnState extends State<_StepBtn> {
  Timer? _hold;
  int _fires = 0;
  // The pointer that owns the current hold. Extra fingers are ignored while
  // held — otherwise a second down would orphan the first auto-repeat timer
  // (ramping BPM forever) and a second up would end the wrong hold.
  int? _pointer;
  bool _pointerTap = false;

  void _start(int pointer) {
    if (_pointer != null) return;
    _pointer = pointer;
    _pointerTap = true;
    _hold?.cancel();
    _fires = 0;
    widget.onStep(1); // immediate first step (also the plain-tap case)
    _hold = Timer(
      const Duration(milliseconds: 360),
      _repeat,
    ); // hold delay before auto-repeat
  }

  void _repeat() {
    _fires++;
    // grow the step after sustained holding so the full 40–220 range is reachable
    final mag = _fires > 36 ? 5 : (_fires > 16 ? 2 : 1);
    widget.onStep(mag);
    // accelerate: 210ms → 40ms between repeats
    final ms = (210 - _fires * 8).clamp(40, 210);
    _hold = Timer(Duration(milliseconds: ms), _repeat);
  }

  void _stop(int pointer) {
    if (pointer != _pointer) return;
    _pointer = null;
    _hold?.cancel();
    _hold = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _pointerTap = false);
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listener (raw pointer) rather than GestureDetector: a long press never
    // gets stolen by the tap recognizer, so down/up reliably bracket the hold.
    return Listener(
      onPointerDown: (e) => _start(e.pointer),
      onPointerUp: (e) => _stop(e.pointer),
      onPointerCancel: (e) => _stop(e.pointer),
      child: IconButton(
        tooltip:
            widget.glyph == '+'
                ? L10n.of(context).ltTransportTempoUp
                : L10n.of(context).ltTransportTempoDown,
        onPressed: () {
          if (!_pointerTap) widget.onStep(1);
        },
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          visualDensity: VisualDensity.standard,
        ),
        icon: Text(
          widget.glyph,
          textScaler: TextScaler.noScaling,
          style: LTType.inter(size: 18, weight: FontWeight.w700, color: LT.t1),
        ),
      ),
    );
  }
}

/// Direct BPM entry — a small modal with a numeric field. Returns the clamped
/// value, or null on cancel / invalid.
Future<int?> _promptBpm(BuildContext context, int current) {
  return showLtModal<int>(
    context,
    width: 260,
    child: _BpmInput(initial: current),
  );
}

class _BpmInput extends StatefulWidget {
  const _BpmInput({required this.initial});
  final int initial;

  @override
  State<_BpmInput> createState() => _BpmInputState();
}

class _BpmInputState extends State<_BpmInput> {
  // Owned here (not by _promptBpm) so it's disposed only once the dialog's
  // TextField has left the tree — i.e. after the pop animation.
  late final TextEditingController _ctrl = TextEditingController(
      text: '${widget.initial}',
    )
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: '${widget.initial}'.length,
    );
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = int.tryParse(_ctrl.text.trim());
    if (v == null || v < _kBpmMin || v > _kBpmMax) {
      setState(() => _error = '$_kBpmMin–$_kBpmMax');
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.ltTransportSetBpm,
          style: LTType.inter(size: 15, weight: FontWeight.w800, color: LT.t1),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 3,
          onSubmitted: (_) => _submit(),
          style: LTType.mono(size: 24, weight: FontWeight.w700, color: LT.t1),
          decoration: InputDecoration(
            counterText: '',
            errorText: _error,
            hintText: '$_kBpmMin–$_kBpmMax',
            filled: true,
            fillColor: LT.surface2,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(LTRadius.pill),
              borderSide: const BorderSide(color: LT.border),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(LTRadius.pill),
              borderSide: const BorderSide(color: LT.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(LTRadius.pill),
              borderSide: const BorderSide(color: LT.lime),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(l.cancel),
            ),
            FilledButton(
              onPressed: _submit,
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              child: Text(l.apply),
            ),
          ],
        ),
      ],
    );
  }
}

class _BarsToggle extends StatelessWidget {
  const _BarsToggle({required this.bars, required this.onBars});
  final int bars;
  final ValueChanged<int> onBars;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 4,
      children: [
        for (final b in const [1, 2, 4])
          ChoiceChip(
            label: Text('$b'),
            selected: bars == b,
            onSelected: (_) => onBars(b),
          ),
      ],
    );
  }
}

// ui-001 stage 1: the desktop top bar's song-settings popover reuses the same
// BPM stepper (40–220, hold to accelerate, tap the number to type), the same
// direct BPM entry and the same 1|2|4 bars toggle as this bar. Thin public
// wrappers keep these widgets single-sourced; the phone bar is unchanged.

/// [_BpmStepper] for other bars.
class BpmStepper extends StatelessWidget {
  const BpmStepper({super.key, required this.bpm, required this.onBpm});
  final int bpm;
  final ValueChanged<int> onBpm;
  @override
  Widget build(BuildContext context) => _BpmStepper(bpm: bpm, onBpm: onBpm);
}

/// [_BarsToggle] for other bars.
class BarsToggle extends StatelessWidget {
  const BarsToggle({super.key, required this.bars, required this.onBars});
  final int bars;
  final ValueChanged<int> onBars;
  @override
  Widget build(BuildContext context) => _BarsToggle(bars: bars, onBars: onBars);
}

/// The direct BPM entry modal (null on cancel), clamped to 40–220.
Future<int?> promptBpm(BuildContext context, int current) =>
    _promptBpm(context, current);
