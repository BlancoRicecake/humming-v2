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
    this.onUndo,
    this.backingStyle,
  });
  final bool hasNotes, playing, saved;
  final VoidCallback onBack, onRecord, onListen, onInstrument, onSave, onEdit;
  final VoidCallback? onSample, onUndo;
  final ValueChanged<BackingStyle>? onBacking;
  final BackingStyle? backingStyle;

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
