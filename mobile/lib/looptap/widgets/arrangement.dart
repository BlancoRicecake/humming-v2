// LoopTap — arrangement strip + sweeping playhead (README §4.3, timeline.jsx).
// 4 rows (Melody/Bass/Drums/Vocal): 96px label chip + 26px lane. A white
// playhead line sweeps across all lanes.
import 'package:flutter/material.dart';

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
// 한 트랙 행 최소 높이 — 라벨 칩의 11dp 아이콘 + 10pt 텍스트 + 칩 테두리가
// 잘리지 않는 한계. 작은 폰(부모 영역 < minTotal)에선 Expanded 균등 분배 대신
// 이 높이를 고정으로 쓰고 strip 전체를 세로 스크롤로 전환.
const double _minRowH = 32;

class Arrangement extends StatelessWidget {
  const Arrangement({
    super.key,
    required this.section,
    required this.activeId,
    required this.mutes,
    required this.onSelect,
    required this.onToggleMute,
    required this.playStep,
    required this.steps,
    required this.ranges,
  });

  final Section section;
  final String activeId;
  final Map<String, bool> mutes;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onToggleMute;
  final double playStep;
  final int steps;
  final Map<String, PitchRange> ranges;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        // 부모가 4 × _minRowH + gap 보다 작으면 Expanded 균등 분배는 텍스트가
        // 잘리는 수준이 되므로 → 고정 높이 + 세로 스크롤로 graceful fallback.
        final totalGap = _rowGap * (kTracks.length - 1);
        final minTotal = kTracks.length * _minRowH + totalGap;
        final needScroll = c.maxHeight < minTotal;

        final rows = <Widget>[];
        for (var i = 0; i < kTracks.length; i++) {
          if (i > 0) rows.add(const SizedBox(height: _rowGap));
          final row = _Row(
            meta: kTracks[i],
            data: section.tracks[kTracks[i].id]!,
            selected: kTracks[i].id == activeId,
            muted: mutes[kTracks[i].id] ?? false,
            onSelect: () => onSelect(kTracks[i].id),
            onToggleMute: () => onToggleMute(kTracks[i].id),
            steps: steps,
            range: ranges[kTracks[i].id],
          );
          rows.add(needScroll
              ? SizedBox(height: _minRowH, child: row)
              : Expanded(child: row));
        }

        final lanes = needScroll
            ? SingleChildScrollView(
                child: SizedBox(
                  height: minTotal,
                  child: Column(children: rows),
                ),
              )
            : Column(children: rows);

        return Stack(
          children: [
            // lanes fill the height the parent gives us (the 1:2 split) so the
            // strip scales with its allotted space instead of a fixed mini-map.
            // 작은 폰에선 스크롤로 떨어지지만 라벨/노트는 항상 가독 가능한 높이로.
            lanes,
            // playhead — viewport 기준으로 그려 lanes 스크롤과 무관하게 시간축
            // 표시 유지. (시간상 위치는 항상 같으므로 스크롤 따라가지 않아도 됨.)
            Positioned(
              left: _labelW + _gap,
              right: 0,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: LayoutBuilder(
                  builder: (context, c2) {
                    final x = (playStep / steps) * c2.maxWidth;
                    return Stack(
                      children: [
                        Positioned(
                          left: x,
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
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
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
  });

  final TrackMeta meta;
  final TrackData data;
  final bool selected;
  final bool muted;
  final VoidCallback onSelect;
  final VoidCallback onToggleMute;
  final int steps;
  final PitchRange? range;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onSelect,
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // label chip (fills the row height)
          Container(
            width: _labelW,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: selected ? meta.color.withValues(alpha: 0.12) : LT.surface,
              borderRadius: BorderRadius.circular(LTRadius.chip),
              border: Border.all(color: selected ? meta.color : LT.border),
            ),
            child: Row(
              children: [
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
          ),
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
      const rows = ['hihat', 'snare', 'kick'];
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
