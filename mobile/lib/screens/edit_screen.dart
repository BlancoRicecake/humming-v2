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
import '../widgets/common.dart';
import '../widgets/meter_painter.dart';
import '../widgets/sheets.dart';
import '../widgets/timeline_editor.dart';

enum _PlayState { stopped, playing, paused }

enum _RecState { idle, recording, processing }

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
  bool _recHasBacking = false; // 반주 트랙이 있는지(헤드셋 무관)
  bool _recPlayingAudio = false; // 반주를 실제 소리로 재생 중인지(헤드셋 연결 시만)
  double _recBackingDur = 0; // 반주 길이(선만 움직일 때 상한)
  final Stopwatch _recWatch = Stopwatch(); // 실제 경과시간(틱 드리프트 방지)
  Timer? _recTimer;
  StreamSubscription? _ampSub;
  final List<double> _recLevels = List.filled(40, 0.04);

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
    for (final t in store.tracks.values) {
      for (final n in t.notes) {
        if (n.end > m) m = n.end;
      }
      if (t.vocalDuration > m) m = t.vocalDuration; // 보컬 길이도 포함
    }
    return m;
  }

  String _instrumentName(TrackData t) {
    for (final i in instrumentPalette[t.role] ?? const <Instrument>[]) {
      if (i.program == t.program) return i.label;
    }
    return t.role == TrackRole.drum ? '드럼 키트' : (t.role == TrackRole.vocal ? '원본 보컬' : '악기');
  }

  // ─── 인라인 녹음 (작업 동시성) ──────────────────────────────────────────
  String get _recTime {
    final s = _recMs ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _startInlineRecord(ProjectStore store) async {
    if (_recState != _RecState.idle) return;
    setState(() => _recState = _RecState.recording); // 즉시 잠금(재진입 방지)
    if (!await _rec.hasPermission()) {
      if (mounted) {
        setState(() => _recState = _RecState.idle);
        comingSoon(context, '마이크 권한이 필요합니다');
      }
      return;
    }
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
    setState(() => _recState = _RecState.recording);
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
    });
    if (path != null) {
      await store.recordAnalyzed(path, role: store.activeRole);
      store.selectNote(null);
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
      final vocalPath = store.vocalMixPath;
      debugPrint('[play] synthTracks=${synthTracks.length} vocal=${vocalPath != null}');
      await _synth.stop();
      await _player.stop();
      final futures = <Future<void>>[];
      if (synthTracks.isNotEmpty) futures.add(_synth.play(synthTracks));
      if (vocalPath != null) futures.add(_player.playFile(vocalPath));
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

    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            _header(store),
            _controls(store, t, dk),
            Expanded(
              child: TimelineEditor(
                // 코드 모드 트랙은 확장된(화음) 노트를 표시 → 코드 변환이 시각적으로 보임.
                tracks: {for (final r in TrackRole.values) r: _displayNotes(store.tracks[r]!)},
                enabled: {for (final r in TrackRole.values) r: store.tracks[r]!.enabled},
                activeRole: store.activeRole,
                durationSec: _projectDuration(store),
                playheadSec: _playheadSec,
                selectedNote: t.chordActive ? null : store.selectedNote,
                selectedChunk: t.chordActive ? null : store.selectedChunk,
                waveforms: {
                  for (final r in TrackRole.values)
                    if (store.tracks[r]!.vocalPeaks.isNotEmpty)
                      r: (peaks: store.tracks[r]!.vocalPeaks, dur: store.tracks[r]!.vocalDuration),
                },
                onActivateRole: store.setActiveRole,
                onToggleEnable: store.toggleEnabled,
                onSeek: _seek,
                onChunkTap: t.chordActive ? null : store.selectChunk,
                onChunkMove: t.chordActive ? null : store.moveChunkBy,
                onChunkResize: t.chordActive
                    ? null
                    : (id, {double? newStart, double? newEnd}) =>
                        store.resizeChunk(id, newStart: newStart, newEnd: newEnd),
                onNoteTap: t.chordActive
                    ? null // 코드 모드에선 후보 편집 비활성 (단음 모드에서 편집)
                    : (i) {
                        store.selectNote(i);
                        showNoteCandidate(context, store, i);
                      },
              ),
            ),
            _toolbar(store),
            _transport(store, t),
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
                child: Text('Done', style: T.body.copyWith(color: AppColors.lime, fontWeight: FontWeight.w600)),
              ),
            ]),
          ],
        ),
      );

  Widget _controls(ProjectStore store, TrackData t, DetectedKey? dk) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        children: [
          _roleChips(store),
          const SizedBox(height: 12),
          _instrumentRow(store, t),
          const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => showKeyPicker(context, store),
                  child: _keyCard(dk, t.options.autoKey),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _assistCard(store, t)),
            ]),
          ),
          const SizedBox(height: 12),
          _recordButton(store, t),
        ],
      ),
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

  Widget _instrumentRow(ProjectStore store, TrackData t) {
    return Row(children: [
      Expanded(
        child: GestureDetector(
          onTap: () => showInstrumentPicker(context, store),
          child: Container(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              Icon(t.role.icon, size: 18, color: AppColors.lime),
              const SizedBox(width: 10),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('INSTRUMENT', style: T.label.copyWith(fontSize: 8)),
                    _helpIcon(
                      title: 'INSTRUMENT',
                      body:
                          '이 트랙을 어떤 악기 소리로 재생할지 선택해요.\n\n'
                          '분석된 음정에 SoundFont 악기 음색을 입혀 들려줘요. '
                          '같은 멜로디라도 피아노·기타·베이스 등 자유롭게 바꿔 들어 볼 수 있어요.',
                    ),
                  ]),
                  Text(_instrumentName(t), style: T.body.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
              const Spacer(),
              const Icon(Symbols.keyboard_arrow_down, size: 20, color: AppColors.textSecondary),
            ]),
          ),
        ),
      ),
      if (t.isChordInstrument) ...[
        const SizedBox(width: 6),
        _helpIcon(
          title: '단음 / 코드',
          body:
              '단음 = 부른 그대로 한 번에 한 음씩 재생.\n\n'
              '코드 = 각 음을 다이아토닉 트라이어드(I·III·V 3화음)로 자동 확장. '
              '키에 맞춰 화음을 깔아 줘요.\n\n'
              '키보드·기타처럼 화음 가능 악기에서만 보여요.',
        ),
        const SizedBox(width: 4),
        _modeToggle(store, t),
      ],
    ]);
  }

  Widget _modeToggle(ProjectStore store, TrackData t) {
    Widget seg(String label, bool active, VoidCallback onTap) => GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: active ? AppColors.lime : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(label,
                style: T.body.copyWith(
                    fontSize: 12, fontWeight: FontWeight.w600, color: active ? AppColors.bg : AppColors.textSecondary)),
          ),
        );
    return Container(
      height: 50,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        seg('단음', !t.chordMode, () => store.setChordMode(false)),
        const SizedBox(width: 3),
        seg('코드', t.chordMode, () => store.setChordMode(true)),
      ]),
    );
  }

  // 5-3: 헤더 라벨 옆 ⓘ — 탭 시 용어 설명 시트.
  Widget _helpIcon({required String title, required String body}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showHelpSheet(context, title, body),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Icon(Symbols.info, size: 13, color: AppColors.textTertiary),
      ),
    );
  }

  Widget _card({required Widget child}) => Container(
        constraints: const BoxConstraints(minHeight: 86),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: child,
      );

  Widget _keyCard(DetectedKey? dk, bool isAuto) {
    final tierLabel = dk?.keyTier == null ? '' : ' · ${dk!.keyTier}';
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              Text('KEY', style: T.label),
              _helpIcon(
                title: 'KEY · 키와 신뢰도',
                body:
                    '곡의 으뜸음(C, D…)과 모드(메이저/마이너)예요.\n\n'
                    'AUTO = 분석이 자동 추정한 키. 카드를 탭하면 수동으로 바꿀 수 있어요.\n\n'
                    '신뢰도 = 추정이 얼마나 확실한지 (0~1). '
                    'high / mid / low 단계로 표시해요. 낮으면 수동 지정을 고려해 보세요.',
              ),
            ]),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: AppColors.activeLane, borderRadius: BorderRadius.circular(6)),
              child: Text(isAuto ? 'AUTO' : '수동', style: T.label.copyWith(color: AppColors.lime, fontSize: 8)),
            ),
          ]),
          const SizedBox(height: 4),
          Text(dk?.label ?? '—', style: T.h2.copyWith(fontSize: 22)),
          const Spacer(),
          Row(children: [
            Expanded(
              child: Text(dk == null ? '녹음 후 분석' : '신뢰도 ${dk.confidence.toStringAsFixed(2)}$tierLabel',
                  style: T.sub.copyWith(fontSize: 10), overflow: TextOverflow.ellipsis),
            ),
            const Icon(Symbols.keyboard_arrow_down, size: 14, color: AppColors.textSecondary),
          ]),
        ],
      ),
    );
  }

  Widget _assistCard(ProjectStore store, TrackData t) {
    final count = t.analysis?.assistAppliedCount ?? 0;
    final on = t.options.pitchAssistant;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Row(children: [
              Text('피치 어시스트', style: T.label),
              _helpIcon(
                title: '피치 어시스트',
                body:
                    '키 밖으로 살짝 빗나간 음을 가장 가까운 in-key 음으로 자동 보정해 줘요.\n\n'
                    '“보정됨” 숫자 = 실제로 끌어당겨진 노트 개수.\n\n'
                    '끄면 부른 음 그대로 유지돼요. 음정이 불안할 때 켜 보세요.',
              ),
            ]),
            GestureDetector(
              onTap: () => store.togglePitchAssistant(!on),
              child: Container(
                width: 38,
                height: 22,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: on ? AppColors.lime : AppColors.border,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Align(
                  alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(width: 18, height: 18, decoration: const BoxDecoration(color: AppColors.bg, shape: BoxShape.circle)),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('$count', style: T.h2.copyWith(fontSize: 22, color: AppColors.lime)),
            const SizedBox(width: 4),
            Padding(padding: const EdgeInsets.only(bottom: 3), child: Text('보정됨', style: T.body.copyWith(fontWeight: FontWeight.w600))),
          ]),
          const Spacer(),
          Text('키 밖 음 자동 정리', style: T.sub.copyWith(fontSize: 10)),
        ],
      ),
    );
  }

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

  Widget _toolbar(ProjectStore store) {
    // 노트 또는 청크가 선택되면 활성. 선택 대상에 따라 동작이 자동 분기.
    final hasSel = store.hasSelection && !store.active.chordActive;
    final hasNotes = store.active.notes.isNotEmpty;
    // Chord 버튼: 단음 선택 시 "Chord"(코드화 시트), 코드 묶음 선택 시 "Unchord".
    final canChord = store.canChordSelected && !store.active.chordActive;
    final canUnchord = store.canUnchordSelected && !store.active.chordActive;
    final chordEnabled = canChord || canUnchord;
    final chordLabel = canUnchord ? 'Unchord' : 'Chord';
    final chordIcon = canUnchord ? Symbols.heart_broken : Symbols.queue_music;

    Widget item(IconData ic, String label, {required bool enabled, required VoidCallback onTap}) {
      // 비활성 시 아이콘만 dim 처리 — 라벨은 항상 readable 하게 유지해
      // 사용자가 어떤 버튼인지 인지할 수 있게 한다.
      return GestureDetector(
        onTap: enabled ? onTap : () => comingSoon(context, hasSel ? label : '노트나 청크를 먼저 선택하세요'),
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

    return Container(
      height: 62,
      color: AppColors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
        item(Symbols.content_cut, 'Split', enabled: hasSel, onTap: () => store.splitSelectedAny(_playheadSec)),
        item(Symbols.content_copy, 'Copy', enabled: hasSel, onTap: store.copySelectedAny),
        item(Symbols.repeat, 'Loop', enabled: hasNotes, onTap: store.loopSelectedAny),
        // 시트가 코드 ↔ 단음 토글을 통합 처리(미리듣기 포함). 항상 picker 열기.
        item(chordIcon, chordLabel,
            enabled: chordEnabled,
            onTap: () => showChordPicker(context, store)),
        item(Symbols.delete, 'Delete', enabled: hasSel, onTap: store.deleteSelectedAny),
        item(Symbols.volume_up, 'Volume', enabled: hasSel, onTap: () => _showVolume(store)),
      ]),
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

