// harmony-001: chord stamp kind + inversion picker. The choice is saved in
// LoopPrefs (app preference, not song data).
import 'package:flutter/material.dart';

import '../../music/theory.dart';
import '../../state/loop_prefs.dart';

/// Opens the picker. [chromatic] = the song has no 7-note scale, so the
/// Diatonic kinds are disabled (the stamp then uses Major).
Future<void> showChordTypeSheet(
  BuildContext context, {
  required bool chromatic,
}) async {
  final prefs = LoopPrefs.instance;
  final ko = Localizations.localeOf(context).languageCode == 'ko';
  await showModalBottomSheet<void>(
    context: context,
    builder:
        (context) => StatefulBuilder(
          builder: (context, setSheet) {
            final current = ChordType.byName(prefs.chordType.value);
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ko ? '코드 종류' : 'Chord type'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final t in ChordType.values)
                        ChoiceChip(
                          key: ValueKey('chord-type-${t.name}'),
                          label: Text(ko ? t.labelKo : t.label),
                          selected:
                              effectiveChordType(
                                current,
                                chromatic ? 'chromatic' : 'major',
                              ) ==
                              t,
                          onSelected:
                              chromatic && t.diatonic
                                  ? null
                                  : (_) {
                                    prefs.setChord(type: t.name);
                                    setSheet(() {});
                                  },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(ko ? '전위 (클릭 위치에 찍을 때)' : 'Inversion (click stamp)'),
                  const SizedBox(height: 6),
                  SegmentedButton<int>(
                    key: const ValueKey('chord-inversion'),
                    segments: const [
                      ButtonSegment(value: 0, label: Text('0')),
                      ButtonSegment(value: 1, label: Text('1')),
                      ButtonSegment(value: 2, label: Text('2')),
                    ],
                    selected: {prefs.chordInversion.value},
                    onSelectionChanged: (v) {
                      prefs.setChord(inversion: v.first);
                      setSheet(() {});
                    },
                  ),
                ],
              ),
            );
          },
        ),
  );
}
