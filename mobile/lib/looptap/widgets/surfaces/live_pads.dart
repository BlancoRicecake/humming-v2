// LoopTap — live note pads (Melody Pads + Bass). README §5.
// Tap = play; hold longer = longer note (printed on release while recording).
import 'package:flutter/material.dart';

import '../../music/theory.dart';
import '../../theme/tokens.dart';
import 'pad_fx.dart';

class _LivePad extends StatelessWidget {
  const _LivePad({
    required this.rung,
    required this.label,
    required this.sub,
    required this.lit,
    required this.accent,
    required this.onDown,
    required this.onUp,
    this.big = false,
  });

  final Rung rung;
  final String label;
  final String sub;
  final bool lit;
  final Color accent;
  final ValueChanged<Rung> onDown;
  final ValueChanged<Rung> onUp;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return PadFx(
      accent: accent,
      borderRadius: 18,
      idle: LT.surface2,
      lit: lit,
      onDown: () => onDown(rung),
      onUp: () => onUp(rung),
      builder: (active) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: LTType.inter(size: big ? 28 : 22, weight: FontWeight.w900, color: active ? LT.bg : LT.t1)),
            const SizedBox(height: 3),
            Text(sub,
                style: LTType.mono(size: 10, color: active ? LT.bg.withValues(alpha: 0.67) : LT.t3)),
          ],
        ),
      ),
    );
  }
}

/// Melody — 8 large live pads (in-key scale degrees).
class NotePads extends StatelessWidget {
  const NotePads({
    super.key,
    required this.ladder,
    required this.litMidis,
    required this.accent,
    required this.onDown,
    required this.onUp,
  });

  final List<Rung> ladder;
  final Set<int> litMidis;
  final Color accent;
  final ValueChanged<Rung> onDown;
  final ValueChanged<Rung> onUp;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < ladder.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _LivePad(
              rung: ladder[i],
              label: ladder[i].name,
              sub: 'deg ${ladder[i].degree + 1}',
              lit: litMidis.contains(ladder[i].midi),
              accent: accent,
              onDown: onDown,
              onUp: onUp,
            ),
          ),
        ],
      ],
    );
  }
}

/// Bass — 5 large pads for I · IV · V · vi · I(8va), one octave down.
class BassPads extends StatelessWidget {
  const BassPads({
    super.key,
    required this.bassLadder,
    required this.litMidis,
    required this.accent,
    required this.onDown,
    required this.onUp,
  });

  final List<Rung> bassLadder;
  final Set<int> litMidis;
  final Color accent;
  final ValueChanged<Rung> onDown;
  final ValueChanged<Rung> onUp;

  static const _roman = ['I', 'IV', 'V', 'vi', 'I'];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < bassLadder.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(
            child: _LivePad(
              rung: bassLadder[i],
              label: _roman[i],
              sub: bassLadder[i].name,
              lit: litMidis.contains(bassLadder[i].midi),
              accent: accent,
              onDown: onDown,
              onUp: onUp,
              big: true,
            ),
          ),
        ],
      ],
    );
  }
}
