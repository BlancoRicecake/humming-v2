// LoopTap — Settings sheet (README §3). Metronome / Haptics toggles, Language
// segmented, Theme (Neon dark), About. Local UI state for v1 (mirrors prototype).
import 'package:flutter/material.dart';

import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showSettingsSheet(BuildContext context) {
  return showLtModal(context, width: 400, child: const _SettingsSheet());
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet();

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  bool _metro = true;
  bool _haptics = true;
  int _lang = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Settings', style: LTType.inter(size: 17, weight: FontWeight.w800, color: LT.t1)),
            IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
          ],
        ),
        const SizedBox(height: 16),
        _Row(
          icon: LtIcons.straighten,
          title: 'Metronome click',
          sub: 'Play a click while recording',
          right: _MiniSwitch(on: _metro, onChanged: (v) => setState(() => _metro = v)),
        ),
        _Row(
          icon: LtIcons.vibration,
          title: 'Haptics',
          sub: 'Buzz on pad hits',
          right: _MiniSwitch(on: _haptics, onChanged: (v) => setState(() => _haptics = v)),
        ),
        _Row(
          icon: LtIcons.translate,
          title: 'Language',
          right: _Segmented(
            options: const ['한국어', 'EN'],
            index: _lang,
            onChanged: (i) => setState(() => _lang = i),
          ),
        ),
        _Row(
          icon: LtIcons.palette,
          title: 'Theme',
          sub: 'Neon dark',
          right: Text('Default', style: LTType.mono(size: 11, color: LT.t3)),
        ),
        const _Row(icon: LtIcons.info, title: 'About', sub: 'LoopTap · v0.4'),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.icon, required this.title, this.sub, this.right});
  final IconData icon;
  final String title;
  final String? sub;
  final Widget? right;

  @override
  Widget build(BuildContext context) {
    return Container(
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
        ],
      ),
    );
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
