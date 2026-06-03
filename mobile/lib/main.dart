// Humming — 벌새 voice-to-MIDI 앱.
// 흐름: Songs(작업 시작) → Edit(녹음→분석→편집→내보내기).
//
// 부트스트랩 순서 (graceful-degrade — 키 미설정 시 해당 서비스만 비활성):
//   1. Sentry (글로벌 Zone, 이후 runApp 을 wrap)
//   2. Supabase (SUPABASE_URL/SUPABASE_ANON_KEY)
//   3. PostHog (POSTHOG_KEY)
//   4. IAP (스토어 isAvailable() 체크)
//
// dart-define 키:
//   ENGINE_URL, SUPABASE_URL, SUPABASE_ANON_KEY,
//   SENTRY_DSN, POSTHOG_KEY, POSTHOG_HOST(optional)
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'l10n/generated/app_localizations.dart';
import 'services/analytics_service.dart';
import 'services/auth_service.dart';
import 'services/iap_service.dart';
import 'services/locale_service.dart';
import 'services/observability_service.dart';
import 'state/project_store.dart';
import 'theme/app_theme.dart';
import 'screens/songs_screen.dart';

Future<void> main() async {
  await ObservabilityService.instance.bootstrap(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // 외부 SDK 들은 병렬 init — 서로 의존성 없음.
    await Future.wait([
      AuthService.instance.bootstrap(),
      AnalyticsService.instance.init(),
      IapService.instance.init(),
      LocaleService.instance.bootstrap(),
    ]);
    runApp(const HummingApp());
  });
}

class HummingApp extends StatelessWidget {
  const HummingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) {
        final store = ProjectStore();
        // IAP 영수증 검증을 같은 엔진 백엔드(/iap/verify) 로.
        IapService.instance.configureVerify(store.engineDio);
        // 클라우드 prefs(자동 동기화 토글 등) 비동기 로드 — UI 렌더에는 영향 없음.
        store.loadCloudPrefs();
        return store;
      },
      child: ValueListenableBuilder<Locale?>(
        valueListenable: LocaleService.instance.selected,
        builder: (_, override, __) {
          return MaterialApp(
            title: 'HumTrack',
            theme: hummingTheme(),
            debugShowCheckedModeBanner: false,
            // null = 시스템 기본 locale (OS 설정 따라감). override 시 강제.
            locale: override,
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: const SongsScreen(),
          );
        },
      ),
    );
  }
}
