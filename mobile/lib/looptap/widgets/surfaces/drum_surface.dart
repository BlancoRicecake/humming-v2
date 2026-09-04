// LoopTap — Drums surface (the signature). README §5.
// A center beat-grid (HH/SN/KK × step cells) flanked by symmetric KICK/SNARE/
// HIHAT pads on BOTH left and right for two-thumb play.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../theme/atoms.dart';
import '../../theme/pad_scale.dart';
import '../../theme/tokens.dart';
import 'pad_fx.dart';

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
      _ => l.ltDrumKick, // matches the kDrumSpecs['kick'] fallback below
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
    (kinds == null || kinds.isEmpty) ? kDrums : [for (final k in kinds) kDrumSpecs[k] ?? kDrumSpecs['kick']!];

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
          Expanded(child: _DrumPad(key: ValueKey('$side${specs[i].kind}'), spec: specs[i], onHit: onHit)),
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
        Expanded(flex: 2, child: _BeatGrid(notes: notes, playStep: playStep, steps: steps, bars: bars, specs: specs)),
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
      builder: (active) => LayoutBuilder(
        builder: (ctx, c) {
          // Base sizes scale with the pad box (PadScale); FittedBox below still
          // shrinks to fit very short/narrow pads so labels never overflow.
          final sc = PadScale(math.min(c.maxWidth, c.maxHeight));
          return Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      spec.short,
                      style: LTType.inter(size: sc.title, weight: FontWeight.w900, color: active ? LT.bg : LT.t1, letterSpacing: 0.5),
                    ),
                    SizedBox(width: sc.gap + 4),
                    Text(
                      drumLabel(L10n.of(context), spec.kind),
                      style: LTType.inter(
                        size: sc.sub,
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
        },
      ),
    );
  }
}

class _BeatGrid extends StatelessWidget {
  const _BeatGrid({required this.notes, required this.playStep, required this.steps, required this.bars, this.specs = kDrums});
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

/// Drums Grid mode (README §5 variant): the beat grid ONLY, full-area and
/// editable — tap a cell to toggle a hit at (kind, step).
class DrumGrid extends StatelessWidget {
  const DrumGrid({
    super.key,
    required this.notes,
    required this.onToggle,
    required this.playStep,
    required this.steps,
    required this.bars,
    this.specs = kDrums,
  });

  final Map<String, Set<int>> notes;
  final void Function(String kind, int step) onToggle;
  final double playStep;
  final int steps;
  final int bars;
  final List<DrumSpec> specs;

  @override
  Widget build(BuildContext context) {
    final cur = playStep.floor() % steps;
    return Container(
      padding: const EdgeInsets.all(14),
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
              LtLabel(L10n.of(context).ltDrumGridMetaEditable(bars), color: LT.t3),
            ],
          ),
          const SizedBox(height: 8),
          // Rows fill the height when they fit (3-lane main drums); once there
          // are too many lanes to stay legible (6-lane Beat Fill), they take a
          // min height and the grid scrolls instead of squishing the labels.
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) {
                const minRow = 40.0;
                final fits = specs.length * minRow <= c.maxHeight;
                final rows = [for (final d in specs) _row(d, cur)];
                if (fits) {
                  return Column(
                    children: [for (final r in rows) Expanded(child: r)],
                  );
                }
                return ListView(
                  padding: EdgeInsets.zero,
                  physics: const ClampingScrollPhysics(),
                  children: [
                    for (final r in rows) SizedBox(height: minRow, child: r),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // One lane: a short label + the step cells. Used both height-filled (Expanded)
  // and at a fixed min height (scrolling). The label is wrapped in a FittedBox
  // so it never clips when the lane is short.
  Widget _row(DrumSpec d, int cur) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: LayoutBuilder(
                builder: (context, c) {
                  final size = (c.maxHeight * 0.7).clamp(10.0, 18.0);
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        d.short,
                        style: LTType.inter(size: size, weight: FontWeight.w900, color: d.color),
                      ),
                    ),
                  );
                },
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  for (var s = 0; s < steps; s++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onToggle(d.kind, s),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: _Cell(
                            on: notes[d.kind]?.contains(s) ?? false,
                            beat: s % 4 == 0,
                            current: s == cur,
                            color: d.color,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
}
