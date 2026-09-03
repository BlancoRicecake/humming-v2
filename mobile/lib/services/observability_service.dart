// Sentry 통합 (에러/크래시 추적 + 성능 트레이싱).
//
// dart-define SENTRY_DSN_MOBILE 미설정 시 비활성 — clarity_service 와 동일한
// graceful-degrade 패턴. 키가 없으면 bootstrap() 은 appRunner 를 그대로 실행하고
// 모든 헬퍼는 debugPrint 로만 남기므로 dev/CI/미설정 빌드에서 안전하다.
//
//   flutter run --dart-define=SENTRY_DSN_MOBILE=https://...ingest.../...
//
// DSN 은 Sentry 모바일(Flutter) 프로젝트의 Client Keys(DSN). 서버 프로젝트와
// 별개 DSN 이다. PII(이메일/IP)는 보내지 않고, 사용자 식별은 setUser(id) 로만.
//
// 결제/인증 경로(audit M8)는 try/catch 로 삼키는 실패가 많아 여기 헬퍼로
// 명시적으로 보고한다: captureException(tags/hint) + breadcrumb(data).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class ObservabilityService {
  ObservabilityService._();
  static final ObservabilityService instance = ObservabilityService._();

  static const _dsn = String.fromEnvironment('SENTRY_DSN_MOBILE');
  static const _environment = String.fromEnvironment(
    'SENTRY_ENVIRONMENT',
    defaultValue: kReleaseMode ? 'production' : 'debug',
  );

  /// DSN 이 주입됐을 때만 true.
  bool get enabled => _dsn.isNotEmpty;

  /// runApp 을 포함한 앱 실행 전체를 Sentry 의 에러 캡처 zone 으로 감싼다.
  /// 비활성 시 appRunner 를 그대로 실행 → 의존성/오버헤드 0. main() 의 본문을
  /// 이 콜백 안에 넣는다.
  Future<void> bootstrap(FutureOr<void> Function() appRunner) async {
    if (!enabled) {
      debugPrint('[sentry] SENTRY_DSN_MOBILE not set — crash reporting disabled');
      await appRunner();
      return;
    }
    debugPrint('[sentry] enabled (env $_environment)');
    await SentryFlutter.init(
      (options) {
        options.dsn = _dsn;
        options.environment = _environment;
        // 성능 트레이싱 10% 샘플링 (백엔드와 동일 비율).
        options.tracesSampleRate = 0.1;
        // PII(이메일·IP 등) 자동 수집 비활성 — 식별은 setUser(id) 로만.
        options.sendDefaultPii = false;
        options.debug = kDebugMode;
      },
      appRunner: appRunner,
    );
  }

  /// 로그인 사용자 식별 (Supabase user id — 불투명 UUID, PII 아님).
  /// 로그아웃 시 setUser(null) 로 스코프에서 제거.
  void setUser(String? userId) {
    if (!enabled) return;
    Sentry.configureScope((scope) {
      scope.setUser(userId == null ? null : SentryUser(id: userId));
    });
  }

  /// 수동 예외 캡처 (try/catch 에서 삼킨 에러를 명시적으로 보고).
  ///
  /// [tags] 는 Sentry 검색/그룹핑용 (store, product_id, http_status …). [hint]
  /// 는 사람이 읽는 한 줄 맥락 — 이벤트의 `hint` context 로 첨부된다. 값에
  /// PII(이메일, 영수증 원문)를 넣지 말 것.
  Future<void> captureException(
    Object e,
    StackTrace? st, {
    Map<String, String>? tags,
    String? hint,
  }) async {
    if (!enabled) {
      debugPrint('[sentry:off] ${hint ?? 'exception'}: $e'
          '${tags == null || tags.isEmpty ? '' : ' tags=$tags'}');
      return;
    }
    try {
      await Sentry.captureException(
        e,
        stackTrace: st,
        hint: hint == null ? null : Hint.withMap({'message': hint}),
        withScope: (scope) {
          tags?.forEach((k, v) => scope.setTag(k, v));
          if (hint != null) scope.setContexts('hint', {'message': hint});
        },
      );
    } catch (err) {
      // 리포팅 자체가 앱 흐름을 깨면 안 된다.
      debugPrint('[sentry] captureException failed: $err');
    }
  }

  /// 디버그 빵부스러기(이벤트 직전 맥락) — 이후 캡처되는 에러에 함께 첨부된다.
  void breadcrumb(String message, {Map<String, dynamic>? data, String? category}) {
    if (!enabled) {
      debugPrint('[sentry:off] breadcrumb ${category ?? ''} $message'
          '${data == null || data.isEmpty ? '' : ' $data'}');
      return;
    }
    unawaited(Sentry.addBreadcrumb(
      Breadcrumb(message: message, category: category, data: data),
    ));
  }
}
