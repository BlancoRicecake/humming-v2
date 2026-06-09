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
//   2. AuthService.bootstrap / IapService.init(+loadProducts) / LoopPrefs /
//      LocaleService 병렬 — 서로 의존성 없음.
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api/engine_api.dart';
import 'looptap/app.dart';
import 'looptap/state/loop_prefs.dart';
import 'services/auth_service.dart';
import 'services/iap_service.dart';
import 'services/locale_service.dart';

/// 앱 전역 EngineApi 인스턴스 — IapService verify + 향후 다른 backend 호출 공용.
late final EngineApi engineApi;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // EngineApi + Bearer 인터셉터 + IAP verify dio 주입 — IapService.init 이전에.
  engineApi = EngineApi();
  engineApi.dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await AuthService.instance.currentAccessToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
        debugPrint('[auth-interceptor] attached token (${token.length} chars) to ${options.uri.path}');
      } else {
        debugPrint('[auth-interceptor] NO token available for ${options.uri.path}');
      }
      handler.next(options);
    },
  ));
  IapService.instance.configureVerify(engineApi.dio);

  await Future.wait([
    LoopPrefs.instance.bootstrap(),
    LocaleService.instance.bootstrap(),
    AuthService.instance.bootstrap(),
    // init 직후 loadProducts() 까지 묶어서 호출 — paywall 진입 시 스토어 가격
    // (ProductDetails.price) 이 즉시 표시되도록 (KRW 폴백 노출 회피).
    IapService.instance.init().then((_) => IapService.instance.loadProducts()),
  ]);
  runApp(const LoopTapApp());
}
