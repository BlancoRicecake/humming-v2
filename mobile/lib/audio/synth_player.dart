// 트랙(노트 리스트) 시퀀서 — SynthEngine 위에서 timeline 기반 noteOn/noteOff 스케줄링.
//
// 백엔드 /render_mix 를 대체하는 온디바이스 재생 경로. 멀티트랙 동시 재생을 위해
// 각 멜로딕 트랙에 채널을 할당(0,1,2,…, 드럼=9 회피)하고, percussive 노트는 ch9 로.
//
// task #14 추가: 위치 보존 pause/resume + seek(점프). 구현 단순화를 위해
//   - pause 시 모든 활성 노트를 stopAll 로 즉시 끄고 누적 진행 시간(_pausedAt) 만 보존
//   - resume / seek 시 누적 진행 시각 이후 이벤트만 필터링해 재스케줄
//   - pause 시점에 sustain 중이던 노트는 다시 발사되지 않음(음 끊김 OK)
//   - envelope 정밀 복원은 미구현 (sf2/midi 한계 — 호출 시점에 다시 noteOn 만)
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../models/models.dart';
import 'synth.dart';

class SynthTrack {
  SynthTrack({required this.notes, required this.program, required this.isDrum});
  final List<Note> notes;
  final int program;
  final bool isDrum;
}

class SynthPlayer {
  SynthPlayer();

  // 진행 중 재생을 식별하는 토큰 — stop() 으로 무효화하면 진행 중 루프가 즉시 종료.
  int _playToken = 0;
  bool _playing = false;
  bool _paused = false;
  Duration _lengthHint = Duration.zero;
  DateTime? _startedAt;

  // 누적 진행 시간 — pause/seek 의 기준점. 재생 시각 = now - _startedAt + _pausedAt.
  Duration _pausedAt = Duration.zero;

  // 가장 최근 play() 호출의 이벤트(resume/seek 재스케줄용).
  List<_Ev> _events = const [];

  // 위치 통지(플레이헤드 갱신). 50ms 주기로 발행.
  final StreamController<Duration> _posCtl = StreamController<Duration>.broadcast();
  final StreamController<void> _doneCtl = StreamController<void>.broadcast();
  Timer? _posTimer;

  Stream<Duration> get onPosition => _posCtl.stream;
  Stream<void> get onComplete => _doneCtl.stream;
  bool get isPlaying => _playing;
  bool get isPaused => _paused;
  Duration get position {
    if (_playing && _startedAt != null) {
      return DateTime.now().difference(_startedAt!) + _pausedAt;
    }
    return _pausedAt;
  }

  /// 멀티트랙 재생. 멜로딕 트랙은 ch 0,1,2 … 로 자동 배정(드럼 채널 9 회피).
  /// [startAt] 부터 시작(기본 0). seek/resume 내부 호출에서도 사용.
  Future<void> play(
    List<SynthTrack> tracks, {
    Duration startAt = Duration.zero,
    Duration? endAt, // 명시 종료 시각 — 마지막 노트 뒤 빈 여백 포함해 재생 길이 결정.
  }) async {
    await stop();
    if (tracks.isEmpty) {
      _doneCtl.add(null);
      return;
    }
    await SynthEngine().ensureLoaded();

    // (time, isOn, channel, pitch, velocity) 이벤트 빌드.
    final events = <_Ev>[];
    int melodicCh = 0;
    double maxEnd = 0;
    for (final tr in tracks) {
      int ch;
      if (tr.isDrum) {
        ch = SynthEngine.drumChannel;
      } else {
        ch = melodicCh;
        melodicCh++;
        if (melodicCh == SynthEngine.drumChannel) melodicCh++; // 9 회피
      }
      // 멜로딕은 트랙 첫 이벤트 직전에 program select. ensureLoaded 직후에 한 번.
      if (!tr.isDrum) {
        // 백그라운드로 program 셋업 — 첫 noteOn 시점에 캐시되어 있을 가능성↑
        // 정확성을 위해 await 으로 sync.
        await SynthEngine().noteOn(
          channel: ch,
          pitch: 60,
          velocity: 1, // 가청 임계 미만 — 사실상 program select 트리거용
          program: tr.program,
        );
        await SynthEngine().noteOff(channel: ch, pitch: 60);
      }
      for (final n in tr.notes) {
        events.add(_Ev(n.start, true, ch, n.pitch, n.velocity));
        events.add(_Ev(n.end, false, ch, n.pitch, 0));
        if (n.end > maxEnd) maxEnd = n.end;
      }
    }
    if (events.isEmpty) {
      _doneCtl.add(null);
      return;
    }
    // on 보다 off 가 먼저 와선 안 됨 → 같은 시각이면 off 우선(이전 노트 종료) 후 on.
    events.sort((a, b) {
      final c = a.time.compareTo(b.time);
      if (c != 0) return c;
      // off=0, on=1 — off 먼저
      return (a.isOn ? 1 : 0).compareTo(b.isOn ? 1 : 0);
    });

    _events = events;
    // endAt 명시 시 그 값 사용 — 노트 뒤 빈 여백/루프 패딩까지 포함해 재생.
    final endMs = endAt != null
        ? endAt.inMilliseconds
        : (maxEnd * 1000).round();
    _lengthHint = Duration(milliseconds: math.max(endMs, (maxEnd * 1000).round()));
    _pausedAt = startAt;
    await _startFrom(startAt);
  }

  /// 내부: 현재 _events 에서 [from] 이후만 골라 시퀀서 시작.
  Future<void> _startFrom(Duration from) async {
    final fromSec = from.inMilliseconds / 1000.0;
    final filtered = _events.where((e) => e.time >= fromSec).toList();
    if (filtered.isEmpty) {
      // 재생할 게 없음 — tail 만 흘려보내고 complete.
      _playing = false;
      _paused = false;
      _startedAt = null;
      _posTimer?.cancel();
      _posTimer = null;
      _doneCtl.add(null);
      return;
    }

    final token = ++_playToken;
    _playing = true;
    _paused = false;
    _startedAt = DateTime.now();

    // 50ms 주기 위치 통지.
    _posTimer?.cancel();
    _posTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_playing || _startedAt == null) return;
      final pos = DateTime.now().difference(_startedAt!) + _pausedAt;
      _posCtl.add(pos);
    });

    unawaited(_runSequencer(filtered, fromSec, token));
  }

  Future<void> _runSequencer(List<_Ev> events, double offsetSec, int token) async {
    final start = DateTime.now();
    for (final ev in events) {
      if (token != _playToken) return; // stop / pause / seek 됨
      final targetMs = ((ev.time - offsetSec) * 1000).round();
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final wait = targetMs - elapsed;
      if (wait > 0) {
        await Future.delayed(Duration(milliseconds: wait));
        if (token != _playToken) return;
      }
      if (ev.isOn) {
        // ignore: discarded_futures
        SynthEngine().noteOn(
          channel: ev.channel, pitch: ev.pitch, velocity: ev.velocity,
        );
      } else {
        // ignore: discarded_futures
        SynthEngine().noteOff(channel: ev.channel, pitch: ev.pitch);
      }
    }
    // 마지막 noteOff release tail 위해 짧게 대기.
    final remainingMs = _lengthHint.inMilliseconds -
        (offsetSec * 1000).round() -
        DateTime.now().difference(start).inMilliseconds;
    if (remainingMs > 0) {
      // 마지막 noteOff 이후 _lengthHint 끝까지 대기 — 청크의 빈 여백/루프 패딩 동안 무음 재생.
      await Future.delayed(Duration(milliseconds: remainingMs));
    }
    if (token != _playToken) return;
    _playing = false;
    _paused = false;
    _pausedAt = Duration.zero;
    _startedAt = null;
    _posTimer?.cancel();
    _posTimer = null;
    _doneCtl.add(null);
  }

  /// 위치 보존 일시정지. 활성 노트는 모두 끄되 누적 진행 시간(_pausedAt) 보존.
  Future<void> pause() async {
    if (!_playing) return;
    final pos = DateTime.now().difference(_startedAt!) + _pausedAt;
    _pausedAt = pos;
    _playToken++; // 진행 중 시퀀서 무효화
    _playing = false;
    _paused = true;
    _startedAt = null;
    _posTimer?.cancel();
    _posTimer = null;
    try {
      await SynthEngine().stopAll();
    } catch (e) {
      debugPrint('[synth_player] pause stopAll failed: $e');
    }
  }

  /// 일시정지된 위치부터 재개. paused 상태가 아니면 no-op.
  Future<void> resume() async {
    if (!_paused) return;
    if (_events.isEmpty) {
      _paused = false;
      _doneCtl.add(null);
      return;
    }
    await _startFrom(_pausedAt);
  }

  /// 특정 시각으로 점프.
  ///   - 재생 중: 새 위치부터 이어서 재생
  ///   - 일시정지: _pausedAt 만 갱신 (재생 시작은 resume 시)
  ///   - 정지: _pausedAt 갱신, ▶ 누르면 그 위치부터 재생되도록 events 보존
  Future<void> seek(double sec) async {
    final target = Duration(milliseconds: (sec * 1000).round());
    if (_playing) {
      // 진행 중인 노트 모두 끄고 새 위치부터 재스케줄.
      _playToken++;
      _playing = false;
      _startedAt = null;
      _posTimer?.cancel();
      _posTimer = null;
      try {
        await SynthEngine().stopAll();
      } catch (e) {
        debugPrint('[synth_player] seek stopAll failed: $e');
      }
      _pausedAt = target;
      await _startFrom(target);
    } else {
      // 일시정지 / 정지 — 위치만 갱신.
      _pausedAt = target;
      _posCtl.add(target);
    }
  }

  /// 즉시 정지 — 진행 중 시퀀서를 무효화하고 모든 노트 off. 누적 위치 초기화.
  Future<void> stop() async {
    _playToken++; // 진행 중 루프 무효화
    _playing = false;
    _paused = false;
    _pausedAt = Duration.zero;
    _startedAt = null;
    _posTimer?.cancel();
    _posTimer = null;
    try {
      await SynthEngine().stopAll();
    } catch (e) {
      debugPrint('[synth_player] stop failed: $e');
    }
  }

  void dispose() {
    stop();
    _posCtl.close();
    _doneCtl.close();
  }
}

class _Ev {
  _Ev(this.time, this.isOn, this.channel, this.pitch, this.velocity);
  final double time;
  final bool isOn;
  final int channel;
  final int pitch;
  final int velocity;
}
