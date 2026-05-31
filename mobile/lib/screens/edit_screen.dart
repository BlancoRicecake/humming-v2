// 메인 편집 화면 — 상단 컨트롤(악기/역할/코드/추천Key/피치어시스트/녹음) + 하단 CapCut 타임라인.
// 녹음은 화면 이동 없이 녹음 버튼 박스 안에서 진행(작업 동시성): 녹음 중 기존 트랙을
// 함께 재생해 흥얼거릴 수 있고, 같은 박스에서 타이머·음파·처리과정을 보여준다.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../audio/audio_route.dart';
import '../audio/metronome.dart';
import '../audio/player.dart';
import '../audio/recorder.dart';
import '../audio/synth_player.dart';
import '../models/models.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/active_track_cards.dart';
import '../widgets/common.dart';
import '../widgets/meter_painter.dart';
import '../widgets/sheets.dart';
import '../widgets/timeline_editor.dart';

enum _PlayState { stopped, playing, paused }

enum _RecState { idle, countingDown, recording, processing }

class EditScreen extends StatefulWidget {
  const EditScreen({super.key});
  @override
  State<EditScreen> createState() => _EditScreenState();
}

class _EditScreenState extends State<EditScreen> {
  final _player = AudioPlayerService();      // 보컬(원본 WAV) 레이어 전용
  final _synth = SynthPlayer();              // 악기 트랙(온디바이스 SF2 합성)
  _PlayState _ps = _PlayState.stopped;
  double? _playheadSec;
  int _lastEpoch = -1;
  StreamSubscription? _posSub, _compSub;
  StreamSubscription? _synthPosSub, _synthCompSub;

  // 인라인 녹음(작업 동시성)
  final _rec = VoiceRecorder();
  _RecState _recState = _RecState.idle;
  int _recMs = 0;
  int _recCountdownN = 3; // 카운트다운 현재 숫자 (3 → 2 → 1)
  double _recCountdownProgress = 0; // 0..1 — 한 비트 안에서 차오르는 비율
  Timer? _countdownTimer;
  int? _recTrackId; // 녹음 중인 트랙 id (인라인 UI 표시 대상)
  bool _recHasBacking = false; // 반주 트랙이 있는지(헤드셋 무관)
  bool _recPlayingAudio = false; // 반주를 실제 소리로 재생 중인지(헤드셋 연결 시만)
  double _recBackingDur = 0; // 반주 길이(선만 움직일 때 상한)
  final Stopwatch _recWatch = Stopwatch(); // 실제 경과시간(틱 드리프트 방지)
  Timer? _recTimer;
  StreamSubscription? _ampSub;
  final List<double> _recLevels = List.filled(40, 0.04, growable: true);

  // 메트로놈
  final _metro = Metronome();
  bool _metroOn = false;
  int _bpm = 90;

  void _seek(double sec) {
    setState(() => _playheadSec = sec);
    // synth: 재생/일시정지/정지 모두에서 위치를 동기화(정지 시엔 다음 ▶ 부터 적용).
    // 보컬: 재생 중일 때만 의미. (audioplayers seek 은 정지 상태에서 효과 한정적)
    _synth.seek(sec);
    if (_ps != _PlayState.stopped) {
      _player.seek(Duration(milliseconds: (sec * 1000).round()));
    }
  }

  @override
  void initState() {
    super.initState();
    // 보컬 레이어(audioplayers) 위치/완료 — 악기 트랙이 없는 경우(보컬 단독)에 사용.
    _posSub = _player.onPosition.listen((d) {
      if (!mounted) return;
      // SynthPlayer 가 재생 중이면 그 쪽이 타이밍 기준 — 무시.
      if (_synth.isPlaying) return;
      setState(() => _playheadSec = d.inMilliseconds / 1000.0);
    });
    _compSub = _player.onComplete.listen((_) {
      if (!mounted) return;
      if (_synth.isPlaying) return; // synth 가 곧 complete 발행
      setState(() {
        _ps = _PlayState.stopped;
        _playheadSec = null;
      });
    });
    // SF2 트랙 재생(타이밍 기준).
    _synthPosSub = _synth.onPosition.listen((d) {
      if (!mounted) return;
      setState(() => _playheadSec = d.inMilliseconds / 1000.0);
    });
    _synthCompSub = _synth.onComplete.listen((_) {
      if (!mounted) return;
      // 보컬 레이어가 더 길 수 있어, audioplayers 가 정지 상태일 때만 종료 처리.
      if (_player.isPlaying) return;
      setState(() {
        _ps = _PlayState.stopped;
        _playheadSec = null;
      });
    });
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _compSub?.cancel();
    _synthPosSub?.cancel();
    _synthCompSub?.cancel();
    _recTimer?.cancel();
    _ampSub?.cancel();
    _rec.dispose();
    _metro.dispose();
    _player.dispose();
    _synth.dispose();
    super.dispose();
  }

  /// 편집(노트/악기/키 등)으로 오디오가 바뀌면 재생을 멈춰 다음 재생 시 재시퀀스.
  void _syncEpoch(ProjectStore store) {
    if (store.editEpoch != _lastEpoch) {
      _lastEpoch = store.editEpoch;
      if (_ps != _PlayState.stopped) {
        _synth.stop();
        _player.stop();
        _ps = _PlayState.stopped;
        _playheadSec = null;
      }
    }
  }

  Future<void> _onPlayTap(ProjectStore store) async {
    switch (_ps) {
      case _PlayState.playing:
        // 위치 보존 일시정지 — synth/보컬 모두 현재 위치 기억.
        await _synth.pause();
        await _player.pause();
        setState(() => _ps = _PlayState.paused);
        break;
      case _PlayState.paused:
        // 일시정지 위치부터 이어서 재생.
        await _synth.resume();
        await _player.resume();
        if (mounted) setState(() => _ps = _PlayState.playing);
        break;
      case _PlayState.stopped:
        await _playMix(store);
        break;
    }
  }

  // 새 리스트 참조를 반환해 _NotesPainter.shouldRepaint(reference equality)가 통과하게 한다.
  // applyCandidate 같은 in-place 변경 후에도 페인트가 발생함.
  List<Note> _displayNotes(TrackData t) => List<Note>.of(t.chordActive ? t.renderNotes : t.notes);

  double _projectDuration(ProjectStore store) {
    double m = 0;
    for (final t in store.tracks) {
      // 청크 timelineEnd 기준 — 청크가 이동/확장되면 타임라인도 따라 확장.
      for (final c in t.chunks) {
        if (c.timelineEnd > m) m = c.timelineEnd;
      }
      // 청크 메타가 없는 레거시 트랙: 노트 end 로 폴백.
      if (t.chunks.isEmpty) {
        for (final n in t.notes) {
          if (n.end > m) m = n.end;
        }
        if (t.vocalDuration > m) m = t.vocalDuration;
      }
    }
    // pending 결과(아직 commit 전)의 길이도 반영.
    final p = store.pendingRecording;
    if (p != null) {
      final pd = p.analysis?.durationSec ?? p.vocalDuration;
      if (pd > m) m = pd;
    }
    return m;
  }

  // ─── 인라인 녹음 (작업 동시성) ──────────────────────────────────────────
  String get _recTime {
    final s = _recMs ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _startInlineRecord(ProjectStore store) async {
    if (_recState != _RecState.idle) return;
    // 권한 먼저 확인 (카운트다운 후 거부되면 시간 낭비).
    if (!await _rec.hasPermission()) {
      if (mounted) comingSoon(context, '마이크 권한이 필요합니다');
      return;
    }
    // 카운트다운 시작 — 3→2→1 (각 400ms). 종료 후 실제 녹음 진입.
    setState(() {
      _recState = _RecState.countingDown;
      _recTrackId = store.activeTrackId;
      _recCountdownN = 3;
      _recCountdownProgress = 0;
    });
    final ok = await _runCountdown();
    if (!ok || !mounted) {
      setState(() => _recState = _RecState.idle);
      return;
    }
    setState(() => _recState = _RecState.recording);
    await _startActualRecording(store);
  }

  /// 카운트다운 실행 — 사용자가 lane 재탭으로 취소하면 false 반환.
  Future<bool> _runCountdown() async {
    const beatMs = 400;
    const stepMs = 16;
    final completer = Completer<bool>();
    int elapsed = 0;
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(milliseconds: stepMs), (timer) {
      if (_recState != _RecState.countingDown) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete(false);
        return;
      }
      elapsed += stepMs;
      final beat = elapsed ~/ beatMs;
      final inBeat = elapsed - beat * beatMs;
      if (beat >= 3) {
        timer.cancel();
        if (!completer.isCompleted) completer.complete(true);
        return;
      }
      setState(() {
        _recCountdownN = 3 - beat;
        _recCountdownProgress = inBeat / beatMs;
      });
    });
    return completer.future;
  }

  Future<void> _startActualRecording(ProjectStore store) async {
    final role = store.activeRole;

    // 기존 트랙 반주: 헤드셋이 있으면 소리로 재생(흥얼거림용), 스피커뿐이면 마이크
    // 누수 방지를 위해 소리는 끄고 트래킹 선만 움직인다(_recMuteAudio).
    _recHasBacking = false;
    _recPlayingAudio = false;
    final headset = await AudioRoute.hasHeadset();
    try {
      // 악기 반주: 온디바이스 SF2 시퀀서.
      final backingSynth = store.accompanimentSynthTracks(role)
          .map((t) => SynthTrack(notes: t.notes, program: t.program, isDrum: t.isDrum))
          .toList();
      final vocalBacking = store.accompanimentVocalPath(role); // 보컬도 함께
      debugPrint('[rec] headset=$headset synthTracks=${backingSynth.length} vocalBacking=${vocalBacking != null}');
      if (backingSynth.isNotEmpty || vocalBacking != null) {
        _recHasBacking = true;
        if (headset) {
          final futures = <Future<void>>[];
          if (backingSynth.isNotEmpty) futures.add(_synth.play(backingSynth));
          if (vocalBacking != null) futures.add(_player.playFile(vocalBacking));
          await Future.wait(futures);
          _recPlayingAudio = true; // 플레이어/시퀀서 위치가 플레이헤드를 구동
        }
      }
    } catch (e) {
      debugPrint('[rec] backing render failed: $e'); // 반주 없이 진행
    }
    if (!mounted) return;
    _recBackingDur = _projectDuration(store);

    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.wav';
    await _rec.start(path);
    _recMs = 0;
    _recWatch
      ..reset()
      ..start();
    for (int i = 0; i < _recLevels.length; i++) {
      _recLevels[i] = 0.04;
    }
    // _recState 는 호출자(_startInlineRecord) 가 카운트다운 종료 후 이미 recording 으로 전환.
    if (mounted) setState(() {});
    // 50ms 틱이되 시간은 Stopwatch 실측을 사용 → UI 지연이 있어도 선이 실제
    // 녹음 시간과 정확히 일치(틱 누적 드리프트 제거).
    _recTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      setState(() {
        _recMs = _recWatch.elapsedMilliseconds;
        // 반주를 소리로 재생 중이면 플레이어 위치가 플레이헤드를 구동(_posSub).
        // 스피커(음소거)면 여기서 실측 시간으로 선을 흘려 타이밍 가이드를 준다.
        if (!_recPlayingAudio && _recBackingDur > 0) {
          _playheadSec = (_recMs / 1000.0).clamp(0.0, _recBackingDur);
        }
      });
    });
    _ampSub = _rec.amplitude().listen((a) {
      final level = ((a.current + 45) / 45).clamp(0.04, 1.0).toDouble();
      if (!mounted) return;
      setState(() {
        _recLevels.removeAt(0);
        _recLevels.add(level);
      });
    });
    if (_metroOn) {
      try {
        await _metro.start(_bpm);
      } catch (e) {
        debugPrint('[metro] start failed: $e');
      }
    }
  }

  Future<void> _stopInlineRecord(ProjectStore store) async {
    if (_recState != _RecState.recording) return;
    _recTimer?.cancel();
    _recWatch.stop();
    await _ampSub?.cancel();
    await _metro.stop();
    if (_recPlayingAudio) {
      await _synth.stop();
      await _player.stop();
      if (mounted) _ps = _PlayState.stopped;
    }
    _recPlayingAudio = false;
    final path = await _rec.stop();
    setState(() {
      _recState = _RecState.processing;
      _playheadSec = null;
      _recTrackId = null; // 인라인 UI 제거.
    });
    if (path != null) {
      final tid = store.activeTrackId ?? store.active.id;
      store.clearSelection();
      final fut = store.analyzeForPending(path, tid);
      if (mounted) {
        setState(() => _recState = _RecState.idle);
        showPendingRecordingSheet(context, store);
      }
      await fut;
      if (mounted && store.error != null) comingSoon(context, store.error!);
      return;
    }
    if (mounted) {
      setState(() => _recState = _RecState.idle);
      if (store.error != null) comingSoon(context, store.error!);
    }
  }

  Future<void> _playMix(ProjectStore store) async {
    if (!store.hasPlayableMix) {
      comingSoon(context, store.hasAnyRecording ? '활성 트랙이 없습니다(사이드바 탭)' : '먼저 녹음하세요');
      return;
    }
    try {
      // 악기 트랙: 온디바이스 SF2 시퀀서(백엔드 호출 없음).
      // 보컬: 원본 WAV 를 audioplayers 로 동시 레이어 재생.
      final synthTracks = store.playableSynthTracks()
          .map((t) => SynthTrack(notes: t.notes, program: t.program, isDrum: t.isDrum))
          .toList();
      final vocalSchedule = store.vocalChunkSchedule();
      // 현재 플레이헤드 위치(scrollX 와 동기화된 _playheadSec)부터 재생 시작.
      final startSec = (_playheadSec ?? 0).clamp(0.0, double.infinity);
      debugPrint('[play] synthTracks=${synthTracks.length} vocalChunks=${vocalSchedule.length} startAt=${startSec.toStringAsFixed(2)}s');
      await _synth.stop();
      await _player.stop();
      final futures = <Future<void>>[];
      if (synthTracks.isNotEmpty) {
        futures.add(_synth.play(synthTracks, startAt: Duration(milliseconds: (startSec * 1000).round())));
      }
      if (vocalSchedule.isNotEmpty) {
        futures.add(_player.playVocalChunks(vocalSchedule, startFromSec: startSec));
      }
      await Future.wait(futures);
      if (mounted) setState(() => _ps = _PlayState.playing);
    } catch (e, st) {
      debugPrint('[play] FAILED: $e\n$st');
      if (mounted) comingSoon(context, '재생 실패: $e');
    }
  }

  Future<void> _playOriginal(ProjectStore store) async {
    final wav = store.active.wavPath;
    if (wav == null) return;
    try {
      await _player.playFile(wav); // 원본(내가 부른 WAV)
    } catch (e) {
      if (mounted) comingSoon(context, '원본 재생 실패');
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProjectStore>();
    _syncEpoch(store);
    final t = store.active;
    final dk = t.analysis?.detectedKey;

    // 컨텍스트 바 노출 여부 — FAB 위치를 컨텍스트 바 + 재생 바 위로 보정.
    final hasNoteSel = store.selectedNote != null && !t.chordActive;
    final hasChunkSel = store.selectedChunk != null && !t.chordActive;
    final hasTrackSel = !hasNoteSel && !hasChunkSel && store.trackSelected && store.activeTrackId != null;
    final ctxVisible = hasNoteSel || hasChunkSel || hasTrackSel;
    // 재생 바(88) + 컨텍스트 바(62, 있을 때) 위에 약간의 여백.
    final fabBottom = 88.0 + (ctxVisible ? 62.0 : 0.0) + 14.0;

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Stack(
          children: [
            Column(
          children: [
            _header(store),
            _controls(store, t, dk),
            Expanded(
              child: TimelineEditor(
                // 멀티트랙 모델 — 모든 트랙(카테고리당 N개) 을 한 번에 전달.
                // 사이드바는 카테고리별로 그룹화해 표시, 레인은 트랙 단위로 1행씩.
                tracks: store.tracks,
                activeTrackId: store.activeTrackId,
                // 코드 모드 활성 트랙은 확장된(화음) 노트를 표시 → 코드 변환이 시각적으로 보임.
                notesOverride: t.chordActive ? {t.id: _displayNotes(t)} : null,
                durationSec: _projectDuration(store),
                playheadSec: _playheadSec,
                selectedNote: t.chordActive ? null : store.selectedNote,
                selectedChunk: t.chordActive ? null : store.selectedChunk,
                onActivateTrack: store.setActiveTrack,
                onToggleEnabled: store.toggleTrackEnabled,
                onRecordAgain: (id) {
                  // 사이드바 "재녹음" chip — 그 트랙을 active 로 만든 뒤 인라인 녹음 시작.
                  // (전용 store 메서드 없음 → 활성화 + 기존 _startInlineRecord 재사용)
                  store.setActiveTrack(id);
                  _startInlineRecord(store);
                },
                onRecordEmpty: (id) {
                  // 빈 트랙 레인 안 "● 녹음 시작" pill → 그 트랙 활성화 + 인라인 녹음 시작.
                  store.setActiveTrack(id);
                  _startInlineRecord(store);
                },
                onSeek: _seek,
                onChunkTap: t.chordActive ? null : store.selectChunk,
                onChunkMove: t.chordActive ? null : store.moveChunkBy,
                onChunkResize: t.chordActive
                    ? null
                    : (id, {double? newLeftTimeline, double? newRightTimeline}) => store.resizeChunk(id,
                        newLeftTimeline: newLeftTimeline, newRightTimeline: newRightTimeline),
                onNoteTap: t.chordActive
                    ? null // 코드 모드에선 후보 편집 비활성 (단음 모드에서 편집)
                    : (i) => store.selectNote(i), // 선택만 — 음정 시트는 컨텍스트 액션 바의 "음정" 탭으로 열기.
                // 녹음 종료 직후 분석 결과 사용/삭제 다이얼로그(task #26).
                pending: store.pendingRecording,
                onPendingUse: store.commitPendingRecording,
                onPendingDiscard: store.discardPendingRecording,
                onPendingToggleAssist: store.togglePendingAssist,
                // 인라인 녹음(카운트다운 + 녹음중 UI) — 해당 트랙 lane 안에 표시.
                recPhase: _recState == _RecState.countingDown
                    ? InlineRecPhase.countingDown
                    : (_recState == _RecState.recording ? InlineRecPhase.recording : InlineRecPhase.idle),
                recTrackId: _recTrackId,
                recCountdownN: _recCountdownN,
                recCountdownProgress: _recCountdownProgress,
                recElapsedMs: _recMs,
                recLevels: _recLevels,
                onStopRec: () => _stopInlineRecord(store),
              ),
            ),
            _contextActionBar(store, t),
            _transport(store, t),
          ],
            ),
            // #27: 트랙 추가 FAB — 우측 하단, 재생 바 + (선택 시) 컨텍스트 바 위.
            Positioned(
              right: 16,
              bottom: fabBottom,
              child: _AddTrackFab(onTap: () => showAddTrackSheet(context, store)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(ProjectStore store) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              child: const Icon(Symbols.chevron_left, color: AppColors.textPrimary, size: 26),
            ),
            Text(store.title, style: T.title),
            Row(children: [
              GestureDetector(
                onTap: store.active.notes.isEmpty ? null : () => showExportShare(context, store),
                child: Icon(Symbols.ios_share, size: 22,
                    color: store.active.notes.isEmpty ? AppColors.textTertiary : AppColors.textPrimary),
              ),
              const SizedBox(width: 16),
              GestureDetector(
                onTap: () => Navigator.of(context).maybePop(),
                child: Text('완료', style: T.body.copyWith(color: AppColors.lime, fontWeight: FontWeight.w600)),
              ),
            ]),
          ],
        ),
      );

  Widget _controls(ProjectStore store, TrackData t, DetectedKey? dk) {
    // INSTRUMENT / KEY / 피치 어시스트 카드는 ActiveTrackCards 위젯이 담당(task #21).
    // 단음/코드 모드 토글(_modeToggle)은 #24 에서 컨텍스트 액션 바의 "코드"로 통합 — 제거됨.
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: _roleChips(store),
        ),
        ActiveTrackCards(store: store),
        // 녹음 진행 UI(카운트다운/녹음중/정지)는 트랙 레인 안 인라인으로 이동(task #35).
        // 상단 카드 영역엔 더 이상 녹음 상태 박스를 띄우지 않는다.
      ],
    );
  }

  Widget _roleChips(ProjectStore store) {
    Widget chip(TrackRole r) {
      final active = store.activeRole == r;
      return Expanded(
        child: GestureDetector(
          onTap: () => store.setActiveRole(r),
          child: Container(
            height: 38,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: active ? AppColors.lime : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.chip),
            ),
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(r.icon, size: 15, color: active ? AppColors.bg : AppColors.textSecondary),
              const SizedBox(width: 5),
              Text(r.label,
                  style: T.body.copyWith(
                      fontSize: 12, fontWeight: FontWeight.w600, color: active ? AppColors.bg : AppColors.textSecondary)),
            ]),
          ),
        ),
      );
    }

    return Container(
      height: 46,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [for (final r in TrackRole.values) chip(r)]),
    );
  }

  // ignore: unused_element
  Widget _recordButton(ProjectStore store, TrackData t) {
    // 모든 상태에서 같은 박스(높이 64) 유지 — idle→recording→processing 전환 시
    // 위치/크기 점프 없음. 미터는 항상 자리 차지(옵션 B): idle 시 lime 알파 0.18 정적,
    // recording 시 lime 1.0 으로 흐름, processing 시 알파 0.5 + 스피너 오버레이.
    const double boxH = 64;
    Widget meter({required bool active, double alpha = 0.18}) => CustomPaint(
          painter: MeterPainter(
            _recLevels,
            active: active,
            inactiveAlpha: alpha,
            barWidthRatio: 0.5,
            barWidthMin: 1.5,
            barWidthMax: 4.0,
            minBarHeight: 2.0,
          ),
          size: Size.infinite,
        );

    // 처리 중
    if (_recState == _RecState.processing) {
      return Container(
        height: boxH,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          const SizedBox(
            width: 18, height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.lime),
          ),
          const SizedBox(width: 12),
          const Text('변환 중…', style: TextStyle(color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(child: meter(active: false, alpha: 0.5)),
        ]),
      );
    }
    // 녹음 중: 같은 박스에 초 + 음파, 탭하면 종료.
    if (_recState == _RecState.recording) {
      return GestureDetector(
        onTap: () => _stopInlineRecord(store),
        child: Container(
          height: boxH,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.danger, width: 1.5),
          ),
          child: Row(children: [
            Container(width: 14, height: 14, decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(3))),
            const SizedBox(width: 10),
            Text(_recTime, style: T.body.copyWith(fontWeight: FontWeight.w700, fontFeatures: const [])),
            const SizedBox(width: 12),
            Expanded(child: meter(active: true)),
            const SizedBox(width: 10),
            if (_recHasBacking) const Icon(Symbols.headphones, size: 16, color: AppColors.textSecondary),
          ]),
        ),
      );
    }
    // 대기: 같은 64px 박스 + always-on 미터(dim). 탭하면 녹음 시작.
    final label = t.hasRecording ? '${t.role.label.toUpperCase()} 다시 녹음' : '${t.role.label.toUpperCase()} 녹음';
    return GestureDetector(
      onTap: () => _startInlineRecord(store),
      child: Container(
        height: boxH,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.dangerBorder),
        ),
        child: Row(children: [
          Container(width: 12, height: 12, decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(label, style: T.body.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 12),
          Expanded(child: meter(active: false)),
        ]),
      ),
    );
  }

  /// 선택 상태(노트 / 청크 / 트랙 / 미선택)에 따라 액션 셋을 동적으로 구성.
  /// - 미선택: 아예 숨김 (재생 바만 보임)
  /// - 트랙: 재녹음 · 코드 · 뮤트 · 볼륨 · 삭제
  /// - 청크: 분할 · 복사 · 루프 · 코드 · 볼륨 · 삭제
  /// - 노트: 음정 · 코드 · 볼륨 · 삭제
  Widget _contextActionBar(ProjectStore store, TrackData t) {
    final hasNote = store.selectedNote != null && !t.chordActive;
    final hasChunk = store.selectedChunk != null && !t.chordActive;
    final hasTrack = !hasNote && !hasChunk && store.trackSelected && store.activeTrackId != null;

    if (!hasNote && !hasChunk && !hasTrack) return const SizedBox.shrink();

    Widget item(IconData ic, String label, {required bool enabled, required VoidCallback onTap}) {
      return GestureDetector(
        onTap: enabled ? onTap : () => comingSoon(context, label),
        behavior: HitTestBehavior.opaque,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Icon(ic, size: 20, color: AppColors.textPrimary),
          ),
          const SizedBox(height: 3),
          Text(label, style: T.label.copyWith(fontSize: 9, color: AppColors.textSecondary)),
        ]),
      );
    }

    final items = <Widget>[];

    if (hasNote) {
      // 노트: 음정 · (코드 — 코드 가능 악기만) · 볼륨 · 삭제
      items.add(item(Symbols.music_note, '음정',
          enabled: true,
          onTap: () => showNoteCandidate(context, store, store.selectedNote!)));
      if (t.isChordInstrument) {
        final isChord = store.canUnchordSelected;
        items.add(item(isChord ? Symbols.heart_broken : Symbols.queue_music,
            isChord ? '코드 해제' : '코드',
            enabled: store.canChordSelected || isChord,
            onTap: () => showChordPicker(context, store)));
      }
      items.addAll([
        item(Symbols.volume_up, '볼륨', enabled: true, onTap: () => _showVolume(store)),
        item(Symbols.delete, '삭제', enabled: true, onTap: store.deleteSelectedAny),
      ]);
    } else if (hasChunk) {
      // 청크: 분할 · 복사 · 루프 · (코드 — 코드 가능 악기만) · 볼륨 · 삭제
      items.addAll([
        item(Symbols.content_cut, '분할',
            enabled: true, onTap: () {
              if (!store.splitSelectedAny(_playheadSec)) {
                comingSoon(context, '현재 위치에서는 분할할 수 없음');
              }
            }),
        item(Symbols.content_copy, '복사', enabled: true, onTap: store.copySelectedAny),
        item(Symbols.repeat, '루프', enabled: true, onTap: store.loopSelectedAny),
      ]);
      if (t.isChordInstrument) {
        final isChunkChord = store.canUnchordChunkSelected;
        items.add(item(isChunkChord ? Symbols.heart_broken : Symbols.queue_music,
            isChunkChord ? '코드 해제' : '코드',
            enabled: store.canChordChunkSelected || isChunkChord,
            onTap: () => showChordPicker(context, store)));
      }
      items.addAll([
        item(Symbols.volume_up, '볼륨', enabled: true, onTap: () => _showVolume(store)),
        item(Symbols.delete, '삭제', enabled: true, onTap: store.deleteSelectedAny),
      ]);
    } else {
      // 트랙: 재녹음 · 코드 · 뮤트 · 볼륨 · 삭제
      // (트랙 코드 = chordMode 토글, 시트 없이 즉시. 비-코드 악기/키 미정이면 disabled)
      final canTrackChord = t.isChordInstrument && t.analysis?.detectedKey?.tonic != null;
      final trackHasNotes = t.notes.isNotEmpty;
      items.add(item(Symbols.mic, '재녹음',
          enabled: _recState == _RecState.idle,
          onTap: () => _startInlineRecord(store)));
      if (t.isChordInstrument) {
        items.add(item(t.chordActive ? Symbols.heart_broken : Symbols.queue_music,
            t.chordActive ? '코드 해제' : '코드',
            enabled: canTrackChord && trackHasNotes,
            onTap: () => store.setChordMode(!t.chordMode)));
      }
      items.addAll([
        item(t.enabled ? Symbols.volume_up : Symbols.volume_off,
            t.enabled ? '뮤트' : '뮤트 해제',
            enabled: true,
            onTap: () => store.toggleTrackEnabled(t.id)),
        item(Symbols.volume_up, '볼륨',
            enabled: t.notes.isNotEmpty,
            onTap: () => _showVolume(store)),
        item(Symbols.delete, '삭제',
            enabled: true,
            onTap: () => _confirmTrackDelete(store, t)),
      ]);
    }

    return Container(
      height: 62,
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: items),
    );
  }

  void _confirmTrackDelete(ProjectStore store, TrackData t) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: Text('${t.role.label} 트랙 삭제', style: T.title),
        content: const Text('녹음과 노트가 모두 삭제됩니다.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('취소')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              store.removeTrack(t.id);
              store.clearSelection();
            },
            child: const Text('삭제', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  void _showVolume(ProjectStore store) {
    int vel = store.selectedVelocity ?? 90;
    final isChunk = store.selectedChunk != null;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => StatefulBuilder(
        builder: (c, setS) => Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text(isChunk ? '청크 볼륨' : '노트 볼륨', style: T.title),
              Text('${(vel / 127 * 100).round()}%', style: T.h2.copyWith(color: AppColors.lime, fontSize: 20)),
            ]),
            const SizedBox(height: 8),
            Slider(
              value: vel.toDouble(),
              min: 1, max: 127, activeColor: AppColors.lime,
              onChanged: (v) {
                setS(() => vel = v.round());
                store.setSelectedVolume(vel); // 즉시 반영(다음 재생에 적용)
              },
            ),
          ]),
        ),
      ),
    );
  }

  Widget _transport(ProjectStore store, TrackData t) {
    final canOrig = t.wavPath != null;
    final icon = store.busy
        ? Symbols.hourglass_empty
        : (_ps == _PlayState.playing ? Symbols.pause : Symbols.play_arrow);
    return Container(
      height: 88,
      color: AppColors.bg,
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 원본(내가 부른 WAV) 재생
          _miniBtn(Symbols.mic, '원본', enabled: canOrig, onTap: () => _playOriginal(store)),
          // 활성 트랙 믹스 — 재생/일시정지 토글(멈춘 지점부터 재개)
          GestureDetector(
            onTap: () => _onPlayTap(store),
            child: Container(
              width: 56,
              height: 56,
              decoration: const BoxDecoration(color: AppColors.lime, shape: BoxShape.circle),
              child: Icon(icon, color: AppColors.bg, size: 26),
            ),
          ),
          _metroBtn(),
        ],
      ),
    );
  }

  Widget _metroBtn() {
    final color = _metroOn ? AppColors.lime : AppColors.textPrimary;
    return GestureDetector(
      onTap: () async {
        setState(() => _metroOn = !_metroOn);
        if (_recState == _RecState.recording) {
          _metroOn ? await _metro.start(_bpm) : await _metro.stop();
        }
      },
      onLongPress: _pickBpm,
      child: SizedBox(
        width: 44,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Symbols.timer, size: 24, color: color),
          const SizedBox(height: 3),
          Text('♩$_bpm', style: T.label.copyWith(fontSize: 9, color: color)),
        ]),
      ),
    );
  }

  void _pickBpm() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (_) => StatefulBuilder(
        builder: (c, setS) {
          Widget step(IconData ic, VoidCallback on) => GestureDetector(
                onTap: () => setS(on),
                child: Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.bg, borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Icon(ic, color: AppColors.textPrimary),
                ),
              );
          return Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('메트로놈 템포', style: T.title),
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                step(Symbols.remove, () => _bpm = (_bpm - 5).clamp(40, 240)),
                const SizedBox(width: 28),
                Text('$_bpm', style: T.h1.copyWith(fontSize: 44)),
                const SizedBox(width: 6),
                Text('BPM', style: T.sub),
                const SizedBox(width: 28),
                step(Symbols.add, () => _bpm = (_bpm + 5).clamp(40, 240)),
              ]),
            ]),
          );
        },
      ),
    ).then((_) {
      if (mounted) setState(() {});
    });
  }

  // _AddTrackFab 는 클래스 외부 StatelessWidget — context.read 가 아닌 콜백 주입.
  Widget _miniBtn(IconData ic, String label, {required bool enabled, required VoidCallback onTap}) {
    // 비활성 시 아이콘만 dim, 라벨은 항상 readable.
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Icon(ic, size: 24, color: AppColors.textPrimary),
        ),
        const SizedBox(height: 3),
        Text(label, style: T.label.copyWith(fontSize: 9, color: AppColors.textSecondary)),
      ]),
    );
  }
}

// 트랙 추가 FAB — 40×40 흰색 원형 + 다크 + 아이콘. 시안 docs/mockups/track-expansion.html.
class _AddTrackFab extends StatelessWidget {
  final VoidCallback onTap;
  const _AddTrackFab({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.textPrimary,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: const Icon(Symbols.add, color: AppColors.bg, size: 22, weight: 700),
      ),
    );
  }
}

