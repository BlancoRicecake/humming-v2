// 마이크 녹음 — 오리지널 레코딩은 **무조건 WAV** (PCM16, mono 22.05kHz).
// 하드 규칙: 원본은 항상 WAV. 백엔드 SR(22050)과 일치시켜 재샘플 없이 분석.
import 'package:record/record.dart';

class VoiceRecorder {
  final AudioRecorder _rec = AudioRecorder();

  Future<bool> hasPermission() => _rec.hasPermission();

  /// WAV 로 녹음 시작. encoder 는 절대 변경 금지(원본=WAV 규칙).
  /// 피치 인식을 위해 마이크 DSP(AGC/노이즈서프레션/에코캔슬)는 모두 OFF —
  /// 이 처리들이 허밍의 배음을 뭉개 pYIN 음정 인식을 떨어뜨림.
  Future<void> start(String filePath) async {
    await _rec.start(
      const RecordConfig(
        encoder: AudioEncoder.wav, // ← 원본 무조건 WAV
        sampleRate: 22050,
        numChannels: 1,
        autoGain: false,
        echoCancel: false,
        noiseSuppress: false,
      ),
      path: filePath,
    );
  }

  /// 정지 후 저장된 WAV 경로 반환.
  Future<String?> stop() => _rec.stop();

  Future<bool> isRecording() => _rec.isRecording();

  Stream<Amplitude> amplitude() =>
      _rec.onAmplitudeChanged(const Duration(milliseconds: 100));

  Future<void> dispose() => _rec.dispose();
}
