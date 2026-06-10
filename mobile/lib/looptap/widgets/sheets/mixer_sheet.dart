// LoopTap — Mixer sheet (README §7). One row per track: color-tinted icon
// (tap = mute), name, volume slider (track color), % readout (or — when muted).
import 'package:flutter/material.dart';

import '../../music/theory.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';

Future<void> showMixerSheet(
  BuildContext context, {
  required Map<String, double> vol,
  required Map<String, bool> mutes,
  required void Function(String id, double v) onVol,
  required void Function(String id) onToggleMute,
}) {
  return showLtModal(
    context,
    width: 460,
    child: _MixerSheet(vol: vol, mutes: mutes, onVol: onVol, onToggleMute: onToggleMute),
  );
}

class _MixerSheet extends StatefulWidget {
  const _MixerSheet({required this.vol, required this.mutes, required this.onVol, required this.onToggleMute});
  final Map<String, double> vol;
  final Map<String, bool> mutes;
  final void Function(String id, double v) onVol;
  final void Function(String id) onToggleMute;

  @override
  State<_MixerSheet> createState() => _MixerSheetState();
}

class _MixerSheetState extends State<_MixerSheet> {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Mixer', style: LTType.inter(size: 15, weight: FontWeight.w800, color: LT.t1)),
            IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
          ],
        ),
        const SizedBox(height: 16),
        for (final t in kTracks) _row(t),
      ],
    );
  }

  Widget _row(TrackMeta t) {
    final muted = widget.mutes[t.id] ?? false;
    final v = widget.vol[t.id] ?? 0.85;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
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
              child: Center(child: Ms(t.icon, size: 18, color: muted ? LT.t3 : t.color)),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 56,
            child: Text(t.label,
                style: LTType.inter(size: 12, weight: FontWeight.w700, color: muted ? LT.t3 : LT.t1)),
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
                onChanged: muted
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
            child: Text(muted ? '—' : '${(v * 100).round()}',
                textAlign: TextAlign.right, style: LTType.mono(size: 11, color: LT.t2)),
          ),
        ],
      ),
    );
  }
}
