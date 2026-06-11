// LoopTap — arrangement strip + sweeping playhead (README §4.3, timeline.jsx).
// One row per track (main + decoration layers): an 88px label chip + lane. The
// strip fills its space, or scrolls when there are more rows than fit. A white
// playhead line sweeps across all lanes.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;

import '../models/loop_models.dart';
import '../music/theory.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';

class PitchRange {
  const PitchRange(this.min, this.max);
  final int min;
  final int max;
}

const double _labelW = 88;
const double _gap = 8;
const double _rowGap = 3;

class Arrangement extends StatelessWidget {
  const Arrangement({
    super.key,
    required this.section,
    required this.tracks,
    required this.activeId,
    required this.mutes,
    required this.onSelect,
    required this.onToggleMute,
    required this.playStep,
    required this.steps,
    required this.ranges,
    this.onSeek,
    this.onAddTrack,
    this.onReorder,
    this.playing = false,
  });

  final Section section;

  /// Ordered track metas to render (base 6 + added instances).
  final List<TrackMeta> tracks;
  final String activeId;
  final Map<String, bool> mutes;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onToggleMute;
  final double playStep;
  final int steps;
  final Map<String, PitchRange> ranges;

  /// Scrub the playhead by dragging across the lanes (null = read-only).
  final ValueChanged<double>? onSeek;

  /// Open the add-track picker (footer button); null hides it (song-preview).
  final VoidCallback? onAddTrack;

  /// Long-press-drag reorder of the rows; null disables (song-preview).
  final void Function(int oldIndex, int newIndex)? onReorder;

  /// Whether the transport is playing — the reorder slow-mo is skipped while
  /// playing so the global timeDilation never dips the music tempo.
  final bool playing;

  static const double _rowH = 44.0;

  _Row _rowFor(int i) {
    final m = tracks[i];
    return _Row(
      meta: m,
      data: section.tracks[m.id] ?? TrackData(),
      selected: m.id == activeId,
      muted: mutes[m.id] ?? false,
      onSelect: () => onSelect(m.id),
      onToggleMute: () => onToggleMute(m.id),
      steps: steps,
      range: ranges[m.id],
      // long-press the label chip to drag-reorder (null = disabled).
      reorderIndex: onReorder == null ? null : i,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Playhead spans only the actual lanes (not the empty space / footer below).
    final lanesHeight = tracks.length * (_rowH + _rowGap);
    return ClipRect(
      child: Stack(
      children: [
        // Fixed-height rows in a reorderable list — long-press a label chip to
        // drag it up/down; the others animate out of the way. The "+ Track"
        // footer sits right under the last chip (non-reorderable).
        ReorderableListView.builder(
          padding: EdgeInsets.zero,
          buildDefaultDragHandles: false,
          itemCount: tracks.length,
          onReorder: onReorder ?? (_, __) {},
          // Flutter hardcodes the reorder animation at 250ms with no knob, so we
          // slow it ~25% (×1.33) for the duration of the drag, restoring normal
          // speed on drop. timeDilation is global, so we only apply it while
          // stopped — never dipping the music tempo during playback.
          onReorderStart: (_) {
            if (!playing) timeDilation = 1.33;
          },
          onReorderEnd: (_) => timeDilation = 1.0,
          proxyDecorator: (child, index, anim) =>
              Material(type: MaterialType.transparency, child: child),
          footer: onAddTrack == null ? null : _AddTrackRow(onTap: onAddTrack!),
          itemBuilder: (context, i) => Padding(
            key: ValueKey(tracks[i].id),
            padding: EdgeInsets.only(bottom: _rowGap),
            child: SizedBox(height: _rowH, child: _rowFor(i)),
          ),
        ),
        // playhead spanning the lane area — draggable to scrub when onSeek is set.
        Positioned(
          left: _labelW + _gap,
          right: 0,
          top: 0,
          height: lanesHeight,
          child: LayoutBuilder(
            builder: (context, c) {
              final x = (playStep / steps) * c.maxWidth;
              void seek(Offset p) =>
                  onSeek?.call((p.dx / c.maxWidth * steps).clamp(0, steps.toDouble()));
              final line = Stack(
                children: [
                  Positioned(
                    left: x,
                    top: 0,
                    bottom: 0,
                    child: Container(
                      width: 2,
                      decoration: BoxDecoration(
                        color: LT.t1.withValues(alpha: 0.9),
                        boxShadow: [BoxShadow(color: LT.t1, blurRadius: 6)],
                      ),
                    ),
                  ),
                ],
              );
              if (onSeek == null) return IgnorePointer(child: line);
              // Horizontal drag scrubs; taps still fall through to lane rows
              // (translucent) so tapping a lane keeps selecting its track.
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: (d) => seek(d.localPosition),
                onHorizontalDragUpdate: (d) => seek(d.localPosition),
                child: line,
              );
            },
          ),
        ),
      ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.meta,
    required this.data,
    required this.selected,
    required this.muted,
    required this.onSelect,
    required this.onToggleMute,
    required this.steps,
    required this.range,
    this.reorderIndex,
  });

  final TrackMeta meta;
  final TrackData data;
  final bool selected;
  final bool muted;
  final VoidCallback onSelect;
  final VoidCallback onToggleMute;
  final int steps;
  final PitchRange? range;

  /// Index in the reorderable list; non-null → the chip is a long-press drag
  /// handle for reordering.
  final int? reorderIndex;

  @override
  Widget build(BuildContext context) {
    Widget chip = Container(
      width: _labelW,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: selected ? meta.color.withValues(alpha: 0.12) : LT.surface,
        borderRadius: BorderRadius.circular(LTRadius.chip),
        border: Border.all(color: selected ? meta.color : LT.border),
      ),
      child: Row(
        children: [
          if (reorderIndex != null) ...[
            Icon(Icons.drag_indicator, size: 11, color: LT.t3.withValues(alpha: 0.5)),
            const SizedBox(width: 1),
          ],
          Ms(meta.icon, size: 11, color: selected ? meta.color : LT.t2),
          const SizedBox(width: 5),
          Expanded(
            child: Text(meta.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: LTType.inter(size: 10, weight: FontWeight.w700, color: selected ? LT.t1 : LT.t2)),
          ),
          GestureDetector(
            onTap: onToggleMute,
            behavior: HitTestBehavior.opaque,
            child: Ms(muted ? LtIcons.volumeOff : LtIcons.volumeUp,
                size: 11, color: muted ? LT.t3 : LT.t2),
          ),
        ],
      ),
    );
    // long-press the chip → start a reorder drag.
    if (reorderIndex != null) {
      chip = ReorderableDelayedDragStartListener(index: reorderIndex!, child: chip);
    }
    return GestureDetector(
      onTap: onSelect,
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          chip,
          const SizedBox(width: _gap),
          // lane (fills the row height)
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: LT.bg,
                borderRadius: BorderRadius.circular(LTRadius.chip),
                border: Border.all(color: selected ? meta.color.withValues(alpha: 0.4) : LT.border),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomPaint(
                painter: _LanePainter(meta: meta, data: data, steps: steps, range: range),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Footer "+ Track" row, aligned under the label-chip column. Opens the picker.
class _AddTrackRow extends StatelessWidget {
  const _AddTrackRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: _rowGap),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          height: 30,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: _labelW,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: LT.surface2,
                  borderRadius: BorderRadius.circular(LTRadius.chip),
                  border: Border.all(color: LT.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Ms(LtIcons.add, size: 13, color: LT.t2),
                    const SizedBox(width: 3),
                    Text('Track',
                        style: LTType.inter(size: 10, weight: FontWeight.w700, color: LT.t2)),
                  ],
                ),
              ),
              const SizedBox(width: _gap),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter({required this.meta, required this.data, required this.steps, required this.range});
  final TrackMeta meta;
  final TrackData data;
  final int steps;
  final PitchRange? range;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = meta.color;
    final w = size.width, h = size.height;

    if (meta.kind == TrackKind.drums) {
      // Use the track's own kit so the beat-fill lane (shaker/tambourine/clap)
      // draws too — hardcoding the main kit hid beatDec notes in the strip.
      final rows = meta.drumKinds ?? const ['hihat', 'snare', 'kick'];
      for (var ri = 0; ri < rows.length; ri++) {
        final y = h * (ri + 0.5) / rows.length;
        for (final n in data.drumNotes.where((n) => n.kind == rows[ri])) {
          final x = (n.step / steps) * w;
          canvas.drawCircle(Offset(x + 2, y), 2, p);
        }
      }
      return;
    }
    if (meta.kind == TrackKind.vocal) {
      final wf = data.clip;
      if (wf == null || wf.isEmpty) return;
      final bw = (w - 12) / wf.length;
      final vp = Paint()..color = meta.color.withValues(alpha: 0.8);
      for (var i = 0; i < wf.length; i++) {
        final bh = (wf[i] * 26).clamp(2, h);
        final x = 6 + i * bw;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: Offset(x, h / 2), width: bw * 0.8, height: bh.toDouble()),
            const Radius.circular(1),
          ),
          vp,
        );
      }
      return;
    }
    // pitched / bass
    final r = range ?? const PitchRange(48, 72);
    final span = (r.max - r.min).clamp(1, 127);
    for (final n in data.pitchNotes) {
      final yNorm = 1 - (n.midi - r.min) / span;
      final y = (yNorm.clamp(0, 1)) * h;
      final x = (n.step / steps) * w;
      final nw = ((n.dur / steps) * w).clamp(2.5, w);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y - 2, nw.toDouble(), 4),
          const Radius.circular(2),
        ),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LanePainter old) =>
      old.data != data || old.steps != steps || old.range != range;
}
