// 트랙(노트 리스트) 시퀀서 — SynthEngine 위에서 timeline 기반 noteOn/noteOff 스케줄링.
//
// 백엔드 /render_mix 를 대체하는 온디바이스 재생 경로. 멀티트랙 동시 재생을 위해
// 각 멜로딕 트랙에 채널을 할당(0,1,2,…, 드럼=9 회피)하고, percussive 노트는 ch9 로.
//
// 현재 범위(task #5):
//   - play(tracks) / stop()        ← 정확히 구현
//   - 일시정지/재개/seek           ← 미지원 (호출자 입장에선 stop 후 재생부터)
// 후속에서 onPosition 스트림, pause/resume 정밀 구현 가능.
import 'dart:async';
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
  Duration _lengthHint = Duration.zero;
  DateTime? _startedAt;

  // 위치 통지(플레이헤드 갱신). 100ms 주기로 발행.
  final StreamController<Duration> _posCtl = StreamController<Duration>.broadcast();
  final StreamController<void> _doneCtl = StreamController<void>.broadcast();
  Timer? _posTimer;

  Stream<Duration> get onPosition => _posCtl.stream;
  Stream<void> get onComplete => _doneCtl.stream;
  bool get isPlaying => _playing;

  /// 멀티트랙 재생. 멜로딕 트랙은 ch 0,1,2 … 로 자동 배정(드럼 채널 9 회피).
  /// 빈 입력이면 즉시 complete.
  Future<void> play(List<SynthTrack> tracks) async {
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

    final token = ++_playToken;
    _playing = true;
    _lengthHint = Duration(milliseconds: (maxEnd * 1000).round());
    _startedAt = DateTime.now();

    // 100ms 주기 위치 통지.
    _posTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!_playing || _startedAt == null) return;
      final pos = DateTime.now().difference(_startedAt!);
      _posCtl.add(pos);
    });

    // 비차단 시퀀서 — Future 체인으로 이벤트 발사.
    unawaited(_runSequencer(events, token));
  }

  Future<void> _runSequencer(List<_Ev> events, int token) async {
    final start = DateTime.now();
    for (final ev in events) {
      if (token != _playToken) return; // stop 됨
      final targetMs = (ev.time * 1000).round();
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
    final tailMs = (_lengthHint.inMilliseconds - DateTime.now().difference(start).inMilliseconds);
    if (tailMs > 0) {
      await Future.delayed(Duration(milliseconds: tailMs.clamp(0, 800)));
    }
    if (token != _playToken) return;
    _playing = false;
    _posTimer?.cancel();
    _posTimer = null;
    _doneCtl.add(null);
  }

  /// 즉시 정지 — 진행 중 시퀀서를 무효화하고 모든 노트 off.
  Future<void> stop() async {
    _playToken++; // 진행 중 루프 무효화
    _playing = false;
    _startedAt = null;
    _posTimer?.cancel();
    _posTimer = null;
    try {
      await SynthEngine().stopAll();
    } catch (e) {
      debugPrint('[synth_player] stop failed: $e');
    }
  }

  /// pause/resume 정밀 구현은 후속. 현재는 stop 과 동일(노트 모두 off).
  /// 호출자는 paused 상태를 자체 관리하고, resume 시 처음부터 재생을 권장.
  Future<void> pause() => stop();

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
