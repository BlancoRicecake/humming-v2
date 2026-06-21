// Microsoft Clarity 통합 (세션 리플레이 + 히트맵, 무료·무제한).
//
// dart-define CLARITY_PROJECT_ID 미설정 시 비활성 — auth_service 와 동일한
// graceful-degrade 패턴. 키가 없으면 wrap() 은 앱을 그대로 돌려주고, 모든
// 헬퍼는 noop 이라 dev/CI/미설정 빌드에서 안전하다.
//
//   flutter run --dart-define=CLARITY_PROJECT_ID=xxxxxxxxxx
//
// projectId 는 Clarity 대시보드 Settings 페이지에서 확인. PII 는 절대 태그/
// 이벤트/userId 로 보내지 않는다 (Clarity 권고 + 우리 개인정보처리방침).
import 'package:clarity_flutter/clarity_flutter.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class ClarityService {
  ClarityService._();
  static final ClarityService instance = ClarityService._();

  static const _projectId = String.fromEnvironment('CLARITY_PROJECT_ID');

  /// 키가 주입됐을 때만 true. 런타임 분기는 모두 이 값으로.
  bool get enabled => _projectId.isNotEmpty;

  /// 루트 위젯을 ClarityWidget 으로 감싼다. 비활성 시 앱을 그대로 반환 →
  /// 의존성/오버헤드 0. main() 의 runApp 에 이 결과를 넘긴다.
  Widget wrap(Widget app) {
    if (!enabled) {
      debugPrint('[clarity] CLARITY_PROJECT_ID not set — session replay disabled');
      return app;
    }
    debugPrint('[clarity] enabled (project $_projectId)');
    final config = ClarityConfig(
      projectId: _projectId,
      // production 빌드는 SDK 가 자동으로 None 강제 (오버헤드 제거). debug 만 Info.
      logLevel: kDebugMode ? LogLevel.Info : LogLevel.None,
    );
    return ClarityWidget(app: app, clarityConfig: config);
  }

  /// 로그인 사용자 식별 (세션 필터용). 이메일 등 PII 가 아니라 Supabase user id
  /// 같은 불투명 식별자만 넘길 것. 로그아웃 시 setUserId(null) 대신 새 세션을 시작.
  void setUserId(String userId) {
    if (!enabled || userId.isEmpty) return;
    Clarity.setCustomUserId(userId);
  }

  /// 사용자 전환(로그아웃→다른 로그인) 시 리플레이를 분리.
  void startNewSession() {
    if (!enabled) return;
    Clarity.startNewSession((_) {});
  }

  /// 세션 필터용 커스텀 태그 (예: role=guitar, plan=pro).
  void tag(String key, String value) {
    if (!enabled || key.isEmpty || value.isEmpty) return;
    Clarity.setCustomTag(key, value);
  }

  /// 커스텀 이벤트 (Clarity 가 자동 캡처하지 못하는 행동: analyze 완료, export 등).
  void event(String name) {
    if (!enabled || name.isEmpty) return;
    Clarity.sendCustomEvent(name);
  }

  /// 라우트 전환 시 화면 이름 지정 → 히트맵/리플레이가 화면 단위로 분리된다.
  void screen(String name) {
    if (!enabled || name.isEmpty) return;
    Clarity.setCurrentScreenName(name);
  }
}
