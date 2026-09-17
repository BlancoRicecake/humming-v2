import 'package:flutter/material.dart';
import '../../l10n/generated/app_localizations.dart';
import '../theme/tokens.dart';

/// A small first-song surface over the existing editor and conversion engine.
class GuidedHumPanel extends StatelessWidget {
  const GuidedHumPanel({super.key, required this.hasNotes, required this.playing,
    required this.saved, required this.onBack, required this.onRecord,
    required this.onListen, required this.onInstrument, required this.onSave,
    required this.onEdit});
  final bool hasNotes, playing, saved;
  final VoidCallback onBack, onRecord, onListen, onInstrument, onSave, onEdit;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return ColoredBox(
      color: LT.bg,
      child: Column(children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            IconButton(onPressed: onBack, tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back, color: LT.t1)),
            Expanded(child: Text(l.ltGuidedSteps,
                style: const TextStyle(color: LT.t2, fontSize: 13))),
            TextButton(onPressed: onEdit, child: Text(l.ltGuidedDirect)),
          ])),
        Expanded(child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.ltGuidedTitle, style: const TextStyle(
                  fontSize: 28, fontWeight: FontWeight.w800, color: LT.t1)),
              const SizedBox(height: 8),
              Text(l.ltGuidedHint, style: const TextStyle(color: LT.t2, fontSize: 16)),
              const SizedBox(height: 20),
              Container(width: double.infinity, padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: LT.surface2,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: hasNotes ? LT.lime : LT.border)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(hasNotes ? Icons.music_note : Icons.mic_none,
                      size: 36, color: LT.lime),
                  const SizedBox(height: 12),
                  Text(hasNotes ? l.ltGuidedReady : l.ltGuidedPrepare,
                      style: const TextStyle(color: LT.t1, fontSize: 16, height: 1.5)),
                  const SizedBox(height: 16),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    FilledButton.icon(onPressed: hasNotes ? onListen : onRecord,
                      icon: Icon(hasNotes ? (playing ? Icons.stop : Icons.play_arrow) : Icons.mic),
                      label: Text(hasNotes ? (playing ? l.ltGuidedStop : l.ltGuidedListen) : l.ltGuidedRecord)),
                    if (hasNotes) ...[
                      OutlinedButton(onPressed: onInstrument, child: Text(l.ltGuidedSound)),
                      OutlinedButton(onPressed: onRecord, child: Text(l.ltGuidedMore)),
                      FilledButton.tonal(onPressed: onSave, child: Text(l.ltGuidedSave)),
                    ],
                  ]),
                ])),
              if (hasNotes && saved) Padding(padding: const EdgeInsets.only(top: 14),
                child: Text(l.ltGuidedSaved, style: const TextStyle(color: LT.lime))),
            ]))),
        )),
      ]),
    );
  }
}
