// Analytics (PostHog) — MVP1 에서 posthog_flutter 제외 (#44 pending).
// 호출 API 는 유지(noop) — 후속 배치에서 PostHog 재도입 시 이 파일만 교체.
//
// 6 개 핵심 이벤트 시그니처 유지:
//   userSignedUp / recordingStarted / analyzeCompleted /
//   songExported / paywallViewed / subscriptionStarted
import 'package:flutter/foundation.dart';

class AnalyticsService {
  AnalyticsService._();
  static final AnalyticsService instance = AnalyticsService._();

  bool get enabled => false;

  Future<void> init() async {
    debugPrint('[analytics] posthog disabled in this build (MVP1 skip)');
  }

  Future<void> identify(String distinctId, {Map<String, Object>? props}) async {}
  Future<void> reset() async {}

  Future<void> _log(String event, [Map<String, Object>? props]) async {
    if (kDebugMode) debugPrint('[analytics-noop] $event $props');
  }

  Future<void> userSignedUp({required String provider, String? email}) =>
      _log('user_signed_up', {'provider': provider, if (email != null) 'email': email});

  Future<void> recordingStarted({required String role}) =>
      _log('recording_started', {'role': role});

  Future<void> analyzeCompleted({
    required String role,
    required int durationMs,
    required int noteCount,
  }) =>
      _log('analyze_completed', {
        'role': role,
        'duration_ms': durationMs,
        'note_count': noteCount,
      });

  Future<void> songExported({required String format}) =>
      _log('song_exported', {'format': format});

  Future<void> paywallViewed({required String trigger}) =>
      _log('paywall_viewed', {'trigger': trigger});

  Future<void> subscriptionStarted({required String productId, required String plan}) =>
      _log('subscription_started', {'product_id': productId, 'plan': plan});
}
