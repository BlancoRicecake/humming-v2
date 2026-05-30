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

  // 짧은 트랙에서 _contentW 가 _vpW 로 늘어나면 _pxPerSec 식이 시각과 어긋난다.
  // painter / chunk outline 과 동일한 ratio 변환을 단일 진실로 사용.
  double _pxToSec(double dx) => dx * (_dur / _contentW);
  double _secToPx(double t) => (t / _dur) * _contentW;
  double _timeAt(double localX) => _pxToSec(localX + _scrollX).clamp(0.0, _dur);

  // 청크 범위 계산 (chunkId → [minStart, maxEnd]). 트림 핸들 + 청크 hit-test 공용.
  Map<int, List<double>> _chunkRanges(List<Note> notes) {
    final ranges = <int, List<double>>{};
    for (final n in notes) {
      final r = ranges.putIfAbsent(n.chunkId, () => [n.start, n.end]);
      if (n.start < r[0]) r[0] = n.start;
      if (n.end > r[1]) r[1] = n.end;
    }
    return ranges;
  }

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
    final leftX = _secToPx(r[0]) - _scrollX;
    final rightX = _secToPx(r[1]) - _scrollX;

    // 핸들 hit 영역 12px (시각 4px 바 + 좌우 여백). 22px 였을 때 청크 몸체 드래그(이동)
    // 가 가장자리 ±11px 에서 핸들로 빨려들어가는 문제 회피.
    Widget handle(double x, bool isLeft) => Positioned(
          left: x - 6,
          top: laneTop,
          height: laneH,
          width: 12,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => isLeft ? _resizeStart = r[0] : _resizeEnd = r[1],
            onHorizontalDragUpdate: (d) {
              if (isLeft) {
                _resizeStart = (_resizeStart ?? r[0]) + _pxToSec(d.delta.dx);
                widget.onChunkResize?.call(cid, newStart: _resizeStart);
              } else {
                _resizeEnd = (_resizeEnd ?? r[1]) + _pxToSec(d.delta.dx);
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
                        // 탭 / 길게-눌러-이동은 레인 내부 레이어드 GD 가 처리.
                        // 루트는 핀치 줌 + 단일/멀티 손가락 팬만 담당.
                        behavior: HitTestBehavior.opaque,
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
    // 라벨은 시각 비례(_secToPx) 로 배치해 짧은 트랙이 viewport 를 채울 때도 균등 정렬.
    final maxSec = _dur.floor();
    return SizedBox(
      width: _contentW,
      height: _rulerH,
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          for (int s = 0; s <= maxSec; s++)
            Positioned(
              left: _secToPx(s.toDouble()),
              top: 0,
              child: Text(
                '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
                style: T.label.copyWith(fontSize: 9),
              ),
            ),
        ],
      ),
    );
  }

  Widget _lane(TrackRole role) {
    final active = role == widget.activeRole;
    final wave = widget.waveforms[role];
    final notes = widget.tracks[role] ?? const [];
    final isWave = wave != null && wave.peaks.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: active ? AppColors.activeLane : AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: active ? Border.all(color: AppColors.lime, width: 1) : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(builder: (ctx, c) {
          final laneW = c.maxWidth;
          final laneH = c.maxHeight;
          final geo = _Geo(notes, _dur, Size(laneW, laneH));

          // 아래에서 위로: 레인 전체 → 청크 → 노트.
          // Flutter 가 자연스럽게 가장 위 레이어부터 hit-test 해 적절한 핸들러를 찾는다.
          return Stack(children: [
            // [Layer 0] 시각 + 레인 전체 hit (활성화 / 선택 해제)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!active) widget.onActivateRole?.call(role);
                  widget.onChunkTap?.call(null); // null = 노트·청크 둘 다 deselect
                },
                child: CustomPaint(
                  size: Size.infinite,
                  painter: isWave
                      ? _WavePainter(peaks: wave.peaks, vocalDur: wave.dur, totalDur: _dur, active: active)
                      : _NotesPainter(
                          notes: notes,
                          durationSec: _dur,
                          active: active,
                          selectedNote: active ? widget.selectedNote : null,
                          selectedChunk: active ? widget.selectedChunk : null,
                        ),
                ),
              ),
            ),

            // [Layer 1] 청크 — 파형(보컬) 레인은 청크 개념 없음
            if (!isWave)
              for (final entry in _chunkRanges(notes).entries)
                _chunkHitWidget(role, active, entry.key, entry.value, laneW, laneH),

            // [Layer 2] 단일 노트 — 시각상 가장 위. Flutter 가 우선 hit.
            if (!isWave)
              for (int i = 0; i < notes.length; i++)
                _noteHitWidget(role, active, i, geo.rectFor(notes[i])),
          ]);
        }),
      ),
    );
  }

  Widget _chunkHitWidget(TrackRole role, bool active, int chunkId, List<double> range, double laneW, double laneH) {
    final x0 = _secToPx(range[0]);
    final x1 = _secToPx(range[1]);
    return Positioned(
      left: x0,
      top: 0,
      width: math.max(8, x1 - x0),
      height: laneH,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!active) widget.onActivateRole?.call(role);
          widget.onChunkTap?.call(chunkId);
        },
        // 청크 몸체 드래그 = 이동 (long-press 불필요).
        // 가장자리 ±6px 는 트림 핸들 hit 영역(width 12)이라 그쪽은 핸들이 catch.
        onHorizontalDragStart: (_) {
          if (!active) widget.onActivateRole?.call(role);
          _moveChunk = chunkId;
          _movePrevCum = 0;
          widget.onChunkTap?.call(chunkId);
        },
        onHorizontalDragUpdate: (d) {
          if (_moveChunk != chunkId) return;
          final dtSec = _pxToSec(d.delta.dx);
          if (dtSec != 0) widget.onChunkMove?.call(chunkId, dtSec);
        },
        onHorizontalDragEnd: (_) => _moveChunk = null,
        onHorizontalDragCancel: () => _moveChunk = null,
      ),
    );
  }

  Widget _noteHitWidget(TrackRole role, bool active, int noteIndex, Rect rect) {
    // hit 영역은 시각 rect 와 일치시켜야 청크의 빈 공간이 그대로 chunk-tap 영역으로
    // 살아남는다. 인플레이트하면 작은 노트가 청크 전체를 덮어 chunk-tap 이 핸들 위치
    // 외엔 막힌다. 가로만 살짝(±2px) 키워 정밀도 보조.
    const padX = 2.0;
    return Positioned(
      left: rect.left - padX,
      top: rect.top,
      width: rect.width + padX * 2,
      height: rect.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!active) widget.onActivateRole?.call(role);
          if (widget.onNoteTap != null) widget.onNoteTap!(noteIndex);
        },
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
