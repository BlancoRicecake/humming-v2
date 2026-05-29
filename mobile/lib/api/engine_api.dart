// SoundLab 엔진(FastAPI, Humming V2/backend) 호출 클라이언트.
// 개발 중에는 로컬 dev 머신(LAN)에 연결. 실기기는 --dart-define 로 URL 주입:
//   flutter run --dart-define=ENGINE_URL=http://192.168.0.x:8000
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/models.dart';

class EngineConfig {
  // Android 에뮬레이터의 호스트 루프백 기본값. 실기기는 LAN IP 로 override.
  static const baseUrl = String.fromEnvironment('ENGINE_URL', defaultValue: 'http://10.0.2.2:8000');
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

  Future<bool> health() async {
    try {
      final r = await _dio.get('/health');
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 녹음 WAV 파일 경로 → 분석 결과(notes, 추천 key, 보정 개수 …).
  Future<AnalyzeResponse> analyze(String wavPath, AnalyzeOptions options) async {
    final form = FormData.fromMap({
      'audio': await MultipartFile.fromFile(wavPath, filename: 'input.wav'),
      'options': jsonEncode(options.toJson()),
    });
    final r = await _dio.post<Map<String, dynamic>>('/analyze', data: form);
    return AnalyzeResponse.fromJson(r.data!);
  }

  /// 보컬 — 악기 변환 없이 목소리 그대로. 가벼운 정리된 WAV bytes + 표시용 파형 peaks + 길이.
  Future<({Uint8List wav, List<double> peaks, double duration})> processVocal(String wavPath) async {
    final form = FormData.fromMap({
      'audio': await MultipartFile.fromFile(wavPath, filename: 'vocal.wav'),
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

  /// notes → SoundFont 렌더 WAV bytes (program = GM 악기 번호).
  Future<Uint8List> renderAudio(List<Note> notes, {int program = 0}) async {
    final r = await _dio.post<List<int>>(
      '/render_audio',
      data: {'notes': notes.map((n) => n.toJson()).toList(), 'program': program},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data!);
  }

  /// 여러 트랙을 하나로 믹스 렌더 → WAV bytes.
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

  /// notes → .mid bytes.
  Future<Uint8List> exportMidi(List<Note> notes, {int program = 0, double tempoBpm = 120}) async {
    final r = await _dio.post<List<int>>(
      '/export_midi',
      data: {'notes': notes.map((n) => n.toJson()).toList(), 'program': program, 'tempo_bpm': tempoBpm},
      options: Options(responseType: ResponseType.bytes),
    );
    return Uint8List.fromList(r.data!);
  }
}
