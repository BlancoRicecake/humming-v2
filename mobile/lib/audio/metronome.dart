// 메트로놈 — 1kHz sine 클릭(원래 맑은 톡) 을 Timer.periodic 으로 매 비트 발음.
//
// audioplayers loop 의 미세 갭(누적 박자 밀림) 회피를 위해 **루프 사용 안 함**.
// 매 비트마다 짧은 클릭 WAV 를 한 번씩 play() — 호출 latency 는 매번 동일하니
// 절대 drift 가 없음. 다음 비트 시각은 `startedAt + N×period` 절대값 기준으로
// 계산해 Timer 지터(수 ms) 도 누적되지 않음.
//
// onTick — 시각 펄스 등 외부 sync 필요 시 호출자가 콜백 등록 (메트로놈 발음과
// 같은 Dart frame 에 실행되어 시각/청각 동기가 보장됨).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class Metronome {
  final AudioPlayer _p = AudioPlayer();
  String? _clickPath;
  bool _clickReady = false;

  Timer? _timer;
  int? _bpm;
  DateTime? _startedAt;
  int _beat = 0;
  VoidCallback? _onTick;

  bool get isRunning => _bpm != null;

  Future<void> start(int bpm, {VoidCallback? onTick}) async {
    await stop();
    _bpm = bpm;
    _onTick = onTick;
    await _ensureClick();
    _startedAt = DateTime.now();
    _beat = 0;
    _click();
    _beat = 1;
    _scheduleNext();
  }

  Future<void> _ensureClick() async {
    if (_clickReady) return;
    final path = await _buildClickWav();
    _clickPath = path;
    // 사전 로딩 — play() 호출 시점 latency 감소.
    try {
      await _p.setReleaseMode(ReleaseMode.release);
      await _p.setVolume(0.9);
    } catch (_) {}
    _clickReady = true;
  }

  void _click() {
    _onTick?.call();
    final path = _clickPath;
    if (path == null) return;
    // ignore: discarded_futures
    _p.play(DeviceFileSource(path), volume: 0.9);
  }

  void _scheduleNext() {
    final bpm = _bpm;
    final start = _startedAt;
    if (bpm == null || start == null) return;
    final periodMs = 60000.0 / bpm;
    final targetAt = start.add(Duration(microseconds: (_beat * periodMs * 1000).round()));
    final waitMs = targetAt.difference(DateTime.now()).inMicroseconds / 1000;
    final wait = waitMs > 0 ? Duration(microseconds: (waitMs * 1000).round()) : Duration.zero;
    _timer = Timer(wait, () {
      if (_bpm == null) return;
      _click();
      _beat++;
      _scheduleNext();
    });
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _bpm = null;
    _onTick = null;
    _startedAt = null;
    _beat = 0;
    try {
      await _p.stop();
    } catch (_) {}
  }

  void dispose() {
    _timer?.cancel();
    _p.dispose();
  }

  /// 1kHz sine click + 빠른 감쇠 — 원래의 "맑은 톡" 사운드.
  Future<String> _buildClickWav() async {
    const sr = 22050;
    const clickMs = 14;
    final n = (sr * clickMs / 1000).round();
    final pcm = Int16List(n);
    for (int i = 0; i < n; i++) {
      final env = math.exp(-5.0 * i / n);
      final s = math.sin(2 * math.pi * 1000 * i / sr) * env * 0.8;
      pcm[i] = (s * 32767).round().clamp(-32768, 32767);
    }
    final bytes = _wrapWav(pcm, sr);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/metro_click.wav');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Uint8List _wrapWav(Int16List pcm, int sr) {
    final dataLen = pcm.lengthInBytes;
    final b = BytesBuilder();
    void s(String x) => b.add(x.codeUnits);
    void u32(int v) => b.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
    void u16(int v) => b.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));
    s('RIFF'); u32(36 + dataLen); s('WAVE');
    s('fmt '); u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16);
    s('data'); u32(dataLen);
    b.add(pcm.buffer.asUint8List(0, dataLen));
    return b.toBytes();
  }
}
