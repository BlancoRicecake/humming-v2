// Cloud Sync HTTP client — api.hum-track.com 의 /projects + /storage endpoints.
//
// Phase 1 백엔드 (2026-06-04 배포) 와 통신:
//   - GET    /projects               → 클라우드 작업물 목록
//   - GET    /projects/{id}          → 상세(meta 포함)
//   - POST   /projects               → upsert (412/409 분기)
//   - DELETE /projects/{id}          → 클라우드에서 삭제
//   - POST   /storage/presign        → R2 PUT presigned URL
//   - GET    /storage/usage          → 사용량
//   - POST   /storage/quota_check    → 사전 검증
//
// 인증: Supabase access token 을 매 호출 직전에 `AuthService.currentAccessToken()`
// 로 재조회 → `Authorization: Bearer ...`. 익명/만료 세션은 모든 메서드가
// `UnauthorizedException` throw.
//
// 에러는 도메인 예외로 wrap — UI 가 분기:
//   401 → UnauthorizedException
//   409 → ConflictException (cloudVersion 포함)
//   412 → QuotaExceededException (used / quota / deficit)
//   network/timeout → NetworkException
//   기타 5xx/4xx → CloudApiException

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/engine_api.dart';
import 'auth_service.dart';

// ─── Domain exceptions ────────────────────────────────────────────────────
class CloudApiException implements Exception {
  CloudApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => 'CloudApiException(${statusCode ?? '-'}): $message';
}

class UnauthorizedException extends CloudApiException {
  UnauthorizedException([super.message = 'unauthorized']) : super(statusCode: 401);
}

class NetworkException extends CloudApiException {
  NetworkException([super.message = 'network unavailable']);
}

class ConflictException extends CloudApiException {
  ConflictException({required this.projectId, required this.cloudVersion})
      : super('conflict', statusCode: 409);
  final String projectId;
  /// {title, size_bytes, updated_at} — 백엔드 응답 그대로.
  final Map<String, dynamic> cloudVersion;
}

class QuotaExceededException extends CloudApiException {
  QuotaExceededException({required this.used, required this.quota, required this.deficit})
      : super('quota_exceeded', statusCode: 412);
  final int used;
  final int quota;
  final int deficit;
}

// ─── Response models ──────────────────────────────────────────────────────
class CloudProject {
  CloudProject({
    required this.projectId,
    required this.title,
    required this.sizeBytes,
    required this.uploadedAt,
    required this.updatedAt,
    this.meta,
  });
  final String projectId;
  final String title;
  final int sizeBytes;
  final DateTime uploadedAt;
  final DateTime updatedAt;
  /// `?include=meta` 또는 `getProject(id)` 시에만 채워짐.
  final Map<String, dynamic>? meta;

  static CloudProject fromJson(Map<String, dynamic> j) => CloudProject(
        projectId: j['project_id'] as String,
        title: (j['title'] ?? '') as String,
        sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
        uploadedAt: _parseDt(j['uploaded_at']) ?? DateTime.now(),
        updatedAt: _parseDt(j['updated_at']) ?? DateTime.now(),
        meta: j['meta'] is Map<String, dynamic> ? j['meta'] as Map<String, dynamic> : null,
      );
}

class UpsertResult {
  UpsertResult({required this.projectId, required this.usedBytes, required this.quotaBytes});
  final String projectId;
  final int usedBytes;
  final int quotaBytes;
}

class PresignResult {
  PresignResult({
    required this.url,
    required this.headers,
    required this.key,
    this.publicUrl,
    required this.expiresAt,
  });
  final String url;
  final Map<String, String> headers;
  final String key;
  final String? publicUrl;
  final DateTime expiresAt;

  static PresignResult fromJson(Map<String, dynamic> j) => PresignResult(
        url: j['url'] as String,
        headers: ((j['headers'] ?? {}) as Map).map((k, v) => MapEntry('$k', '$v')),
        key: (j['key'] ?? '') as String,
        publicUrl: j['public_url'] as String?,
        expiresAt: _parseDt(j['expires_at']) ?? DateTime.now().add(const Duration(minutes: 5)),
      );
}

class Usage {
  Usage({required this.usedBytes, required this.quotaBytes});
  final int usedBytes;
  final int quotaBytes;
}

class QuotaCheck {
  QuotaCheck({required this.allowed, required this.used, required this.quota, required this.deficit});
  final bool allowed;
  final int used;
  final int quota;
  final int deficit;
}

DateTime? _parseDt(dynamic v) {
  if (v == null) return null;
  if (v is DateTime) return v;
  try {
    return DateTime.parse(v.toString());
  } catch (_) {
    return null;
  }
}

// ─── Client ───────────────────────────────────────────────────────────────
class CloudApi {
  CloudApi._() : _dio = Dio(BaseOptions(
          baseUrl: EngineConfig.baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 60),
          // 4xx/5xx 도 응답으로 받아 직접 분기 → 깔끔한 예외 매핑.
          validateStatus: (_) => true,
        )) {
    debugPrint('[cloud-api] baseUrl=${_dio.options.baseUrl}');
  }

  static final CloudApi instance = CloudApi._();
  final Dio _dio;

  /// R2 직접 PUT 전용 — Authorization 헤더 없음. presigned URL 의 서명이 인증을 대신.
  final Dio _r2 = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    sendTimeout: const Duration(minutes: 5),
    receiveTimeout: const Duration(minutes: 5),
    validateStatus: (_) => true,
  ));

  Future<Map<String, String>> _authHeaders() async {
    final token = await AuthService.instance.currentAccessToken();
    if (token == null || token.isEmpty) {
      throw UnauthorizedException('Supabase 세션 없음 — 로그인 필요');
    }
    return {'Authorization': 'Bearer $token'};
  }

  Never _throwFor(Response res, String tag) {
    final code = res.statusCode ?? 0;
    final detail = res.data is Map ? (res.data as Map)['detail'] : res.data;
    debugPrint('[cloud-api] $tag status=$code detail=$detail');
    if (code == 401 || code == 403) {
      throw UnauthorizedException('인증 실패 ($code)');
    }
    if (code == 412 && detail is Map && detail['error'] == 'quota_exceeded') {
      throw QuotaExceededException(
        used: (detail['used'] as num?)?.toInt() ?? 0,
        quota: (detail['quota'] as num?)?.toInt() ?? 0,
        deficit: (detail['deficit'] as num?)?.toInt() ?? 0,
      );
    }
    if (code == 409 && detail is Map && detail['error'] == 'conflict') {
      throw ConflictException(
        projectId: (detail['project_id'] ?? '') as String,
        cloudVersion: (detail['cloud_version'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
    }
    throw CloudApiException('$tag failed: $detail', statusCode: code);
  }

  Future<T> _wrapNetwork<T>(Future<T> Function() body, String tag) async {
    try {
      return await body();
    } on DioException catch (e) {
      debugPrint('[cloud-api] $tag dio error: ${e.type} ${e.message}');
      throw NetworkException('네트워크 오류 ($tag): ${e.message}');
    } on CloudApiException {
      rethrow;
    } catch (e) {
      throw CloudApiException('$tag unexpected: $e');
    }
  }

  // ── /projects ───────────────────────────────────────────────────────────
  Future<List<CloudProject>> listProjects({bool includeMeta = false}) =>
      _wrapNetwork(() async {
        final headers = await _authHeaders();
        final res = await _dio.get<dynamic>(
          '/projects',
          queryParameters: includeMeta ? {'include': 'meta'} : null,
          options: Options(headers: headers),
        );
        if (res.statusCode != 200) _throwFor(res, 'listProjects');
        final list = (res.data as List).cast<Map<String, dynamic>>();
        return list.map(CloudProject.fromJson).toList();
      }, 'listProjects');

  Future<CloudProject> getProject(String id) => _wrapNetwork(() async {
        final headers = await _authHeaders();
        final res = await _dio.get<dynamic>(
          '/projects/$id',
          options: Options(headers: headers),
        );
        if (res.statusCode != 200) _throwFor(res, 'getProject');
        return CloudProject.fromJson((res.data as Map).cast<String, dynamic>());
      }, 'getProject');

  Future<UpsertResult> upsertProject({
    required String projectId,
    required String title,
    required Map<String, dynamic> meta,
    required int sizeBytes,
    DateTime? expectedUpdatedAt,
  }) =>
      _wrapNetwork(() async {
        final headers = await _authHeaders();
        final body = <String, dynamic>{
          'project_id': projectId,
          'title': title,
          'meta': meta,
          'size_bytes': sizeBytes,
          if (expectedUpdatedAt != null)
            'expected_updated_at': expectedUpdatedAt.toUtc().toIso8601String(),
        };
        final res = await _dio.post<dynamic>(
          '/projects',
          data: body,
          options: Options(headers: headers),
        );
        if (res.statusCode != 200) _throwFor(res, 'upsertProject');
        final j = (res.data as Map).cast<String, dynamic>();
        return UpsertResult(
          projectId: (j['project_id'] ?? projectId) as String,
          usedBytes: (j['used_bytes'] as num?)?.toInt() ?? 0,
          quotaBytes: (j['quota_bytes'] as num?)?.toInt() ?? 0,
        );
      }, 'upsertProject');

  Future<void> deleteProject(String id) => _wrapNetwork(() async {
        final headers = await _authHeaders();
        final res = await _dio.delete<dynamic>(
          '/projects/$id',
          options: Options(headers: headers),
        );
        if (res.statusCode != 204 && res.statusCode != 200) {
          _throwFor(res, 'deleteProject');
        }
      }, 'deleteProject');

  // ── /storage ────────────────────────────────────────────────────────────
  Future<PresignResult> presignUpload({
    required String projectId,
    required String fileName,
    required String contentType,
  }) =>
      _wrapNetwork(() async {
        final headers = await _authHeaders();
        final res = await _dio.post<dynamic>(
          '/storage/presign',
          data: {
            'project_id': projectId,
            'file_name': fileName,
            'content_type': contentType,
          },
          options: Options(headers: headers),
        );
        if (res.statusCode != 200) _throwFor(res, 'presignUpload');
        return PresignResult.fromJson((res.data as Map).cast<String, dynamic>());
      }, 'presignUpload');

  Future<Usage> getUsage() => _wrapNetwork(() async {
        final headers = await _authHeaders();
        final res = await _dio.get<dynamic>(
          '/storage/usage',
          options: Options(headers: headers),
        );
        if (res.statusCode != 200) _throwFor(res, 'getUsage');
        final j = (res.data as Map).cast<String, dynamic>();
        return Usage(
          usedBytes: (j['used_bytes'] as num?)?.toInt() ?? 0,
          quotaBytes: (j['quota_bytes'] as num?)?.toInt() ?? 0,
        );
      }, 'getUsage');

  Future<QuotaCheck> quotaCheck(int size) => _wrapNetwork(() async {
        final headers = await _authHeaders();
        final res = await _dio.post<dynamic>(
          '/storage/quota_check',
          data: {'size': size},
          options: Options(headers: headers),
        );
        if (res.statusCode != 200) _throwFor(res, 'quotaCheck');
        final j = (res.data as Map).cast<String, dynamic>();
        return QuotaCheck(
          allowed: (j['allowed'] ?? false) as bool,
          used: (j['used'] as num?)?.toInt() ?? 0,
          quota: (j['quota'] as num?)?.toInt() ?? 0,
          deficit: (j['deficit'] as num?)?.toInt() ?? 0,
        );
      }, 'quotaCheck');

  // ── R2 직접 PUT / GET ───────────────────────────────────────────────────
  /// Presigned URL 로 파일 바이트 PUT. progress 콜백은 0..1 누적.
  Future<void> putToR2({
    required PresignResult presign,
    required List<int> bytes,
    void Function(double)? onProgress,
  }) =>
      _wrapNetwork(() async {
        final res = await _r2.put<dynamic>(
          presign.url,
          data: Stream.fromIterable([bytes]),
          options: Options(
            headers: {
              ...presign.headers,
              Headers.contentLengthHeader: bytes.length,
            },
            // R2 는 200/204 모두 가능 (S3 호환).
            followRedirects: false,
          ),
          onSendProgress: (sent, total) {
            if (total > 0 && onProgress != null) {
              onProgress((sent / total).clamp(0.0, 1.0));
            }
          },
        );
        final code = res.statusCode ?? 0;
        if (code < 200 || code >= 300) {
          throw CloudApiException('R2 PUT 실패 ($code)', statusCode: code);
        }
      }, 'putToR2');

  /// 공개 URL 로 GET. (백엔드 presigned-GET endpoint 가 없으므로 R2 bucket
  /// public read 또는 publicBaseUrl 설정 시에만 작동.)
  Future<List<int>> getFromUrl(String url, {void Function(double)? onProgress}) =>
      _wrapNetwork(() async {
        final res = await _r2.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
          onReceiveProgress: (got, total) {
            if (total > 0 && onProgress != null) {
              onProgress((got / total).clamp(0.0, 1.0));
            }
          },
        );
        final code = res.statusCode ?? 0;
        if (code < 200 || code >= 300 || res.data == null) {
          throw CloudApiException('R2 GET 실패 ($code)', statusCode: code);
        }
        return res.data!;
      }, 'getFromUrl');
}
