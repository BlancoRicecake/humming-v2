// ui-001 stage 1 (docs/specs/ui/ui-001-desktop-b2-layout.md "공통: 상단 바"):
// the desktop editor's single 52 px top bar. It replaces the phone top bar
// and the bottom TransportBar on desktop only; every control calls the
// editor's existing handler (play/stop/record, metronome, count-in, range
// loop, BPM entry and stepper, key sheet, swing, section length, undo/redo,
// mixer, guided start, clear track, export). The view switch (편곡 | 편집)
// arrives in stage 3 and is not shown yet.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';
import 'shortcut_help.dart';
import 'transport_bar.dart' show BarsToggle, BpmStepper, promptBpm;

/// `bar.beat.16th` (1-based) of a playhead in 16th steps.
String playheadLabel(double step) {
  final s = step.isFinite && step > 0 ? step.floor() : 0;
  return '${s ~/ 16 + 1}.${(s % 16) ~/ 4 + 1}.${s % 4 + 1}';
}

class DesktopTopBar extends StatefulWidget {
  const DesktopTopBar({
    super.key,
    required this.titleController,
    required this.onTitleChanged,
    required this.dirty,
    required this.savedAt,
    required this.savedFlash,
    required this.onBack,
    required this.metro,
    required this.onMetro,
    required this.countIn,
    required this.onCountIn,
    required this.rangeLoop,
    required this.onLoop,
    required this.playing,
    required this.recording,
    required this.showRecord,
    required this.onPlay,
    required this.onStop,
    required this.onRec,
    required this.playhead,
    required this.bpm,
    required this.onBpm,
    required this.keyLabel,
    required this.onKey,
    required this.swing,
    required this.onSwing,
    required this.bars,
    required this.onBars,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.onMixer,
    required this.onGuide,
    required this.onClear,
    required this.onShortcuts,
    required this.onExport,
    required this.pro,
  });

  final TextEditingController titleController;
  final ValueChanged<String> onTitleChanged;
  final bool dirty;
  final DateTime? savedAt;
  final bool savedFlash;
  final VoidCallback onBack;
  final bool metro;
  final ValueChanged<bool> onMetro;
  final bool countIn;
  final ValueChanged<bool> onCountIn;
  final bool rangeLoop;
  final VoidCallback? onLoop;
  final bool playing, recording, showRecord;
  final VoidCallback onPlay, onStop, onRec;
  final ValueListenable<double> playhead;
  final int bpm;
  final ValueChanged<int> onBpm;
  final String keyLabel;
  final VoidCallback onKey;
  final double swing; // 0..0.6
  final ValueChanged<double> onSwing;
  final int bars;
  final ValueChanged<int> onBars;
  final bool canUndo, canRedo;
  final VoidCallback onUndo, onRedo, onMixer, onGuide, onClear, onShortcuts, onExport;
  final bool pro;

  static const double height = 52;

  @override
  State<DesktopTopBar> createState() => _DesktopTopBarState();
}

class _DesktopTopBarState extends State<DesktopTopBar> {
  final _settings = MenuController();
  final _more = MenuController();

  Future<void> _typeBpm() async {
    final v = await promptBpm(context, widget.bpm);
    // the editor may have closed (back / Esc) while the dialog was up
    if (!mounted) return;
    if (v != null && v != widget.bpm) widget.onBpm(v);
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Container(
      key: const ValueKey('desktop-top-bar'),
      height: DesktopTopBar.height,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: LT.bg,
        border: Border(bottom: BorderSide(color: LT.border)),
      ),
      // [1fr] [auto] [1fr]: the transport is centred on the window while the
      // right group fits beside it; on a narrow window (960 minimum) the
      // centre slides left and the title takes what remains (ellipsis).
      child: LayoutBuilder(
        builder: (context, c) => CustomMultiChildLayout(
          delegate: _TopBarLayout(),
          children: [
            LayoutId(id: _Slot.left, child: _left(l)),
            LayoutId(id: _Slot.center, child: _center(l)),
            LayoutId(id: _Slot.right, child: _right(l, compact: c.maxWidth < 1068)),
          ],
        ),
      ),
    );
  }

  // ── left: back · title / save state ──
  Widget _left(L10n l) {
    final t = widget.savedAt;
    final time = t == null ? null : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    final saved = !widget.dirty && time != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolButton(
          key: const ValueKey('top-back'),
          icon: Symbols.arrow_back,
          tooltip: l.topBarBackToSongs,
          onTap: widget.onBack,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: TextField(
                  key: const ValueKey('top-title'),
                  controller: widget.titleController,
                  onChanged: widget.onTitleChanged,
                  cursorColor: LT.lime,
                  maxLines: 1,
                  style: LTType.inter(size: 14, weight: FontWeight.w700),
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 2),
                    border: InputBorder.none,
                  ),
                ),
              ),
              Row(
                key: const ValueKey('top-save-state'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (saved) ...[
                    const Ms(Symbols.check_circle, size: 12, color: LT.lime, fill: 1),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      widget.dirty ? l.ltEditorUnsaved : (time == null ? '' : l.topBarAutoSaved(time)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LTType.mono(
                        size: 10,
                        weight: FontWeight.w600,
                        color: widget.savedFlash ? LT.lime : LT.t3,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── centre: metronome · count-in · loop · stop · play · record · song info ──
  Widget _center(L10n l) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToolButton(
          key: const ValueKey('top-metro'),
          icon: Symbols.straighten,
          tooltip: l.metronomeTitle,
          active: widget.metro,
          onTap: () => widget.onMetro(!widget.metro),
        ),
        const SizedBox(width: 6),
        _ToolButton(
          key: const ValueKey('top-count-in'),
          icon: Symbols.timer,
          tooltip: l.ltTransportCountIn,
          active: widget.countIn,
          onTap: () => widget.onCountIn(!widget.countIn),
        ),
        const SizedBox(width: 6),
        _ToolButton(
          key: const ValueKey('top-loop'),
          icon: Symbols.repeat,
          tooltip: withShortcut(context, l.topBarRangeLoop, DesktopShortcutId.rangeLoop),
          active: widget.rangeLoop,
          onTap: widget.onLoop,
        ),
        const SizedBox(width: 12),
        _ToolButton(
          key: const ValueKey('top-stop'),
          icon: Symbols.stop,
          tooltip: l.pendingStop,
          onTap: widget.onStop,
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: withShortcut(context, l.shortcutPlay, DesktopShortcutId.play),
          child: GestureDetector(
            key: const ValueKey('top-play'),
            onTap: widget.onPlay,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: LT.lime,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: LT.lime.withValues(alpha: 0.4), blurRadius: 18)],
              ),
              child: Center(
                child: Ms(
                  widget.playing ? Symbols.pause : Symbols.play_arrow,
                  size: 22,
                  color: LT.bg,
                  fill: 1,
                ),
              ),
            ),
          ),
        ),
        if (widget.showRecord) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: withShortcut(context, l.shortcutRecord, DesktopShortcutId.record),
            child: GestureDetector(
              key: const ValueKey('top-record'),
              onTap: widget.onRec,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: widget.recording ? LT.danger : LT.surface2,
                  shape: BoxShape.circle,
                  border: Border.all(color: LT.danger, width: 2),
                ),
                child: Center(
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: widget.recording ? LT.t1 : LT.danger,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(width: 12),
        _songInfo(l),
      ],
    );
  }

  Widget _divider() => Container(
    width: 1,
    height: 18,
    margin: const EdgeInsets.symmetric(horizontal: 10),
    color: LT.borderStrong,
  );

  Widget _songInfo(L10n l) {
    return MenuAnchor(
      controller: _settings,
      alignmentOffset: const Offset(0, 6),
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(LT.surface),
        side: WidgetStatePropertyAll(BorderSide(color: LT.border)),
        padding: WidgetStatePropertyAll(EdgeInsets.all(14)),
      ),
      menuChildren: [_SongSettings(top: widget)],
      builder: (context, controller, _) => GestureDetector(
        key: const ValueKey('top-song-info'),
        onSecondaryTap: () => controller.isOpen ? controller.close() : controller.open(),
        child: Container(
          height: 36,
          padding: const EdgeInsets.only(left: 12, right: 4),
          decoration: BoxDecoration(
            color: LT.surface2,
            borderRadius: BorderRadius.circular(LTRadius.pill),
            border: Border.all(color: LT.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: l.topBarPosition,
                child: ValueListenableBuilder<double>(
                  valueListenable: widget.playhead,
                  builder: (_, step, _) => SizedBox(
                    width: 56,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        playheadLabel(step),
                        key: const ValueKey('top-position'),
                        maxLines: 1,
                        style: LTType.mono(size: 13, weight: FontWeight.w700, color: LT.t1),
                      ),
                    ),
                  ),
                ),
              ),
              _divider(),
              Tooltip(
                message: l.topBarBpmTap,
                child: GestureDetector(
                  key: const ValueKey('top-bpm'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _typeBpm,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text('${widget.bpm}', style: LTType.mono(size: 13, weight: FontWeight.w700, color: LT.t1)),
                      const SizedBox(width: 3),
                      Text('BPM', style: LTType.inter(size: 9, color: LT.t3)),
                    ],
                  ),
                ),
              ),
              _divider(),
              Tooltip(
                message: l.topBarKeyTap,
                child: GestureDetector(
                  key: const ValueKey('top-key'),
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onKey,
                  child: Text(
                    widget.keyLabel,
                    style: LTType.inter(size: 12, weight: FontWeight.w700, color: LT.lime),
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Tooltip(
                message: l.topBarSongSettings,
                child: InkResponse(
                  key: const ValueKey('top-song-settings'),
                  radius: 16,
                  onTap: () => controller.isOpen ? controller.close() : controller.open(),
                  child: const SizedBox(
                    width: 28,
                    height: 32,
                    child: Center(child: Ms(Symbols.expand_more, size: 18, color: LT.t2)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── right: undo · redo · more · shortcuts · export ──
  Widget _right(L10n l, {required bool compact}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Opacity(
          opacity: widget.canUndo ? 1 : 0.35,
          child: _ToolButton(
            key: const ValueKey('top-undo'),
            icon: Symbols.undo,
            tooltip: withShortcut(context, l.ltEditorUndo, DesktopShortcutId.undo),
            onTap: widget.canUndo ? widget.onUndo : null,
          ),
        ),
        const SizedBox(width: 6),
        Opacity(
          opacity: widget.canRedo ? 1 : 0.35,
          child: _ToolButton(
            key: const ValueKey('top-redo'),
            icon: Symbols.redo,
            tooltip: withShortcut(context, l.ltEditorRedo, DesktopShortcutId.redo),
            onTap: widget.canRedo ? widget.onRedo : null,
          ),
        ),
        const SizedBox(width: 6),
        MenuAnchor(
          controller: _more,
          style: const MenuStyle(
            backgroundColor: WidgetStatePropertyAll(LT.surface),
            side: WidgetStatePropertyAll(BorderSide(color: LT.border)),
          ),
          menuChildren: [
            MenuItemButton(
              key: const ValueKey('top-more-mixer'),
              leadingIcon: const Ms(Symbols.tune, size: 18, color: LT.t2),
              trailingIcon: Text(
                desktopShortcutKeys(context, DesktopShortcutId.mixer),
                style: LTType.mono(size: 11, color: LT.t3),
              ),
              onPressed: widget.onMixer,
              child: Text(l.ltMixerTitle),
            ),
            MenuItemButton(
              key: const ValueKey('top-more-guide'),
              leadingIcon: const Ms(Symbols.auto_awesome, size: 18, color: LT.t2),
              onPressed: widget.onGuide,
              child: Text(l.ltGuidedStart),
            ),
            MenuItemButton(
              key: const ValueKey('top-more-clear'),
              leadingIcon: const Ms(Symbols.backspace, size: 18, color: LT.t2),
              onPressed: widget.onClear,
              child: Text(l.ltTransportClearTrack),
            ),
          ],
          builder: (context, controller, _) => _ToolButton(
            key: const ValueKey('top-more'),
            icon: Symbols.more_horiz,
            tooltip: l.topBarMore,
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
          ),
        ),
        const SizedBox(width: 6),
        _ToolButton(
          key: const ValueKey('top-shortcuts'),
          icon: Symbols.help,
          tooltip: withShortcut(context, l.topBarShortcuts, DesktopShortcutId.help),
          onTap: widget.onShortcuts,
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: l.projectOptionExport,
          child: GestureDetector(
            key: const ValueKey('top-export'),
            onTap: widget.onExport,
            child: Container(
              height: 36,
              padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
              decoration: BoxDecoration(
                color: LT.surface2,
                borderRadius: BorderRadius.circular(LTRadius.pill),
                border: Border.all(color: LT.border),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Ms(Symbols.ios_share, size: 16, color: LT.t1),
                  if (!compact) ...[
                    const SizedBox(width: 6),
                    Text(
                      l.projectOptionExport,
                      style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t1),
                    ),
                  ],
                  if (!widget.pro) ...[
                    const SizedBox(width: 6),
                    Container(
                      key: const ValueKey('top-export-pro'),
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: LT.lime.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(LTRadius.chip),
                      ),
                      child: Text(
                        l.topBarProBadge,
                        style: LTType.inter(size: 10, weight: FontWeight.w900, color: LT.lime),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

enum _Slot { left, center, right }

/// Right group at its natural width; centre group centred unless that would
/// hit the right group (then it sits just left of it); left group gets the
/// rest. Gaps 12 px.
class _TopBarLayout extends MultiChildLayoutDelegate {
  static const _gap = 12.0;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final r = layoutChild(_Slot.right, loose);
    final c = layoutChild(_Slot.center, loose);
    final cx = math.max(0.0, math.min((size.width - c.width) / 2, size.width - r.width - _gap - c.width));
    final l = layoutChild(_Slot.left, BoxConstraints(maxWidth: math.max(0.0, cx - _gap), maxHeight: size.height));
    double y(Size s) => (size.height - s.height) / 2;
    positionChild(_Slot.left, Offset(0, y(l)));
    positionChild(_Slot.center, Offset(cx, y(c)));
    positionChild(_Slot.right, Offset(size.width - r.width, y(r)));
  }

  @override
  bool shouldRelayout(_TopBarLayout oldDelegate) => false;
}

/// The song-settings popover: BPM stepper, swing 0–60 %, section length.
class _SongSettings extends StatelessWidget {
  const _SongSettings({required this.top});
  final DesktopTopBar top;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    Widget label(String text, [Widget? trailing]) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(text, style: LTType.inter(size: 11, weight: FontWeight.w700, color: LT.t2)),
          if (trailing != null) ...[const Spacer(), trailing],
        ],
      ),
    );
    return SizedBox(
      key: const ValueKey('song-settings-popover'),
      width: 260,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          label(l.topBarTempo),
          BpmStepper(key: const ValueKey('song-settings-bpm'), bpm: top.bpm, onBpm: top.onBpm),
          const SizedBox(height: 14),
          Tooltip(
            message: l.topBarSwingHint,
            child: label(
              l.ltTransportSwing,
              Text('${(top.swing * 100).round()}%', style: LTType.mono(size: 11, color: LT.t3)),
            ),
          ),
          Slider(
            key: const ValueKey('song-settings-swing'),
            min: 0,
            max: 60,
            value: (top.swing * 100).clamp(0, 60),
            onChanged: (v) => top.onSwing(v / 100),
          ),
          const SizedBox(height: 6),
          label(l.topBarSectionLength),
          BarsToggle(key: const ValueKey('song-settings-bars'), bars: top.bars, onBars: top.onBars),
        ],
      ),
    );
  }
}

/// A 36 px desktop icon button: on = lime 14 % + lime border + lime icon,
/// off = surface2 + border + t2. Always has a tooltip.
class _ToolButton extends StatelessWidget {
  const _ToolButton({super.key, required this.icon, required this.tooltip, this.onTap, this.active = false});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: LTMotion.state,
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active ? LT.lime.withValues(alpha: 0.14) : LT.surface2,
          shape: BoxShape.circle,
          border: Border.all(color: active ? LT.lime : LT.border),
        ),
        child: Center(child: Ms(icon, size: 18, color: active ? LT.lime : LT.t2)),
      ),
    ),
  );
}
