// LoopTap — Settings sheet (README §3). Metronome / Haptics toggles (persisted
// via LoopPrefs), Language segmented (ko/en via the shared LocaleService),
// Legal & Policies (privacy / terms / refund + open-source + contact), About.
//
// Only the Settings detail text + legal docs are localized (per product call);
// the rest of the LoopTap DAW UI stays English.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../screens/legal_doc_screen.dart';
import '../../../services/locale_service.dart';
import '../../state/loop_prefs.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

/// Support contact — same address published in the legal docs.
const String _kSupportEmail = 'heobusy@gmail.com';

Future<void> showSettingsSheet(BuildContext context) {
  return showLtModal(context, width: 400, child: const _SettingsSheet());
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late bool _metro = LoopPrefs.instance.metro.value;
  late bool _haptics = LoopPrefs.instance.haptics.value;

  void _setMetro(bool v) {
    setState(() => _metro = v);
    LoopPrefs.instance.setMetro(v);
  }

  void _setHaptics(bool v) {
    setState(() => _haptics = v);
    LoopPrefs.instance.setHaptics(v);
  }

  void _setLang(int i) {
    LocaleService.instance.setLocale(Locale(i == 0 ? 'ko' : 'en'));
  }

  Future<void> _contact() async {
    final uri = Uri(
      scheme: 'mailto',
      path: _kSupportEmail,
      query: 'subject=HumTrack',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    // null (system default) falls back to the Korean segment.
    final langIdx = LocaleService.instance.selected.value?.languageCode == 'en' ? 1 : 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l.ltSettingsTitle, style: LTType.inter(size: 17, weight: FontWeight.w800, color: LT.t1)),
            IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
          ],
        ),
        const SizedBox(height: 16),
        _Row(
          icon: LtIcons.straighten,
          title: l.ltSettingsMetronome,
          sub: l.ltSettingsMetronomeSub,
          right: _MiniSwitch(on: _metro, onChanged: _setMetro),
        ),
        _Row(
          icon: LtIcons.vibration,
          title: l.ltSettingsHaptics,
          sub: l.ltSettingsHapticsSub,
          right: _MiniSwitch(on: _haptics, onChanged: _setHaptics),
        ),
        _Row(
          icon: LtIcons.translate,
          title: l.menuLanguage,
          right: _Segmented(
            options: const ['한국어', 'EN'],
            index: langIdx,
            onChanged: _setLang,
          ),
        ),
        const SizedBox(height: 6),
        _SectionLabel(l.ltSettingsLegalSection),
        _Row(
          icon: LtIcons.privacyTip,
          title: l.privacyTitle,
          onTap: () => LegalDocScreen.open(context, LegalDoc.privacy),
        ),
        _Row(
          icon: LtIcons.description,
          title: l.termsTitle,
          onTap: () => LegalDocScreen.open(context, LegalDoc.terms),
        ),
        _Row(
          icon: LtIcons.receiptLong,
          title: l.refundScreenTitle,
          onTap: () => LegalDocScreen.open(context, LegalDoc.refund),
        ),
        _Row(
          icon: LtIcons.code,
          title: l.ltSettingsOpenSource,
          onTap: () => showLicensePage(context: context, applicationName: 'HumTrack'),
        ),
        _Row(
          icon: LtIcons.mail,
          title: l.ltSettingsContact,
          sub: _kSupportEmail,
          onTap: _contact,
        ),
        const SizedBox(height: 6),
        _Row(icon: LtIcons.info, title: l.ltSettingsAbout, sub: l.ltSettingsAboutSub),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2, bottom: 8),
      child: Text(text.toUpperCase(),
          style: LTType.mono(size: 10, weight: FontWeight.w700, color: LT.t3)),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, this.sub, this.right, this.onTap});
  final IconData icon;
  final String title;
  final String? sub;
  final Widget? right;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Container(
      constraints: const BoxConstraints(minHeight: 52),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(LTRadius.control),
        border: Border.all(color: LT.border),
      ),
      child: Row(
        children: [
          Ms(icon, size: 20, color: LT.t2),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(title, style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t1)),
                if (sub != null) Text(sub!, style: LTType.inter(size: 11, color: LT.t3)),
              ],
            ),
          ),
          if (right != null) right!,
          if (onTap != null && right == null) const Ms(LtIcons.arrowBack, size: 16, color: LT.t3),
        ],
      ),
    );
    if (onTap == null) return row;
    return GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: row);
  }
}

class _MiniSwitch extends StatelessWidget {
  const _MiniSwitch({required this.on, required this.onChanged});
  final bool on;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!on),
      child: Container(
        width: 40,
        height: 23,
        decoration: BoxDecoration(
          color: on ? LT.lime : LT.surface3,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: on ? Colors.transparent : LT.border),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 160),
          alignment: on ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: Container(
              width: 17,
              height: 17,
              decoration: BoxDecoration(color: on ? LT.bg : LT.t3, shape: BoxShape.circle),
            ),
          ),
        ),
      ),
    );
  }
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.options, required this.index, required this.onChanged});
  final List<String> options;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: LT.bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: LT.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < options.length; i++)
            GestureDetector(
              onTap: () => onChanged(i),
              child: Container(
                height: 24,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: index == i ? LT.lime : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(options[i],
                    style: LTType.inter(size: 11, weight: FontWeight.w700, color: index == i ? LT.bg : LT.t2)),
              ),
            ),
        ],
      ),
    );
  }
}
