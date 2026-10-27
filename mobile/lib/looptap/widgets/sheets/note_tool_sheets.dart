// Quantize / Humanize settings sheets shared by the piano roll (StepGrid)
// and the drum grid (DrumGrid). Values live in LoopPrefs, so both editors
// use the same last settings.
import 'package:flutter/material.dart';

import '../../music/pitch_note_edit.dart' show QuantizeGrid;
import '../../state/loop_prefs.dart';

bool _isKo(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'ko';

/// Quantize settings (grid, strength and, for notes, ends). Returns true when
/// the user pressed Apply.
Future<bool> showQuantizeSheet(
  BuildContext context, {
  required bool canApply,
  bool showEnds = true,
}) async {
  final prefs = LoopPrefs.instance;
  final ko = _isKo(context);
  final apply = await showModalBottomSheet<bool>(
    context: context,
    builder:
        (context) => StatefulBuilder(
          builder:
              (context, setSheet) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ko ? '퀀타이즈' : 'Quantize'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: [
                        for (final g in QuantizeGrid.values)
                          ChoiceChip(
                            key: ValueKey('quantize-grid-${g.name}'),
                            label: Text(g.label),
                            selected: prefs.quantizeGrid.value == g.name,
                            onSelected: (_) {
                              prefs.setQuantize(grid: g.name);
                              setSheet(() {});
                            },
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          '${ko ? '강도' : 'Strength'} '
                          '${prefs.quantizeStrength.value.round()}%',
                        ),
                        Expanded(
                          child: Slider(
                            key: const ValueKey('quantize-strength'),
                            min: 0,
                            max: 100,
                            divisions: 100,
                            value: prefs.quantizeStrength.value,
                            onChanged:
                                (v) => setSheet(
                                  () => prefs.quantizeStrength.value = v,
                                ),
                            onChangeEnd: (v) => prefs.setQuantize(strength: v),
                          ),
                        ),
                      ],
                    ),
                    if (showEnds)
                      SwitchListTile(
                        key: const ValueKey('quantize-ends'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(ko ? '끝도 맞추기' : 'Quantize ends'),
                        value: prefs.quantizeEnds.value,
                        onChanged: (v) {
                          prefs.setQuantize(ends: v);
                          setSheet(() {});
                        },
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        key: const ValueKey('quantize-apply'),
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

/// Humanize settings (timing and velocity ranges). Returns true on Apply.
Future<bool> showHumanizeSheet(
  BuildContext context, {
  required bool canApply,
}) async {
  final prefs = LoopPrefs.instance;
  final ko = _isKo(context);
  final apply = await showModalBottomSheet<bool>(
    context: context,
    builder:
        (context) => StatefulBuilder(
          builder:
              (context, setSheet) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ko ? '휴머나이즈' : 'Humanize'),
                    Row(
                      children: [
                        Text(
                          '${ko ? '타이밍' : 'Timing'} '
                          '${(prefs.humanizeTiming.value * 100).round()}%',
                        ),
                        Expanded(
                          child: Slider(
                            key: const ValueKey('humanize-timing'),
                            min: 0,
                            max: 50,
                            divisions: 50,
                            value: prefs.humanizeTiming.value * 100,
                            onChanged:
                                (v) => setSheet(
                                  () => prefs.humanizeTiming.value = v / 100,
                                ),
                            onChangeEnd:
                                (v) => prefs.setHumanize(timing: v / 100),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        Text(
                          '${ko ? '강약' : 'Velocity'} '
                          '±${prefs.humanizeVelocity.value}',
                        ),
                        Expanded(
                          child: Slider(
                            key: const ValueKey('humanize-velocity'),
                            min: 0,
                            max: 40,
                            divisions: 40,
                            value: prefs.humanizeVelocity.value.toDouble(),
                            onChanged:
                                (v) => setSheet(
                                  () =>
                                      prefs.humanizeVelocity.value = v.round(),
                                ),
                            onChangeEnd:
                                (v) => prefs.setHumanize(velocity: v.round()),
                          ),
                        ),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        key: const ValueKey('humanize-apply'),
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
