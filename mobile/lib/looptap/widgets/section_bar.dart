// LoopTap — SONG section bar (README §4.2, screens.jsx SectionBar).
// Horizontally-scrolling section chips; the active chip shows an inline rename
// input, a −/+ repeat stepper, and a delete ×. A dashed + adds a section.
// Far right: Play song / Stop song.
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../models/loop_models.dart';
import '../music/section_links.dart';
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
    final groups = linkGroupNumbers(sections);
    final active =
        activeIdx >= 0 && activeIdx < sections.length
            ? sections[activeIdx]
            : null;
    final linked =
        active?.linkId == null
            ? 0
            : sections.where((s) => s.linkId == active!.linkId).length;
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        children: [
          LtLabel(L10n.of(context).ltSectionsLabel),
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
                    // key by id so each chip's edit state follows its section
                    // across reorder/duplicate (not the stale list position).
                    key: ValueKey(sections[i].id),
                    section: sections[i],
                    linkGroup: groups[sections[i].linkId],
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
          if (linked > 1) ...[
            const SizedBox(width: 8),
            Text(
              ko
                  ? '연결된 구간 $linked개에 함께 적용'
                  : 'Edits apply to $linked linked sections',
              key: const ValueKey('section-link-notice'),
              style: LTType.inter(size: 10, color: LT.t3),
            ),
          ],
          const SizedBox(width: 10),
          _PlaySongButton(songMode: songMode, onTap: onPlaySong),
        ],
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  const _Chip({
    super.key,
    required this.section,
    this.linkGroup,
    required this.active,
    required this.canDelete,
    required this.onTap,
    required this.onRename,
    required this.onRepeats,
    required this.onDelete,
    required this.onLongPress,
  });

  final Section section;

  /// AR-001 link group number (null = not linked).
  final int? linkGroup;
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
    // Sync the field to the section name when it's not being typed into: any
    // inactive chip, or an active chip still on its auto position-letter (which
    // relabel changes on reorder). A custom (autoName == false) active chip is
    // left alone so the user's typing isn't clobbered.
    if (_ctl.text != widget.section.name &&
        (!widget.active || widget.section.autoName)) {
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
      onSecondaryTap: widget.onLongPress, // desktop right-click menu
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
            if (widget.linkGroup != null) ...[
              LinkBadge(
                key: ValueKey('section-link-${s.id}'),
                group: widget.linkGroup!,
              ),
              const SizedBox(width: 4),
            ],
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

/// AR-001: link icon + group number, tinted per group.
class LinkBadge extends StatelessWidget {
  const LinkBadge({super.key, required this.group});
  final int group;

  static const _colors = [LT.blue, LT.amber, LT.pink, LT.lime];

  @override
  Widget build(BuildContext context) {
    final color = _colors[(group - 1) % _colors.length];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.link, size: 12, color: color),
        Text(
          '$group',
          style: LTType.mono(size: 10, weight: FontWeight.w700, color: color),
        ),
      ],
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
            Text(
                songMode
                    ? L10n.of(context).ltSectionStopSong
                    : L10n.of(context).ltSectionPlaySong,
                style: LTType.inter(size: 12, weight: FontWeight.w800, color: songMode ? LT.bg : LT.t1)),
          ],
        ),
      ),
    );
  }
}
