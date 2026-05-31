// CapCut 스타일 멀티트랙 타임라인.
// - 레인 영역: 1손가락 드래그=가로 스크롤, 2손가락 핀치=줌, 탭=노트선택/악기전환.
// - 룰러(시간 숫자): 터치+드래그=시킹(플레이헤드 이동).
// - 사이드바: 카테고리 헤더 + 그 아래 N개 트랙 라벨. 탭 → 트랙 활성화.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../models/models.dart';
import '../music/instrument_icons.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';

const double _rulerH = 22;
const double _laneGap = 6;
const double _basePx = 90;

/// 인라인 녹음 phase — TimelineEditor 가 트랙 안에 카운트다운/녹음 UI 표시.
enum InlineRecPhase { idle, countingDown, recording }
const double _anchorX = 86; // 좌측 고정 영역 — 플레이헤드 기준선이 위치하는 x.
const double _catH = 26; // 카테고리 헤더 행 높이
const double _trackNameH = 20; // 레인 위쪽 트랙 이름 행 높이
const double _trackH = 56; // 레인 자체 높이 (이름 행 제외)

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
    this.onToggleEnabled,
    this.onRecordEmpty,
    this.onSeek,
    this.onChunkMove,
    this.onChunkResize,
    this.notesOverride,
    this.pending,
    this.onPendingUse,
    this.onPendingDiscard,
    this.onPendingToggleAssist,
    this.recPhase = InlineRecPhase.idle,
    this.recTrackId,
    this.recCountdownN = 3,
    this.recCountdownProgress = 0,
    this.recElapsedMs = 0,
    this.recLevels = const [],
    this.onStopRec,
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
  final void Function(int trackId)? onToggleEnabled;
  /// 빈 트랙(녹음/노트 없음) 레인 안 "● 녹음 시작" pill 탭. 그 트랙으로 인라인 녹음 시작.
  final void Function(int trackId)? onRecordEmpty;
  final void Function(double sec)? onSeek;
  final void Function(int chunkId, double dtSec)? onChunkMove; // 길게 눌러 이동
  final void Function(int chunkId, {double? newLeftTimeline, double? newRightTimeline})? onChunkResize;

  /// 활성 트랙의 표시용 노트 오버라이드 (코드 모드 시 확장된 노트 등).
  /// null 이면 트랙의 `notes` 를 그대로 사용.
  final Map<int, List<Note>>? notesOverride;

  /// 녹음 종료 직후 분석된 임시 결과 — 해당 트랙 레인 위에 사용/삭제 다이얼로그
  /// 오버레이로 표시한다(task #26). null 이면 다이얼로그 미표시.
  final PendingRecording? pending;
  final VoidCallback? onPendingUse;
  final VoidCallback? onPendingDiscard;
  final void Function(bool on)? onPendingToggleAssist;

  /// 인라인 녹음 — 카운트다운/녹음 중 해당 트랙 레인 안 UI 표시.
  final InlineRecPhase recPhase;
  final int? recTrackId; // 녹음 중인 트랙 id
  final int recCountdownN; // 3 / 2 / 1
  final double recCountdownProgress; // 0..1 한 비트 안 진행률
  final int recElapsedMs;
  final List<double> recLevels; // 최근 amplitude (0..1)
  final VoidCallback? onStopRec;

  @override
  State<TimelineEditor> createState() => _TimelineEditorState();
}

class _TimelineEditorState extends State<TimelineEditor> with TickerProviderStateMixin {
  double _zoom = 1.0;
  double _scrollX = 0;
  double _startZoom = 1.0;

  // 청크 이동/트림 드래그 상태
  int? _moveChunk;
  double? _resizeStart, _resizeEnd;
  double? _moveDxAcc; // 롱프레스 이동 — offsetFromOrigin.dx 누적값(델타 계산용)
  Timer? _autoScrollTimer;
  int _autoScrollDir = 0; // -1 / 0 / +1

  // 스냅 — 현재 드래그 중인 청크/핸들이 붙은 timeline 좌표(시각화 + 햅틱 중복 방지).
  double? _snapTimeline;
  double? _lastSnapTimeline;
  // 청크 드래그용 — 손가락이 원하는 위치(스냅 미적용) 추적 + 현재 스냅된 target.
  // 히스테리시스: engage 10px, release 22px (스냅이 너무 끈적해 보이지 않게).
  double? _desiredChunkStart;
  double? _snappedToTarget;

  // 스크롤 부드러운 이동(시킹/센터링용). 외부 변경 시작 직전에 stop 해야
  // 사용자 수동 팬과 충돌하지 않음.
  AnimationController? _scrollAnim;

  // 사용자가 직접 pan 중인지 — didUpdateWidget 에서 외부 playheadSec 로 scrollX 덮어쓰지
  // 않도록 가드(피드백 루프 방지).
  bool _panning = false;

  // 제스처 콜백에서 쓰는 레이아웃 값(빌드 때 갱신).
  double _dur = 1, _pxPerSec = 90, _contentW = 0, _vpW = 0, _maxScroll = 0;

  void _clampScroll() => _scrollX = _scrollX.clamp(0.0, _maxScroll);

// ─── 스냅 ──────────────────────────────────────────────────────────────
  // 청크 이동/트림 드래그 시 다른 청크 경계 + 플레이헤드 + 0초 에 자석처럼 붙는다.
  // 임계값: 화면상 10px (현재 zoom 의 _pxPerSec 기준 초로 환산).

  /// 스냅 후보 — 모든 트랙의 청크 경계 + 0. excludeChunkId 제외.
  /// 앵커 모델에선 playheadSec === scrollX/pxPerSec 라 청크 드래그 시 자동 스크롤이
  /// playheadSec 를 같이 움직여 청크가 그 근처에 영구 snap 되어 못 넘어가는 문제 발생 →
  /// playhead 는 snap 타겟에서 제외.
  List<double> _snapTargets({int? excludeChunkId}) {
    final out = <double>[0.0];
    for (final t in widget.tracks) {
      for (final c in t.chunks) {
        if (c.id == excludeChunkId) continue;
        out.add(c.timelineStart);
        out.add(c.timelineEnd);
      }
    }
    return out;
  }

  /// 후보 중 시간 t 에 가장 가까운 좌표를 스냅 임계값 안에서 찾기. 없으면 null.
  double? _closestSnap(double t, List<double> targets) {
    final thresholdSec = _pxToSec(10);
    double? best;
    double bestDist = thresholdSec;
    for (final tgt in targets) {
      final d = (tgt - t).abs();
      if (d < bestDist) {
        bestDist = d;
        best = tgt;
      }
    }
    return best;
  }

  /// 청크 이동 — 손가락 원하는 위치(desiredStart) 기준으로 스냅 적용 후 최종 시작점 반환.
  /// 히스테리시스: 한번 스냅되면 release 임계값(22px) 넘어야 풀림 → 손가락 따라가는 느낌.
  double _snapResolveStart({
    required double desiredStart,
    required double chunkLength,
    required List<double> targets,
  }) {
    final desiredEnd = desiredStart + chunkLength;
    final engageSec = _pxToSec(10);
    final releaseSec = _pxToSec(22);

    // 이미 스냅된 target 이 있으면 release 거리 안에 들면 유지.
    if (_snappedToTarget != null) {
      final dStart = (_snappedToTarget! - desiredStart).abs();
      final dEnd = (_snappedToTarget! - desiredEnd).abs();
      final closer = math.min(dStart, dEnd);
      if (closer < releaseSec) {
        _onSnapHit(_snappedToTarget);
        return dStart <= dEnd
            ? _snappedToTarget! // start 정렬
            : (_snappedToTarget! - chunkLength); // end 정렬
      }
      _snappedToTarget = null; // release
    }

    // 새 스냅 engage 체크.
    double? bestT;
    double bestDist = engageSec;
    bool snapEnd = false;
    for (final t in targets) {
      final ds = (t - desiredStart).abs();
      if (ds < bestDist) {
        bestDist = ds;
        bestT = t;
        snapEnd = false;
      }
      final de = (t - desiredEnd).abs();
      if (de < bestDist) {
        bestDist = de;
        bestT = t;
        snapEnd = true;
      }
    }
    if (bestT != null) {
      _snappedToTarget = bestT;
      _onSnapHit(bestT);
      return snapEnd ? (bestT - chunkLength) : bestT;
    }
    _onSnapHit(null);
    return desiredStart;
  }

  void _onSnapHit(double? sec) {
    if (sec == null) {
      if (_snapTimeline != null) {
        setState(() => _snapTimeline = null);
      }
      return;
    }
    if (_lastSnapTimeline == null || (_lastSnapTimeline! - sec).abs() > 1e-4) {
      HapticFeedback.selectionClick();
    }
    _lastSnapTimeline = sec;
    if (_snapTimeline != sec) {
      setState(() => _snapTimeline = sec);
    }
  }

  void _clearSnap() {
    _lastSnapTimeline = null;
    if (_snapTimeline != null) {
      setState(() => _snapTimeline = null);
    }
  }

  Chunk? _findChunk(int chunkId) {
    for (final t in widget.tracks) {
      for (final c in t.chunks) {
        if (c.id == chunkId) return c;
      }
    }
    return null;
  }

  void _stopScrollAnim() {
    _scrollAnim?.stop();
    _scrollAnim?.dispose();
    _scrollAnim = null;
  }

  /// scrollX 를 부드럽게 (또는 즉시) 변경. delta 가 작으면 setState 만, 크면 220ms 애니메이션.
  void _setScrollX(double target, {bool animate = false}) {
    final clamped = target.clamp(0.0, _maxScroll);
    if ((clamped - _scrollX).abs() < 0.5) return;
    _stopScrollAnim();
    if (!animate) {
      setState(() => _scrollX = clamped);
      return;
    }
    final ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 220));
    final tween = Tween<double>(begin: _scrollX, end: clamped)
        .chain(CurveTween(curve: Curves.easeOutCubic))
        .animate(ctrl);
    tween.addListener(() => setState(() => _scrollX = tween.value));
    ctrl.forward();
    _scrollAnim = ctrl;
  }

  /// 외부 playheadSec 변경 시 scrollX 를 동기화. 연속 변화는 즉시, 점프는 애니메이션.
  @override
  void didUpdateWidget(covariant TimelineEditor old) {
    super.didUpdateWidget(old);
    if (_panning) return; // pan 중에는 scrollX 가 primary — 덮어쓰지 않음.
    final ph = widget.playheadSec;
    if (ph == null) return;
    final desired = (ph / _dur) * _contentW;
    final dt = (ph - (old.playheadSec ?? 0)).abs();
    _setScrollX(desired, animate: dt > 0.1);
  }

  /// 청크를 끌고 가장자리에 머무르면 같은 방향으로 자동 스크롤 + 청크도 함께 이동.
  /// dir: -1(왼쪽) / 0(정지) / 1(오른쪽).
  void _setAutoScroll(int dir, int chunkId) {
    if (dir == _autoScrollDir) return;
    _autoScrollDir = dir;
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    if (dir == 0) return;
    const stepPx = 6.0; // 매 틱 6px ≈ 360px/s
    _autoScrollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (_moveChunk != chunkId) {
        _setAutoScroll(0, chunkId);
        return;
      }
      final dx = stepPx * _autoScrollDir;
      setState(() {
        _scrollX += dx;
        _clampScroll();
      });
      final dtSec = _pxToSec(dx);
      widget.onChunkMove?.call(chunkId, dtSec);
      // auto-scroll 도 desired 위치를 같이 advance — 다음 finger move 시 desired 가 outdated 안 되게.
      if (_desiredChunkStart != null) _desiredChunkStart = _desiredChunkStart! + dtSec;
      widget.onSeek?.call(_pxToSec(_scrollX));
    });
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _scrollAnim?.dispose();
    super.dispose();
  }

  double _pxToSec(double dx) => dx * (_dur / _contentW);
  double _secToPx(double t) => (t / _dur) * _contentW;
  // 룰러/레인 위 탭의 localX 를 시간으로 변환 — 좌측 _anchorX 오프셋 + 현재 스크롤 반영.
  double _timeAt(double localX) =>
      _pxToSec((localX - _anchorX + _scrollX).clamp(0.0, _contentW)).clamp(0.0, _dur);

  TrackData? get _activeTrack {
    for (final t in widget.tracks) {
      if (t.id == widget.activeTrackId) return t;
    }
    return null;
  }

  List<Note> _notesFor(TrackData t) {
    final ov = widget.notesOverride?[t.id];
    if (ov != null) return ov;
    // 청크 메타(timelineStart/inPoint/outPoint) 적용 후 효과 시간 기준 노트.
    return t.effectiveRenderNotes;
  }

  /// 청크의 타임라인 시작/끝 — chunk 메타 우선, 없으면(레거시) 노트로부터 추정.
  Map<int, List<double>> _chunkTimelineRanges(TrackData t) {
    final out = <int, List<double>>{};
    for (final c in t.chunks) {
      out[c.id] = [c.timelineStart, c.timelineEnd];
    }
    return out;
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
      y += _catH; // 카테고리 헤더
      for (final t in ts) {
        y += _trackNameH; // 트랙 이름 strip
        tops[t.id] = y; // 레인 상단(이름 strip 아래)
        y += _trackH;
      }
    }
    return tops;
  }

  double get _lanesH {
    double h = 0;
    for (final (_, ts) in _grouped()) {
      h += _catH + (_trackNameH + _trackH) * ts.length;
    }
    return h;
  }

  // 선택된 청크의 양끝 트림 핸들(활성 트랙 레인). 좌/우 핸들을 끌어 길이 조절.
  List<Widget> _trimHandles() {
    final cid = widget.selectedChunk;
    final t = _activeTrack;
    if (cid == null || t == null) return const [];
    final ranges = _chunkTimelineRanges(t);
    final r = ranges[cid];
    if (r == null) return const [];
    final top = _trackTops()[t.id];
    if (top == null) return const [];
    final laneTop = top;
    final laneH = _trackH - _laneGap;
    final leftX = _anchorX + _secToPx(r[0]) - _scrollX;
    final rightX = _anchorX + _secToPx(r[1]) - _scrollX;

    Widget handle(double x, bool isLeft) => Positioned(
          left: x - 6,
          top: laneTop,
          height: laneH,
          width: 12,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => isLeft ? _resizeStart = r[0] : _resizeEnd = r[1],
            onHorizontalDragUpdate: (d) {
              final targets = _snapTargets(excludeChunkId: cid);
              if (isLeft) {
                _resizeStart = (_resizeStart ?? r[0]) + _pxToSec(d.delta.dx);
                final snap = _closestSnap(_resizeStart!, targets);
                _onSnapHit(snap);
                widget.onChunkResize?.call(cid, newLeftTimeline: snap ?? _resizeStart);
              } else {
                _resizeEnd = (_resizeEnd ?? r[1]) + _pxToSec(d.delta.dx);
                final snap = _closestSnap(_resizeEnd!, targets);
                _onSnapHit(snap);
                widget.onChunkResize?.call(cid, newRightTimeline: snap ?? _resizeEnd);
              }
            },
            onHorizontalDragEnd: (_) {
              _resizeStart = null;
              _resizeEnd = null;
              _clearSnap();
            },
            onHorizontalDragCancel: () {
              _resizeStart = null;
              _resizeEnd = null;
              _clearSnap();
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
    return Container(
      color: AppColors.bg,
      padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
      child: LayoutBuilder(
        builder: (context, c) {
          _vpW = c.maxWidth;
          _pxPerSec = _basePx * _zoom;
          // CapCut 식: pxPerSec(=basePx * zoom) 가 시간↔픽셀 기본 환산.
          // 컨텐츠 시간(_dur) 은 데이터 끝 vs 뷰포트가 보여줄 수 있는 시간 중 큰 값.
          // 데이터가 짧아도 뷰포트는 항상 꽉 차게 표시되고, 줌하면 같은 viewport 가
          // 더 많거나 더 적은 시간을 보여준다.
          final dataDur = math.max(widget.durationSec, 0.0);
          final minDurFromVp = _vpW > 0 ? _vpW / _pxPerSec : 0.5;
          _dur = math.max(dataDur, minDurFromVp);
          _contentW = _dur * _pxPerSec;
          // 앵커 고정 모델: scrollX 의 최대 = 마지막 재생 컨텐츠 끝(dataDur) × pxPerSec.
          // 그 지점에서 anchor 가 dataDur 시점을 가리킴(= 마지막 청크의 우측 끝이 플레이헤드에 닿음).
          // 빈 트랙(dataDur=0) → maxScroll=0 (스크롤 없음).
          _maxScroll = math.max(0.0, dataDur * _pxPerSec);
          _clampScroll();
          final laneH = _lanesH;

          return SingleChildScrollView(
            // 전체 트랙 수가 늘어나면 세로 스크롤로 모두 접근 가능.
            child: SizedBox(
              height: math.max(c.maxHeight, _rulerH + laneH),
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
                                Positioned(left: _anchorX - _scrollX, top: 0, width: _contentW, child: _ruler()),
                              ]),
                            ),
                          ),
                        ),
                        // 레인 영역 — 1손가락 팬 / 2손가락 핀치줌 / 탭 선택
                        SizedBox(
                          height: laneH,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onScaleStart: (_) {
                              _startZoom = _zoom;
                              _stopScrollAnim();
                              _panning = true;
                            },
                            onScaleUpdate: (d) {
                              setState(() {
                                if (d.scale != 1.0) {
                                  _zoom = (_startZoom * d.scale).clamp(0.3, 6.0);
                                }
                                _scrollX -= d.focalPointDelta.dx;
                                _clampScroll();
                              });
                              // scrollX 변화를 외부 playheadSec 와 동기화 — 스크롤 = 시킹.
                              widget.onSeek?.call(_pxToSec(_scrollX));
                            },
                            onScaleEnd: (_) {
                              _panning = false;
                            },
                            child: ClipRect(
                              child: Stack(
                                children: [
                                  // 카테고리 헤더 + 트랙 strip + lane 컨테이너 — 전체 가로폭, 비-스크롤.
                                  // lane 내부에서 painter/청크가 scroll layer 로 anchor 오프셋 적용.
                                  Positioned.fill(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: _laneRows(),
                                    ),
                                  ),
                                  ..._trimHandles(),
                                  // 플레이헤드 — 항상 좌측 anchor 에 시각 고정.
                                  // 스크롤이 컨텐츠를 흐르게 만들고, 그 위에 플레이헤드가 떠 있는 모델.
                                  Positioned(
                                    left: _anchorX - 1,
                                    top: 0,
                                    bottom: 0,
                                    child: IgnorePointer(child: Container(width: 2, color: Colors.white)),
                                  ),
                                  // 스냅 가이드라인 — 현재 드래그가 스냅된 좌표에 일시 표시.
                                  if (_snapTimeline != null) ...() {
                                    final sx = _anchorX + _secToPx(_snapTimeline!) - _scrollX;
                                    if (sx < -1 || sx > _vpW + 1) return const <Widget>[];
                                    return [
                                      Positioned(
                                        left: sx,
                                        top: 0,
                                        bottom: 0,
                                        child: IgnorePointer(
                                          child: Container(width: 1, color: AppColors.lime),
                                        ),
                                      ),
                                    ];
                                  }(),
                                ],
                              ),
                            ),
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
  // 각 카테고리: [카테고리 헤더] + 트랙별 [트랙 이름 strip] + [레인 컨텐츠].
  // 전체 가로폭에서 좌측 정렬 — 부모가 전체 viewport 너비를 가짐.
  List<Widget> _laneRows() {
    final rows = <Widget>[];
    for (final (role, ts) in _grouped()) {
      rows.add(SizedBox(
        height: _catH,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Text(
            role.label.toUpperCase(),
            style: T.label.copyWith(fontSize: 10, letterSpacing: 1.2, color: AppColors.textSecondary),
          ),
        ),
      ));
      for (final t in ts) {
        rows.add(_trackNameStrip(t));
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

  Widget _trackNameStrip(TrackData t) {
    final active = t.id == widget.activeTrackId;
    final color = active ? AppColors.lime : AppColors.textSecondary;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onActivateTrack?.call(t.id),
      child: SizedBox(
        height: _trackNameH,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            instrumentIcon(_iconProgram(t), size: 12, color: color),
            const SizedBox(width: 6),
            Text(
              _trackDisplayName(t),
              style: T.label.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: color,
              ),
            ),
            const Spacer(),
            // 뮤트 토글 — 사이드바 항시 표시(CapCut #6).
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => widget.onToggleEnabled?.call(t.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                child: Icon(
                  t.enabled ? Icons.volume_up : Icons.volume_off,
                  size: 14,
                  color: t.enabled ? AppColors.textSecondary : AppColors.textTertiary,
                ),
              ),
            ),
            // 재녹음 — 녹음본이 있는 트랙에만 표시. outlined pill 형태(라벨 + 빨강 점).
            if (t.hasRecording) ...[
              const SizedBox(width: 4),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onRecordAgain?.call(t.id),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.lime, width: 1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 6, height: 6,
                      decoration: const BoxDecoration(
                        color: Color(0xFFFF4D4D),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      '재녹음',
                      style: T.label.copyWith(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: AppColors.lime,
                        height: 1.3,
                      ),
                    ),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _ruler() {
    // 줌(pxPerSec) 에 따라 라벨 간격 자동 선택. 약 60~90px 마다 라벨이 오도록.
    // CapCut/DAW 표준 단계 — 10s/5s/2s/1s/0.5s/0.1s.
    final pps = _pxPerSec;
    double major;
    if (pps < 14) {
      major = 30; // 매우 줌 아웃
    } else if (pps < 28) {
      major = 10;
    } else if (pps < 55) {
      major = 5;
    } else if (pps < 110) {
      major = 2;
    } else if (pps < 220) {
      major = 1;
    } else if (pps < 500) {
      major = 0.5;
    } else {
      major = 0.1;
    }
    final minor = major / 5; // minor tick 단위

    String fmt(double t) {
      if (major >= 1) {
        final s = t.toInt();
        return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
      }
      // 1초 미만 단위: 초 + 소수점 1자리.
      final whole = t.floor();
      final frac = ((t - whole) * 10).round();
      return '$whole.${frac}s';
    }

    final ticks = <Widget>[];
    // major (라벨 + 긴 tick)
    for (double t = 0; t <= _dur + 1e-6; t += major) {
      final x = _secToPx(t);
      ticks.add(Positioned(
        left: x,
        top: 0,
        child: Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Text(fmt(t), style: T.label.copyWith(fontSize: 9)),
        ),
      ));
      ticks.add(Positioned(
        left: x,
        bottom: 0,
        child: Container(width: 1, height: 6, color: AppColors.textSecondary.withValues(alpha: 0.5)),
      ));
    }
    // minor tick (라벨 없음, 짧은 막대)
    if (minor > 0) {
      for (double t = 0; t <= _dur + 1e-6; t += minor) {
        // major 와 거의 같은 좌표면 스킵.
        if ((t / major - (t / major).round()).abs() < 1e-4) continue;
        final x = _secToPx(t);
        ticks.add(Positioned(
          left: x,
          bottom: 0,
          child: Container(width: 1, height: 3, color: AppColors.textTertiary.withValues(alpha: 0.4)),
        ));
      }
    }

    return SizedBox(
      width: _contentW,
      height: _rulerH,
      child: Stack(clipBehavior: Clip.hardEdge, children: ticks),
    );
  }

  Widget _lane(TrackData t) {
    final active = t.id == widget.activeTrackId;
    final notes = _notesFor(t);
    final hasWave = t.isVocal && t.vocalPeaks.isNotEmpty;
    final isEmpty = notes.isEmpty && !hasWave && !t.hasRecording;
    final hasPending = widget.pending != null && widget.pending!.trackId == t.id;
    final isRecHere = widget.recTrackId == t.id && widget.recPhase != InlineRecPhase.idle;

    if (isRecHere) {
      // 녹음 중인 트랙 — 인라인 카운트다운/녹음 UI 로 lane 전체 대체.
      return _inlineRecLane();
    }

    return Container(
      decoration: BoxDecoration(
        color: active ? AppColors.activeLane : AppColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: active ? Border.all(color: AppColors.lime, width: 1) : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: LayoutBuilder(builder: (ctx, c) {
          final laneH = c.maxHeight;
          final geo = _Geo(notes, _dur, Size(_contentW, laneH));

          return Stack(children: [
            // [Layer 0] 전체 lane hit — 활성화 / chunk 선택 해제
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // 빈 영역 탭 → 트랙 선택(이미 active 여도 trackSelected=true 로 강제) → 액션 바 표시.
                onTap: () => widget.onActivateTrack?.call(t.id),
              ),
            ),

            // [Layer 1] 스크롤 컨텐츠 — painter + 청크/노트 hit. anchor 오프셋 적용,
            // 전체 컨텐츠 너비(_contentW). 재생/스크롤 시 좌우로 흐름.
            Positioned(
              left: _anchorX - _scrollX,
              top: 0,
              bottom: 0,
              width: _contentW,
              child: Stack(children: [
                Positioned.fill(
                  // 페인터는 시각만 — 빈 영역 탭이 Layer 0 (트랙 활성화) 으로 통과되도록.
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: hasWave
                          ? _WavePainter(peaks: t.vocalPeaks, vocalDur: t.vocalDuration, totalDur: _dur, active: active)
                          : _NotesPainter(
                              notes: notes,
                              durationSec: _dur,
                              active: active,
                              chunkRanges: _chunkTimelineRanges(t),
                              selectedNote: active ? widget.selectedNote : null,
                              selectedChunk: active ? widget.selectedChunk : null,
                            ),
                    ),
                  ),
                ),
                if (!hasWave)
                  for (final entry in _chunkTimelineRanges(t).entries)
                    _chunkHitWidget(t, active, entry.key, entry.value, _contentW, laneH),
                if (!hasWave)
                  for (int i = 0; i < notes.length; i++)
                    _noteHitWidget(t, active, i, geo.rectFor(notes[i])),
              ]),
            ),

            // [Layer 2] 빈 트랙 — 녹음 시작 pill, lane 전체 중앙.
            if (isEmpty && !hasPending) Positioned.fill(child: Center(child: _recPill(t))),
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

  // ─── 인라인 녹음 lane (카운트다운 / 녹음중) ────────────────────────────────
  Widget _inlineRecLane() {
    final isCountdown = widget.recPhase == InlineRecPhase.countingDown;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x1AFF4D4D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xB3FF4D4D), width: 1),
        boxShadow: [
          BoxShadow(color: const Color(0xFFFF4D4D).withValues(alpha: 0.18), blurRadius: 14, spreadRadius: 1),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: isCountdown ? _countdownContent() : _recordingContent(),
      ),
    );
  }

  Widget _countdownContent() {
    return Center(
      child: SizedBox(
        width: 38,
        height: 38,
        child: CustomPaint(
          painter: _CountdownRingPainter(
            progress: widget.recCountdownProgress,
          ),
          child: Center(
            child: Text(
              '${widget.recCountdownN}',
              style: T.body.copyWith(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: const Color(0xFFFF4D4D),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _recordingContent() {
    final secs = widget.recElapsedMs ~/ 1000;
    final timeStr = '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(children: [
        // 좌: 빨강 깜박이는 점 + 경과 시간.
        _BlinkDot(),
        const SizedBox(width: 8),
        Text(
          timeStr,
          style: T.body.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: const Color(0xFFFF4D4D),
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 14),
        // 중: 진폭 미터.
        Expanded(
          child: CustomPaint(
            painter: _RecMeterPainter(levels: widget.recLevels),
            size: const Size.fromHeight(36),
          ),
        ),
        const SizedBox(width: 12),
        // 우: 정지 버튼.
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onStopRec,
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFFF4D4D),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Center(
              child: SizedBox(
                width: 12, height: 12,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: Colors.white),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }

  // 사용/삭제는 sheets.dart 의 showPendingRecordingSheet 가 담당 (2026-06).
  // 아래 함수들은 더 이상 호출되지 않으며 추후 정리 예정.
  // ignore: unused_element
  Widget _pendingDialog(PendingRecording p) {
    final isVocal = p.role == TrackRole.vocal;
    final notesCount = p.notes.length;
    final msg = isVocal
        ? '녹음 완료 — 보컬을 사용할까요?'
        : (notesCount > 0
            ? '녹음 완료 — 노트 $notesCount개를 사용할까요?'
            : '녹음 완료 — 사용할까요?');
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F27),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.lime, width: 1),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(msg,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: T.body.copyWith(fontSize: 11, fontWeight: FontWeight.w600)),
              if (!isVocal) ...[
                const SizedBox(height: 4),
                _assistMiniToggle(p),
              ],
            ],
          ),
        ),
        const SizedBox(width: 6),
        _pendingBtn('삭제',
            outlined: true, onTap: () => widget.onPendingDiscard?.call()),
        const SizedBox(width: 6),
        _pendingBtn('사용',
            outlined: false, onTap: () => widget.onPendingUse?.call()),
      ]),
    );
  }

  Widget _assistMiniToggle(PendingRecording p) {
    final on = p.pitchAssist;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: p.reassisting ? null : () => widget.onPendingToggleAssist?.call(!on),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 22, height: 12,
          decoration: BoxDecoration(
            color: on ? AppColors.lime : AppColors.border,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Align(
            alignment: on ? Alignment.centerRight : Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1),
              child: Container(
                width: 10, height: 10,
                decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        Text('피치 어시스트',
            style: T.label.copyWith(
                fontSize: 9,
                color: on ? AppColors.lime : AppColors.textSecondary,
                fontWeight: FontWeight.w600)),
        if (p.reassisting) ...[
          const SizedBox(width: 6),
          const SizedBox(
            width: 8, height: 8,
            child: CircularProgressIndicator(strokeWidth: 1.2, color: AppColors.lime),
          ),
        ],
      ]),
    );
  }

  Widget _pendingBtn(String label, {required bool outlined, required VoidCallback onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: outlined ? Colors.transparent : AppColors.lime,
          border: outlined ? Border.all(color: AppColors.border) : null,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label,
            style: T.body.copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: outlined ? AppColors.textPrimary : AppColors.bg)),
      ),
    );
  }

  Widget _chunkHitWidget(TrackData t, bool active, int chunkId, List<double> range, double laneW, double laneH) {
    final x0 = _secToPx(range[0]);
    final x1 = _secToPx(range[1]);
    // 짧은 탭 → 청크 선택. 롱프레스 후 드래그 → 청크 이동(원위치).
    // 일반 드래그는 청크 GestureDetector 가 잡지 않으므로 상위 onScaleUpdate 가
    // 타임라인 팬으로 받음(사용자 요청 — 평범한 드래그는 스크롤 우선).
    final picked = _moveChunk == chunkId;
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
          // 플레이헤드 위치만 청크 시작점으로 — 뷰포트는 사용자가 둔 상태 그대로 유지.
          widget.onSeek?.call(range[0]);
        },
        onLongPressStart: (_) {
          if (!active) widget.onActivateTrack?.call(t.id);
          widget.onChunkTap?.call(chunkId);
          setState(() => _moveChunk = chunkId);
          HapticFeedback.mediumImpact();
          final cur = _findChunk(chunkId);
          _desiredChunkStart = cur?.timelineStart;
          _snappedToTarget = null;
        },
        onLongPressMoveUpdate: (d) {
          if (_moveChunk != chunkId) return;
          final dxDelta = d.offsetFromOrigin.dx - (_moveDxAcc ?? 0);
          _moveDxAcc = d.offsetFromOrigin.dx;
          if (dxDelta != 0) {
            final cur = _findChunk(chunkId);
            if (cur != null) {
              // desired = 손가락 이동분 누적(스냅 미적용).
              _desiredChunkStart = math.max(0.0, (_desiredChunkStart ?? cur.timelineStart) + _pxToSec(dxDelta));
              final newStart = _snapResolveStart(
                desiredStart: _desiredChunkStart!,
                chunkLength: cur.visibleLength,
                targets: _snapTargets(excludeChunkId: chunkId),
              );
              final dt = newStart - cur.timelineStart;
              if (dt != 0) widget.onChunkMove?.call(chunkId, dt);
            }
          }
          // 손가락 viewport-x — chunk 은 scroll layer(left:_anchorX-_scrollX) 안에 있으므로
          // lane-x = (_anchorX - _scrollX) + x0 + localPosition.dx.
          final fx = _anchorX - _scrollX + x0 + d.localPosition.dx;
          const edge = 36.0;
          int dir = 0;
          if (fx > _vpW - edge) {
            dir = 1;
          } else if (fx < edge) {
            dir = -1;
          }
          _setAutoScroll(dir, chunkId);
        },
        onLongPressEnd: (_) {
          setState(() => _moveChunk = null);
          _moveDxAcc = null;
          _desiredChunkStart = null;
          _snappedToTarget = null;
          _setAutoScroll(0, chunkId);
          _clearSnap();
        },
        onLongPressCancel: () {
          setState(() => _moveChunk = null);
          _moveDxAcc = null;
          _desiredChunkStart = null;
          _snappedToTarget = null;
          _setAutoScroll(0, chunkId);
          _clearSnap();
        },
        // 픽업 시 시각 피드백 — 살짝 떠오르는 효과(스케일 + lime 그림자).
        child: AnimatedScale(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          scale: picked ? 1.03 : 1.0,
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              boxShadow: picked
                  ? [
                      BoxShadow(
                        color: AppColors.lime.withValues(alpha: 0.4),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ]
                  : const [],
            ),
          ),
        ),
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
    required this.chunkRanges,
    this.selectedNote,
    this.selectedChunk,
  });
  final List<Note> notes;
  final double durationSec;
  final bool active;
  /// 청크 id → [timelineStart, timelineEnd] — 트림 핸들과 일치하는 좌표.
  /// 비어있으면(레거시) 노트 범위로 폴백.
  final Map<int, List<double>> chunkRanges;
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
      old.chunkRanges != chunkRanges ||
      old.selectedNote != selectedNote ||
      old.selectedChunk != selectedChunk ||
      old.active != active ||
      old.durationSec != durationSec;
}

String drumLabel(int pitch) => drumNames[pitch] ?? 'Drum $pitch';

// ─── 인라인 녹음 헬퍼들 ──────────────────────────────────────────────────

class _CountdownRingPainter extends CustomPainter {
  _CountdownRingPainter({required this.progress});
  final double progress;
  static const Color _rec = Color(0xFFFF4D4D);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 2;
    final bg = Paint()
      ..color = _rec.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, radius, bg);
    final fg = Paint()
      ..color = _rec
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    final sweep = (progress.clamp(0.0, 1.0)) * 2 * math.pi;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: radius),
      -math.pi / 2, // 12시 방향에서 시작
      sweep,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(covariant _CountdownRingPainter old) => old.progress != progress;
}

class _RecMeterPainter extends CustomPainter {
  _RecMeterPainter({required this.levels});
  final List<double> levels;
  static const Color _rec = Color(0xFFFF4D4D);

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty) return;
    final w = size.width, h = size.height;
    final mid = h / 2;
    final paint = Paint()
      ..color = _rec
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;
    final n = levels.length;
    final stride = w / n;
    for (int i = 0; i < n; i++) {
      final x = (i + 0.5) * stride;
      final amp = levels[i].clamp(0.0, 1.0) * (h * 0.42);
      canvas.drawLine(Offset(x, mid - amp), Offset(x, mid + amp), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RecMeterPainter old) => old.levels != levels;
}

class _BlinkDot extends StatefulWidget {
  @override
  State<_BlinkDot> createState() => _BlinkDotState();
}

class _BlinkDotState extends State<_BlinkDot> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);
  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Container(
          width: 10, height: 10,
          decoration: BoxDecoration(
            color: const Color(0xFFFF4D4D).withValues(alpha: 0.35 + 0.65 * _ctrl.value),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}
