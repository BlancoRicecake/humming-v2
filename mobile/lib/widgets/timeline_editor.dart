// CapCut 스타일 멀티트랙 타임라인.
// - 레인 영역: 1손가락 드래그=가로 스크롤, 2손가락 핀치=줌, 탭=노트선택/악기전환.
// - 룰러(시간 숫자): 터치+드래그=시킹(플레이헤드 이동).
// - 사이드바(레이블) 탭=트랙 활성/비활성.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../models/models.dart';
import '../theme/app_theme.dart';

const double _rulerH = 22;
const double _laneGap = 6;
const double _labelW = 46;
const double _basePx = 90;

class TimelineEditor extends StatefulWidget {
  const TimelineEditor({
    super.key,
    required this.tracks,
    required this.enabled,
    required this.activeRole,
    required this.durationSec,
    this.playheadSec,
    this.selectedNote,
    this.selectedChunk,
    this.waveforms = const {},
    this.onNoteTap,
    this.onChunkTap,
    this.onActivateRole,
    this.onToggleEnable,
    this.onSeek,
    this.onChunkMove,
    this.onChunkResize,
  });

  final Map<TrackRole, List<Note>> tracks;
  final Map<TrackRole, bool> enabled;
  final TrackRole activeRole;
  final double durationSec;
  final double? playheadSec;
  final int? selectedNote;
  final int? selectedChunk;
  final Map<TrackRole, ({List<double> peaks, double dur})> waveforms; // 보컬 등 파형 표시 트랙
  final void Function(int index)? onNoteTap;
  final void Function(int? chunkId)? onChunkTap; // null = 선택 해제
  final void Function(TrackRole role)? onActivateRole;
  final void Function(TrackRole role)? onToggleEnable;
  final void Function(double sec)? onSeek;
  final void Function(int chunkId, double dtSec)? onChunkMove; // 길게 눌러 이동
  final void Function(int chunkId, {double? newStart, double? newEnd})? onChunkResize; // 양끝 트림

  @override
  State<TimelineEditor> createState() => _TimelineEditorState();
}

class _TimelineEditorState extends State<TimelineEditor> {
  double _zoom = 1.0;
  double _scrollX = 0;
  double _startZoom = 1.0;

  // 청크 이동/트림 드래그 상태
  int? _moveChunk;
  double _movePrevCum = 0;
  double? _resizeStart, _resizeEnd;

  // 제스처 콜백에서 쓰는 레이아웃 값(빌드 때 갱신).
  double _dur = 1, _pxPerSec = 90, _contentW = 0, _vpW = 0, _lanesH = 0, _maxScroll = 0;

  void _clampScroll() => _scrollX = _scrollX.clamp(0.0, _maxScroll);

  double _timeAt(double localX) => ((localX + _scrollX) / _pxPerSec).clamp(0.0, _dur);

  void _onTap(TapUpDetails d) {
    final lp = d.localPosition;
    final slot = _lanesH / TrackRole.values.length;
    final idx = (lp.dy / slot).floor().clamp(0, TrackRole.values.length - 1);
    final role = TrackRole.values[idx];

    // 캡컷식: 탭한 레인의 청크/노트만 선택 가능(빈 곳=선택 해제). 다른 트랙의
    // 청크/노트를 탭해도 한 번에 그 트랙으로 전환 + 선택.
    if (role != widget.activeRole) widget.onActivateRole?.call(role);

    final notes = widget.tracks[role] ?? const [];
    final withinY = lp.dy - idx * slot;
    final contentX = lp.dx + _scrollX;
    final geo = _Geo(notes, _dur, Size(_contentW, slot - _laneGap));

    // 1) 노트 히트 → 노트 선택.
    for (int i = 0; i < notes.length; i++) {
      if (geo.rectFor(notes[i]).inflate(8).contains(Offset(contentX, withinY))) {
        if (widget.onNoteTap != null) widget.onNoteTap!(i);
        return;
      }
    }

    // 2) 청크 영역 히트 → 청크 선택. 빈 곳이면 null(선택 해제).
    final time = contentX / _pxPerSec;
    int? cid;
    final ranges = <int, List<double>>{}; // chunkId → [minStart, maxEnd]
    for (final n in notes) {
      final r = ranges.putIfAbsent(n.chunkId, () => [n.start, n.end]);
      if (n.start < r[0]) r[0] = n.start;
      if (n.end > r[1]) r[1] = n.end;
    }
    ranges.forEach((id, r) {
      if (time >= r[0] && time <= r[1]) cid = id;
    });
    widget.onChunkTap?.call(cid);
  }

  Map<int, List<double>> _chunkRanges(List<Note> notes) {
    final ranges = <int, List<double>>{};
    for (final n in notes) {
      final r = ranges.putIfAbsent(n.chunkId, () => [n.start, n.end]);
      if (n.start < r[0]) r[0] = n.start;
      if (n.end > r[1]) r[1] = n.end;
    }
    return ranges;
  }

  // 길게 눌러 청크 이동 — 활성 레인에서 누른 청크를 잡아 가로로 끌면 위치 이동.
  void _onLongPressStart(LongPressStartDetails d) {
    final slot = _lanesH / TrackRole.values.length;
    final idx = (d.localPosition.dy / slot).floor().clamp(0, TrackRole.values.length - 1);
    if (TrackRole.values[idx] != widget.activeRole) return;
    final time = (d.localPosition.dx + _scrollX) / _pxPerSec;
    int? cid;
    _chunkRanges(widget.tracks[widget.activeRole] ?? const []).forEach((id, r) {
      if (time >= r[0] && time <= r[1]) cid = id;
    });
    if (cid == null) return;
    _moveChunk = cid;
    _movePrevCum = 0;
    widget.onChunkTap?.call(cid); // 선택 표시
  }

  void _onLongPressMove(LongPressMoveUpdateDetails d) {
    if (_moveChunk == null) return;
    final cum = d.localOffsetFromOrigin.dx;
    final dtSec = (cum - _movePrevCum) / _pxPerSec;
    _movePrevCum = cum;
    if (dtSec != 0) widget.onChunkMove?.call(_moveChunk!, dtSec);
  }

  void _onLongPressEnd(_) => _moveChunk = null;

  // 선택된 청크의 양끝 트림 핸들(활성 레인). 좌/우 핸들을 끌어 길이 조절.
  List<Widget> _trimHandles() {
    final cid = widget.selectedChunk;
    if (cid == null) return const [];
    final notes = widget.tracks[widget.activeRole] ?? const [];
    final r = _chunkRanges(notes)[cid];
    if (r == null) return const [];
    final idx = TrackRole.values.indexOf(widget.activeRole);
    final slot = _lanesH / TrackRole.values.length;
    final laneTop = idx * slot;
    final laneH = slot - _laneGap;
    final leftX = r[0] * _pxPerSec - _scrollX;
    final rightX = r[1] * _pxPerSec - _scrollX;

    Widget handle(double x, bool isLeft) => Positioned(
          left: x - 11,
          top: laneTop,
          height: laneH,
          width: 22,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => isLeft ? _resizeStart = r[0] : _resizeEnd = r[1],
            onHorizontalDragUpdate: (d) {
              if (isLeft) {
                _resizeStart = (_resizeStart ?? r[0]) + d.delta.dx / _pxPerSec;
                widget.onChunkResize?.call(cid, newStart: _resizeStart);
              } else {
                _resizeEnd = (_resizeEnd ?? r[1]) + d.delta.dx / _pxPerSec;
                widget.onChunkResize?.call(cid, newEnd: _resizeEnd);
              }
            },
            onHorizontalDragEnd: (_) {
              _resizeStart = null;
              _resizeEnd = null;
            },
            child: Center(
              child: Container(
                width: 4,
                height: laneH * 0.6,
                decoration: BoxDecoration(color: AppColors.lime, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
        );

    return [handle(leftX, true), handle(rightX, false)];
  }

  @override
  Widget build(BuildContext context) {
    _dur = math.max(widget.durationSec, 0.5);
    return Container(
      color: AppColors.bg,
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: LayoutBuilder(
        builder: (context, c) {
          _vpW = c.maxWidth - _labelW - 4;
          _pxPerSec = _basePx * _zoom;
          _contentW = math.max(_dur * _pxPerSec, _vpW);
          _maxScroll = math.max(0, _contentW - _vpW);
          _lanesH = c.maxHeight - _rulerH;
          _clampScroll();
          final headContentX = widget.playheadSec == null ? null : (widget.playheadSec! / _dur) * _contentW;

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _labelColumn(c.maxHeight),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  children: [
                    // 룰러 — 터치+드래그 시킹
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (d) => widget.onSeek?.call(_timeAt(d.localPosition.dx)),
                      onHorizontalDragUpdate: (d) => widget.onSeek?.call(_timeAt(d.localPosition.dx)),
                      child: ClipRect(
                        child: SizedBox(
                          height: _rulerH,
                          width: _vpW,
                          child: Stack(children: [
                            Positioned(left: -_scrollX, top: 0, width: _contentW, child: _ruler()),
                          ]),
                        ),
                      ),
                    ),
                    // 레인 — 1손가락 팬 / 2손가락 핀치줌 / 탭 선택
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: _onTap,
                        onLongPressStart: _onLongPressStart,
                        onLongPressMoveUpdate: _onLongPressMove,
                        onLongPressEnd: _onLongPressEnd,
                        onScaleStart: (_) => _startZoom = _zoom,
                        onScaleUpdate: (d) {
                          setState(() {
                            if (d.scale != 1.0) {
                              _zoom = (_startZoom * d.scale).clamp(0.3, 6.0);
                            }
                            _scrollX -= d.focalPointDelta.dx;
                            _clampScroll();
                          });
                        },
                        child: ClipRect(
                          child: Stack(
                            children: [
                              Positioned(
                                left: -_scrollX,
                                top: 0,
                                bottom: 0,
                                width: _contentW,
                                child: Column(
                                  children: [
                                    for (final role in TrackRole.values)
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.only(bottom: _laneGap),
                                          child: Opacity(
                                            opacity: (widget.enabled[role] ?? true) ? 1 : 0.4,
                                            child: _lane(role),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              ..._trimHandles(),
                              if (headContentX != null && headContentX - _scrollX >= 0 && headContentX - _scrollX <= _vpW)
                                Positioned(
                                  left: headContentX - _scrollX,
                                  top: 0,
                                  bottom: 0,
                                  child: IgnorePointer(child: Container(width: 2, color: Colors.white)),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _labelColumn(double h) => SizedBox(
        width: _labelW,
        height: h,
        child: Column(
          children: [
            const SizedBox(height: _rulerH),
            for (final role in TrackRole.values)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: _laneGap),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onToggleEnable?.call(role),
                    child: Opacity(
                      opacity: (widget.enabled[role] ?? true) ? 1 : 0.4,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon((widget.enabled[role] ?? true) ? role.icon : Symbols.volume_off,
                                size: 16, color: AppColors.textPrimary),
                            const SizedBox(height: 2),
                            Text(role.label.toUpperCase(), style: T.label),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _ruler() {
    final secs = _dur.ceil();
    return SizedBox(
      width: _contentW,
      height: _rulerH,
      child: Row(
        children: [
          for (int s = 0; s <= secs; s++)
            SizedBox(
              width: _pxPerSec,
              child: Text('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}', style: T.label.copyWith(fontSize: 9)),
            ),
        ],
      ),
    );
  }

  Widget _lane(TrackRole role) {
    final active = role == widget.activeRole;
    final wave = widget.waveforms[role];
    return Container(
      decoration: BoxDecoration(
        color: active ? AppColors.activeLane : AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: active ? Border.all(color: AppColors.lime, width: 1) : null,
      ),
      child: CustomPaint(
        size: Size.infinite,
        painter: (wave != null && wave.peaks.isNotEmpty)
            ? _WavePainter(peaks: wave.peaks, vocalDur: wave.dur, totalDur: _dur, active: active)
            : _NotesPainter(
                notes: widget.tracks[role] ?? const [],
                durationSec: _dur,
                active: active,
                selectedNote: active ? widget.selectedNote : null,
                selectedChunk: active ? widget.selectedChunk : null,
              ),
      ),
    );
  }
}

/// 보컬 파형 — peaks 를 0..vocalDur 구간에 중앙 대칭으로 채워 그림.
class _WavePainter extends CustomPainter {
  _WavePainter({required this.peaks, required this.vocalDur, required this.totalDur, required this.active});
  final List<double> peaks;
  final double vocalDur, totalDur;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty || totalDur <= 0) return;
    final w = (vocalDur / totalDur) * size.width;
    final cy = size.height / 2;
    final paint = Paint()..color = active ? AppColors.lime : AppColors.textSecondary;
    final n = peaks.length;
    final step = w / n;
    for (int i = 0; i < n; i++) {
      final h = (peaks[i] * size.height * 0.9).clamp(1.0, size.height);
      final x = i * step;
      canvas.drawRect(Rect.fromLTWH(x, cy - h / 2, step.clamp(0.6, 3.0), h), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.peaks != peaks || old.vocalDur != vocalDur || old.totalDur != totalDur || old.active != active;
}

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
    this.selectedNote,
    this.selectedChunk,
  });
  final List<Note> notes;
  final double durationSec;
  final bool active;
  final int? selectedNote;
  final int? selectedChunk;

  @override
  void paint(Canvas canvas, Size size) {
    final geo = _Geo(notes, durationSec, size);

    // 활성 레인: 청크 배경(반투명) — 선택된 청크는 강조. 노트 뒤에 먼저 그림.
    if (active && notes.isNotEmpty) {
      final ranges = <int, List<double>>{};
      for (final n in notes) {
        final r = ranges.putIfAbsent(n.chunkId, () => [n.start, n.end]);
        if (n.start < r[0]) r[0] = n.start;
        if (n.end > r[1]) r[1] = n.end;
      }
      ranges.forEach((id, r) {
        final x0 = (r[0] / durationSec) * size.width;
        final x1 = (r[1] / durationSec) * size.width;
        final rect = Rect.fromLTRB(x0 - 2, 1, x1 + 2, size.height - 1);
        final sel = id == selectedChunk;
        canvas.drawRRect(
          RRect.fromRectAndRadius(rect, const Radius.circular(6)),
          Paint()..color = (sel ? AppColors.lime : Colors.white).withValues(alpha: sel ? 0.14 : 0.05),
        );
        if (sel) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, const Radius.circular(6)),
            Paint()
              ..color = AppColors.lime
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
        }
      });
    }

    for (int i = 0; i < notes.length; i++) {
      final n = notes[i];
      final r = geo.rectFor(n);
      Color col;
      if (n.source == 'user') {
        col = const Color(0xFF3FB950);
      } else if (n.source == 'assistant') {
        col = const Color(0xFFF0883E);
      } else {
        col = active ? AppColors.lime : AppColors.textSecondary;
      }
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(2)), Paint()..color = col);
      if (i == selectedNote) {
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
      old.selectedNote != selectedNote ||
      old.selectedChunk != selectedChunk ||
      old.active != active ||
      old.durationSec != durationSec;
}

String drumLabel(int pitch) => drumNames[pitch] ?? 'Drum $pitch';
