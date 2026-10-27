// harmony-002: Arpeggiate settings. Values live in LoopPrefs (last used).
import 'package:flutter/material.dart';

import '../../music/arpeggiate.dart';
import '../../music/pitch_note_edit.dart' show QuantizeGrid;
import '../../state/loop_prefs.dart';

/// The saved Arpeggiate settings.
ArpSettings currentArpSettings() {
  final p = LoopPrefs.instance;
  return ArpSettings(
    style: ArpStyle.byName(p.arpStyle.value),
    grid: QuantizeGrid.byName(p.arpGrid.value),
    gate: p.arpGate.value / 100,
    octaves: p.arpOctaves.value,
    keepOriginalMuted: p.arpKeepOriginal.value,
  );
}

/// Style, rate, gate, octaves and "keep the chord muted". Returns true when
/// the user pressed Apply.
Future<bool> showArpSheet(BuildContext context, {required bool canApply}) async {
  final prefs = LoopPrefs.instance;
  final ko = Localizations.localeOf(context).languageCode == 'ko';
  final apply = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder:
        (context) => StatefulBuilder(
          builder:
              (context, setSheet) => SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ko ? '펼치기 (아르페지오)' : 'Arpeggiate'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final s in ArpStyle.values)
                          ChoiceChip(
                            key: ValueKey('arp-style-${s.name}'),
                            label: Text(ko ? s.labelKo : s.label),
                            selected: prefs.arpStyle.value == s.name,
                            onSelected: (_) {
                              prefs.setArp(style: s.name);
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final g in QuantizeGrid.values)
                          ChoiceChip(
                            key: ValueKey('arp-rate-${g.name}'),
                            label: Text(g.label),
                            selected: prefs.arpGrid.value == g.name,
                            onSelected: (_) {
                              prefs.setArp(grid: g.name);
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        Text('Gate ${prefs.arpGate.value}%'),
                        Expanded(
                          child: Slider(
                            key: const ValueKey('arp-gate'),
                            min: 10,
                            max: 200,
                            divisions: 190,
                            value: prefs.arpGate.value.toDouble(),
                            onChanged:
                                (v) => setSheet(
                                  () => prefs.arpGate.value = v.round(),
                                ),
                            onChangeEnd: (v) => prefs.setArp(gate: v.round()),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          '${ko ? '옥타브' : 'Octaves'} '
                          '${prefs.arpOctaves.value}',
                        ),
                        Expanded(
                          child: Slider(
                            key: const ValueKey('arp-octaves'),
                            min: 1,
                            max: 4,
                            divisions: 3,
                            value: prefs.arpOctaves.value.toDouble(),
                            onChanged:
                                (v) => setSheet(
                                  () => prefs.arpOctaves.value = v.round(),
                                ),
                            onChangeEnd:
                                (v) => prefs.setArp(octaves: v.round()),
                          ),
                        ),
                      ],
                    ),
                    SwitchListTile(
                      key: const ValueKey('arp-keep-original'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        ko
                            ? '원래 코드는 소리 끄고 남기기'
                            : 'Keep the chord (muted)',
                      ),
                      value: prefs.arpKeepOriginal.value,
                      onChanged: (v) {
                        prefs.setArp(keepOriginal: v);
                        setSheet(() {});
                      },
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        key: const ValueKey('arp-apply'),
                        onPressed:
                            canApply
                                ? () => Navigator.of(context).pop(true)
                                : null,
                        child: Text(ko ? '적용' : 'Apply'),
                      ),
                    ),
                  ],
                ),
              ),
        ),
  );
  return apply == true;
}
