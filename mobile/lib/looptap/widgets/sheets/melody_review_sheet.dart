import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/loop_models.dart';
import '../../music/melody_review.dart';
import '../../theme/tokens.dart';

Future<void> showMelodyReviewSheet(
  BuildContext context, {
  required List<PitchNote> Function() notes,
  required ValueChanged<int> onOctaveDown,
  required ValueChanged<int> onOctaveUp,
  required ValueChanged<int> onSplit,
  required ValueChanged<int> onMerge,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: LT.surface,
  builder: (context) => StatefulBuilder(
    builder: (context, refresh) {
      final l = L10n.of(context);
      final current = notes();
      final uncertain = uncertainNoteIndices(current);
      void apply(ValueChanged<int> action, int index) {
        action(index);
        refresh(() {});
      }

      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.ltMelodyReview,
                  style: const TextStyle(
                    color: LT.t1,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l.ltMelodyReviewHint,
                  style: const TextStyle(color: LT.t2, height: 1.4),
                ),
                const SizedBox(height: 14),
                if (uncertain.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      l.ltMelodyNoIssues,
                      style: const TextStyle(color: LT.lime),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: uncertain.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: LT.border),
                      itemBuilder: (context, row) {
                        final index = uncertain[row];
                        final note = current[index];
                        final source = note.sourceMidi ?? note.midi;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${_noteName(source)} → ${_noteName(note.midi)} · ${l.ltMelodyConfidence((note.confidence * 100).round())}',
                                      style: const TextStyle(
                                        color: LT.t1,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    'step ${note.step + 1}',
                                    style: const TextStyle(
                                      color: LT.t3,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  OutlinedButton(
                                    onPressed: () => apply(onOctaveDown, index),
                                    child: Text(l.ltMelodyOctaveDown),
                                  ),
                                  OutlinedButton(
                                    onPressed: () => apply(onOctaveUp, index),
                                    child: Text(l.ltMelodyOctaveUp),
                                  ),
                                  OutlinedButton(
                                    onPressed: note.dur >= 2
                                        ? () => apply(onSplit, index)
                                        : null,
                                    child: Text(l.ltMelodySplit),
                                  ),
                                  OutlinedButton(
                                    onPressed: index + 1 < current.length
                                        ? () => apply(onMerge, index)
                                        : null,
                                    child: Text(l.ltMelodyMerge),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      MaterialLocalizations.of(context).closeButtonLabel,
                    ),
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

String _noteName(int midi) {
  const names = [
    'C',
    'C♯',
    'D',
    'D♯',
    'E',
    'F',
    'F♯',
    'G',
    'G♯',
    'A',
    'A♯',
    'B',
  ];
  return '${names[midi % 12]}${midi ~/ 12 - 1}';
}
