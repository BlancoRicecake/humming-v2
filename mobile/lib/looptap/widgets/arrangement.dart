// LoopTap — arrangement strip + sweeping playhead (README §4.3, timeline.jsx).
// One row per track: a fixed label column + a shared musical-time viewport. The
// strip fills its space, or scrolls when there are more rows than fit. A white
// playhead line sweeps across all lanes.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show kDoubleTapSlop, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show timeDilation;

import '../../l10n/generated/app_localizations.dart';
import '../models/loop_models.dart';
import '../music/theory.dart';
import '../music/audition.dart';
import '../music/timeline_view.dart';
import 'timeline_ruler.dart';
import '../theme/atoms.dart';
import '../theme/tokens.dart';

class VocalClipDrag {
  const VocalClipDrag(this.trackId, this.clipIndex, this.clip);
  final String trackId;
  final int clipIndex;
  final VocalClip clip;
}

class PitchRange {
  const PitchRange(this.min, this.max);
  final int min;
  final int max;
}

const double _defaultLabelW = 220;
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
    this.onConvertClip,
    this.playing = false,
    this.solos = const {},
    this.bypassSolo = false,
    this.onToggleSolo,
    this.loopRange,
    this.view,
    this.labelWidth = _defaultLabelW,
    this.onLabelWidthChanged,
    this.instrumentNames = const {},
    this.sectionBand,
    this.soloHeader,
    this.headerActions = const [],
    this.onLoopRange,
    this.loopRangeEnabled = true,
    this.rowHeight = _rowH,
    this.onOpenTrack,
  });

  /// ui-001 stage 3: track row height (the desktop arrange view uses 64).
  final double rowHeight;

  /// ui-001 stage 3 (desktop arrange view): double-click a track row = edit
  /// that track. A single click still selects at once (no double-tap wait).
  final ValueChanged<String>? onOpenTrack;

  /// ui-001 stage 2 (desktop): the section band drawn in the top 16 px of a
  /// 36 px header row, above a 16 px ruler that sets the loop range by drag
  /// ([onLoopRange]). [soloHeader] (only while a Solo is active) and
  /// [headerActions] sit in the label column. Null band = the phone 28 px row.
  final Widget? sectionBand;
  final Widget? soloHeader;
  final List<Widget> headerActions;
  final ValueChanged<PlaybackRange>? onLoopRange;

  /// False while recording / counting in / previewing the song.
  final bool loopRangeEnabled;

  final Section section;
  final TimelineView? view;
  TimelineView get visible => view ?? TimelineView(0, steps.toDouble());
  final double labelWidth;
  final ValueChanged<double>? onLabelWidthChanged;
  final Map<String, String> instrumentNames;

  /// Ordered track metas to render (base 6 + added instances).
  final List<TrackMeta> tracks;
  final String activeId;
  final Map<String, bool> mutes;
  final Set<String> solos;
  final bool bypassSolo;
  final ValueChanged<String>? onToggleSolo;
  final PlaybackRange? loopRange;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onToggleMute;

  /// The play head position, as a listenable so that moving it repaints only
  /// the head — not the reorderable lane list under it (audit C22).
  final ValueListenable<double> playStep;
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
  final void Function(String trackId, int clipIndex, int newStartStep)?
  onMoveClip;

  /// Whether the transport is playing — the reorder slow-mo is skipped while
  /// playing so the global timeDilation never dips the music tempo.
  final bool playing;
  final void Function(VocalClipDrag clip, String targetTrack)? onConvertClip;

  static const double _rowH = 44.0;

  _Row _rowFor(int i) {
    final m = tracks[i];
    return _Row(
      meta: m,
      labelWidth: labelWidth,
      view: visible,
      instrument: instrumentNames[m.id],
      data: section.tracks[m.id] ?? TrackData(),
      selected: m.id == activeId,
      muted: mutes[m.id] ?? false,
      audible: trackIsAudible(m.id, mutes, solos, bypassSolo: bypassSolo),
      solo: solos.contains(m.id),
      onToggleSolo: onToggleSolo == null ? null : () => onToggleSolo!(m.id),
      onSelect: () => onSelect(m.id),
      onToggleMute: () => onToggleMute(m.id),
      steps: steps,
      range: ranges[m.id],
      onConvertClip: onConvertClip,
      // long-press the label chip to drag-reorder (null = disabled).
      reorderIndex: onReorder == null ? null : i,
      playStep: playStep,
      onMoveClip:
          onMoveClip == null ? null : (ci, st) => onMoveClip!(m.id, ci, st),
      onOpen: onOpenTrack == null ? null : () => onOpenTrack!(m.id),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Playhead spans only the actual lanes (not the empty space / footer below).
    final lanesHeight = tracks.length * (rowHeight + _rowGap);
    final lanes = ClipRect(
      child: Stack(
        children: [
          // Fixed-height rows in a reorderable list — long-press a label chip to
          // drag it up/down; the others animate out of the way. The "+ Track"
          // footer sits right under the last chip (non-reorderable).
          ReorderableListView.builder(
            padding: EdgeInsets.zero,
            buildDefaultDragHandles: false,
            itemCount: tracks.length,
            onReorderItem: onReorder ?? (_, __) {},
            // Flutter hardcodes the reorder animation at 250ms with no knob, so we
            // slow it ~25% (×1.33) for the duration of the drag, restoring normal
            // speed on drop. timeDilation is global, so we only apply it while
            // stopped — never dipping the music tempo during playback.
            onReorderStart: (_) {
              if (!playing) timeDilation = 1.33;
            },
            onReorderEnd: (_) => timeDilation = 1.0,
            proxyDecorator:
                (child, index, anim) =>
                    Material(type: MaterialType.transparency, child: child),
            footer:
                onAddTrack == null
                    ? null
                    : _AddTrackRow(onTap: onAddTrack!, labelWidth: labelWidth),
            itemBuilder:
                (context, i) => Padding(
                  key: ValueKey(tracks[i].id),
                  padding: EdgeInsets.only(bottom: _rowGap),
                  child: SizedBox(height: rowHeight, child: _rowFor(i)),
                ),
          ),
          // playhead spanning the lane area — draggable to scrub when onSeek is set.
          Positioned(
            left: labelWidth + _gap,
            right: 0,
            top: 0,
            height: lanesHeight,
            child: LayoutBuilder(
              builder: (context, c) {
                void seek(Offset p) =>
                    onSeek?.call(visible.stepAt(p.dx / c.maxWidth));
                // Only the head listens to the clock, so the lane list below is
                // not rebuilt every frame (audit C22).
                final line = ValueListenableBuilder<double>(
                  valueListenable: playStep,
                  builder:
                      (context, ps, _) => Stack(
                        children: [
                          if (loopRange != null)
                            Positioned(
                              left:
                                  visible
                                      .fraction(loopRange!.start)
                                      .clamp(0.0, 1.0) *
                                  c.maxWidth,
                              width:
                                  (visible
                                          .fraction(loopRange!.end)
                                          .clamp(0.0, 1.0) -
                                      visible
                                          .fraction(loopRange!.start)
                                          .clamp(0.0, 1.0)) *
                                  c.maxWidth,
                              top: 0,
                              bottom: 0,
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: LT.lime.withValues(alpha: .06),
                                    border: Border.symmetric(
                                      vertical: BorderSide(
                                        color: LT.lime.withValues(alpha: .5),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (ps >= visible.start && ps < visible.end)
                            Positioned(
                              key: const ValueKey('timeline-playhead'),
                              left: visible.fraction(ps) * c.maxWidth,
                              top: 0,
                              bottom: 0,
                              child: Container(
                                width: 2,
                                decoration: BoxDecoration(
                                  color: LT.t1.withValues(alpha: 0.9),
                                  boxShadow: [
                                    BoxShadow(color: LT.t1, blurRadius: 6),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
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
    final ko = Localizations.localeOf(context).languageCode == 'ko';
    final labelRow = Row(
      children: [
        Expanded(
          child: Text(
            ko ? '트랙 · 악기' : 'Track · instrument',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, color: LT.t2),
          ),
        ),
        ...headerActions,
        if (onLabelWidthChanged != null)
          Tooltip(
            message:
                ko
                    ? '좌우로 끌어 이름 영역 조절'
                    : 'Drag to resize track labels',
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                key: const ValueKey('track-label-resize'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate:
                    (d) => onLabelWidthChanged!(
                      labelWidth + d.delta.dx,
                    ),
                child: const SizedBox(
                  width: 16,
                  height: 28,
                  child: Icon(
                    Icons.drag_indicator,
                    size: 13,
                    color: LT.t3,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    final ruler = TimelineRuler(
      view: visible,
      steps: steps,
      loopRange: loopRange,
      onSeek: onSeek,
      onRange: sectionBand == null ? null : onLoopRange,
      rangeEnabled: loopRangeEnabled,
    );
    final header =
        sectionBand == null
            ? SizedBox(
              height: 28,
              child: Row(
                children: [
                  SizedBox(width: labelWidth, child: labelRow),
                  const SizedBox(width: _gap),
                  Expanded(child: ruler),
                ],
              ),
            )
            : SizedBox(
              key: const ValueKey('arrangement-header'),
              height: 36,
              child: Row(
                children: [
                  SizedBox(
                    width: labelWidth,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: 16,
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: soloHeader ?? const SizedBox.shrink(),
                          ),
                        ),
                        Expanded(child: ClipRect(child: OverflowBox(maxHeight: 28, child: labelRow))),
                      ],
                    ),
                  ),
                  const SizedBox(width: _gap),
                  Expanded(
                    child: Column(
                      children: [
                        sectionBand!,
                        const SizedBox(height: 4),
                        Expanded(child: ruler),
                      ],
                    ),
                  ),
                ],
              ),
            );
    return Column(
      children: [
        header,
        Expanded(child: lanes),
      ],
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
    required this.playStep,
    required this.labelWidth,
    required this.view,
    this.instrument,
    this.reorderIndex,
    this.solo = false,
    this.audible = true,
    this.onToggleSolo,
    this.onMoveClip,
    this.onConvertClip,
    this.onOpen,
  });

  /// Double-click on the row (null = off).
  final VoidCallback? onOpen;
  final TrackMeta meta;
  final double labelWidth;
  final TimelineView view;
  final String? instrument;
  final TrackData data;
  final bool selected;
  final bool muted;
  final bool solo, audible;
  final VoidCallback? onToggleSolo;
  final VoidCallback onSelect;
  final VoidCallback onToggleMute;
  final int steps;
  final PitchRange? range;

  /// Index in the reorderable list; non-null → the chip is a long-press drag
  /// handle for reordering.
  final int? reorderIndex;

  /// Only read at drag time (to snap a clip to the head) — never in build.
  final ValueListenable<double> playStep;
  final void Function(int clipIndex, int newStartStep)? onMoveClip;
  final void Function(VocalClipDrag clip, String targetTrack)? onConvertClip;

  @override
  Widget build(BuildContext context) {
    final name = data.label ?? instrument ?? meta.label;
    final detail =
        instrument != null && instrument != name ? instrument! : meta.label;
    Widget chip = Tooltip(
      message: '$name\n$detail',
      child: Container(
        key: ValueKey('track-label-${meta.id}'),
        width: labelWidth,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: selected ? meta.color.withValues(alpha: 0.12) : LT.surface,
          borderRadius: BorderRadius.circular(LTRadius.chip),
          border: Border.all(color: selected ? meta.color : LT.border),
        ),
        child: Row(
          children: [
            if (reorderIndex != null) ...[
              Icon(
                Icons.drag_indicator,
                size: 11,
                color: LT.t3.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 1),
            ],
            Ms(meta.icon, size: 11, color: selected ? meta.color : LT.t2),
            const SizedBox(width: 5),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    key: ValueKey('track-name-${meta.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LTType.inter(
                      size: 12,
                      weight: FontWeight.w700,
                      color: selected ? LT.t1 : LT.t2,
                    ),
                  ),
                  if (detail != name)
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LTType.inter(size: 10, color: LT.t3),
                    ),
                ],
              ),
            ),
            if (onToggleSolo != null)
              Tooltip(
                message: 'Solo',
                child: GestureDetector(
                  key: ValueKey('solo-${meta.id}'),
                  onTap: onToggleSolo,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 22,
                    height: 32,
                    child: Center(
                      child: Text(
                        'S',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: solo ? LT.lime : LT.t3,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            GestureDetector(
              key: ValueKey('mute-${meta.id}'),
              onTap: onToggleMute,
              behavior: HitTestBehavior.opaque,
              child: Ms(
                muted ? LtIcons.volumeOff : LtIcons.volumeUp,
                size: 11,
                color: muted ? LT.t3 : LT.t2,
              ),
            ),
          ],
        ),
      ),
    );
    // long-press the chip → start a reorder drag.
    if (reorderIndex != null) {
      chip = ReorderableDelayedDragStartListener(
        index: reorderIndex!,
        child: chip,
      );
    }
    final open = onOpen;
    Widget tapArea({required Widget child}) =>
        open == null
            ? GestureDetector(onTap: onSelect, behavior: HitTestBehavior.opaque, child: child)
            : _RowClicks(
              key: ValueKey('track-row-${meta.id}'),
              onClick: onSelect,
              onDouble: open,
              child: child,
            );
    final row = tapArea(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          chip,
          const SizedBox(width: _gap),
          // lane (fills the row height)
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: audible ? LT.bg : LT.surface3,
                borderRadius: BorderRadius.circular(LTRadius.chip),
                border: Border.all(
                  color:
                      selected ? meta.color.withValues(alpha: 0.4) : LT.border,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child:
                  (meta.kind == TrackKind.vocal && onMoveClip != null)
                      ? _VocalLane(
                        meta: meta,
                        view: view,
                        data: data,
                        steps: steps,
                        playStep: playStep,
                        onMove: onMoveClip!,
                        canConvert: onConvertClip != null,
                      )
                      : CustomPaint(
                        painter: _LanePainter(
                          meta: meta,
                          view: view,
                          data: data,
                          steps: steps,
                          range: range,
                        ),
                      ),
            ),
          ),
        ],
      ),
    );
    if (onConvertClip == null || meta.kind != TrackKind.pitched) return row;
    return DragTarget<VocalClipDrag>(
      onWillAcceptWithDetails: (_) => true,
      onAcceptWithDetails: (details) => onConvertClip!(details.data, meta.id),
      builder:
          (_, candidates, _) => DecoratedBox(
            decoration: BoxDecoration(
              border:
                  candidates.isEmpty
                      ? null
                      : Border.all(color: meta.color, width: 2),
            ),
            child: row,
          ),
    );
  }
}

/// The row's click (select) and double-click (edit). Only clicks the row's
/// own tap recognizer wins count: a click on the Solo / mute buttons, a scrub
/// or reorder drag, or a cancelled press is never a click. Two counted clicks
/// in a row (no other press between them) within the double-tap time and
/// distance = [onDouble]. The first click selects at once (no double-tap
/// wait).
class _RowClicks extends StatefulWidget {
  const _RowClicks({
    super.key,
    required this.onClick,
    required this.onDouble,
    required this.child,
  });
  final VoidCallback onClick, onDouble;
  final Widget child;
  @override
  State<_RowClicks> createState() => _RowClicksState();
}

class _RowClicksState extends State<_RowClicks> {
  // the latest press, and the last press that ended as a row click
  Duration? _downAt, _clickAt;
  Offset? _downPos, _clickPos;
  bool _pressOpen = false;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (e) {
      // the previous press did not become a row click: no double-click
      // across it
      if (_pressOpen) _clickAt = _clickPos = null;
      _pressOpen = true;
      _downAt = e.timeStamp;
      _downPos = e.position;
    },
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        _pressOpen = false;
        final at = _downAt, pos = _downPos, last = _clickAt, lastPos = _clickPos;
        widget.onClick();
        if (at != null &&
            pos != null &&
            last != null &&
            lastPos != null &&
            at - last <= kDoubleTapTimeout &&
            (pos - lastPos).distance <= kDoubleTapSlop) {
          _clickAt = _clickPos = null;
          widget.onDouble();
          return;
        }
        _clickAt = at;
        _clickPos = pos;
      },
      child: widget.child,
    ),
  );
}

/// Footer "+ Track" row, aligned under the label-chip column. Opens the picker.
class _AddTrackRow extends StatelessWidget {
  const _AddTrackRow({required this.onTap, required this.labelWidth});
  final double labelWidth;
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
                width: labelWidth,
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
                    Text(
                      L10n.of(context).ltArrangeAddTrack,
                      style: LTType.inter(
                        size: 10,
                        weight: FontWeight.w700,
                        color: LT.t2,
                      ),
                    ),
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
    required this.view,
    required this.data,
    required this.steps,
    required this.playStep,
    required this.onMove,
    this.canConvert = false,
  });

  final TrackMeta meta;
  final TimelineView view;
  final TrackData data;
  final int steps;
  final ValueListenable<double> playStep;
  final void Function(int clipIndex, int newStartStep) onMove;
  final bool canConvert;

  @override
  State<_VocalLane> createState() => _VocalLaneState();
}

class _VocalLaneState extends State<_VocalLane> {
  int? _grabIdx; // clip being dragged
  int _grabOffset = 0; // steps between the grab point and the chunk start
  double _laneW = 1;

  int _durOf(VocalClip c) =>
      c.durSteps > 0 ? c.durSteps : (widget.steps - c.startStep);

  void _onStart(LongPressStartDetails d) {
    final clips = widget.data.effectiveClips;
    final pressStep = widget.view.stepAt(d.localPosition.dx / _laneW);
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
    final stepF = widget.view.stepAt(d.localPosition.dx / _laneW);
    var raw = (stepF - _grabOffset).round();
    raw = _snap(raw, dur, clips, idx).clamp(0, widget.steps - 1);
    widget.onMove(idx, raw);
  }

  int _snap(int raw, int dur, List<VocalClip> clips, int self) {
    final thresh = (widget.steps * 0.03).ceil().clamp(1, 3);
    final targets = <int>[0, widget.steps, widget.playStep.value.round()];
    for (var i = 0; i < clips.length; i++) {
      if (i == self) continue;
      targets
        ..add(clips[i].startStep)
        ..add(clips[i].startStep + _durOf(clips[i]));
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
    return LayoutBuilder(
      builder: (context, c) {
        _laneW = c.maxWidth <= 0 ? 1 : c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: _onStart,
          onLongPressMoveUpdate: _onMoveUpdate,
          onLongPressEnd: (_) => setState(() => _grabIdx = null),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _LanePainter(
                    meta: widget.meta,
                    view: widget.view,
                    data: widget.data,
                    steps: widget.steps,
                    range: null,
                    grabbedClip: _grabIdx,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              if (widget.canConvert)
                for (var i = 0; i < widget.data.effectiveClips.length; i++)
                  _dragHandle(i, c.maxWidth),
            ],
          ),
        );
      },
    );
  }

  Widget _dragHandle(int index, double width) {
    final clip = widget.data.effectiveClips[index];
    if (clip.startStep < 0 || clip.startStep >= widget.steps) {
      return const SizedBox.shrink();
    }
    final start = clip.startStep;
    final duration = _durOf(clip).clamp(1, widget.steps - start);
    return Positioned(
      left: widget.view.fraction(start) * width,
      width: duration / widget.view.length * width,
      top: 0,
      bottom: 0,
      child: Draggable<VocalClipDrag>(
        hitTestBehavior: HitTestBehavior.opaque,
        data: VocalClipDrag(widget.meta.id, index, clip.copy()),
        // Desktop pointer dragging can cross lanes. A cancelled drop retimes
        // the clip; mobile retains its existing hold-and-drag recognizer.
        onDraggableCanceled: (_, offset) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final local = box.globalToLocal(offset);
          final newStep = widget.view
              .stepAt(local.dx / _laneW)
              .round()
              .clamp(0, widget.steps - duration);
          widget.onMove(index, newStep);
        },
        feedback: Material(
          color: LT.pink,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              L10n.of(context).ltMidiTitle,
              style: const TextStyle(color: Colors.black),
            ),
          ),
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _LanePainter extends CustomPainter {
  _LanePainter({
    required this.meta,
    required this.view,
    required this.data,
    required this.steps,
    required this.range,
    this.grabbedClip,
  }) : _sig = _sigOf(data);
  final TrackMeta meta;
  final TimelineView view;
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
      h = h * 31 + (n.step + n.offsetSteps).hashCode;
      h = h * 31 + (n.muted ? 1 : 0);
      h = h * 31 + n.chance.hashCode;
    }
    for (final n in d.pitchNotes) {
      h = h * 31 + n.midi;
      h = (h * 31 + n.startSteps.hashCode) * 31 + n.soundingSteps.hashCode;
      h = h * 31 + (n.muted ? 1 : 0);
      h = h * 31 + n.chance.hashCode;
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
    canvas.clipRect(Offset.zero & size);
    final beatWidth = size.width * 4 / view.length;
    for (var step = (view.start / 4).ceil() * 4; step < view.end; step += 4) {
      final bar = step % 16 == 0;
      if (!bar && beatWidth < 16) continue;
      final x = view.fraction(step) * size.width;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = bar ? LT.borderStrong : LT.border.withValues(alpha: .4),
      );
    }
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
          final x = view.fraction(n.step + n.offsetSteps) * w;
          canvas.drawCircle(
            Offset(x + 2, y),
            2,
            n.muted ? (Paint()..color = meta.color.withValues(alpha: .3)) : p,
          );
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
        final fill =
            Paint()
              ..color = meta.color.withValues(alpha: grabbed ? 0.30 : 0.16);
        final stroke =
            Paint()
              ..color = meta.color.withValues(alpha: grabbed ? 0.95 : 0.55)
              ..style = PaintingStyle.stroke
              ..strokeWidth = grabbed ? 2 : 1;
        final vp = Paint()..color = meta.color.withValues(alpha: 0.85);
        final x0 = view.fraction(c.startStep) * w;
        final wSteps = c.durSteps > 0 ? c.durSteps : (steps - c.startStep);
        final cw = ((wSteps / view.length) * w).clamp(4.0, double.infinity);
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
                  height: bh.toDouble(),
                ),
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
    final mutedPaint = Paint()..color = meta.color.withValues(alpha: .3);
    for (final n in data.pitchNotes) {
      final yNorm = 1 - (n.midi - r.min) / span;
      final y = (yNorm.clamp(0, 1)) * h;
      final x = view.fraction(n.startSteps) * w;
      final nw = ((n.soundingSteps / view.length) * w).clamp(
        2.5,
        double.infinity,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y - 2, nw.toDouble(), 4),
          const Radius.circular(2),
        ),
        n.muted ? mutedPaint : p,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LanePainter old) =>
      old._sig != _sig ||
      old.data != data ||
      old.steps != steps ||
      old.view.start != view.start ||
      old.view.end != view.end ||
      old.range != range ||
      old.grabbedClip != grabbedClip;
}
