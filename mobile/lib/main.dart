import 'dart:io' show Platform;
// HumTrack — app entrypoint. Landscape tap-to-make-beats DAW.
//
// The product lives in lib/looptap/ (the former "LoopTap" module, now HumTrack).
// The legacy portrait recording app was removed; this is the single entry:
// lock landscape, load persisted settings + language + auth/IAP, then run the app.
//
// Bootstrap 순서 (race 회피):
//   1. EngineApi 생성 + Bearer 인터셉터 + IapService.configureVerify — *IAP
//      init 이전* 에 끝내야 부팅 시 pending 영수증 replay 가 verify dio 없이
//      "accepting locally" 분기로 떨어지지 않는다.
//   2. LoopPrefs / LocaleService 로 사용자 분석 동의와 locale 을 복원.
//   3. ProductAnalytics 를 초기화한 뒤 AuthService / IapService 를 시작해,
//      부팅 중 복원되는 로그인·pending 결제 이벤트도 놓치지 않는다.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/engine_api.dart';
import 'looptap/app.dart';
import 'looptap/state/loop_prefs.dart';
import 'services/auth_service.dart';
import 'services/firebase_product_analytics_sink.dart';
import 'services/iap_service.dart';
import 'services/locale_service.dart';
import 'services/observability_service.dart';
import 'services/product_analytics.dart';

/// 앱 전역 EngineApi 인스턴스 — IapService verify + 향후 다른 backend 호출 공용.
late final EngineApi engineApi;

Future<void> main() async {
  // 앱 실행 전체를 Sentry 의 에러 캡처 zone 으로 감싼다 (SENTRY_DSN_MOBILE 미설정
  // 시 아래 본문을 그대로 실행 — graceful-degrade). lib/services/observability_service.dart.
  await ObservabilityService.instance.bootstrap(() async {
    WidgetsFlutterBinding.ensureInitialized();
    if (Platform.isAndroid || Platform.isIOS) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    // EngineApi + Bearer 인터셉터 + IAP verify dio 주입 — IapService.init 이전에.
    engineApi = EngineApi();
    engineApi.dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final token = await AuthService.instance.currentAccessToken();
          if (token != null && token.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $token';
            debugPrint(
              '[auth-interceptor] attached token (${token.length} chars) to ${options.uri.path}',
            );
          } else {
            debugPrint(
              '[auth-interceptor] NO token available for ${options.uri.path}',
            );
          }
          handler.next(options);
        },
      ),
    );
    IapService.instance.configureVerify(engineApi.dio);

    await Future.wait([
      LoopPrefs.instance.bootstrap(),
      LocaleService.instance.bootstrap(),
    ]);
    ProductAnalytics.instance.installSinks([
      ClarityProductAnalyticsSink(),
      FirebaseProductAnalyticsSink(),
    ]);
    await ProductAnalytics.instance.bootstrap(
      enabled: LoopPrefs.instance.analyticsEnabled.value,
      locale: LocaleService.instance.selected.value?.toLanguageTag(),
    );
    LoopPrefs.instance.analyticsEnabled.addListener(() {
      ProductAnalytics.instance.setConsent(
        LoopPrefs.instance.analyticsEnabled.value,
      );
    });
    LocaleService.instance.selected.addListener(() {
      ProductAnalytics.instance.setLocale(
        LocaleService.instance.selected.value?.toLanguageTag() ?? 'system',
      );
    });
    // 로그인 사용자를 분석 세션에 opaque id 로 태깅한다. 리스너를 auth bootstrap
    // 전에 연결해야 cold-start 캐시 세션도 받을 수 있다.
    String? lastAnalyticsUid;
    AuthService.instance.onSession.listen((s) {
      final uid = s.userId;
      // Sentry: 세션 변화마다 사용자 식별(id 만). 로그아웃이면 null 로 제거.
      ObservabilityService.instance.setUser(uid);
      ProductAnalytics.instance.setUserId(uid);
      if (uid == null) return;
      if (uid != lastAnalyticsUid) {
        lastAnalyticsUid = uid;
        ProductAnalytics.instance.track(
          ProductEvent.signedIn,
          properties: {'auth_provider': s.provider ?? 'unknown'},
        );
      }
    });

    await Future.wait([
      AuthService.instance.bootstrap(),
      // init 직후 loadProducts() 까지 묶어서 호출 — paywall 진입 시 스토어 가격
      // (ProductDetails.price) 이 즉시 표시되도록 (KRW 폴백 노출 회피).
      IapService.instance.init().then(
        (_) => IapService.instance.loadProducts(),
      ),
    ]);

    // Clarity 세션 리플레이/히트맵으로 루트를 감싼다 (CLARITY_PROJECT_ID 미설정
    // 시 앱을 그대로 반환 — graceful-degrade). lib/services/clarity_service.dart.
    runApp(ProductAnalytics.instance.wrapSessionReplay(const LoopTapApp()));
  });
}
