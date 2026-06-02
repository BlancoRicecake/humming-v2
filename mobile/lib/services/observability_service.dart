// Observability (Sentry) — Xcode 26 호환성 이슈로 **MVP1 에서 sentry_flutter 제외**.
// 호출 API 는 유지(noop) — 후속 배치에서 sentry 재도입 시 이 파일만 교체하면 됨.
//
// 사용처:
//   await ObservabilityService.instance.bootstrap(() async { runApp(...) });
//   ObservabilityService.instance.breadcrumb(category: ..., message: ...);
//   ObservabilityService.instance.captureException(e, stack);
import 'dart:async';

import 'package:flutter/foundation.dart';

class ObservabilityService {
  ObservabilityService._();
  static final ObservabilityService instance = ObservabilityService._();

  bool get enabled => false;

  /// Sentry 부트스트랩 자리 — 현재는 그대로 appRunner 호출.
  Future<void> bootstrap(FutureOr<void> Function() appRunner) async {
    debugPrint('[observability] sentry disabled in this build (Xcode 26 compat)');
    await appRunner();
  }

  void breadcrumb({
    required String category,
    required String message,
    String level = 'info',
    Map<String, dynamic>? data,
  }) {
    if (kDebugMode) {
      debugPrint('[breadcrumb] $category/$level $message ${data ?? ''}');
    }
  }

  Future<void> captureException(Object error, [StackTrace? stack]) async {
    debugPrint('[exception] $error\n$stack');
  }

  void setUser({String? id, String? email}) {}
  void clearUser() {}
}
