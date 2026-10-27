// LoopTap — Mixer sheet (README §7). One row per track: color-tinted icon
// (tap = mute), name, volume slider (track color), % readout (or — when muted),
// and under it a Pan slider L100…C…R100 (mixer-001; double-tap / Alt+click =
// back to C). Mobile and desktop open this same sheet.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;

import '../../../l10n/generated/app_localizations.dart';
import '../../music/pan.dart';
import '../../music/theory.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showMixerSheet(
  BuildContext context, {
  required List<TrackMeta> tracks,
  required Map<String, double> vol,
  required Map<String, bool> mutes,
  required void Function(String id, double v) onVol,
  required void Function(String id) onToggleMute,
  Set<String> solos = const {},
  void Function(String id)? onToggleSolo,
  Future<void> Function(String id)? onGroove,
  String? Function(String id)? grooveLabel,
  Map<String, double> pan = const {},
  void Function(String id, double p)? onPan,
  void Function(String id)? onPanReset,
}) {
  return showLtModal(
    context,
    width: 460,
    child: MixerSheet(
      tracks: tracks,
      vol: vol,
      mutes: mutes,
      onVol: onVol,
      onToggleMute: onToggleMute,
      solos: solos,
      onToggleSolo: onToggleSolo,
      onGroove: onGroove,
      grooveLabel: grooveLabel,
      pan: pan,
      onPan: onPan,
      onPanReset: onPanReset,
    ),
  );
}

/// The mixer body (public so widget tests can pump it without the modal).
class MixerSheet extends StatefulWidget {
  const MixerSheet({
    super.key,
    required this.tracks,
    required this.vol,
    required this.mutes,
    required this.onVol,
    required this.onToggleMute,
    this.solos = const {},
    this.onToggleSolo,
    this.onGroove,
    this.grooveLabel,
    this.pan = const {},
    this.onPan,
    this.onPanReset,
  });
  final List<TrackMeta> tracks;
  final Map<String, double> vol;

  /// mixer-001: track id -> p in [-1, 1] (missing = centre). [onPan] fires
  /// while dragging; [onPanReset] on double-tap / Alt+click (back to C).
  final Map<String, double> pan;
  final void Function(String id, double p)? onPan;
  final void Function(String id)? onPanReset;
  final Map<String, bool> mutes;
  final Set<String> solos;
  final void Function(String id)? onToggleSolo;

  /// groove-001: open the track's groove sheet; [grooveLabel] names the
  /// assigned groove (null = none).
  final Future<void> Function(String id)? onGroove;
  final String? Function(String id)? grooveLabel;
  final void Function(String id, double v) onVol;
  final void Function(String id) onToggleMute;

  @override
  State<MixerSheet> createState() => _MixerSheetState();
}

class _MixerSheetState extends State<MixerSheet> {
  // Alt+click reset in progress: swallow the slider's own value jump.
  bool _altReset = false;

  void _resetPan(String id) {
    widget.onPanReset?.call(id);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l.ltMixerTitle,
              style: LTType.inter(
                size: 15,
                weight: FontWeight.w800,
                color: LT.t1,
              ),
            ),
            IconBtn(
              icon: LtIcons.close,
              tooltip: l.close,
              onTap: () => Navigator.of(context).pop(),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 430),
          child: ListView(
            shrinkWrap: true,
            physics: const ClampingScrollPhysics(),
            children: [for (final t in widget.tracks) _row(t)],
          ),
        ),
      ],
    );
  }

  Widget _row(TrackMeta t) {
    final muted = widget.mutes[t.id] ?? false;
    final v = widget.vol[t.id] ?? 0.85;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _volRow(t, muted, v),
          if (widget.onPan != null) _panRow(t),
        ],
      ),
    );
  }

  // Pan: L100…C…R100 under the volume slider. Works while muted (Mute/Solo
  // are independent of pan). One drag = one undo step (the editor coalesces).
  Widget _panRow(TrackMeta t) {
    final p = clampPan(widget.pan[t.id]);
    return Row(
      children: [
        const SizedBox(width: 46),
        SizedBox(
          width: 56,
          child: Text(
            'Pan',
            style: LTType.inter(size: 11, weight: FontWeight.w600, color: LT.t3),
          ),
        ),
        Expanded(
          child: GestureDetector(
            key: ValueKey('mixer-pan-${t.id}'),
            onDoubleTap: () => _resetPan(t.id),
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 2,
                activeTrackColor: LT.surface3,
                inactiveTrackColor: LT.surface3,
                thumbColor: t.color,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              ),
              child: Slider(
                min: -100,
                max: 100,
                value: p * 100,
                onChangeStart: (_) {
                  if (HardwareKeyboard.instance.isAltPressed) {
                    _altReset = true;
                    _resetPan(t.id);
                  }
                },
                onChanged: (nv) {
                  if (_altReset) return;
                  widget.onPan!(t.id, nv.round() / 100);
                  setState(() {});
                },
                onChangeEnd: (_) => _altReset = false,
              ),
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            panLabel(p),
            key: ValueKey('mixer-pan-label-${t.id}'),
            textAlign: TextAlign.right,
            style: LTType.mono(size: 11, color: LT.t2),
          ),
        ),
      ],
    );
  }

  Widget _volRow(TrackMeta t, bool muted, double v) {
    return Row(
      children: [
        GestureDetector(
          onTap: () {
            widget.onToggleMute(t.id);
            setState(() {});
          },
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: muted ? LT.surface2 : t.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: muted ? LT.border : t.color),
            ),
            child: Center(
              child: Ms(t.icon, size: 18, color: muted ? LT.t3 : t.color),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 56,
          child: Text(
            t.label,
            style: LTType.inter(
              size: 12,
              weight: FontWeight.w700,
              color: muted ? LT.t3 : LT.t1,
            ),
          ),
        ),
        if (widget.onToggleSolo != null)
          IconButton(
            key: ValueKey('mixer-solo-${t.id}'),
            tooltip: 'Solo',
            onPressed: () {
              widget.onToggleSolo!(t.id);
              setState(() {});
            },
            icon: Text(
              'S',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: widget.solos.contains(t.id) ? LT.lime : LT.t3,
              ),
            ),
          ),
        if (widget.onGroove != null && t.kind != TrackKind.vocal)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: ActionChip(
              key: ValueKey('mixer-groove-${t.id}'),
              visualDensity: VisualDensity.compact,
              label: Text(
                widget.grooveLabel?.call(t.id) ??
                    (Localizations.localeOf(context).languageCode == 'ko'
                        ? '그루브'
                        : 'Groove'),
                style: const TextStyle(fontSize: 10),
              ),
              onPressed: () async {
                await widget.onGroove!(t.id);
                if (mounted) setState(() {});
              },
            ),
          ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              activeTrackColor: t.color,
              inactiveTrackColor: LT.surface3,
              thumbColor: t.color,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              min: 0,
              max: 100,
              value: (v * 100).clamp(0, 100),
              onChanged:
                  muted
                      ? null
                      : (nv) {
                        widget.onVol(t.id, nv / 100);
                        setState(() {});
                      },
            ),
          ),
        ),
        SizedBox(
          width: 34,
          child: Text(
            muted ? '—' : '${(v * 100).round()}',
            textAlign: TextAlign.right,
            style: LTType.mono(size: 11, color: LT.t2),
          ),
        ),
      ],
    );
  }
}
