// 노트 페인터 — 청크 배경 + 노트 직사각형 + _Geo 좌표 계산 + drumLabel 헬퍼.
part of '../timeline_editor.dart';

class _Geo {
  _Geo(this.notes, this.durationSec, this.size) {
    final pitched = notes.where((n) => n.kind == 'pitched').toList();
    if (pitched.isNotEmpty) {
      minP = pitched.map((n) => n.pitch).reduce((a, b) => a < b ? a : b) - 1;
      maxP = pitched.map((n) => n.pitch).reduce((a, b) => a > b ? a : b) + 1;
      if (maxP - minP < 6) {
        final cc = (maxP + minP) ~/ 2;
        minP = cc - 3;
        maxP = cc + 3;
      }
    }
  }
  final List<Note> notes;
  final double durationSec;
  final Size size;
  int minP = 48, maxP = 72;

  Rect rectFor(Note n) {
    final w = size.width, h = size.height;
    final x = (n.start / durationSec) * w;
    final bw = ((n.end - n.start) / durationSec * w).clamp(4.0, w);
    if (n.kind == 'percussive') {
      final row = n.pitch == 36 ? 2 : (n.pitch == 42 ? 0 : 1);
      final y = (h - 8) * (row / 2) + 2;
      return Rect.fromLTWH(x, y, bw.clamp(4.0, 12.0), 6);
    }
    final range = (maxP - minP).clamp(1, 127);
    final t = 1 - (n.pitch - minP) / range;
    final bh = (h / range).clamp(4.0, 9.0);
    final y = (t * (h - bh)).clamp(0.0, h - bh);
    return Rect.fromLTWH(x, y, bw, bh);
  }
}

class _NotesPainter extends CustomPainter {
  _NotesPainter({
    required this.notes,
    required this.durationSec,
    required this.active,
    required this.chunkRanges,
    this.loopReplicaRanges = const [],
    this.selectedNote,
    this.selectedChunk,
  });
  final List<Note> notes;
  final double durationSec;
  final bool active;
  /// 청크 id → [timelineStart, timelineEnd] — 트림 핸들과 일치하는 좌표.
  /// 비어있으면(레거시) 노트 범위로 폴백.
  final Map<int, List<double>> chunkRanges;
  /// 루프 반복본 청크 범위 — dashed border + 옅은 fill.
  final List<List<double>> loopReplicaRanges;
  final int? selectedNote;
  final int? selectedChunk;

  @override
  void paint(Canvas canvas, Size size) {
    final geo = _Geo(notes, durationSec, size);

    // 청크 배경 — chunkRanges 우선, 비어있으면 노트로부터 추정.
    Map<int, List<double>> ranges = chunkRanges;
    if (ranges.isEmpty && notes.isNotEmpty) {
      final fallback = <int, List<double>>{};
      for (final n in notes) {
        final r = fallback.putIfAbsent(n.chunkId, () => [n.start, n.end]);
        if (n.start < r[0]) r[0] = n.start;
        if (n.end > r[1]) r[1] = n.end;
      }
      ranges = fallback;
    }
    if (ranges.isNotEmpty) {
      ranges.forEach((id, r) {
        final x0 = (r[0] / durationSec) * size.width;
        final x1 = (r[1] / durationSec) * size.width;
        // 양쪽 padding 없음 — 인접 청크끼리 border 가 겹쳐 두 줄로 보이는 문제 방지.
        final rect = Rect.fromLTRB(x0, 1, x1, size.height - 1);
        final isSelected = id == selectedChunk;
        final baseAlpha = isSelected ? 0.16 : (active ? 0.08 : 0.04);
        final borderAlpha = isSelected ? 1.0 : (active ? 0.22 : 0.14);
        final borderWidth = isSelected ? 1.5 : 1.0;
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()..color = AppColors.lime.withValues(alpha: baseAlpha),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()
            ..color = AppColors.lime.withValues(alpha: borderAlpha)
            ..style = PaintingStyle.stroke
            ..strokeWidth = borderWidth,
        );
      });
    }

    // 루프 반복본 청크 — dashed border + 옅은 fill.
    for (final r in loopReplicaRanges) {
      final x0 = (r[0] / durationSec) * size.width;
      final x1 = (r[1] / durationSec) * size.width;
      final rect = Rect.fromLTRB(x0, 1, x1, size.height - 1);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(6)),
        Paint()..color = AppColors.lime.withValues(alpha: 0.03),
      );
      _drawDashedRRect(canvas, rect, const Radius.circular(6), AppColors.lime.withValues(alpha: 0.5));
    }

    for (int i = 0; i < notes.length; i++) {
      final n = notes[i];
      final r = geo.rectFor(n);
      final isReplica = n.chunkId < 0; // 루프 반복본 마킹.
      Color col;
      if (n.source == 'user') {
        col = const Color(0xFF3FB950);
      } else if (n.source == 'assistant') {
        col = const Color(0xFFF0883E);
      } else {
        col = active ? AppColors.lime : AppColors.textSecondary;
      }
      if (isReplica) col = col.withValues(alpha: 0.55);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = col);
      // selectedNote 는 원본 t.notes 인덱스 → 표시 노트의 renderSrcIndex 와 매칭(반복본 포함).
      if (selectedNote != null && n.renderSrcIndex == selectedNote) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(r.inflate(1.5), const Radius.circular(3)),
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NotesPainter old) =>
      old.notes != notes ||
      old.chunkRanges != chunkRanges ||
      old.loopReplicaRanges != loopReplicaRanges ||
      old.selectedNote != selectedNote ||
      old.selectedChunk != selectedChunk ||
      old.active != active ||
      old.durationSec != durationSec;
}

void _drawDashedRRect(Canvas canvas, Rect rect, Radius radius, Color color) {
  final path = Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
  final metrics = path.computeMetrics();
  const dashWidth = 4.0;
  const dashGap = 3.0;
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.2;
  for (final m in metrics) {
    double dist = 0;
    while (dist < m.length) {
      final next = (dist + dashWidth).clamp(0, m.length).toDouble();
      canvas.drawPath(m.extractPath(dist, next), paint);
      dist = next + dashGap;
    }
  }
}

String drumLabel(int pitch) => drumNames[pitch] ?? 'Drum $pitch';
