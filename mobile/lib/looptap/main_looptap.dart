// LoopTap dev entrypoint — run with:
//   flutter run -t lib/looptap/main_looptap.dart
// Locks the app to landscape (README: "landscape mobile DAW") and launches the
// new UI in isolation from the legacy app. Final switchover repoints main.dart.
//
// Bootstrap 순서 (graceful-degrade — 키 미설정 시 해당 서비스만 비활성):
//   1. Supabase (SUPABASE_URL/SUPABASE_ANON_KEY) — Apple/Google 글로벌 로그인
//   2. IAP — humtrack_pro_monthly_v2 / yearly 구독
//      ※ `configureVerify` 를 `init()` *이전* 에 호출해야 함. init 이 부착하는
//      purchaseStream 리스너가 StoreKit 의 pending 영수증을 즉시 replay 하는데,
//      이 시점에 verify dio 가 비어있으면 `_verifyOnServer` 가 "accepting
//      locally" 분기로 떨어져 영수증을 소진해 버린다. EngineApi 를 main 에서
//      만들고 인터셉터까지 부착해서 동기적으로 주입.
//
// dart-define 키: SUPABASE_URL, SUPABASE_ANON_KEY, GOOGLE_WEB_CLIENT_ID, ENGINE_URL.
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/engine_api.dart';
import '../services/auth_service.dart';
import '../services/iap_service.dart';
import 'app.dart';

/// 앱 전역 EngineApi 인스턴스 — main 에서 만들어 LoopTapApp 에 전달.
late final EngineApi engineApi;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // EngineApi 생성 + Supabase Bearer 토큰 자동 부착 인터셉터 + IAP verify dio 주입.
  // 모두 IapService.init() 이전에 끝내야 pending 영수증 replay 시 verify 가
  // 올바른 dio (인증 헤더 포함) 로 흐른다.
  engineApi = EngineApi();
  engineApi.dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final token = await AuthService.instance.currentAccessToken();
      if (token != null && token.isNotEmpty) {
        options.headers['Authorization'] = 'Bearer $token';
        // JWT header decode for diagnostics — alg/kid/typ.
        try {
          final parts = token.split('.');
          if (parts.length == 3) {
            final padded = parts[0] + '=' * ((4 - parts[0].length % 4) % 4);
            final header = utf8.decode(base64Url.decode(padded));
            debugPrint('[auth-interceptor] attached token (${token.length} chars) header=$header to ${options.uri.path}');
          } else {
            debugPrint('[auth-interceptor] attached token (${token.length} chars) to ${options.uri.path}');
          }
        } catch (_) {
          debugPrint('[auth-interceptor] attached token (${token.length} chars) to ${options.uri.path}');
        }
      } else {
        debugPrint('[auth-interceptor] NO token available for ${options.uri.path}');
      }
      handler.next(options);
    },
  ));
  IapService.instance.configureVerify(engineApi.dio);

  // Supabase 부트는 IAP init 과 병렬로 — verify 가 호출되는 시점에 Auth 가
  // 준비돼 있도록 (Future.wait 이 둘 다 완료될 때까지 대기).
  await Future.wait([
    AuthService.instance.bootstrap(),
    // init 직후 loadProducts() 까지 묶어서 호출 — paywall 진입 시 스토어 가격
    // (ProductDetails.price) 이 즉시 표시되도록(=KRW 폴백 노출 회피).
    IapService.instance.init().then((_) => IapService.instance.loadProducts()),
  ]);
  runApp(const LoopTapApp());
}
