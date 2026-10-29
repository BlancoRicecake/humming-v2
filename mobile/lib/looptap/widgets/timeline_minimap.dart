// ui-001 stage 3 (docs/specs/ui/ui-001-desktop-b2-layout.md "3단계 — 편곡 보기
// ↔ 편집 보기"): the desktop edit view's 44 px stand-in for the timeline.
//
// Left 220: the active track ("Melody 편집 중"), click = arrange view.
// Right: the whole song at a glance (32 px): a 10 px section strip, every
// track's notes as thin rows, the playhead and the piano roll's visible time
// range as a rectangle. Click = move the playhead (other sections: switch to
// that section instance first), drag the rectangle = pan the piano roll.
//
// Coordinates: the overview is the whole song in GLOBAL steps (every section
// instance, repeats included, in order — [SongMap]). The roll's view and the
// playhead are LOCAL to the active section, so they are drawn at the active
// section instance ([TimelineMinimap.activeRepeat]). In song preview the
// editor already works in song steps (offset 0).
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../theme/atoms.dart';
import '../theme/tokens.dart';
import 'surfaces/pitch_grid_surface.dart';

/// Global song steps of every section instance (sections in order, each
/// played [repeats] times).
class SongMap {
  SongMap(List<({int steps, int repeats})> sections)
    : steps = [for (final s in sections) math.max(1, s.steps)],
      repeats = [for (final s in sections) math.max(1, s.repeats)] {
    var at = 0;
    for (var i = 0; i < steps.length; i++) {
      starts.add(at);
      at += steps[i] * repeats[i];
    }
    total = math.max(1, at);
  }

  final List<int> steps, repeats;
  final List<int> starts = [];
  late final int total;

  /// First global step of section [section]'s [repeat]-th instance.
  int instanceStart(int section, int repeat) =>
      starts[section] + repeat.clamp(0, repeats[section] - 1) * steps[section];

  /// The section instance under global step [global] (clamped to the song)
  /// and the step inside that section.
  ({int section, int repeat, double local}) locate(double global) {
    final g = global.clamp(0.0, total - 1e-6);
    var i = starts.length - 1;
    while (i > 0 && starts[i] > g) {
      i--;
    }
    final into = g - starts[i];
    final r = (into ~/ steps[i]).clamp(0, repeats[i] - 1);
    return (section: i, repeat: r, local: into - r * steps[i]);
  }
}

/// One section as the overview draws it.
class MinimapSection {
  const MinimapSection({
    required this.name,
    required this.steps,
    required this.repeats,
    required this.rows,
  });
  final String name;
  final int steps, repeats;

  /// Per overview track row: note / clip spans [start, end) in section steps.
  final List<List<(double, double)>> rows;
}

class TimelineMinimap extends StatefulWidget {
  const TimelineMinimap({
    super.key,
    required this.sections,
    required this.rowColors,
    required this.activeIdx,
    required this.activeRepeat,
    required this.playStep,
    required this.label,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.overviewTooltip,
    this.songMode = false,
    this.link,
    this.onArrange,
    this.onSeek,
    this.canSwitch = true,
    this.soloHeader,
  });

  /// The Solo controls (compare / clear / quiet warning) while a Solo is on:
  /// the edit view has no track header, so they sit beside the track button.
  final Widget? soloHeader;

  final List<MinimapSection> sections;
  final List<Color> rowColors;
  final int activeIdx, activeRepeat;

  /// Song preview: the playhead and the roll view are already song steps.
  final bool songMode;
  final ValueListenable<double> playStep;
  final PitchGridViewLink? link;

  final String label, tooltip, overviewTooltip;
  final IconData icon;
  final Color color;

  /// Back to the arrange view (null = locked, e.g. while recording).
  final VoidCallback? onArrange;

  /// Click in the overview: section, repeat and step inside it (null =
  /// read-only, e.g. song preview).
  final void Function(int section, int repeat, double local)? onSeek;

  /// Clicks may land in another section (false while recording).
  final bool canSwitch;

  static const double height = 44, labelWidth = 220, overviewHeight = 32;
  static const double bandHeight = 10;

  /// Track rows under the section strip in [avail] px: 3 px rows on a 4 px
  /// pitch when they fit, otherwise thinner rows sharing the space evenly —
  /// every track always gets a row inside the overview.
  static ({double pitch, double rowH}) rowLayout(int rows, double avail) {
    if (rows <= 0) return (pitch: 0, rowH: 0);
    final pitch = math.min(4.0, avail / rows);
    return (pitch: pitch, rowH: pitch >= 4 ? 3.0 : math.max(.5, pitch * .8));
  }

  SongMap get map => SongMap([
    for (final s in sections) (steps: s.steps, repeats: s.repeats),
  ]);

  /// Global step of the active section instance's first step (0 in song
  /// preview).
  double get offset =>
      songMode || sections.isEmpty
          ? 0
          : map.instanceStart(activeIdx, activeRepeat).toDouble();

  @override
  State<TimelineMinimap> createState() => _TimelineMinimapState();
}

class _TimelineMinimapState extends State<TimelineMinimap> {
  // rectangle drag: the roll view's start and the pointer x at drag start
  double? _dragStart, _dragX;

  bool _inRect(double x, double width) {
    final view = widget.link?.view;
    if (view == null) return false;
    final total = widget.map.total;
    final v = view.view;
    final left = (widget.offset + v.start) / total * width;
    final right = (widget.offset + v.end) / total * width;
    return x >= left - 4 && x <= right + 4;
  }

  void _tap(double x, double width) {
    final seek = widget.onSeek;
    if (seek == null || widget.sections.isEmpty) return;
    final map = widget.map;
    final hit = map.locate(x / width * map.total);
    if (!widget.canSwitch && hit.section != widget.activeIdx) return;
    seek(hit.section, hit.repeat, hit.local);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const ValueKey('timeline-minimap'),
      height: TimelineMinimap.height,
      child: Row(
        children: [
          SizedBox(
            width: TimelineMinimap.labelWidth,
            child: Tooltip(
              message: widget.tooltip,
              child: GestureDetector(
                key: const ValueKey('minimap-arrange'),
                onTap: widget.onArrange,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: .12),
                    borderRadius: BorderRadius.circular(LTRadius.chip),
                    border: Border.all(color: widget.color.withValues(alpha: .6)),
                  ),
                  child: Row(
                    children: [
                      Ms(widget.icon, size: 16, color: widget.color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.label,
                          key: const ValueKey('minimap-label'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: LTType.inter(size: 12, weight: FontWeight.w800, color: LT.t1),
                        ),
                      ),
                      Icon(
                        Icons.unfold_less,
                        size: 16,
                        color: widget.onArrange == null ? LT.t3 : LT.t2,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (widget.soloHeader != null) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: widget.soloHeader,
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: widget.overviewTooltip,
              waitDuration: const Duration(milliseconds: 800),
              child: LayoutBuilder(
                builder: (context, c) {
                  final width = math.max(1.0, c.maxWidth);
                  return GestureDetector(
                    key: const ValueKey('minimap-overview'),
                    behavior: HitTestBehavior.opaque,
                    dragStartBehavior: DragStartBehavior.down,
                    onTapUp: (d) => _tap(d.localPosition.dx, width),
                    onHorizontalDragStart: (d) {
                      final view = widget.link?.view;
                      if (view == null || !_inRect(d.localPosition.dx, width)) return;
                      _dragStart = view.view.start;
                      _dragX = d.localPosition.dx;
                    },
                    onHorizontalDragUpdate: (d) {
                      final view = widget.link?.view;
                      if (view == null || _dragStart == null) return;
                      final steps = (d.localPosition.dx - _dragX!) / width * widget.map.total;
                      view.panTo(_dragStart! + steps);
                    },
                    onHorizontalDragEnd: (_) => _dragStart = _dragX = null,
                    onHorizontalDragCancel: () => _dragStart = _dragX = null,
                    child: Container(
                      height: TimelineMinimap.overviewHeight,
                      decoration: BoxDecoration(
                        color: LT.surface,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: LT.border),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: _OverviewPainter(
                          widget,
                          repaint: Listenable.merge([
                            widget.playStep,
                            if (widget.link != null) widget.link!,
                          ]),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter(this.w, {super.repaint});
  final TimelineMinimap w;

  @override
  void paint(Canvas canvas, Size size) {
    if (w.sections.isEmpty) return;
    final map = w.map;
    double x(double global) => global / map.total * size.width;
    const band = TimelineMinimap.bandHeight;

    // section strip, one cell per section instance
    for (var i = 0; i < w.sections.length; i++) {
      for (var r = 0; r < map.repeats[i]; r++) {
        final a = x(map.instanceStart(i, r).toDouble());
        final b = x((map.instanceStart(i, r) + map.steps[i]).toDouble());
        final active = i == w.activeIdx;
        final here = active && (w.songMode || r == w.activeRepeat);
        canvas.drawRect(
          Rect.fromLTRB(a, 0, b, band),
          Paint()..color = active ? LT.lime.withValues(alpha: here ? .32 : .14) : LT.surface3,
        );
        if (here) {
          // the section instance the editor shows
          canvas.drawRect(
            Rect.fromLTRB(a, band, b, size.height),
            Paint()..color = LT.t1.withValues(alpha: .04),
          );
        }
        canvas.drawRect(Rect.fromLTRB(b - .5, 0, b + .5, size.height), Paint()..color = LT.border);
        if (b - a > 24) {
          final tp = TextPainter(
            text: TextSpan(
              text: w.sections[i].name,
              style: LTType.inter(size: 7, weight: FontWeight.w800, color: active ? LT.lime : LT.t3, height: 1),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: b - a - 4);
          tp.paint(canvas, Offset(a + 2, (band - tp.height) / 2));
        }
      }
    }

    // every track's notes: rows share the space under the strip (3 px each
    // with a 1 px gap when there is room, thinner rows otherwise — never
    // fewer rows than tracks)
    final rowsN = w.rowColors.length;
    if (rowsN > 0) {
      final top = band + 1, avail = size.height - top - 1;
      final (:pitch, :rowH) = TimelineMinimap.rowLayout(rowsN, avail);
      for (var i = 0; i < w.sections.length; i++) {
        final sec = w.sections[i];
        for (var t = 0; t < rowsN && t < sec.rows.length; t++) {
          final paint = Paint()..color = w.rowColors[t].withValues(alpha: .85);
          final y = top + t * pitch;
          for (var r = 0; r < map.repeats[i]; r++) {
            final at = map.instanceStart(i, r).toDouble();
            for (final (s, e) in sec.rows[t]) {
              final a = x(at + s.clamp(0, map.steps[i]));
              final b = x(at + e.clamp(0, map.steps[i]));
              canvas.drawRect(Rect.fromLTRB(a, y, math.max(b, a + 1), y + rowH), paint);
            }
          }
        }
      }
    }

    // the piano roll's visible time range
    final view = w.link?.view;
    if (view != null) {
      final v = view.view;
      final rect = Rect.fromLTRB(x(w.offset + v.start), .75, x(w.offset + v.end), size.height - .75);
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = LT.t1.withValues(alpha: .55),
      );
    }

    // playhead
    final head = x(w.offset + w.playStep.value);
    canvas.drawRect(Rect.fromLTWH(head - 1, 0, 2, size.height), Paint()..color = LT.t1);
  }

  @override
  bool shouldRepaint(_OverviewPainter old) => true;
}
