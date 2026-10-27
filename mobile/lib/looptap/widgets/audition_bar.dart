import 'package:flutter/material.dart';
import '../music/audition.dart';
import '../theme/tokens.dart';

/// Scrollable on phones, with explicit bar numbers rather than pixel-only
/// handles so the same phrase can be compared repeatedly.
class AuditionBar extends StatelessWidget {
  const AuditionBar({
    super.key,
    required this.bars,
    required this.range,
    required this.looping,
    required this.soloCount,
    required this.bypassSolo,
    required this.onRange,
    required this.onLoop,
    required this.onCompare,
    required this.onClearSolo,
    required this.onRestart,
    this.enabled = true,
  });

  final int bars, soloCount;
  final PlaybackRange range;
  final bool looping, bypassSolo, enabled;
  final ValueChanged<PlaybackRange> onRange;
  final VoidCallback onLoop, onCompare, onClearSolo, onRestart;

  @override
  Widget build(BuildContext context) {
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    final start = range.start ~/ 16 + 1;
    final end = (range.end / 16).ceil();
    Widget pick(
      String key,
      int value,
      Iterable<int> options,
      ValueChanged<int> change,
      String label,
    ) => Tooltip(
      message: label,
      child: DropdownButton<int>(
        key: ValueKey(key),
        value: value,
        isDense: true,
        dropdownColor: LT.surface2,
        style: const TextStyle(color: LT.t1, fontSize: 12),
        items: [
          for (final n in options)
            DropdownMenuItem(value: n, child: Text('$n')),
        ],
        onChanged:
            enabled
                ? (n) {
                  if (n != null) change(n);
                }
                : null,
      ),
    );
    return SizedBox(
      height: 38,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            TextButton.icon(
              key: const ValueKey('audition-loop'),
              onPressed: enabled ? onLoop : null,
              style: TextButton.styleFrom(
                foregroundColor: looping ? LT.lime : LT.t2,
              ),
              icon: Icon(Icons.repeat, size: 16),
              label: Text(
                ko
                    ? (looping ? '구간 반복 켬' : '전체 반복')
                    : (looping ? 'Range loop on' : 'Full loop'),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              ko ? '마디 ' : 'Bars ',
              style: const TextStyle(color: LT.t2, fontSize: 12),
            ),
            pick(
              'loop-start-bar',
              start,
              List.generate(bars, (i) => i + 1),
              (n) => onRange(
                PlaybackRange((n - 1) * 16, (end < n ? n : end) * 16),
              ),
              ko ? '시작 마디' : 'First bar',
            ),
            const Text(' – ', style: TextStyle(color: LT.t2)),
            pick(
              'loop-end-bar',
              end,
              List.generate(bars - start + 1, (i) => i + start),
              (n) => onRange(PlaybackRange((start - 1) * 16, n * 16)),
              ko ? '끝 마디 (포함)' : 'Last bar (inclusive)',
            ),
            IconButton(
              key: const ValueKey('audition-restart'),
              tooltip: ko ? '같은 구간 처음부터 듣기' : 'Restart this phrase',
              visualDensity: VisualDensity.compact,
              onPressed: enabled ? onRestart : null,
              icon: const Icon(Icons.first_page, size: 19, color: LT.t2),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const ValueKey('audition-compare'),
              onPressed: enabled && soloCount > 0 ? onCompare : null,
              style: TextButton.styleFrom(
                foregroundColor: bypassSolo ? LT.t1 : LT.lime,
              ),
              child: Text(
                soloCount == 0
                    ? (ko ? '트랙 S로 Solo 선택' : 'Select track S for Solo')
                    : bypassSolo
                    ? (ko ? '전체 파트 · Solo로 비교' : 'Full mix · compare Solo')
                    : (ko
                        ? 'Solo $soloCount · 전체와 비교'
                        : 'Solo $soloCount · compare full mix'),
              ),
            ),
            if (soloCount > 0)
              TextButton(
                key: const ValueKey('audition-clear-solo'),
                onPressed: enabled ? onClearSolo : null,
                child: Text(ko ? 'Solo 해제' : 'Clear Solo'),
              ),
          ],
        ),
      ),
    );
  }
}
