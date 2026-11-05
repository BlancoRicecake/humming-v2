import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../screens/legal_doc_screen.dart';
import '../state/loop_prefs.dart';
import '../theme/tokens.dart';

// Keep this date aligned with assets/legal and docs/legal/notice-2026-09-05.md.
const policyNoticeId = 'policies-2026-10-20';
const policyEffectiveDate = '2026-10-20';

/// The terms update the user hasn't confirmed yet (shown in the
/// announcement center and as the megaphone's dot, 2026-11-02).
bool get policyNoticePending =>
    LoopPrefs.instance.acknowledgedPolicyNotice.value != policyNoticeId;

/// The pending terms update as a row at the top of the announcement center.
class PolicyNoticeTile extends StatelessWidget {
  const PolicyNoticeTile({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: LoopPrefs.instance.acknowledgedPolicyNotice,
      builder: (context, seen, _) {
        if (seen == policyNoticeId) return const SizedBox.shrink();
        return Card(
          key: const ValueKey('policy-notice-tile'),
          child: ListTile(
            leading: const Icon(Icons.info_outline, color: LT.lime),
            title: Text(
              l.policyNoticeTitle,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(l.policyNoticeEffective(policyEffectiveDate)),
            onTap: () => showPolicyNotice(context),
          ),
        );
      },
    );
  }
}

/// (2026-11-02: no longer on the library — it covered too much; the
/// announcement center lists it. Kept for screens that still want a bar.)
/// Visible until acknowledged, and always accessible in Settings.
class PolicyNoticeBanner extends StatelessWidget {
  const PolicyNoticeBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: LoopPrefs.instance.acknowledgedPolicyNotice,
      builder: (context, seen, _) {
        if (seen == policyNoticeId) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Material(
            color: LT.surface2,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => showPolicyNotice(context),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: LT.lime, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${l.policyNoticeTitle} · ${l.policyNoticeEffective(policyEffectiveDate)}',
                        style: const TextStyle(color: LT.t1, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: () => showPolicyNotice(context),
                      child: Text(l.policyNoticeRead),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showPolicyNotice(BuildContext context) {
  final l = L10n.of(context);
  return showDialog<void>(
    context: context,
    builder:
        (dialogContext) => AlertDialog(
          backgroundColor: LT.surface,
          title: Text(l.policyNoticeTitle),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.policyNoticeEffective(policyEffectiveDate),
                  style: const TextStyle(
                    color: LT.lime,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                Text(l.policyNoticeBody),
                const SizedBox(height: 12),
                for (final item in [
                  (l.termsTitle, LegalDoc.terms),
                  (l.privacyTitle, LegalDoc.privacy),
                  (l.refundScreenTitle, LegalDoc.refund),
                ])
                  TextButton(
                    onPressed:
                        () => LegalDocScreen.open(dialogContext, item.$2),
                    child: Text(item.$1),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(l.close),
            ),
            TextButton(
              onPressed: () async {
                await LoopPrefs.instance.acknowledgePolicyNotice(
                  policyNoticeId,
                );
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
              },
              child: Text(l.policyNoticeAcknowledge),
            ),
          ],
        ),
  );
}
