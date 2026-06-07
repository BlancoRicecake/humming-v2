// LoopTap — SONG section bar (README §4.2, screens.jsx SectionBar).
// Horizontally-scrolling section chips; the active chip shows an inline rename
// input, a −/+ repeat stepper, and a delete ×. A dashed + adds a section.
// Far right: Play song / Stop song.
import 'package:flutter/material.dart';

import '../models/loop_models.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';

class SectionBar extends StatelessWidget {
  const SectionBar({
    super.key,
    required this.sections,
    required this.activeIdx,
    required this.songMode,
    required this.onSwitch,
    required this.onAdd,
    required this.onRename,
    required this.onRepeats,
    required this.onDelete,
    required this.onLongPress,
    required this.onPlaySong,
  });

  final List<Section> sections;
  final int activeIdx;
  final bool songMode;
  final ValueChanged<int> onSwitch;
  final VoidCallback onAdd;
  final void Function(int idx, String name) onRename;
  final void Function(int idx, int repeats) onRepeats;
  final ValueChanged<int> onDelete;
  final ValueChanged<int> onLongPress;
  final VoidCallback onPlaySong;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          const LtLabel('Song'),
          const SizedBox(width: 10),
          Expanded(
            child: SizedBox(
              height: 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: sections.length + 1,
                separatorBuilder: (_, __) => const SizedBox(width: 6),
                itemBuilder: (context, i) {
                  if (i == sections.length) {
                    return _AddChip(onTap: onAdd);
                  }
                  return _Chip(
                    section: sections[i],
                    active: i == activeIdx,
                    canDelete: sections.length > 1,
                    onTap: () => onSwitch(i),
                    onRename: (name) => onRename(i, name),
                    onRepeats: (r) => onRepeats(i, r),
                    onDelete: () => onDelete(i),
                    onLongPress: () => onLongPress(i),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 10),
          _PlaySongButton(songMode: songMode, onTap: onPlaySong),
        ],
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({
    required this.section,
    required this.active,
    required this.canDelete,
    required this.onTap,
    required this.onRename,
    required this.onRepeats,
    required this.onDelete,
    required this.onLongPress,
  });

  final Section section;
  final bool active;
  final bool canDelete;
  final VoidCallback onTap;
  final ValueChanged<String> onRename;
  final ValueChanged<int> onRepeats;
  final VoidCallback onDelete;
  final VoidCallback onLongPress;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  late final TextEditingController _ctl = TextEditingController(text: widget.section.name);

  @override
  void didUpdateWidget(_Chip old) {
    super.didUpdateWidget(old);
    if (_ctl.text != widget.section.name && !widget.active) {
      _ctl.text = widget.section.name;
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.active;
    final s = widget.section;
    return GestureDetector(
      onTap: a ? null : widget.onTap,
      onLongPress: widget.onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: a ? LT.lime.withValues(alpha: 0.12) : LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.chip),
          border: Border.all(color: a ? LT.lime : LT.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (a)
              IntrinsicWidth(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 16, maxWidth: 70),
                  child: TextField(
                    controller: _ctl,
                    onChanged: widget.onRename,
                    cursorColor: LT.lime,
                    style: LTType.inter(size: 12, weight: FontWeight.w800, color: LT.lime),
                    decoration: const InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                    ),
                  ),
                ),
              )
            else
              Text(s.name, style: LTType.inter(size: 12, weight: FontWeight.w800, color: LT.t1)),
            const SizedBox(width: 4),
            if (a) ...[
              _MiniBtn('−', () => widget.onRepeats(s.repeats - 1)),
              SizedBox(
                width: 22,
                child: Text('×${s.repeats}',
                    textAlign: TextAlign.center, style: LTType.mono(size: 11, color: LT.t2)),
              ),
              _MiniBtn('+', () => widget.onRepeats(s.repeats + 1)),
              if (widget.canDelete)
                GestureDetector(
                  onTap: widget.onDelete,
                  child: const Padding(
                    padding: EdgeInsets.only(left: 2),
                    child: Ms(LtIcons.close, size: 14, color: LT.t3),
                  ),
                ),
            ] else
              Text('×${s.repeats}', style: LTType.mono(size: 11, color: LT.t3)),
          ],
        ),
      ),
    );
  }
}

class _MiniBtn extends StatelessWidget {
  const _MiniBtn(this.glyph, this.onTap);
  final String glyph;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 18,
        height: 18,
        child: Center(child: Text(glyph, style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.t1))),
      ),
    );
  }
}

class _AddChip extends StatelessWidget {
  const _AddChip({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(LTRadius.chip),
          border: Border.all(color: LT.border, style: BorderStyle.solid),
        ),
        child: const Center(child: Ms(LtIcons.add, size: 18, color: LT.t2)),
      ),
    );
  }
}

class _PlaySongButton extends StatelessWidget {
  const _PlaySongButton({required this.songMode, required this.onTap});
  final bool songMode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: songMode ? LT.lime : LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.pill),
          border: Border.all(color: songMode ? LT.lime : LT.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Ms(songMode ? LtIcons.stop : LtIcons.playlistPlay,
                size: 16, color: songMode ? LT.bg : LT.lime, fill: 1),
            const SizedBox(width: 6),
            Text(songMode ? 'Stop song' : 'Play song',
                style: LTType.inter(size: 12, weight: FontWeight.w800, color: songMode ? LT.bg : LT.t1)),
          ],
        ),
      ),
    );
  }
}
