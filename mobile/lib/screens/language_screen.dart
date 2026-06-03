// 언어 선택 화면 — "시스템 기본 / 한국어 / English / ...".
//
// 확장 가능:
//   1) `lib/l10n/app_<code>.arb` 추가 → flutter pub get → L10n 자동 생성
//   2) 이 화면은 `L10n.supportedLocales` 를 그대로 노출하므로 추가 작업 없이 picker 에 표시됨
//   3) 새 언어의 native 이름은 `_nativeName` 맵에 한 줄만 추가 (없으면 자동으로 ISO code 폴백)
//
// 디자인 토큰: AppColors / T 사용.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/locale_service.dart';
import '../theme/app_theme.dart';

class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});

  /// 새 언어 추가 시 native 이름만 한 줄 추가.
  /// 누락된 언어는 ISO code (예: 'ja', 'zh') 가 그대로 표시됨 — 임시지만 동작은 함.
  static const Map<String, String> _nativeName = {
    'ko': '한국어',
    'en': 'English',
    // 'ja': '日本語',
    // 'zh': '中文',
  };

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final supported = L10n.supportedLocales;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(l.languageScreenTitle, style: T.h2.copyWith(fontSize: 17)),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: ValueListenableBuilder<Locale?>(
          valueListenable: LocaleService.instance.selected,
          builder: (_, current, __) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
              children: [
                // 시스템 기본 — locale = null
                _LocaleRow(
                  title: l.languageSystemDefault,
                  subtitle: l.languageSystemDefaultSub,
                  selected: current == null,
                  onTap: () => LocaleService.instance.setLocale(null),
                ),
                const SizedBox(height: 8),
                // 지원 언어 — supportedLocales 에 등록된 모든 언어 자동 노출.
                for (final loc in supported)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _LocaleRow(
                      title: _nativeName[loc.languageCode] ?? loc.languageCode,
                      subtitle: loc.languageCode.toUpperCase(),
                      selected: current?.languageCode == loc.languageCode,
                      onTap: () => LocaleService.instance.setLocale(loc),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _LocaleRow extends StatelessWidget {
  const _LocaleRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? AppColors.activeLane : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppColors.lime : AppColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    style: T.body.copyWith(
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.textPrimary : AppColors.textPrimary,
                    )),
                const SizedBox(height: 2),
                Text(subtitle, style: T.sub.copyWith(fontSize: 11)),
              ],
            ),
          ),
          if (selected)
            const Icon(Symbols.check, color: AppColors.lime, size: 20)
          else
            const SizedBox(width: 20),
        ]),
      ),
    );
  }
}
