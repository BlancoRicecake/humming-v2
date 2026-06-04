// CapCut 스타일 멀티트랙 타임라인.
// - 레인 영역: 1손가락 드래그=가로 스크롤, 2손가락 핀치=줌, 탭=노트선택/악기전환.
// - 룰러(시간 숫자): 터치+드래그=시킹(플레이헤드 이동).
// - 사이드바: 카테고리 헤더 + 그 아래 N개 트랙 라벨. 탭 → 트랙 활성화.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../l10n/generated/app_localizations.dart';
import '../models/models.dart';
import '../music/instrument_icons.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';

part 'visualization/waveform_painter.dart';
part 'visualization/notes_painter.dart';
part 'visualization/countdown_ring_painter.dart';
part 'visualization/rec_meter_painter.dart';
part 'visualization/blink_dot.dart';

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
    this.onNoteResize,
    this.onEditCheckpoint,
    this.notesOverride,
    this.quantizeDisplay,
    this.loopPeriod,
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
    this.projectEnd = 0,
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
  /// 노트 길이조절 — 선택 노트의 좌/우 엣지 핸들 드래그. 타임라인(effective) 좌표 전달.
  final void Function(int noteIndex, {double? newStartTimeline, double? newEndTimeline})? onNoteResize;
  /// 드래그(리사이즈/이동) 시작 시 1회 — undo 체크포인트.
  final VoidCallback? onEditCheckpoint;

  /// 활성 트랙의 표시용 노트 오버라이드 (코드 모드 시 확장된 노트 등).
  /// null 이면 트랙의 `notes` 를 그대로 사용.
  final Map<int, List<Note>>? notesOverride;

  /// 박자 보정 표시 — 트랙의 base 노트를 그리드 스냅한 결과를 반환(없으면 그대로).
  /// 에디터가 quantize 결과(위치·길이 이동)를 보이도록 store.quantizeNotes 를 연결.
  final List<Note> Function(TrackData t, List<Note> base)? quantizeDisplay;

  /// 루프 반복 주기 — 마디 정렬 주기(store.loopPeriodFor). null 이면 청크 끝 사용(폴백).
  final double Function(TrackData t)? loopPeriod;

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
  /// 루프 트랙의 반복 한계 — non-loop 트랙들의 가장 늦은 timelineEnd.
  final double projectEnd;

  @override
  State<TimelineEditor> createState() => _TimelineEditorState();
}

class _TimelineEditorState extends State<TimelineEditor> with TickerProviderStateMixin {
  double _zoom = 1.0;
  double _scrollX = 0;
  double _startZoom = 1.0;
  double _laneZoom = 1.0; // 활성 레인 세로 확대(1~4). 노트 터치/미세조정용.
  double _laneStartZoom = 1.0;

  // 청크 이동/트림 드래그 상태
  int? _moveChunk;
  double? _resizeStart, _resizeEnd;
  double? _noteResizeStart, _noteResizeEnd; // 노트 길이조절 드래그 누적(effective 시간)
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

  /// 스냅 후보 — 모든 트랙의 청크 경계 + 활성 트랙 노트 경계 + 0 + 플레이헤드(흰색 선).
  /// excludeChunkId 제외. 플레이헤드 시간 === _pxToSec(_scrollX) (앵커에 시각 고정된 흰색
  /// 선 아래의 시간). 단, 자동 스크롤 중에는 playhead 가 scroll 과 함께 움직여 청크가 그
  /// 근처에 영구 snap 되어 못 넘어가는 피드백이 생기므로 그때만 제외한다.
  /// 노트 경계는 청크 끝단을 노트에 붙이는 편집 편의용(_notesFor 는 이미 effective 좌표).
  List<double> _snapTargets({int? excludeChunkId, int? excludeNoteIdx}) {
    final out = <double>[0.0];
    for (final t in widget.tracks) {
      for (final c in t.chunks) {
        if (c.id == excludeChunkId) continue;
        out.add(c.timelineStart);
        out.add(c.timelineEnd);
      }
    }
    // 활성 트랙 노트 경계 — 청크/노트 리사이즈가 인접 노트에 자석처럼 붙도록.
    final at = _activeTrack;
    if (at != null) {
      final notes = _notesFor(at);
      for (var i = 0; i < notes.length; i++) {
        if (i == excludeNoteIdx) continue;
        out.add(notes[i].start);
        out.add(notes[i].end);
      }
    }
    if (_autoScrollDir == 0 && _contentW > 0) {
      out.add(_pxToSec(_scrollX)); // 흰색 선(플레이헤드)
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
    var base = t.effectiveRenderNotes;
    // 박자 보정 결과를 표시(위치·길이 이동이 눈에 보이게). 루프 반복본도 스냅본 기준.
    if (widget.quantizeDisplay != null) base = widget.quantizeDisplay!(t, base);
    if (!t.looping || widget.projectEnd <= 0 || base.isEmpty || t.chunks.isEmpty) return base;
    // 루프 주기 = 마디 정렬 주기(loopPeriod, 재생과 동일). 없으면 청크 끝 폴백.
    final period = widget.loopPeriod?.call(t) ??
        t.chunks.map((c) => c.timelineEnd).reduce(math.max);
    if (period <= 0.01) return base;
    final out = List<Note>.from(base);
    double offset = period;
    while (offset < widget.projectEnd) {
      for (final n in base) {
        if (n.start + offset >= widget.projectEnd) continue;
        final clone = Note.fromJson(n.toJson())
          ..start = n.start + offset
          ..end = math.min(n.end + offset, widget.projectEnd)
          ..chunkId = -n.chunkId - 1 // 반복본은 음수 chunkId 로 마킹.
          ..renderSrcIndex = n.renderSrcIndex; // 반복본 탭/하이라이트는 원본 노트를 가리킨다.
        clone.duration = clone.end - clone.start;
        out.add(clone);
      }
      offset += period;
    }
    return out;
  }

  /// 청크의 타임라인 시작/끝 — 원본 청크 ID → [start, end].
  Map<int, List<double>> _chunkTimelineRanges(TrackData t) {
    final out = <int, List<double>>{};
    for (final c in t.chunks) {
      out[c.id] = [c.timelineStart, c.timelineEnd];
    }
    return out;
  }

  /// 루프 반복본 청크 범위 — looping 트랙만, 원본 다음 반복부터.
  /// 주기는 청크 timelineEnd 최대값(가시 영역 끝).
  List<List<double>> _loopReplicaRanges(TrackData t) {
    if (!t.looping || widget.projectEnd <= 0 || t.chunks.isEmpty) return const [];
    final base = t.chunks.map((c) => [c.timelineStart, c.timelineEnd]).toList();
    final period = base.map((r) => r[1]).reduce(math.max);
    if (period <= 0.01) return const [];
    final out = <List<double>>[];
    double offset = period;
    while (offset < widget.projectEnd) {
      for (final r in base) {
        final s = r[0] + offset;
        if (s >= widget.projectEnd) continue;
        final e = math.min(r[1] + offset, widget.projectEnd);
        out.add([s, e]);
      }
      offset += period;
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
        y += _laneHeightFor(t);
      }
    }
    return tops;
  }

  /// 레인 높이 — 활성 트랙만 세로 줌(_laneZoom)배. 노트는 _Geo 가 자동 스케일.
  double _laneHeightFor(TrackData t) =>
      _trackH * (t.id == widget.activeTrackId ? _laneZoom : 1.0);

  double get _lanesH {
    double h = 0;
    for (final (_, ts) in _grouped()) {
      h += _catH;
      for (final t in ts) {
        h += _trackNameH + _laneHeightFor(t);
      }
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
    final laneH = _laneHeightFor(t) - _laneGap;
    final leftX = _anchorX + _secToPx(r[0]) - _scrollX;
    final rightX = _anchorX + _secToPx(r[1]) - _scrollX;

    Widget handle(double x, bool isLeft) => Positioned(
          left: x - 6,
          top: laneTop,
          height: laneH,
          width: 12,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) {
              widget.onEditCheckpoint?.call();
              isLeft ? _resizeStart = r[0] : _resizeEnd = r[1];
            },
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

  // 선택된 노트의 양끝 길이조절 핸들(활성 트랙 레인). 청크 트림과 동일한 방식이되
  // 대상이 단일 노트. effective 시간으로 누적해 onNoteResize 로 전달.
  List<Widget> _noteResizeHandles() {
    final nidx = widget.selectedNote; // 원본 t.notes 인덱스(renderSrcIndex 기준)
    final t = _activeTrack;
    if (nidx == null || t == null) return const [];
    final notes = _notesFor(t);
    // 원본 인덱스 → 현재 표시 노트 위치. 드롭/반복본으로 표시 인덱스가 달라도 올바른 노트.
    final di = notes.indexWhere((n) => n.renderSrcIndex == nidx);
    if (di < 0) return const [];
    final n = notes[di];
    if (n.kind != 'pitched') return const []; // 드럼(percussive)은 길이조절 비대상
    final top = _trackTops()[t.id];
    if (top == null) return const [];
    final laneTop = top;
    final laneH = _laneHeightFor(t) - _laneGap;
    final leftX = _anchorX + _secToPx(n.start) - _scrollX;
    final rightX = _anchorX + _secToPx(n.end) - _scrollX;

    Widget handle(double x, bool isLeft) => Positioned(
          left: x - 7,
          top: laneTop,
          height: laneH,
          width: 14,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) {
              widget.onEditCheckpoint?.call();
              isLeft ? _noteResizeStart = n.start : _noteResizeEnd = n.end;
            },
            onHorizontalDragUpdate: (d) {
              final targets = _snapTargets(excludeNoteIdx: di); // 제외는 표시 인덱스 기준
              if (isLeft) {
                _noteResizeStart = (_noteResizeStart ?? n.start) + _pxToSec(d.delta.dx);
                final snap = _closestSnap(_noteResizeStart!, targets);
                _onSnapHit(snap);
                widget.onNoteResize?.call(nidx, newStartTimeline: snap ?? _noteResizeStart);
              } else {
                _noteResizeEnd = (_noteResizeEnd ?? n.end) + _pxToSec(d.delta.dx);
                final snap = _closestSnap(_noteResizeEnd!, targets);
                _onSnapHit(snap);
                widget.onNoteResize?.call(nidx, newEndTimeline: snap ?? _noteResizeEnd);
              }
            },
            onHorizontalDragEnd: (_) {
              _noteResizeStart = null;
              _noteResizeEnd = null;
            },
            onHorizontalDragCancel: () {
              _noteResizeStart = null;
              _noteResizeEnd = null;
            },
            child: Center(
              child: Container(
                width: 3,
                height: laneH * 0.7,
                decoration: BoxDecoration(
                    color: AppColors.lime, borderRadius: BorderRadius.circular(2)),
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
                              _laneStartZoom = _laneZoom;
                              _stopScrollAnim();
                              _panning = true;
                            },
                            onScaleUpdate: (d) {
                              setState(() {
                                // 지배 축 판정 — 세로 핀치가 더 크면 활성 레인 세로 줌,
                                // 아니면 가로(시간) 줌. (한 핀치로 택1.)
                                final hMag = (d.horizontalScale - 1.0).abs();
                                final vMag = (d.verticalScale - 1.0).abs();
                                if (vMag > hMag && d.verticalScale != 1.0) {
                                  _laneZoom = (_laneStartZoom * d.verticalScale).clamp(1.0, 4.0);
                                } else if (d.scale != 1.0) {
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
                                  ..._noteResizeHandles(),
                                  // 플레이헤드(흰 가이드선) — 좌측 anchor 에 시각 고정.
                                  // 상단 그립을 끌면 그 시간으로 스크럽(= _playheadSec 갱신,
                                  // 분할/길이 편집의 기준선). 룰러 드래그와 같은 방향(우=뒤로).
                                  Positioned(
                                    left: _anchorX - 11,
                                    top: 0,
                                    bottom: 0,
                                    width: 22, // 터치 히트존
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onHorizontalDragStart: (_) {
                                        _stopScrollAnim();
                                        _panning = true;
                                      },
                                      onHorizontalDragUpdate: (d) {
                                        setState(() {
                                          _scrollX += d.delta.dx;
                                          _clampScroll();
                                        });
                                        widget.onSeek?.call(_pxToSec(_scrollX));
                                      },
                                      onHorizontalDragEnd: (_) => _panning = false,
                                      onHorizontalDragCancel: () => _panning = false,
                                      child: Stack(alignment: Alignment.center, children: [
                                        Container(width: 2, color: Colors.white),
                                        Positioned(
                                          top: 0,
                                          child: Container(
                                            width: 16,
                                            height: 16,
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.circular(8),
                                              boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 3)],
                                            ),
                                            child: const Icon(Icons.drag_indicator, size: 12, color: Colors.black54),
                                          ),
                                        ),
                                      ]),
                                    ),
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
    for (final i in instrumentsForRole(t.role)) {
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
          height: _laneHeightFor(t),
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
            // 루프 뱃지 — looping=true 일 때만.
            if (t.looping) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.lime.withValues(alpha: 0.16),
                  border: Border.all(color: AppColors.lime.withValues(alpha: 0.4), width: 1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.repeat, size: 9, color: AppColors.lime),
                  const SizedBox(width: 3),
                  Text(L10n.of(context).timelineLoop,
                      style: T.label.copyWith(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: AppColors.lime,
                        height: 1.2,
                      )),
                ]),
              ),
              const SizedBox(width: 6),
            ],
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
                      L10n.of(context).timelineRerecord,
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
                            loopReplicaRanges: _loopReplicaRanges(t),
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
                    // 표시 인덱스 i 가 아니라 원본 t.notes 인덱스(renderSrcIndex)를 넘긴다 —
                    // 리딩 트림 드롭으로 i 와 원본이 어긋나도 올바른 노트를 선택/편집한다.
                    _noteHitWidget(t, active, notes[i].renderSrcIndex, geo.rectFor(notes[i])),
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
          Text(L10n.of(context).timelineRecordStart,
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
    final l = L10n.of(context);
    final isVocal = p.role == TrackRole.vocal;
    final notesCount = p.notes.length;
    final msg = isVocal
        ? l.timelineRecCompleteVocal
        : (notesCount > 0
            ? l.timelineRecCompleteNotes(notesCount)
            : l.timelineRecCompleteGeneric);
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
        _pendingBtn(l.delete,
            outlined: true, onTap: () => widget.onPendingDiscard?.call()),
        const SizedBox(width: 6),
        _pendingBtn(l.use,
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
        Text(L10n.of(context).timelinePitchAssist,
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
          widget.onEditCheckpoint?.call(); // undo 체크포인트(이동 시작)
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

