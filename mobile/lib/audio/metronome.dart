// 메트로놈 — BPM 한 박자 길이의 클릭 WAV를 만들어 루프 재생.
// 별도 플레이어라 반주/믹스와 독립적으로 켜고 끌 수 있다.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class Metronome {
  final AudioPlayer _p = AudioPlayer();
  int? _builtBpm;
  String? _path;

  Future<void> start(int bpm) async {
    final path = await _buildClick(bpm);
    await _p.stop();
    await _p.setReleaseMode(ReleaseMode.loop); // 한 박자 클릭을 무한 반복
    await _p.setVolume(0.9);
    await _p.play(DeviceFileSource(path), volume: 0.9);
  }

  Future<void> stop() => _p.stop();
  void dispose() => _p.dispose();

  /// 한 박자(60/bpm초) 길이의 모노 PCM16 WAV: 앞부분 1kHz 짧은 클릭 + 나머지 무음.
  Future<String> _buildClick(int bpm) async {
    if (_builtBpm == bpm && _path != null) return _path!;
    const sr = 22050;
    final samples = (sr * 60 / bpm).round();
    final pcm = Int16List(samples);
    const clickMs = 14;
    final clickN = (sr * clickMs / 1000).round();
    for (int i = 0; i < clickN && i < samples; i++) {
      final env = math.exp(-5.0 * i / clickN); // 빠른 감쇠
      final s = math.sin(2 * math.pi * 1000 * i / sr) * env * 0.8;
      pcm[i] = (s * 32767).round().clamp(-32768, 32767);
    }
    final bytes = _wrapWav(pcm, sr);
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/metro_$bpm.wav');
    await f.writeAsBytes(bytes, flush: true);
    _builtBpm = bpm;
    _path = f.path;
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
