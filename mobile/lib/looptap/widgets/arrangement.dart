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
    this.onMoveClip,
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

  /// Hold-and-drag a vocal/audio clip chunk along its lane to retime it
  /// ([newStartStep]); null disables. The chunk snaps to other chunks' edges and
  /// the playhead.
  final void Function(String trackId, int clipIndex, int newStartStep)? onMoveClip;

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
      playStep: playStep,
      onMoveClip: onMoveClip == null ? null : (ci, st) => onMoveClip!(m.id, ci, st),
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
    this.playStep = 0,
    this.onMoveClip,
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

  final double playStep;
  final void Function(int clipIndex, int newStartStep)? onMoveClip;

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
              child: (meta.kind == TrackKind.vocal && onMoveClip != null)
                  ? _VocalLane(
                      meta: meta,
                      data: data,
                      steps: steps,
                      playStep: playStep,
                      onMove: onMoveClip!,
                    )
                  : CustomPaint(
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

/// Vocal/Audio lane with hold-and-drag chunk retiming. Long-press a chunk to
/// grab it, then drag along the lane to move its startStep; it snaps to other
/// chunks' edges and the playhead. (Long-press, not plain drag, so it never
/// fights the playhead-scrub overlay above.)
class _VocalLane extends StatefulWidget {
  const _VocalLane({
    required this.meta,
    required this.data,
    required this.steps,
    required this.playStep,
    required this.onMove,
  });

  final TrackMeta meta;
  final TrackData data;
  final int steps;
  final double playStep;
  final void Function(int clipIndex, int newStartStep) onMove;

  @override
  State<_VocalLane> createState() => _VocalLaneState();
}

class _VocalLaneState extends State<_VocalLane> {
  int? _grabIdx; // clip being dragged
  int _grabOffset = 0; // steps between the grab point and the chunk start
  double _laneW = 1;

  int _durOf(VocalClip c) => c.durSteps > 0 ? c.durSteps : (widget.steps - c.startStep);

  void _onStart(LongPressStartDetails d) {
    final clips = widget.data.effectiveClips;
    final pressStep = (d.localPosition.dx / _laneW).clamp(0.0, 1.0) * widget.steps;
    // topmost chunk under the finger (later clips draw on top)
    for (var i = clips.length - 1; i >= 0; i--) {
      final c = clips[i];
      if (pressStep >= c.startStep && pressStep < c.startStep + _durOf(c)) {
        setState(() {
          _grabIdx = i;
          _grabOffset = (pressStep - c.startStep).round();
        });
        return;
      }
    }
    _grabIdx = null;
  }

  void _onMoveUpdate(LongPressMoveUpdateDetails d) {
    final idx = _grabIdx;
    if (idx == null) return;
    final clips = widget.data.effectiveClips;
    if (idx >= clips.length) return;
    final dur = _durOf(clips[idx]);
    final stepF = (d.localPosition.dx / _laneW).clamp(0.0, 1.0) * widget.steps;
    var raw = (stepF - _grabOffset).round();
    raw = _snap(raw, dur, clips, idx).clamp(0, widget.steps - 1);
    widget.onMove(idx, raw);
  }

  int _snap(int raw, int dur, List<VocalClip> clips, int self) {
    final thresh = (widget.steps * 0.03).ceil().clamp(1, 3);
    final targets = <int>[0, widget.steps, widget.playStep.round()];
    for (var i = 0; i < clips.length; i++) {
      if (i == self) continue;
      targets..add(clips[i].startStep)..add(clips[i].startStep + _durOf(clips[i]));
    }
    for (final t in targets) {
      if ((raw - t).abs() <= thresh) return t; // snap the start edge
    }
    for (final t in targets) {
      if ((raw + dur - t).abs() <= thresh) return t - dur; // snap the end edge
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      _laneW = c.maxWidth <= 0 ? 1 : c.maxWidth;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: _onStart,
        onLongPressMoveUpdate: _onMoveUpdate,
        onLongPressEnd: (_) => setState(() => _grabIdx = null),
        child: CustomPaint(
          painter: _LanePainter(
            meta: widget.meta,
            data: widget.data,
            steps: widget.steps,
            range: null,
            grabbedClip: _grabIdx,
          ),
          child: const SizedBox.expand(),
        ),
      );
    });
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter(
      {required this.meta,
      required this.data,
      required this.steps,
      required this.range,
      this.grabbedClip})
      : _sig = _sigOf(data);
  final TrackMeta meta;
  final TrackData data;
  final int steps;
  final PitchRange? range;

  /// Index of the chunk currently being hold-dragged (highlighted), or null.
  final int? grabbedClip;

  // Content signature FROZEN at construction. The old and new painter share the
  // same TrackData object (notes mutate in place on record/clear/toggle), so a
  // live read in shouldRepaint always sees identical state — capturing the
  // signature when the painter is built lets us detect the change and redraw.
  final int _sig;
  static int _sigOf(TrackData d) {
    var h = 17;
    h = h * 31 + d.drumNotes.length;
    h = h * 31 + d.pitchNotes.length;
    for (final n in d.drumNotes) {
      h = h * 31 + n.kind.hashCode;
      h = h * 31 + n.step;
    }
    for (final n in d.pitchNotes) {
      h = h * 31 + n.midi;
      h = (h * 31 + n.step) * 31 + n.dur;
    }
    h = h * 31 + (d.clip?.length ?? 0);
    // vocal chunks: position/size/identity so moving or editing a take redraws.
    final clips = d.clips;
    if (clips != null) {
      h = h * 31 + clips.length;
      for (final c in clips) {
        h = h * 31 + c.path.hashCode;
        h = (h * 31 + c.startStep) * 31 + c.durSteps;
        h = h * 31 + c.peaks.length;
      }
    }
    return h;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = meta.color;
    final w = size.width, h = size.height;

    if (meta.kind == TrackKind.drums) {
      // Lanes = the track's default kinds PLUS any kind actually present in the
      // notes. Beat-Fill pads are user-assignable (cowbell/maracas/…), so the
      // notes can carry kinds outside the const drumKinds — append them so every
      // recorded hit draws instead of vanishing.
      final base = meta.drumKinds ?? const ['hihat', 'snare', 'kick'];
      final present = data.drumNotes.map((n) => n.kind).toSet();
      final rows = <String>[
        ...base,
        for (final k in present)
          if (!base.contains(k)) k,
      ];
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
      // One rounded "chunk" per placed take, positioned at its startStep and
      // sized by its measured durSteps (−1 → runs to the section end). The
      // take's waveform is drawn inside the chunk so the user sees WHERE each
      // recording sounds on the timeline.
      final clips = data.effectiveClips;
      if (clips.isEmpty) return;
      for (var ci = 0; ci < clips.length; ci++) {
        final c = clips[ci];
        final grabbed = ci == grabbedClip;
        final fill = Paint()..color = meta.color.withValues(alpha: grabbed ? 0.30 : 0.16);
        final stroke = Paint()
          ..color = meta.color.withValues(alpha: grabbed ? 0.95 : 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = grabbed ? 2 : 1;
        final vp = Paint()..color = meta.color.withValues(alpha: 0.85);
        final x0 = (c.startStep / steps) * w;
        final wSteps = c.durSteps > 0 ? c.durSteps : (steps - c.startStep);
        final cw = ((wSteps / steps) * w).clamp(4.0, w - x0);
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(x0 + 1, 3, (cw - 2).clamp(3.0, w), h - 6),
          const Radius.circular(3),
        );
        canvas.drawRRect(rect, fill);
        canvas.drawRRect(rect, stroke);
        final pk = c.peaks;
        if (pk.isNotEmpty && cw > 8) {
          final bw = (cw - 6) / pk.length;
          for (var i = 0; i < pk.length; i++) {
            final bh = (pk[i] * 22).clamp(2, h - 8);
            final bx = x0 + 3 + i * bw;
            canvas.drawRRect(
              RRect.fromRectAndRadius(
                Rect.fromCenter(
                    center: Offset(bx, h / 2),
                    width: (bw * 0.7).clamp(0.6, 4),
                    height: bh.toDouble()),
                const Radius.circular(1),
              ),
              vp,
            );
          }
        }
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
      old._sig != _sig ||
      old.data != data ||
      old.steps != steps ||
      old.range != range ||
      old.grabbedClip != grabbedClip;
}
