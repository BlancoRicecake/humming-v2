// LoopTap — Beat-Fill launchpad. A single row of 6 SQUARE pads, each playing a
// user-assignable GM percussion sound (kind in kFillPalette). Unlike DrumSurface
// there is NO center beat grid — tap a pad to play+record at the playhead; tap
// its corner ⚙ to change that pad's sound. Only used for the Beat-Fill track in
// pads mode (the main drums keep DrumSurface).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../music/theory.dart' show kFillPalette;
import '../../theme/atoms.dart';
import '../../theme/pad_scale.dart';
import '../../theme/tokens.dart';
import 'drum_surface.dart' show DrumSpec, drumLabel, kDrumSpecs;
import 'pad_fx.dart';

class FillLaunchpad extends StatelessWidget {
  const FillLaunchpad({
    super.key,
    required this.kinds,
    required this.notes,
    required this.playStep,
    required this.steps,
    required this.onHit,
    required this.onSwap,
  });

  /// The 6 percussion sounds, one per pad (left→right).
  final List<String> kinds;

  /// kind → steps that play it (drives the live flash + the has-notes dot).
  final Map<String, Set<int>> notes;
  final double playStep;
  final int steps;

  /// Fired with the pad's kind when pressed (records like the drum pads).
  final ValueChanged<String> onHit;

  /// Open the sound picker for pad [padIndex].
  final void Function(int padIndex) onSwap;

  @override
  Widget build(BuildContext context) {
    final cur = steps > 0 ? playStep.floor() % steps : 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < kinds.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(
            child: _FillPad(
              spec: kDrumSpecs[kinds[i]] ?? kDrumSpecs['clap']!,
              lit: notes[kinds[i]]?.contains(cur) ?? false,
              hasNotes: notes[kinds[i]]?.isNotEmpty ?? false,
              onHit: onHit,
              onSwap: () => onSwap(i),
            ),
          ),
        ],
      ],
    );
  }
}

class _FillPad extends StatelessWidget {
  const _FillPad({
    required this.spec,
    required this.lit,
    required this.hasNotes,
    required this.onHit,
    required this.onSwap,
  });
  final DrumSpec spec;
  final bool lit;
  final bool hasNotes;
  final ValueChanged<String> onHit;
  final VoidCallback onSwap;

  @override
  Widget build(BuildContext context) {
    final label = drumLabel(L10n.of(context), spec.kind);
    return LayoutBuilder(
      builder: (ctx, c) {
        // Keep pads square in the wide landscape row: size to the smaller axis.
        final side = math.min(c.maxWidth, c.maxHeight);
        return Center(
          child: SizedBox(
            width: side,
            height: side,
            child: Stack(
              children: [
                Positioned.fill(
                  child: PadFx(
                    accent: spec.color,
                    borderRadius: LTRadius.card,
                    idle: LT.surface2,
                    lit: lit, // flash on its own hits during playback
                    onDown: () => onHit(spec.kind),
                    builder: (active) => _padBody(active, label),
                  ),
                ),
                // "has recorded notes" dot (top-left) — disappears on clear, so
                // the launchpad reflects edits even when stopped.
                if (hasNotes)
                  Positioned(
                    top: 7,
                    left: 7,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: lit ? LT.bg : spec.color,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                // Per-pad sound swap — sits above PadFx so its taps don't hit.
                Positioned(
                  top: 6,
                  right: 6,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onSwap,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: LT.bg.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: LT.border),
                      ),
                      child: Ms(LtIcons.tune, size: 16, color: LT.t2),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // [label] is resolved by build() — this body runs inside PadFx's builder,
  // which has no BuildContext of its own.
  Widget _padBody(bool active, String label) => LayoutBuilder(
        builder: (ctx, c) {
          final sc = PadScale(math.min(c.maxWidth, c.maxHeight));
          return Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
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
                    SizedBox(height: sc.gap),
                    Text(
                      label,
                      style: LTType.inter(
                        size: sc.sub,
                        weight: FontWeight.w800,
                        color: active ? LT.bg.withValues(alpha: 0.67) : spec.color,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );
}

/// Sound picker for one Fill pad — a wrap of the kFillPalette percussion sounds.
/// Tapping a chip previews it and pops the chosen kind (use with showLtModal).
class FillPaletteSheet extends StatelessWidget {
  const FillPaletteSheet({super.key, required this.current, required this.onPreview});

  /// The pad's current kind (highlighted).
  final String current;

  /// Play a one-shot preview of the tapped kind before closing.
  final ValueChanged<String> onPreview;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          L10n.of(context).ltFillPadSound,
          style: LTType.inter(size: 15, weight: FontWeight.w800, color: LT.t1),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final k in kFillPalette)
              _PaletteChip(
                spec: kDrumSpecs[k]!,
                selected: k == current,
                onTap: () {
                  onPreview(k);
                  Navigator.of(context).pop(k);
                },
              ),
          ],
        ),
      ],
    );
  }
}

class _PaletteChip extends StatelessWidget {
  const _PaletteChip({required this.spec, required this.selected, required this.onTap});
  final DrumSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? spec.color : LT.surface2;
    final fg = selected ? LT.bg : LT.t1;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minWidth: 96),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? spec.color : LT.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(spec.short,
                style: LTType.inter(size: 13, weight: FontWeight.w900, color: fg)),
            const SizedBox(width: 8),
            Text(drumLabel(L10n.of(context), spec.kind),
                style: LTType.inter(
                    size: 11,
                    weight: FontWeight.w800,
                    color: selected ? LT.bg.withValues(alpha: 0.7) : spec.color,
                    letterSpacing: 0.8)),
          ],
        ),
      ),
    );
  }
}
