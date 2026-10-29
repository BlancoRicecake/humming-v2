// ui-001 stage 2 (docs/specs/ui/ui-001-desktop-b2-layout.md "2단계 — 섹션 띠와
// 눈금 구간 반복"): desktop-only pieces of the track header row.
//
// DesktopSectionBand replaces the standalone SectionBar row on desktop: a
// 16 px strip of section cells above the ruler. Click = select, double-click
// = rename, right-click = the existing section menu, wheel = repeats, `+` =
// add section; LinkBadge, the linked-sections notice and Play song stay.
//
// DesktopSoloHeader replaces AuditionBar's Solo part and SoloStatusNotice on
// desktop: shown only while a Solo is active, with the same compare / clear
// handlers and the quiet-Solo warning as an icon tooltip (click = 강약 보기).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/generated/app_localizations.dart';
import '../models/loop_models.dart';
import '../music/section_links.dart';
import '../music/solo_status.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';
import 'section_bar.dart' show LinkBadge;
import 'sheets/lt_modal.dart';

class DesktopSectionBand extends StatelessWidget {
  const DesktopSectionBand({
    super.key,
    required this.sections,
    required this.activeIdx,
    required this.songMode,
    required this.onSwitch,
    required this.onAdd,
    required this.onRename,
    required this.onRepeats,
    required this.onMenu,
    required this.onPlaySong,
  });

  final List<Section> sections;
  final int activeIdx;
  final bool songMode;
  final ValueChanged<int> onSwitch;
  final VoidCallback onAdd;
  final void Function(int idx, String name) onRename;
  final void Function(int idx, int repeats) onRepeats;
  final ValueChanged<int> onMenu;
  final VoidCallback onPlaySong;

  static const double height = 16;

  Future<void> _rename(BuildContext context, int idx) async {
    final before = sections[idx].name;
    final name = await showLtModal<String>(
      context,
      width: 300,
      child: _RenameField(initial: before),
    );
    // the editor (or this band) may be gone by the time the dialog answers
    if (!context.mounted || idx >= sections.length) return;
    if (name != null && name.trim().isNotEmpty && name != before) {
      onRename(idx, name.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final groups = linkGroupNumbers(sections);
    final active = activeIdx >= 0 && activeIdx < sections.length ? sections[activeIdx] : null;
    final linked = active?.linkId == null ? 0 : sections.where((s) => s.linkId == active!.linkId).length;
    return SizedBox(
      key: const ValueKey('desktop-section-band'),
      height: height,
      child: Row(
        children: [
          Flexible(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              shrinkWrap: true,
              itemCount: sections.length,
              separatorBuilder: (_, _) => const SizedBox(width: 4),
              itemBuilder: (context, i) {
                final s = sections[i];
                final on = i == activeIdx;
                return Tooltip(
                  message: l.bandChipTooltip,
                  waitDuration: const Duration(milliseconds: 600),
                  child: Listener(
                    onPointerSignal: (e) {
                      if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
                        onRepeats(i, s.repeats + (e.scrollDelta.dy < 0 ? 1 : -1));
                      }
                    },
                    child: GestureDetector(
                      // the same per-section key the phone SectionBar chip uses
                      key: ValueKey(s.id),
                      onTap: () => onSwitch(i),
                      onDoubleTap: () => _rename(context, i),
                      onSecondaryTap: () => onMenu(i),
                      onLongPress: () => onMenu(i),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        decoration: BoxDecoration(
                          color: on ? LT.lime.withValues(alpha: 0.16) : LT.surface2,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: on ? LT.lime : LT.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (groups[s.linkId] != null) ...[
                              LinkBadge(key: ValueKey('section-link-${s.id}'), group: groups[s.linkId]!),
                              const SizedBox(width: 3),
                            ],
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 120),
                              child: Text(
                                s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: LTType.inter(size: 10, weight: FontWeight.w800, color: on ? LT.lime : LT.t1, height: 1),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '×${s.repeats}',
                              key: ValueKey('section-repeats-${s.id}'),
                              style: LTType.mono(size: 9, color: on ? LT.lime : LT.t3),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 4),
          // outside the scrolling cells: always reachable
          Tooltip(
            message: l.bandAddSection,
            child: GestureDetector(
              key: const ValueKey('section-add'),
              onTap: onAdd,
              child: Container(
                width: 22,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: LT.border),
                ),
                child: const Center(child: Ms(LtIcons.add, size: 12, color: LT.t2)),
              ),
            ),
          ),
          const Spacer(),
          if (linked > 1) ...[
            const SizedBox(width: 8),
            Text(
              l.bandLinkedNotice(linked),
              key: const ValueKey('section-link-notice'),
              style: LTType.inter(size: 10, color: LT.t3, height: 1),
            ),
          ],
          const SizedBox(width: 8),
          GestureDetector(
            key: const ValueKey('section-play-song'),
            onTap: onPlaySong,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: songMode ? LT.lime : LT.surface2,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: songMode ? LT.lime : LT.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Ms(songMode ? LtIcons.stop : LtIcons.playlistPlay, size: 12, color: songMode ? LT.bg : LT.lime, fill: 1),
                  const SizedBox(width: 4),
                  Text(
                    songMode ? l.ltSectionStopSong : l.bandSongPlay,
                    style: LTType.inter(size: 10, weight: FontWeight.w800, color: songMode ? LT.bg : LT.t1, height: 1),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RenameField extends StatefulWidget {
  const _RenameField({required this.initial});
  final String initial;
  @override
  State<_RenameField> createState() => _RenameFieldState();
}

class _RenameFieldState extends State<_RenameField> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop(_ctl.text);

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l.bandRenameTitle, style: LTType.inter(size: 15, weight: FontWeight.w800)),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('section-rename-field'),
          controller: _ctl,
          autofocus: true,
          // no length cap: like the phone chip's field, an existing long name
          // is kept as it is
          onSubmitted: (_) => _submit(),
          style: LTType.inter(size: 14, weight: FontWeight.w700),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(l.cancel)),
            const SizedBox(width: 8),
            FilledButton(key: const ValueKey('section-rename-apply'), onPressed: _submit, child: Text(l.apply)),
          ],
        ),
      ],
    );
  }
}

/// Solo controls for the desktop track header (only while a Solo is active).
class DesktopSoloHeader extends StatelessWidget {
  const DesktopSoloHeader({
    super.key,
    required this.soloCount,
    required this.bypassSolo,
    required this.issues,
    required this.enabled,
    required this.onCompare,
    required this.onClear,
    this.onOpenVelocity,
  });

  final int soloCount;
  final bool bypassSolo, enabled;
  final List<SoloStatus> issues;
  final VoidCallback onCompare, onClear;
  final ValueChanged<String>? onOpenVelocity;

  static String reason(L10n l, SoloStatus s) => switch (s.issue) {
    SoloIssue.muted => l.soloIssueMuted,
    SoloIssue.zeroVolume => l.soloIssueZeroVolume,
    SoloIssue.noNotes => l.soloIssueNoNotes,
    SoloIssue.veryQuiet => l.soloIssueVeryQuiet(s.minVelocity ?? 0, s.maxVelocity ?? 0),
  };

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final quiet = issues.where((s) => s.issue == SoloIssue.veryQuiet).firstOrNull;
    final message = issues.map((s) => '${s.label}: ${reason(l, s)}').join('\n');
    Widget link(String key, String text, VoidCallback? onTap, Color color) => GestureDetector(
      key: ValueKey(key),
      onTap: enabled ? onTap : null,
      child: Text(text, maxLines: 1, style: LTType.inter(size: 10, weight: FontWeight.w800, color: enabled ? color : LT.t3, height: 1)),
    );
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        key: const ValueKey('desktop-solo-header'),
        mainAxisSize: MainAxisSize.min,
        children: [
          link('audition-compare', bypassSolo ? l.soloCompareBack : l.soloCompareFull(soloCount), onCompare, bypassSolo ? LT.t1 : LT.lime),
          const SizedBox(width: 8),
          link('audition-clear-solo', l.soloClear, onClear, LT.t2),
          if (issues.isNotEmpty) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: quiet != null && onOpenVelocity != null ? '$message\n${l.soloIssueOpenHint}' : message,
              child: GestureDetector(
                key: const ValueKey('solo-status-notice'),
                onTap: quiet != null && onOpenVelocity != null ? () => onOpenVelocity!(quiet.id) : null,
                child: const Icon(Icons.warning_amber_rounded, size: 13, color: LT.amber),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
