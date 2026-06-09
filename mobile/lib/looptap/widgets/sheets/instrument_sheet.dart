// Instrument picker (melody / bass). Mirrors key_sheet.dart: a centered modal
// with a grid of selectable instruments. Picking is live — the host swaps the
// program + plays a preview note via onPick, so the user can audition several
// before closing. The chosen GM program persists on the song.
import 'package:flutter/material.dart';

import '../../music/instruments.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showInstrumentSheet(
  BuildContext context, {
  required String trackId,
  required String trackLabel,
  required int currentProgram,
  required void Function(int program) onPick,
}) {
  return showLtModal(
    context,
    child: _InstrumentSheet(
      trackId: trackId,
      trackLabel: trackLabel,
      currentProgram: currentProgram,
      onPick: onPick,
    ),
  );
}

class _InstrumentSheet extends StatefulWidget {
  const _InstrumentSheet({
    required this.trackId,
    required this.trackLabel,
    required this.currentProgram,
    required this.onPick,
  });
  final String trackId;
  final String trackLabel;
  final int currentProgram;
  final void Function(int program) onPick;

  @override
  State<_InstrumentSheet> createState() => _InstrumentSheetState();
}

class _InstrumentSheetState extends State<_InstrumentSheet> {
  late int _program = widget.currentProgram;

  void _pick(int program) {
    setState(() => _program = program);
    widget.onPick(program); // host swaps the live program + previews a note
  }

  @override
  Widget build(BuildContext context) {
    final list = instrumentsForTrack(widget.trackId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('${widget.trackLabel} instrument',
            style: LTType.inter(size: 15, weight: FontWeight.w800, color: LT.t1)),
        const SizedBox(height: 14),
        GridView.count(
          crossAxisCount: 2,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 3.6,
          children: [
            for (final inst in list)
              _PickButton(
                label: inst.label,
                selected: inst.program == _program,
                onTap: () => _pick(inst.program),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text('Tap to preview — the sound applies to this track.',
            style: LTType.inter(size: 11, color: LT.t3)),
      ],
    );
  }
}

class _PickButton extends StatelessWidget {
  const _PickButton({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bg = selected ? LT.lime : LT.surface2;
    final fg = selected ? LT.bg : LT.t1;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? LT.lime : LT.border),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: LTType.inter(size: 13, weight: FontWeight.w700, color: fg)),
      ),
    );
  }
}
