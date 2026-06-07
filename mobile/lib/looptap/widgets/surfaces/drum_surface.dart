// LoopTap — Drums surface (the signature). README §5.
// A center beat-grid (HH/SN/KK × step cells) flanked by symmetric KICK/SNARE/
// HIHAT pads on BOTH left and right for two-thumb play.
import 'package:flutter/material.dart';

import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'pad_fx.dart';

class DrumSpec {
  const DrumSpec(this.kind, this.label, this.short, this.color);
  final String kind;
  final String label;
  final String short;
  final Color color;
}

const List<DrumSpec> kDrums = [
  DrumSpec('hihat', 'HI-HAT', 'HH', LT.blue),
  DrumSpec('snare', 'SNARE', 'SN', LT.lime),
  DrumSpec('kick', 'KICK', 'KK', LT.amber),
];

class DrumSurface extends StatelessWidget {
  const DrumSurface({
    super.key,
    required this.notes, // list of (kind, step)
    required this.litDrums,
    required this.onHit,
    required this.playStep,
    required this.steps,
    required this.bars,
  });

  /// kind -> set of active steps.
  final Map<String, Set<int>> notes;
  final Set<String> litDrums;
  final ValueChanged<String> onHit;
  final double playStep;
  final int steps;
  final int bars;

  Widget _column() {
    return SizedBox(
      width: 200,
      child: Column(
        children: [
          for (var i = 0; i < kDrums.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Expanded(child: _DrumPad(spec: kDrums[i], lit: litDrums.contains(kDrums[i].kind), onHit: onHit)),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _column(),
        const SizedBox(width: 12),
        Expanded(
          child: _BeatGrid(notes: notes, playStep: playStep, steps: steps, bars: bars),
        ),
        const SizedBox(width: 12),
        _column(),
      ],
    );
  }
}

class _DrumPad extends StatelessWidget {
  const _DrumPad({required this.spec, required this.lit, required this.onHit});
  final DrumSpec spec;
  final bool lit;
  final ValueChanged<String> onHit;

  @override
  Widget build(BuildContext context) {
    return PadFx(
      accent: spec.color,
      borderRadius: LTRadius.card,
      idle: LT.surface2,
      lit: lit,
      onDown: () => onHit(spec.kind),
      builder: (active) => Center(
        child: SizedBox(
          width: 150,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  spec.short,
                  textAlign: TextAlign.right,
                  style: LTType.inter(size: 30, weight: FontWeight.w900, color: active ? LT.bg : LT.t1, letterSpacing: 0.5),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                spec.label,
                style: LTType.inter(
                  size: 11,
                  weight: FontWeight.w800,
                  color: active ? LT.bg.withValues(alpha: 0.67) : spec.color,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BeatGrid extends StatelessWidget {
  const _BeatGrid({required this.notes, required this.playStep, required this.steps, required this.bars});
  final Map<String, Set<int>> notes;
  final double playStep;
  final int steps;
  final int bars;

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
              const LtLabel('Beat grid'),
              LtLabel('$bars bars · 4/4', color: LT.t3),
            ],
          ),
          const SizedBox(height: 6),
          for (final d in kDrums)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: Text(d.short, style: LTType.inter(size: 9, weight: FontWeight.w800, color: d.color)),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          for (var s = 0; s < steps; s++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 1),
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
  const _Cell({required this.on, required this.beat, required this.current, required this.color});
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
          color: current ? LT.t1.withValues(alpha: 0.33) : (on ? color : LT.border),
          width: current ? 1.5 : 1,
        ),
        boxShadow: on ? [BoxShadow(color: color.withValues(alpha: 0.67), blurRadius: 8)] : null,
      ),
    );
  }
}
