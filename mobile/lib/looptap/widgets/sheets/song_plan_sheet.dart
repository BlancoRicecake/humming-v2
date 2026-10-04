import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../models/loop_models.dart';
import '../../theme/tokens.dart';

class SongPlanSheet extends StatelessWidget {
  const SongPlanSheet({
    super.key,
    required this.sections,
    required this.activeIndex,
    required this.locks,
    required this.onSelect,
    required this.onDuplicate,
    required this.onMove,
    required this.onRepeats,
    required this.onLock,
  });

  final List<Section> sections;
  final int activeIndex;
  final Map<String, bool> locks;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onDuplicate;
  final void Function(int index, int direction) onMove;
  final void Function(int index, int repeats) onRepeats;
  final void Function(String track, bool locked) onLock;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.ltSongPlanTitle,
          style: const TextStyle(
            color: LT.t1,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l.ltSongPlanHint,
          style: const TextStyle(color: LT.t2, height: 1.4),
        ),
        const SizedBox(height: 18),
        for (var i = 0; i < sections.length; i++) ...[
          _SectionRow(
            section: sections[i],
            barsLabel: l.ltSongPlanBars,
            duplicateLabel: l.projectOptionDuplicate,
            moveLeftLabel: l.ltEditorMoveLeft,
            moveRightLabel: l.ltEditorMoveRight,
            selected: i == activeIndex,
            canMoveLeft: i > 0,
            canMoveRight: i < sections.length - 1,
            onSelect: () => onSelect(i),
            onDuplicate: () => onDuplicate(i),
            onMoveLeft: () => onMove(i, -1),
            onMoveRight: () => onMove(i, 1),
            onRepeats: (value) => onRepeats(i, value),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 14),
        Text(
          l.ltSongPlanLocks,
          style: const TextStyle(color: LT.t1, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 4),
        Text(
          l.ltSongPlanLocksHint,
          style: const TextStyle(color: LT.t3, fontSize: 12),
        ),
        const SizedBox(height: 8),
        for (final item in [
          ('melody', l.ltSongPlanMelody),
          ('harmony', l.ltSongPlanHarmony),
          ('bass', l.ltSongPlanBass),
          ('drums', l.ltSongPlanDrums),
        ])
          SwitchListTile.adaptive(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(item.$2, style: const TextStyle(color: LT.t1)),
            secondary: Icon(
              locks[item.$1] ?? false ? Icons.lock_outline : Icons.lock_open,
              color: locks[item.$1] ?? false ? LT.lime : LT.t3,
            ),
            value: locks[item.$1] ?? false,
            onChanged: (value) => onLock(item.$1, value),
          ),
      ],
    );
  }
}

class _SectionRow extends StatelessWidget {
  const _SectionRow({
    required this.section,
    required this.barsLabel,
    required this.duplicateLabel,
    required this.moveLeftLabel,
    required this.moveRightLabel,
    required this.selected,
    required this.canMoveLeft,
    required this.canMoveRight,
    required this.onSelect,
    required this.onDuplicate,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onRepeats,
  });

  final Section section;
  final String barsLabel, duplicateLabel, moveLeftLabel, moveRightLabel;
  final bool selected, canMoveLeft, canMoveRight;
  final VoidCallback onSelect, onDuplicate, onMoveLeft, onMoveRight;
  final ValueChanged<int> onRepeats;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: selected ? LT.lime.withValues(alpha: .08) : LT.surface2,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: selected ? LT.lime : LT.border),
      ),
      child: Row(
        children: [
          InkWell(
            onTap: onSelect,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Text(
                section.name,
                style: const TextStyle(
                  color: LT.t1,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '${section.bars} $barsLabel',
            style: const TextStyle(color: LT.t3),
          ),
          const Spacer(),
          IconButton(
            tooltip: moveLeftLabel,
            onPressed: canMoveLeft ? onMoveLeft : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: moveRightLabel,
            onPressed: canMoveRight ? onMoveRight : null,
            icon: const Icon(Icons.chevron_right),
          ),
          IconButton(
            tooltip: duplicateLabel,
            onPressed: onDuplicate,
            icon: const Icon(Icons.content_copy_outlined, size: 19),
          ),
          DropdownButton<int>(
            value: section.repeats,
            dropdownColor: LT.surface,
            underline: const SizedBox.shrink(),
            style: const TextStyle(color: LT.t1),
            items: [
              for (var i = 1; i <= 8; i++)
                DropdownMenuItem(value: i, child: Text('×$i')),
            ],
            onChanged: (value) {
              if (value != null) onRepeats(value);
            },
          ),
        ],
      ),
    );
  }
}
