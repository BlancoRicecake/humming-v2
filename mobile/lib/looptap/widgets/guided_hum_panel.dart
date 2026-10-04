import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/tokens.dart';
import '../music/beginner_backing.dart';

class GuidedHumPanel extends StatelessWidget {
  const GuidedHumPanel({
    super.key,
    required this.hasNotes,
    required this.playing,
    required this.saved,
    required this.onBack,
    required this.onRecord,
    required this.onListen,
    required this.onInstrument,
    required this.onSave,
    required this.onEdit,
    this.onSample,
    this.onBacking,
    this.onPreviewBacking,
    this.onApplyBacking,
    this.onSongPlan,
    this.onUndo,
    this.backingStyle,
    this.previewCandidate,
    this.appliedCandidate,
    this.lowConfidenceCount = 0,
    this.previewingOriginal = false,
    this.melodyLocked = true,
    this.onPreviewOriginal,
    this.onPreviewCorrected,
    this.onReviewMelody,
  });
  final bool hasNotes, playing, saved;
  final VoidCallback onBack, onRecord, onListen, onInstrument, onSave, onEdit;
  final VoidCallback? onSample, onUndo, onSongPlan;
  final ValueChanged<BackingStyle>? onBacking;
  final ValueChanged<int>? onPreviewBacking, onApplyBacking;
  final BackingStyle? backingStyle;
  final int? previewCandidate, appliedCandidate;
  final int lowConfidenceCount;
  final bool previewingOriginal;
  final bool melodyLocked;
  final VoidCallback? onPreviewOriginal, onPreviewCorrected, onReviewMelody;

  Widget _card(List<Widget> children) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: LT.surface2,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: LT.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final melody = _card([
      Text(
        l.ltGuidedTitle,
        style: const TextStyle(
          color: LT.t1,
          fontSize: 21,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      Text(
        hasNotes ? l.ltGuidedReady : l.ltGuidedPrepare,
        style: const TextStyle(color: LT.t2, height: 1.4),
      ),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          FilledButton.icon(
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: onRecord,
            icon: const Icon(Icons.mic),
            label: Text(hasNotes ? l.ltGuidedMore : l.ltGuidedRecord),
          ),
          if (hasNotes)
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: onInstrument,
              child: Text(l.ltGuidedSound),
            ),
          if (onSample != null)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: onSample,
              icon: const Icon(Icons.graphic_eq),
              label: Text(l.ltGuidedSample),
            ),
        ],
      ),
      if (hasNotes) ...[
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              melodyLocked ? Icons.lock_outline : Icons.lock_open,
              color: melodyLocked ? LT.lime : LT.t3,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.ltMelodyLocked,
                    style: const TextStyle(
                      color: LT.t1,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    l.ltMelodyLockedHint,
                    style: const TextStyle(color: LT.t3, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
      if (hasNotes &&
          onPreviewOriginal != null &&
          onPreviewCorrected != null) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ChoiceChip(
              label: Text(l.ltMelodyRaw),
              selected: previewingOriginal,
              onSelected: (_) => onPreviewOriginal!(),
            ),
            ChoiceChip(
              label: Text(l.ltMelodyCorrected),
              selected: !previewingOriginal,
              onSelected: (_) => onPreviewCorrected!(),
            ),
            if (onReviewMelody != null)
              TextButton.icon(
                onPressed: onReviewMelody,
                icon: const Icon(Icons.tune),
                label: Text(
                  lowConfidenceCount > 0
                      ? l.ltMelodyUncertain(lowConfidenceCount)
                      : l.ltMelodyReview,
                ),
              ),
          ],
        ),
      ],
    ]);
    final backing = _card([
      Text(
        l.ltBackingTitle,
        style: const TextStyle(
          color: LT.t1,
          fontSize: 21,
          fontWeight: FontWeight.bold,
        ),
      ),
      const SizedBox(height: 8),
      Text(l.ltBackingHint, style: const TextStyle(color: LT.t2, height: 1.4)),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final style in BackingStyle.values)
            ChoiceChip(
              label: Text(switch (style) {
                BackingStyle.calm => l.ltBackingCalm,
                BackingStyle.bounce => l.ltBackingBounce,
                BackingStyle.drive => l.ltBackingDrive,
              }),
              selected: backingStyle == style,
              onSelected:
                  hasNotes && onBacking != null
                      ? (_) => onBacking!(style)
                      : null,
            ),
        ],
      ),
      if (backingStyle != null) ...[
        const SizedBox(height: 16),
        Text(
          l.ltBackingCompare,
          style: const TextStyle(color: LT.t1, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < 3; i++) ...[
          Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            decoration: BoxDecoration(
              color:
                  previewCandidate == i
                      ? LT.lime.withValues(alpha: .08)
                      : LT.bg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: previewCandidate == i ? LT.lime : LT.border,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: LT.surface2,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Text(
                    String.fromCharCode(65 + i),
                    style: const TextStyle(
                      color: LT.t1,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    backingCandidateLabel(backingStyle!, i),
                    style: const TextStyle(color: LT.t2, fontSize: 12),
                  ),
                ),
                IconButton(
                  tooltip: l.ltBackingPreview,
                  onPressed:
                      onPreviewBacking == null
                          ? null
                          : () => onPreviewBacking!(i),
                  icon: Icon(
                    previewCandidate == i && playing
                        ? Icons.stop_circle_outlined
                        : Icons.play_circle_outline,
                  ),
                ),
                FilledButton.tonal(
                  onPressed:
                      onApplyBacking == null ? null : () => onApplyBacking!(i),
                  child: Text(
                    appliedCandidate == i
                        ? l.ltBackingApplied
                        : l.ltBackingApply,
                  ),
                ),
              ],
            ),
          ),
          if (i != 2) const SizedBox(height: 8),
        ],
      ],
      if (hasNotes && onSongPlan != null) ...[
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: onSongPlan,
          icon: const Icon(Icons.account_tree_outlined),
          label: Text(l.ltSongPlan),
        ),
      ],
    ]);
    return ColoredBox(
      color: LT.bg,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back, color: LT.t1),
                ),
                Expanded(
                  child: Text(
                    l.ltGuidedSteps,
                    style: const TextStyle(color: LT.t2, fontSize: 13),
                  ),
                ),
                TextButton(onPressed: onEdit, child: Text(l.ltGuidedDirect)),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder:
                  (context, constraints) => SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    child:
                        constraints.maxWidth >= 680 && onBacking != null
                            ? Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(child: melody),
                                const SizedBox(width: 16),
                                Expanded(child: backing),
                              ],
                            )
                            : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                melody,
                                if (onBacking != null) ...[
                                  const SizedBox(height: 16),
                                  backing,
                                ],
                              ],
                            ),
                  ),
            ),
          ),
          if (hasNotes)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    onPressed: onListen,
                    icon: Icon(playing ? Icons.stop : Icons.play_arrow),
                    label: Text(playing ? l.ltGuidedStop : l.ltGuidedListen),
                  ),
                  FilledButton.tonal(
                    onPressed: onSave,
                    child: Text(l.ltGuidedSave),
                  ),
                  if (onUndo != null)
                    TextButton.icon(
                      onPressed: onUndo,
                      icon: const Icon(Icons.undo),
                      label: Text(l.ltEditorUndo),
                    ),
                  if (saved)
                    const Icon(Icons.check_circle_outline, color: LT.lime),
                  if (saved)
                    Text(
                      l.ltEditorSaved,
                      style: const TextStyle(color: LT.lime),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
