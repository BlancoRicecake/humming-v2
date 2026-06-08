// SoundLab 엔진(FastAPI, Humming V2/backend) 호출 클라이언트.
// 개발 중에는 로컬 dev 머신(LAN)에 연결. 실기기는 --dart-define 로 URL 주입:
//   flutter run --dart-define=ENGINE_URL=http://192.168.0.x:8000
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/models.dart';

class EngineConfig {
  // 운영 도메인 기본값 (api.hum-track.com, 배포 라이브). 릴리스 빌드는 override 없이
  // 이 기본값을 그대로 사용. 로컬 dev 빌드만 LAN IP 로 override:
  //   flutter run --dart-define=ENGINE_URL=http://192.168.0.x:8000
  static const baseUrl = String.fromEnvironment(
    'ENGINE_URL',
    defaultValue: 'https://api.hum-track.com',
  );
}

class AssistResult {
  AssistResult(this.notes, this.detectedKey, this.assistAppliedCount, this.keyCandidates);
  final List<Note> notes;
  final DetectedKey? detectedKey;
  final int assistAppliedCount;
  final List<KeyCandidate> keyCandidates;
}

class EngineApi {
  EngineApi({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? EngineConfig.baseUrl,
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 90),
        )) {
    debugPrint('[engine] baseUrl=${_dio.options.baseUrl}');
    _dio.interceptors.add(LogInterceptor(
      request: true, requestHeader: false, requestBody: false,
      responseHeader: false, responseBody: false, error: true,
      logPrint: (o) => debugPrint('[dio] $o'),
    ));
  }
  final Dio _dio;

  /// 외부 서비스(IapService.configureVerify 등) 가 같은 백엔드를 공유할 때 사용.
  Dio get dio => _dio;

  Future<bool> health() async {
    try {
      final r = await _dio.get('/health');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 녹음 파일 경로 → 분석 결과(notes, 추천 key, 보정 개수 …).
  /// 컨테이너는 Opus(.caf/.ogg) 또는 AAC(.m4a). 서버 ffmpeg pipe 가 magic bytes 로 판별 — filename 무시.
  Future<AnalyzeResponse> analyze(String wavPath, AnalyzeOptions options) async {
    final form = FormData.fromMap({
      'audio': await MultipartFile.fromFile(wavPath, filename: 'input.opus'),
      'options': jsonEncode(options.toJson()),
    });
    final r = await _dio.post<Map<String, dynamic>>('/analyze', data: form);
    return AnalyzeResponse.fromJson(r.data!);
  }

  /// 보컬 — 악기 변환 없이 목소리 그대로. 가벼운 정리된 WAV bytes + 표시용 파형 peaks + 길이.
  /// 입력 컨테이너는 Opus(.caf/.ogg)/AAC(.m4a). 서버는 magic bytes 로 판별.
  Future<({Uint8List wav, List<double> peaks, double duration})> processVocal(String wavPath) async {
    final form = FormData.fromMap({
      'audio': await MultipartFile.fromFile(wavPath, filename: 'vocal.opus'),
      'denoise': '1',
    });
    final r = await _dio.post<Map<String, dynamic>>('/process_vocal', data: form);
    final j = r.data!;
    return (
      wav: base64Decode(j['audio_b64'] as String),
      peaks: ((j['peaks'] ?? []) as List).map((e) => (e as num).toDouble()).toList(),
      duration: (j['duration'] as num?)?.toDouble() ?? 0,
    );
  }

  /// 이미 분석된 notes 에 키/어시스턴트만 빠르게 재적용 (pYIN 재실행 없음).
  Future<AssistResult> assist(List<Note> notes, AnalyzeOptions options) async {
    final r = await _dio.post<Map<String, dynamic>>('/assist', data: {
      'notes': notes.map((n) => n.toJson()).toList(),
      'options': options.toJson(),
    });
    final j = r.data!;
    return AssistResult(
      ((j['notes'] ?? []) as List).map((e) => Note.fromJson(e as Map<String, dynamic>)).toList(),
      j['detected_key'] == null ? null : DetectedKey.fromJson(j['detected_key'] as Map<String, dynamic>),
      (j['assist_applied_count'] as num?)?.toInt() ?? 0,
      ((j['key_candidates'] ?? []) as List).map((e) => KeyCandidate.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  /// 단음 미리듣기용 — pitch 1개를 짧은 길이(기본 0.5s)로 렌더해 WAV bytes 반환.
  /// @deprecated 6-3 이후 온디바이스 합성(`SynthEngine`)으로 대체됨. 호환을 위해 잠시 유지.
  @Deprecated('Use SynthEngine().playNote — backend round-trip removed in task 6-3')
  Future<Uint8List> previewNote(int pitch, {int program = 0, double duration = 0.5, int velocity = 100}) async {
    final note = Note(
      start: 0,
      end: duration,
      duration: duration,
      pitch: pitch,
      pitchRaw: pitch.toDouble(),
      pitchHz: 0, // 백엔드는 pitch(MIDI) 로 합성. Hz 는 미리듣기 페이로드에 불필요.
      velocity: velocity,
      confidence: 1.0,
      voicedRatio: 1.0,
      kind: 'pitched',
      pitchOriginal: pitch,
      assisted: false,
      candidates: const [],
      source: 'user',
      inKey: true,
      correctionCents: 0,
    );
    return renderAudio([note], program: program);
  }

  /// notes → SoundFont 렌더 WAV bytes (program = GM 악기 번호).
  ///
  /// 역할: **Task 6-6 (2026-05-31) 기준 일상 재생 경로에서 호출되지 않음**.
  /// 단음 미리듣기·트랙 재생은 모두 온디바이스 `SynthEngine` / `SynthPlayer` 가
  /// 처리하며 (커밋 `6de9bec`), 모바일 코드에서 살아있는 호출처는 사실상
  /// 없음 (`previewNote` 가 호환 보조용으로만 호출). 호환 + 회귀 검증용으로
  /// 보존하나 신규 호출처 금지.
  @Deprecated('On-device SynthEngine replaces /render_audio playback (task 6-6). '
      'Kept for backward-compat only — do not add new call sites.')
  Future<Uint8List> renderAudio(List<Note> notes, {int program = 0}) async {
    final r = await _dio.post<List<int>>(
      '/render_audio',
      data: {'notes': notes.map((n) => n.toJson()).toList(), 'program': program},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data!);
  }

  /// 여러 트랙을 하나로 믹스 렌더 → WAV bytes.
  ///
  /// 역할: **Task 6-6 (2026-05-31) 기준 WAV export(공유) 전용**.
  /// 모바일 재생(▶, 인라인 녹음 모니터링)은 `SynthPlayer` 로 온디바이스 합성
  /// (커밋 `6de9bec`). 현재 살아있는 호출처는 `ProjectStore.exportMixWav()`
  /// → `sheets.dart` 의 `_exportFile(midi: false)` 뿐.
  /// 향후 export 도 온디바이스 PCM bounce 로 옮기면 deprecate 가능.
  Future<Uint8List> renderMix(List<({List<Note> notes, int program})> tracks) async {
    final r = await _dio.post<List<int>>(
      '/render_mix',
      data: {
        'tracks': tracks
            .map((t) => {'notes': t.notes.map((n) => n.toJson()).toList(), 'program': t.program})
            .toList(),
      },
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data!);
  }

  /// notes → .mid bytes (단일 트랙).
  Future<Uint8List> exportMidi(List<Note> notes, {int program = 0, double tempoBpm = 120}) async {
    final r = await _dio.post<List<int>>(
      '/export_midi',
      data: {'notes': notes.map((n) => n.toJson()).toList(), 'program': program, 'tempo_bpm': tempoBpm},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data!);
  }

  /// 여러 트랙을 한 .mid 로 export — 각 트랙이 별도 MidiTrack + channel.
  Future<Uint8List> exportMidiMix(
    List<({List<Note> notes, int program, int channel})> tracks, {
    double tempoBpm = 120,
  }) async {
    final r = await _dio.post<List<int>>(
      '/export_midi',
      data: {
        'tempo_bpm': tempoBpm,
        'tracks': tracks
            .map((t) => {
                  'notes': t.notes.map((n) => n.toJson()).toList(),
                  'program': t.program,
                  'channel': t.channel,
                })
            .toList(),
      },
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data!);
  }
}
