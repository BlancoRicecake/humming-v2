// 재생 — audioplayers. 재생/일시정지/재개 + 위치 스트림(플레이헤드용).
import 'dart:io';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';

class AudioPlayerService {
  final AudioPlayer _player = AudioPlayer(); // 메인(악기 믹스 또는 단독 소스) — 타이밍 기준
  final AudioPlayer _vocal = AudioPlayer(); // 보컬 레이어(목소리 그대로)
  int _tmpSeq = 0;

  AudioPlayerService() {
    // 녹음(마이크)이 시작돼도 반주 재생이 멈추지 않도록 오디오 포커스를 양보하지
    // 않게 설정(이어폰 끼고 흥얼거리며 녹음하는 동시작동의 핵심). iOS 는 재생+녹음
    // 동시 허용 카테고리.
    final ctx = AudioContext(
      android: const AudioContextAndroid(
        contentType: AndroidContentType.music,
        usageType: AndroidUsageType.media,
        audioFocus: AndroidAudioFocus.none,
      ),
      iOS: AudioContextIOS(
        category: AVAudioSessionCategory.playAndRecord,
        options: const {AVAudioSessionOptions.mixWithOthers, AVAudioSessionOptions.defaultToSpeaker},
      ),
    );
    _player.setAudioContext(ctx);
    _vocal.setAudioContext(ctx);
  }

  // 위치/완료는 항상 메인 플레이어 기준(보컬은 동기 추종).
  Stream<Duration> get onPosition => _player.onPositionChanged;
  Stream<void> get onComplete => _player.onPlayerComplete;
  PlayerState get state => _player.state;
  bool get isPlaying => _player.state == PlayerState.playing;
  bool get isPaused => _player.state == PlayerState.paused;

  Future<void> playFile(String path) async {
    await stop();
    await _player.setVolume(1.0);
    await _player.play(DeviceFileSource(path), volume: 1.0);
  }

  Future<void> playBytes(Uint8List bytes) async {
    final f = await _writeTemp(bytes);
    await playFile(f);
  }

  /// 악기 믹스(mixBytes)와 보컬(vocalPath)을 동시 재생. 둘 중 하나만 있어도 됨.
  /// 메인 플레이어가 타이밍 기준이라, 믹스가 있으면 메인=믹스/보조=보컬,
  /// 믹스가 없으면 메인=보컬(단독).
  Future<void> playLayered({Uint8List? mixBytes, String? vocalPath}) async {
    await stop();
    final mixPath = mixBytes != null ? await _writeTemp(mixBytes) : null;
    final futures = <Future<void>>[];
    if (mixPath != null) {
      futures.add(_player.play(DeviceFileSource(mixPath), volume: 1.0));
      if (vocalPath != null) futures.add(_vocal.play(DeviceFileSource(vocalPath), volume: 1.0));
    } else if (vocalPath != null) {
      futures.add(_player.play(DeviceFileSource(vocalPath), volume: 1.0));
    }
    await Future.wait(futures);
  }

  Future<String> _writeTemp(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/render_${_tmpSeq++}.wav');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<void> pause() async {
    await _player.pause();
    await _vocal.pause();
  }

  Future<void> resume() async {
    await _player.resume();
    await _vocal.resume();
  }

  Future<void> seek(Duration pos) async {
    await _player.seek(pos);
    await _vocal.seek(pos);
  }

  Future<void> stop() async {
    await _player.stop();
    await _vocal.stop();
  }

  void dispose() {
    _player.dispose();
    _vocal.dispose();
  }
}
