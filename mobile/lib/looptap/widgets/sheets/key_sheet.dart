// LoopTap — Key & scale sheet (README §6). 12 root buttons + 4 scales.
// "Only in-key notes show on the pads — you can't play a wrong note."
import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../music/theory.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

/// Localized display name for a `kScales` id. The scale table lives in
/// music/theory.dart (no BuildContext there), so the label is resolved here and
/// shared by the key sheet, the editor's key pill and the song cards.
String ltScaleLabel(L10n l, String scale) => switch (scale) {
      'minor' => l.keyPickerMinor,
      'major' => l.keyPickerMajor,
      'pentatonic' => l.ltScalePenta,
      'dorian' => l.ltScaleDorian,
      _ => scale,
    };

Future<void> showKeySheet(
  BuildContext context, {
  required String root,
  required String scale,
  required void Function(String root, String scale) onPick,
}) {
  return showLtModal(
    context,
    child: _KeySheet(initialRoot: root, initialScale: scale, onPick: onPick),
  );
}

class _KeySheet extends StatefulWidget {
  const _KeySheet({required this.initialRoot, required this.initialScale, required this.onPick});
  final String initialRoot;
  final String initialScale;
  final void Function(String, String) onPick;

  @override
  State<_KeySheet> createState() => _KeySheetState();
}

class _KeySheetState extends State<_KeySheet> {
  late String _root = widget.initialRoot;
  late String _scale = widget.initialScale;

  void _pick(String r, String s) {
    setState(() {
      _root = r;
      _scale = s;
    });
    widget.onPick(r, s);
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l.ltKeySheetTitle, style: LTType.inter(size: 15, weight: FontWeight.w800, color: LT.t1)),
        const SizedBox(height: 14),
        LtLabel(l.ltKeyRoot),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 6,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.6,
          children: [
            for (final r in kNoteNames)
              _PickButton(
                label: r,
                selected: r == _root,
                onTap: () => _pick(r, _scale),
              ),
          ],
        ),
        const SizedBox(height: 16),
        LtLabel(l.ltKeyScale),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 4.2,
          children: [
            for (final s in kScales.keys)
              _PickButton(
                label: ltScaleLabel(l, s),
                selected: s == _scale,
                tinted: true,
                onTap: () => _pick(_root, s),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text(l.ltKeyHint, style: LTType.inter(size: 11, color: LT.t3)),
      ],
    );
  }
}

class _PickButton extends StatelessWidget {
  const _PickButton({required this.label, required this.selected, required this.onTap, this.tinted = false});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? (tinted ? LT.lime.withValues(alpha: 0.12) : LT.lime) : LT.surface2;
    final fg = selected ? (tinted ? LT.lime : LT.bg) : LT.t1;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? LT.lime : LT.border),
        ),
        child: Text(label, style: LTType.inter(size: 13, weight: FontWeight.w700, color: fg)),
      ),
    );
  }
}
