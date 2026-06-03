// 계정/구독/프로젝트 옵션 관련 바텀시트 모음 (라이브러리).
//
// 자연 경계를 따라 `account/` 하위 part 파일로 분할:
//  - paywall_sheet.dart      — showPaywallSheet + _PaywallBody
//  - login_sheet.dart        — showLoginSheet + _LoginBody + _TermsAgreement
//  - logout_sheet.dart       — showLogoutConfirm
//  - restore_sheet.dart      — showRestoreResult
//  - project_options_sheet.dart — showProjectOptionsSheet + _ProjectOptionsBody + _ProjectThumb + ProjectThumb
//  - rename_dialog.dart      — _promptRename
//  - delete_dialog.dart      — _promptDelete
//
// 분할 후에도 import 경로 변경 없음 — 호출처는 `widgets/account_sheets.dart` 그대로 사용.
//
// 디자인 토큰만 사용 (AppColors, T). IAP/OAuth 는 mockPurchase / mockLogin 으로 호출 —
// 실제 in_app_purchase / supabase 패키지는 다음 배치에서 도입.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/generated/app_localizations.dart';
import '../screens/legal_doc_screen.dart';

import '../services/analytics_service.dart';
import '../services/auth_service.dart';
import '../services/iap_pricing.dart';
import '../services/iap_service.dart';
import '../state/local_storage.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'common.dart';
import 'social_sign_in_buttons.dart';
import 'cloud/sync_progress_sheet.dart';

part 'account/paywall_sheet.dart';
part 'account/login_sheet.dart';
part 'account/logout_sheet.dart';
part 'account/restore_sheet.dart';
part 'account/project_options_sheet.dart';
part 'account/rename_dialog.dart';
part 'account/delete_dialog.dart';

// ─── 공통 헬퍼 ─────────────────────────────────────────────────────────
BoxDecoration _sheetDeco() => const BoxDecoration(
      color: AppColors.surface,
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.sheet)),
    );

String _authProviderLabel(L10n l, String provider) {
  switch (provider.toLowerCase()) {
    case 'apple':    return 'Apple';
    case 'google':   return 'Google';
    case 'kakao':    return l.authProviderKakao;
    case 'naver':    return l.authProviderNaver;
    case 'github':   return 'GitHub';
    case 'facebook': return 'Facebook';
    default:         return provider;
  }
}

/// AuthError → 사용자 표시용 로컬라이즈 문자열.
String _localizedAuthError(L10n l, AuthError e) {
  switch (e.code) {
    case 'disabled':
      return l.authErrDisabled;
    case 'googleNoIdToken':
      return l.authErrGoogleNoIdToken;
    case 'identityBlockedGeneric':
      return l.authErrIdentityBlockedGeneric;
    case 'identityBlockedSpecific':
      final labels = e.providers.map((p) => _authProviderLabel(l, p)).join(', ');
      return l.authErrIdentityBlockedSpecific(labels);
    case 'appleCode':
      return l.authErrAppleCode(e.appleCode ?? '', e.appleMessage ?? '');
    case 'generic':
    default:
      return l.authErrGeneric(e.provider ?? '', e.raw ?? '');
  }
}

Widget _grabber() => Center(
      child: Container(
        width: 40,
        height: 4,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(color: const Color(0xFF3F3F46), borderRadius: BorderRadius.circular(2)),
      ),
    );

// ─── 포맷 헬퍼 ────────────────────────────────────────────────────────
String _fmtDur(BuildContext context, double s) {
  final m = (s ~/ 60), ss = (s % 60).round();
  return L10n.of(context).projectDurationLabel(m, ss.toString().padLeft(2, '0'));
}

String _fmtAgo(BuildContext context, DateTime dt) {
  final t = L10n.of(context);
  final d = DateTime.now().difference(dt);
  if (d.inMinutes < 1) return t.agoJustNow;
  if (d.inHours < 1) return t.agoMinutes(d.inMinutes);
  if (d.inDays < 1) return t.agoHours(d.inHours);
  if (d.inDays < 7) return t.agoDays(d.inDays);
  return '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';
}

/// fmt helpers 외부 공개.
String fmtProjectDuration(BuildContext context, double s) => _fmtDur(context, s);
String fmtProjectAgo(BuildContext context, DateTime dt) => _fmtAgo(context, dt);
