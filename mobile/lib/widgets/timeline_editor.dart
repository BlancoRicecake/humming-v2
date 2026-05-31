// CapCut 스타일 멀티트랙 타임라인.
// - 레인 영역: 1손가락 드래그=가로 스크롤, 2손가락 핀치=줌, 탭=노트선택/악기전환.
// - 룰러(시간 숫자): 터치+드래그=시킹(플레이헤드 이동).
// - 사이드바: 카테고리 헤더 + 그 아래 N개 트랙 라벨. 탭 → 트랙 활성화.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/models.dart';
import '../music/instrument_icons.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';

const double _rulerH = 22;
const double _laneGap = 6;
const double _labelW = 86; // 시안 (track-expansion.html) sidebar 너비
const double _basePx = 90;
const double _catH = 24; // 카테고리 헤더 행 높이
const double _trackH = 64; // 트랙 라벨/레인 행 높이

class TimelineEditor extends StatefulWidget {
  const TimelineEditor({
    super.key,
    required this.tracks,
    required this.activeTrackId,
    required this.durationSec,
    this.playheadSec,
    this.selectedNote,
    this.selectedChunk,
    this.onNoteTap,
    this.onChunkTap,
    this.onActivateTrack,
    this.onRecordAgain,
    this.onRecordEmpty,
    this.onSeek,
    this.onChunkMove,
    this.onChunkResize,
    this.notesOverride,
  });

  /// 전체 트랙(카테고리당 N개). 사이드바와 레인 모두 이 순서를 카테고리로 그룹화해
  /// 표시한다. 빈 카테고리는 헤더만 보여준다.
  final List<TrackData> tracks;
  final int? activeTrackId;
  final double durationSec;
  final double? playheadSec;
  final int? selectedNote;
  final int? selectedChunk;
  final void Function(int index)? onNoteTap;
  final void Function(int? chunkId)? onChunkTap; // null = 선택 해제
  final void Function(int trackId)? onActivateTrack;
  final void Function(int trackId)? onRecordAgain;
  /// 빈 트랙(녹음/노트 없음) 레인 안 "● 녹음 시작" pill 탭. 그 트랙으로 인라인 녹음 시작.
  final void Function(int trackId)? onRecordEmpty;
  final void Function(double sec)? onSeek;
  final void Function(int chunkId, double dtSec)? onChunkMove; // 길게 눌러 이동
  final void Function(int chunkId, {double? newStart, double? newEnd})? onChunkResize;

  /// 활성 트랙의 표시용 노트 오버라이드 (코드 모드 시 확장된 노트 등).
  /// null 이면 트랙의 `notes` 를 그대로 사용.
  final Map<int, List<Note>>? notesOverride;

  @override
  State<TimelineEditor> createState() => _TimelineEditorState();
}

class _TimelineEditorState extends State<TimelineEditor> {
  double _zoom = 1.0;
  double _scrollX = 0;
  double _startZoom = 1.0;

  // 청크 이동/트림 드래그 상태
  int? _moveChunk;
  double? _resizeStart, _resizeEnd;

  // 제스처 콜백에서 쓰는 레이아웃 값(빌드 때 갱신).
  double _dur = 1, _pxPerSec = 90, _contentW = 0, _vpW = 0, _maxScroll = 0;

  void _clampScroll() => _scrollX = _scrollX.clamp(0.0, _maxScroll);

  double _pxToSec(double dx) => dx * (_dur / _contentW);
  double _secToPx(double t) => (t / _dur) * _contentW;
  double _timeAt(double localX) => _pxToSec(localX + _scrollX).clamp(0.0, _dur);

  TrackData? get _activeTrack {
    for (final t in widget.tracks) {
      if (t.id == widget.activeTrackId) return t;
    }
    return null;
  }

  List<Note> _notesFor(TrackData t) {
    final ov = widget.notesOverride?[t.id];
    return ov ?? t.notes;
  }

  /// 카테고리 헤더 → 그 카테고리의 트랙들. 빈 카테고리도 entry 유지(헤더만 표시).
  List<(TrackRole, List<TrackData>)> _grouped() {
    final out = <(TrackRole, List<TrackData>)>[];
    for (final r in TrackRole.values) {
      out.add((r, widget.tracks.where((t) => t.role == r).toList()));
    }
    return out;
  }

  // 활성 트랙의 인덱스(전체 트랙 리스트 안에서) → 레인 영역의 y 오프셋 계산.
  // 사이드바와 레인 양쪽이 같은 행 시퀀스를 따라가야 정렬됨.
  Map<int, double> _trackTops() {
    final tops = <int, double>{};
    double y = 0;
    for (final (_, ts) in _grouped()) {
      y += _catH; // 카테고리 헤더 패드
      for (final t in ts) {
        tops[t.id] = y;
        y += _trackH;
      }
    }
    return tops;
  }

  double get _lanesH {
    double h = 0;
    for (final (_, ts) in _grouped()) {
      h += _catH + _trackH * ts.length;
    }
    return h;
  }

  // 선택된 청크의 양끝 트림 핸들(활성 트랙 레인). 좌/우 핸들을 끌어 길이 조절.
  List<Widget> _trimHandles() {
    final cid = widget.selectedChunk;
    final t = _activeTrack;
    if (cid == null || t == null) return const [];
    final notes = _notesFor(t);
    final ranges = _chunkRanges(notes);
    final r = ranges[cid];
    if (r == null) return const [];
    final top = _trackTops()[t.id];
    if (top == null) return const [];
    final laneTop = top;
    final laneH = _trackH - _laneGap;
    final leftX = _secToPx(r[0]) - _scrollX;
    final rightX = _secToPx(r[1]) - _scrollX;

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

  Map<int, List<double>> _chunkRanges(List<Note> notes) {
    final ranges = <int, List<double>>{};
    for (final n in notes) {
      final r = ranges.putIfAbsent(n.chunkId, () => [n.start, n.end]);
      if (n.start < r[0]) r[0] = n.start;
      if (n.end > r[1]) r[1] = n.end;
    }
    return ranges;
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
          _clampScroll();
          final headContentX = widget.playheadSec == null ? null : (widget.playheadSec! / _dur) * _contentW;
          final laneH = _lanesH;

          return SingleChildScrollView(
            // 전체 트랙 수가 늘어나면 세로 스크롤로 모두 접근 가능.
            child: SizedBox(
              height: math.max(c.maxHeight, _rulerH + laneH),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _labelColumn(),
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
                        // 레인 영역 — 1손가락 팬 / 2손가락 핀치줌 / 탭 선택
                        SizedBox(
                          height: laneH,
                          child: GestureDetector(
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
                                    child: Column(children: _laneRows()),
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
              ),
            ),
          );
        },
      ),
    );
  }

  // ─── 사이드바 ───────────────────────────────────────────────────────────
  Widget _labelColumn() {
    final groups = _grouped();
    return SizedBox(
      width: _labelW,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: _rulerH),
          for (final (role, ts) in groups) ...[
            // 카테고리 헤더
            SizedBox(
              height: _catH,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Text(
                  role.label.toUpperCase(),
                  style: T.label.copyWith(fontSize: 10, letterSpacing: 1, color: AppColors.textSecondary),
                ),
              ),
            ),
            for (final t in ts) _trackLabel(t),
          ],
        ],
      ),
    );
  }

  Widget _trackLabel(TrackData t) {
    final active = t.id == widget.activeTrackId;
    final hasRec = t.hasRecording;
    final color = active ? AppColors.lime : AppColors.textSecondary;
    return SizedBox(
      height: _trackH,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onActivateTrack?.call(t.id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Opacity(
                opacity: hasRec ? 1.0 : 0.5,
                child: instrumentIcon(_iconProgram(t), size: 18, color: color),
              ),
              const SizedBox(height: 2),
              Opacity(
                opacity: hasRec ? 1.0 : 0.5,
                child: Text(
                  _trackDisplayName(t),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.label.copyWith(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    color: color,
                  ),
                ),
              ),
              if (hasRec) ...[
                const SizedBox(height: 3),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onRecordAgain?.call(t.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: AppColors.lime, width: 1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '재녹음',
                      style: T.label.copyWith(
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        color: AppColors.lime,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _trackDisplayName(TrackData t) {
    if (t.role == TrackRole.drum) return 'DRUM';
    if (t.role == TrackRole.vocal) return 'VOCAL';
    for (final i in instrumentPalette[t.role] ?? const <Instrument>[]) {
      if (i.program == t.program) return i.label.toUpperCase();
    }
    return t.role.label.toUpperCase();
  }

  int _iconProgram(TrackData t) {
    switch (t.role) {
      case TrackRole.drum:
        return kDrumKitProgram;
      case TrackRole.vocal:
        return kVocalProgram;
      case TrackRole.keys:
      case TrackRole.bass:
        return t.program;
    }
  }

  // ─── 레인 영역 ──────────────────────────────────────────────────────────
  List<Widget> _laneRows() {
    final rows = <Widget>[];
    for (final (_, ts) in _grouped()) {
      rows.add(const SizedBox(height: _catH)); // 카테고리 헤더 패드
      for (final t in ts) {
        rows.add(SizedBox(
          height: _trackH,
          child: Padding(
            padding: const EdgeInsets.only(bottom: _laneGap),
            child: Opacity(
              opacity: t.enabled ? 1 : 0.4,
              child: _lane(t),
            ),
          ),
        ));
      }
    }
    return rows;
  }

  Widget _ruler() {
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

  Widget _lane(TrackData t) {
    final active = t.id == widget.activeTrackId;
    final notes = _notesFor(t);
    final hasWave = t.isVocal && t.vocalPeaks.isNotEmpty;
    // 빈 트랙(녹음/노트 없음) → 레인 중앙에 "● 녹음 시작" pill 표시(시안 track-expansion.html).
    // 노트 또는 보컬 파형이 생기면 자동으로 사라짐(청크 블록과 겹치지 않게).
    final isEmpty = notes.isEmpty && !hasWave && !t.hasRecording;

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

          return Stack(children: [
            // [Layer 0] 시각 + 레인 전체 hit (활성화 / 선택 해제)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (!active) widget.onActivateTrack?.call(t.id);
                  widget.onChunkTap?.call(null);
                },
                child: CustomPaint(
                  size: Size.infinite,
                  painter: hasWave
                      ? _WavePainter(peaks: t.vocalPeaks, vocalDur: t.vocalDuration, totalDur: _dur, active: active)
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
            if (!hasWave)
              for (final entry in _chunkRanges(notes).entries)
                _chunkHitWidget(t, active, entry.key, entry.value, laneW, laneH),

            // [Layer 2] 단일 노트
            if (!hasWave)
              for (int i = 0; i < notes.length; i++)
                _noteHitWidget(t, active, i, geo.rectFor(notes[i])),

            // [Layer 3] 빈 트랙 인라인 녹음 pill — 노트/파형 위에 그릴 일 없음(isEmpty 가드).
            if (isEmpty) Positioned.fill(child: Center(child: _recPill(t))),
          ]);
        }),
      ),
    );
  }

  // 빈 트랙 레인 안 "● 녹음 시작" pill. 탭 → 해당 트랙 활성화 + 인라인 녹음 시작.
  Widget _recPill(TrackData t) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (t.id != widget.activeTrackId) widget.onActivateTrack?.call(t.id);
        widget.onRecordEmpty?.call(t.id);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1F1F27),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 8, height: 8,
            decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text('녹음 시작',
              style: T.body.copyWith(fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _chunkHitWidget(TrackData t, bool active, int chunkId, List<double> range, double laneW, double laneH) {
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
          if (!active) widget.onActivateTrack?.call(t.id);
          widget.onChunkTap?.call(chunkId);
        },
        onHorizontalDragStart: (_) {
          if (!active) widget.onActivateTrack?.call(t.id);
          _moveChunk = chunkId;
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

  Widget _noteHitWidget(TrackData t, bool active, int noteIndex, Rect rect) {
    const padX = 2.0;
    return Positioned(
      left: rect.left - padX,
      top: rect.top,
      width: rect.width + padX * 2,
      height: rect.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          if (!active) widget.onActivateTrack?.call(t.id);
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

    if (notes.isNotEmpty) {
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
