import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../services/product_analytics.dart';
import '../theme/tokens.dart';

/// Shown before the demos until the library contains the user's own work.
class FirstSongCard extends StatefulWidget {
  const FirstSongCard({super.key, required this.onStart});
  final VoidCallback onStart;

  @override
  State<FirstSongCard> createState() => _FirstSongCardState();
}

class _FirstSongCardState extends State<FirstSongCard> {
  @override
  void initState() {
    super.initState();
    ProductAnalytics.instance.track(ProductEvent.firstSongPromptViewed);
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Container(
      key: const ValueKey('first-song-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: LT.lime.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(LTRadius.card),
        border: Border.all(color: LT.lime),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.ltFirstSongTitle,
            style: const TextStyle(
              color: LT.t1,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l.ltFirstSongHint,
            style: const TextStyle(color: LT.t2, fontSize: 11, height: 1.4),
          ),
          const Spacer(),
          FilledButton.icon(
            key: const ValueKey('first-song-start'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: const TextStyle(fontSize: 12),
            ),
            onPressed: widget.onStart,
            icon: const Icon(Icons.mic, size: 18),
            label: Text(l.ltGuidedStart),
          ),
        ],
      ),
    );
  }
}
