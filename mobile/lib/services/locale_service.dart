// 앱 언어 선택 — 시스템 기본 / 한국어 / English.
//
// 동작:
//   - null = 시스템 기본 (OS 의 Locale 자동 사용, supportedLocales 와 매치)
//   - Locale('ko') / Locale('en') = 사용자 명시 override
//
// 영속화: LocalStorage.writeCloudPrefs 의 cloud_prefs.json 에 같이 저장
// ('locale' 키, 값: null / 'ko' / 'en').
//
// MaterialApp 의 locale 파라미터로 전달 — null 이면 Flutter 가 시스템 언어로 폴백.
import 'package:flutter/widgets.dart';

import '../state/local_storage.dart';

class LocaleService {
  LocaleService._();
  static final LocaleService instance = LocaleService._();

  /// 현재 선택된 locale. null = 시스템 기본.
  final ValueNotifier<Locale?> selected = ValueNotifier<Locale?>(null);

  /// 앱 시작 시 1회 호출 — 영속 값 로드.
  Future<void> bootstrap() async {
    try {
      final prefs = await LocalStorage.instance.readCloudPrefs();
      final raw = prefs['locale'];
      if (raw is String && raw.isNotEmpty) {
        selected.value = Locale(raw);
      }
    } catch (e) {
      debugPrint('[locale] bootstrap failed: $e');
    }
  }

  /// 사용자 선택 변경 — 영속화 + UI 갱신.
  Future<void> setLocale(Locale? locale) async {
    selected.value = locale;
    try {
      await LocalStorage.instance.writeCloudPrefs({
        'locale': locale?.languageCode,
      });
    } catch (e) {
      debugPrint('[locale] save failed: $e');
    }
  }
}
