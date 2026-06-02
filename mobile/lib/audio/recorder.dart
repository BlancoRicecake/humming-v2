// 마이크 녹음 — **Opus 16kHz mono 64kbps** 가 기본, 미지원 OS 는 AAC LC 폴백.
//
// 배경: 원본을 WAV(PCM16 22.05kHz) 로 보내면 업로드 1MB/min·서버 리샘플 비용 발생.
// `docs/opus-integration-plan.md` 권고대로 16kHz mono Opus 64kbps 로 인코딩하면
// 업로드 1/10, 보컬 80–800Hz fundamentals + 9~10차 배음(<8kHz) 전 영역 보존,
// pYIN fmax=1000Hz 범위와 충돌 없음. 백엔드는 ffmpeg 로 디코드+리샘플 일관 처리.
//
// 마이크 DSP(AGC/노이즈서프레션/에코캔슬)는 모두 OFF — 이 처리들이 허밍의 배음을
// 뭉개 pYIN 음정 인식을 떨어뜨리므로 절대 켜지 말 것.
import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import '../services/observability_service.dart';

class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();

  /// 마지막 start() 가 실제로 사용한 인코더. iOS 15 / Android API 29 미만 등
  /// Opus 미지원 환경에서 폴백되었는지 호출자에게 노출.
  AudioEncoder? lastUsedEncoder;

  Future<bool> hasPermission() => _rec.hasPermission();

  /// Opus 16kHz mono 64kbps 로 녹음 시작. OS 가 Opus 미지원이면 AAC LC 폴백.
  Future<void> start(String filePath) async {
    AudioEncoder encoder = AudioEncoder.opus;
    bool opusOk = false;
    try {
      opusOk = await _rec.isEncoderSupported(AudioEncoder.opus);
    } catch (_) {
      opusOk = false;
    }
    if (!opusOk) {
      encoder = AudioEncoder.aacLc;
      // ignore: avoid_print
      debugPrint('[recorder] Opus unsupported — falling back to AAC LC');
      ObservabilityService.instance.breadcrumb(
        category: 'recorder',
        message: 'opus_unsupported_fallback_to_aac',
        level: 'warning',
      );
    }
    lastUsedEncoder = encoder;
    await _rec.start(
      RecordConfig(
        encoder: encoder,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 64000,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
      path: filePath,
    );
  }

  /// 정지 후 저장된 파일 경로 반환.
  /// 컨테이너(record 6.2.1):
  ///   • Opus  → iOS=CAF(.caf), Android=Ogg(.ogg)
  ///   • AAC LC → iOS/Android 모두 .m4a (Opus 미지원 단말 폴백)
  /// 호출자는 `audio/container.dart` 의 `audioContainerExt()` 로 경로 확장자를 정해
  /// 넘기되, 실제 디스크에 존재하는 파일은 `findExistingByExt` 로 fallback 탐색하는 게 안전.
  /// 백엔드 ffmpeg pipe 는 magic bytes 기반이라 filename 확장자 무시.
  Future<String?> stop() => _rec.stop();

  Future<bool> isRecording() => _rec.isRecording();

  Stream<Amplitude> amplitude() =>
      _rec.onAmplitudeChanged(const Duration(milliseconds: 100));

  Future<void> dispose() => _rec.dispose();
}
