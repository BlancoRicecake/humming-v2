// LoopTap shared atoms — Flutter ports of prototype/shared.jsx (Ms, IconBtn, Pill, Label).
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import 'tokens.dart';

/// Material Symbols glyph (prototype's Ms).
///
/// IMPORTANT: we deliberately do NOT pass the variable-font axes (fill/weight/
/// opticalSize) to [Icon]. In release builds the icon-font tree-shaker + those
/// axes leave glyphs unrendered on-device. The legacy app proves that the plain
/// `Icon(Symbols.x, size:, color:)` form renders reliably. The [fill] param is
/// kept for source-compat but intentionally ignored.
class Ms extends StatelessWidget {
  const Ms(this.icon, {super.key, this.size = 20, this.color = LT.t2, this.fill = 0});

  final IconData icon;
  final double size;
  final Color color;
  /// Kept for call-site compat; not forwarded (see class doc).
  final double fill;

  @override
  Widget build(BuildContext context) {
    return Icon(icon, size: size, color: color);
  }
}

/// Small round icon button (prototype's IconBtn).
class IconBtn extends StatelessWidget {
  const IconBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.active = false,
    this.size = 36,
    this.color,
    this.tooltip,
    this.fill = 0,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool active;
  final double size;
  final Color? color;
  final String? tooltip;
  final double fill;

  @override
  Widget build(BuildContext context) {
    final btn = GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: LTMotion.state,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: active ? LT.lime : LT.surface2,
          shape: BoxShape.circle,
          border: Border.all(color: active ? Colors.transparent : LT.border),
        ),
        child: Center(
          child: Ms(icon,
              size: (size * 0.52).roundToDouble(),
              color: active ? LT.bg : (color ?? LT.t1),
              fill: fill),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

enum PillTone { surface, lime, ghost }

/// Pill button (prototype's Pill).
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    required this.label,
    this.icon,
    this.iconColor,
    this.onTap,
    this.tone = PillTone.surface,
    this.height = 32,
    this.fontSize = 12,
    this.horizontalPadding = 12,
  });

  final String label;
  final IconData? icon;
  /// 아이콘 색을 라벨(fg) 과 따로 지정하고 싶을 때. null 이면 fg 와 동색.
  final Color? iconColor;
  final VoidCallback? onTap;
  final PillTone tone;
  final double height;
  final double fontSize;
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    late final Color bg, fg, bd;
    switch (tone) {
      case PillTone.surface:
        bg = LT.surface2;
        fg = LT.t1;
        bd = LT.border;
      case PillTone.lime:
        bg = LT.lime;
        fg = LT.bg;
        bd = Colors.transparent;
      case PillTone.ghost:
        bg = Colors.transparent;
        fg = LT.t2;
        bd = LT.border;
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(LTRadius.pill),
          border: Border.all(color: bd),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Ms(icon!, size: 15, color: iconColor ?? fg),
              const SizedBox(width: 6),
            ],
            Text(label,
                style: LTType.inter(size: fontSize, weight: FontWeight.w700, color: fg)),
          ],
        ),
      ),
    );
  }
}

/// Uppercase micro-label (prototype's Label).
class LtLabel extends StatelessWidget {
  const LtLabel(this.text, {super.key, this.color = LT.t2});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: LTType.microLabel(color));
}

/// Common glyphs used across LoopTap (README §Icons), mapped to Material Symbols.
class LtIcons {
  static const graphicEq = Symbols.graphic_eq;
  static const piano = Symbols.piano;
  static const audiotrack = Symbols.audiotrack;
  static const mic = Symbols.mic;
  static const arrowBack = Symbols.arrow_back;
  static const iosShare = Symbols.ios_share;
  static const musicNote = Symbols.music_note;
  static const save = Symbols.save;
  static const tune = Symbols.tune;
  static const settings = Symbols.settings;
  static const person = Symbols.person;
  static const add = Symbols.add;
  static const remove = Symbols.remove;
  static const chevronLeft = Symbols.chevron_left;
  static const chevronRight = Symbols.chevron_right;
  static const close = Symbols.close;
  static const stop = Symbols.stop;
  static const playArrow = Symbols.play_arrow;
  static const pause = Symbols.pause;
  static const repeat = Symbols.repeat;
  static const straighten = Symbols.straighten; // metronome
  static const timer = Symbols.timer; // count-in
  static const backspace = Symbols.backspace; // clear
  static const playlistPlay = Symbols.playlist_play;
  static const volumeUp = Symbols.volume_up;
  static const volumeOff = Symbols.volume_off;
  static const download = Symbols.download;
  static const lock = Symbols.lock;
  static const layers = Symbols.layers;
  static const progressActivity = Symbols.progress_activity;
  static const cloudDone = Symbols.cloud_done;
  static const workspacePremium = Symbols.workspace_premium;
  static const restore = Symbols.restore;
  static const vibration = Symbols.vibration;
  static const translate = Symbols.translate;
  static const palette = Symbols.palette;
  static const info = Symbols.info;
  static const edit = Symbols.edit;
  static const checkCircle = Symbols.check_circle;
  static const delete = Symbols.delete;
  static const undo = Symbols.undo;
  static const redo = Symbols.redo;
  static const moreHoriz = Symbols.more_horiz;
  static const privacyTip = Symbols.privacy_tip; // privacy policy
  static const description = Symbols.description; // terms of service
  static const receiptLong = Symbols.receipt_long; // refund policy
  static const code = Symbols.code; // open-source licenses
  static const mail = Symbols.mail; // contact
  static const expandLess = Symbols.expand_less; // collapse header
  static const expandMore = Symbols.expand_more; // expand header
}
