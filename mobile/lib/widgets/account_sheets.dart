// 계정/구독/프로젝트 옵션 관련 바텀시트 모음.
// 시안 launch-ui-p0.html: ③ Paywall, ⑤ Login, ⑱ Logout, ⑲ Restore Result, ⑳ Project Options,
// ㉑ Rename, ㉒ Delete.
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
import 'sync_progress_sheet.dart';

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

// ─── ③ Paywall ─────────────────────────────────────────────────────────
/// trigger: 'export' | 'sync' | 'backup' — 진입 컨텍스트에 따라 헤더 카피 분기.
Future<bool> showPaywallSheet(BuildContext context, ProjectStore store, {required String trigger}) async {
  AnalyticsService.instance.paywallViewed(trigger: trigger);
  // 상품 로드는 _PaywallBodyState.initState 에서 처리 — 완료 시 setState 로 가격 표시 갱신.
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _PaywallBody(store: store, trigger: trigger),
  );
  return ok == true;
}

class _PaywallBody extends StatefulWidget {
  const _PaywallBody({required this.store, required this.trigger});
  final ProjectStore store;
  final String trigger;
  @override
  State<_PaywallBody> createState() => _PaywallBodyState();
}

class _PaywallBodyState extends State<_PaywallBody> {
  String _plan = 'yearly'; // yearly | monthly
  bool _purchasing = false;

  @override
  void initState() {
    super.initState();
    // 스토어가 가격 정보를 비동기로 가져오는 동안 UI 는 폴백(KRW 상수)로 먼저 그림.
    // 로드 완료 시 setState 로 다시 그리면 ProductDetails.price (로컬라이즈된 통화) 가 반영됨.
    if (IapService.instance.enabled && IapService.instance.products.isEmpty) {
      IapService.instance.loadProducts().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  String _headlineFor(L10n t) {
    switch (widget.trigger) {
      case 'export': return t.paywallHeadlineExport;
      case 'sync': return t.paywallHeadlineSync;
      case 'backup': return t.paywallHeadlineBackup;
      default: return t.paywallHeadlineDefault;
    }
  }

  String _subFor(L10n t) {
    switch (widget.trigger) {
      case 'export': return t.paywallSubExport;
      case 'sync': return t.paywallSubSync;
      case 'backup': return t.paywallSubBackup;
      default: return t.paywallSubDefault;
    }
  }

  Future<void> _purchase() async {
    final store = widget.store;
    // 로그인 안 되어 있으면 로그인 시트 먼저 — 시안 ③ → ⑤ 흐름.
    if (store.accountEmail == null) {
      final ok = await showLoginSheet(context, store);
      if (!ok) return;
    }
    setState(() => _purchasing = true);
    bool ok = false;
    // 실 IAP 가용 → 스토어 결제. purchaseStream 이 ProjectStore 를 갱신.
    if (IapService.instance.enabled) {
      final productId = _plan == 'yearly' ? kProductYearly : kProductMonthly;
      final completer = Completer<bool>();
      late StreamSubscription sub;
      sub = IapService.instance.onPurchaseResult.listen((r) {
        if (r.productId != productId) return;
        if (!completer.isCompleted) completer.complete(r.ok);
        sub.cancel();
      });
      final launched = await IapService.instance.buy(productId);
      if (!launched) {
        sub.cancel();
        ok = false;
      } else {
        // 최대 60초 대기 — 사용자가 결제 시트 취소해도 canceled 이벤트로 풀림.
        ok = await completer.future.timeout(
          const Duration(seconds: 60),
          onTimeout: () { sub.cancel(); return false; },
        );
      }
    } else {
      // 스토어 비가용(시뮬레이터/개발) → mockPurchase 폴백.
      ok = await store.mockPurchase(plan: _plan);
    }
    if (!mounted) return;
    setState(() => _purchasing = false);
    if (ok && mounted) {
      // 시안 ⑫ — Pro 결제 통과 직후 환영 화면 1회 표시 (SongsScreen 진입 시).
      store.pendingProWelcome = true;
      Navigator.pop(context, true);
    }
  }

  Widget _planTile(String key, String title, String price, String hint) {
    final active = _plan == key;
    return GestureDetector(
      onTap: () => setState(() => _plan = key),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: active ? AppColors.activeLane : AppColors.bg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: active ? AppColors.lime : AppColors.border, width: active ? 1.5 : 1),
        ),
        child: Row(children: [
          Container(
            width: 20, height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: active ? AppColors.lime : Colors.transparent,
              border: Border.all(color: active ? AppColors.lime : AppColors.border, width: 1.5),
            ),
            child: active ? const Icon(Symbols.check, color: AppColors.bg, size: 14) : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title, style: T.body.copyWith(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(hint, style: T.sub.copyWith(fontSize: 11)),
              ],
            ),
          ),
          Text(price, style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w700, color: AppColors.lime)),
        ]),
      ),
    );
  }

  Widget _feature(IconData ic, String t, String s) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 32, height: 32, alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.activeLane,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(ic, color: AppColors.lime, size: 18),
      ),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t, style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 1),
        Text(s, style: T.sub.copyWith(fontSize: 11)),
      ])),
    ]),
  );

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final t = L10n.of(context);
    return Container(
      decoration: _sheetDeco(),
      constraints: BoxConstraints(maxHeight: mq.size.height * 0.92),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _grabber(),
            Row(children: [
              Expanded(child: Text(_headlineFor(t), style: T.h2.copyWith(fontSize: 20))),
              GestureDetector(
                onTap: () => Navigator.pop(context, false),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(Symbols.close, color: AppColors.textSecondary, size: 22),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            Text(_subFor(t), style: T.sub),
            const SizedBox(height: 18),
            // 시안 ⑪ — 5GB 클라우드 가장 위로, 4개 가치 카드 순서 정리.
            _feature(Symbols.cloud, t.paywallFeatureCloudTitle, t.paywallFeatureCloudSub),
            _feature(Symbols.shield, t.paywallFeatureBackupTitle, t.paywallFeatureBackupSub),
            _feature(Symbols.download, t.paywallFeatureExportTitle, t.paywallFeatureExportSub),
            _feature(Symbols.bolt, t.paywallFeaturePriorityTitle, t.paywallFeaturePrioritySub),
            const SizedBox(height: 8),
            _planTile(
              'yearly',
              t.paywallPlanYearly,
              t.paywallPlanYearlyPrice(IapPricing.yearlyLabel()),
              t.paywallPlanYearlyHint(IapPricing.yearlyAsMonthlyLabel(), IapPricing.yearlyDiscountPercent()),
            ),
            _planTile(
              'monthly',
              t.paywallPlanMonthly,
              t.paywallPlanMonthlyPrice(IapPricing.monthlyLabel()),
              t.paywallPlanMonthlyHint,
            ),
            const SizedBox(height: 4),
            LimeButton(
              label: _purchasing
                  ? t.paywallCtaProcessing
                  : t.paywallCtaStartTrial(IapPricing.trialDays),
              onTap: _purchasing ? null : _purchase,
            ),
            const SizedBox(height: 10),
            Center(child: Text(t.paywallFooterTrial,
                style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary))),
            const SizedBox(height: 8),
            Center(
              child: GestureDetector(
                onTap: () async {
                  if (IapService.instance.enabled) {
                    await IapService.instance.restore();
                    if (context.mounted) {
                      await showRestoreResult(context,
                          ok: widget.store.subscription.hasProAccess);
                    }
                  } else {
                    comingSoon(context, t.paywallRestoreLink);
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(t.paywallRestoreLink, style: T.sub.copyWith(fontSize: 12, color: AppColors.textSecondary)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── ⑤ Login ──────────────────────────────────────────────────────────
Future<bool> showLoginSheet(BuildContext context, ProjectStore store) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _LoginBody(store: store),
  );
  return ok == true;
}

class _LoginBody extends StatelessWidget {
  const _LoginBody({required this.store});
  final ProjectStore store;

  Future<void> _login(BuildContext context, String provider, String email) async {
    if (AuthService.instance.enabled) {
      final launched = await AuthService.instance.signInWith(provider);
      if (!context.mounted) return;
      if (launched) {
        Navigator.pop(context, true);
        return;
      }
      // 실패 — lastError 있으면 표시. 사용자 취소면 null 이라 silent.
      final err = AuthService.instance.lastError;
      if (err != null) {
        // SnackBar 는 모달 시트 아래에 깔려 안 보이므로 dialog 로 — 모달 위 보장.
        await showDialog<void>(
          context: context,
          builder: (dctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(L10n.of(dctx).loginFailedTitle, style: const TextStyle(color: AppColors.danger)),
            content: SelectableText(
              _localizedAuthError(L10n.of(dctx), err),
              style: T.body.copyWith(fontSize: 12),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: Text(L10n.of(dctx).ok),
              ),
            ],
          ),
        );
      }
      return;
    }
    store.mockLogin(provider: provider, email: email);
    if (context.mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final t = L10n.of(context);
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          Text(t.loginTitle, style: T.h2.copyWith(fontSize: 20), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(t.loginSub,
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          // App Store Review Guideline 5.1.5: Sign in with Apple 는 다른 소셜
          // 로그인보다 prominence 동등 이상 — 시안 ⑤ 와 동일하게 최상단 배치.
          AppleSignInButton(
            label: t.appleSignInCta,
            onPressed: () => _login(context, 'apple', 'me@privaterelay.appleid.com'),
          ),
          GoogleSignInButton(
            label: t.googleSignInCta,
            onPressed: () => _login(context, 'google', 'me@gmail.com'),
          ),
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: () => Navigator.pop(context, false),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(t.later, style: T.sub.copyWith(fontSize: 13, color: AppColors.textSecondary)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const _TermsAgreement(),
        ],
      ),
    );
  }
}

/// 로그인 시트 하단 약관 동의 안내.
/// "서비스 약관", "개인정보 처리방침" 은 풀모달로 해당 문서를 연다.
class _TermsAgreement extends StatelessWidget {
  const _TermsAgreement();

  @override
  Widget build(BuildContext context) {
    final base = T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary, height: 1.5);
    final link = base.copyWith(
      color: AppColors.textSecondary,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.textSecondary.withValues(alpha: 0.6),
    );
    final t = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(text: t.loginTermsPrefix),
            TextSpan(
              text: t.loginTermsLinkTerms,
              style: link,
              recognizer: TapGestureRecognizer()
                ..onTap = () => LegalDocScreen.open(context, LegalDoc.terms),
            ),
            TextSpan(text: t.loginTermsBetween),
            TextSpan(
              text: t.loginTermsLinkPrivacy,
              style: link,
              recognizer: TapGestureRecognizer()
                ..onTap = () => LegalDocScreen.open(context, LegalDoc.privacy),
            ),
            TextSpan(text: t.loginTermsSuffix),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}

// ─── ⑱ Logout 확인 ────────────────────────────────────────────────────
Future<void> showLogoutConfirm(BuildContext context, ProjectStore store) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) {
      final t = L10n.of(sheetCtx);
      return Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          Text(t.logoutConfirmTitle, style: T.h2.copyWith(fontSize: 18), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(t.logoutConfirmBody,
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: () async {
              if (AuthService.instance.enabled) {
                await AuthService.instance.signOut();
              } else {
                store.mockLogout();
              }
              if (sheetCtx.mounted) Navigator.pop(sheetCtx);
            },
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.15),
                border: Border.all(color: AppColors.dangerBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(t.logoutCta,
                  style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.danger)),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => Navigator.pop(sheetCtx),
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.bg,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(t.cancel, style: T.body.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
    },
  );
}

// ─── ⑲ 구매 복원 결과 ────────────────────────────────────────────────
Future<void> showRestoreResult(BuildContext context, {required bool ok, String? message}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) {
      final t = L10n.of(sheetCtx);
      return Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _grabber(),
          Icon(ok ? Symbols.check_circle : Symbols.error,
              color: ok ? AppColors.lime : AppColors.danger, size: 48),
          const SizedBox(height: 12),
          Text(ok ? t.restoreOkTitle : t.restoreEmptyTitle,
              style: T.h2.copyWith(fontSize: 18)),
          const SizedBox(height: 6),
          Text(message ?? (ok ? t.restoreOkBody : t.restoreEmptyBody),
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: LimeButton(label: t.ok, onTap: () => Navigator.pop(sheetCtx)),
          ),
        ],
      ),
    );
    },
  );
}

// ─── ⑳ ㉑ ㉒ 프로젝트 옵션 ───────────────────────────────────────────
// cloud-sync-p3 ⑥ — 내 작업물 탭 옵션 시트에 "클라우드에 올리기 / 클라우드 최신화" 추가.
enum _ProjectAction {
  open,
  rename,
  duplicate,
  export,
  delete,
  uploadToCloud,
  refreshCloud,
}

/// `onChanged` 는 옵션 시트 결과로 리스트를 갱신해야 할 때 호출 — songs screen 에서 setState.
Future<void> showProjectOptionsSheet(
  BuildContext context,
  ProjectStore store,
  ProjectMeta meta, {
  required VoidCallback onChanged,
  required Future<void> Function() onOpen,
}) async {
  final action = await showModalBottomSheet<_ProjectAction>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _ProjectOptionsBody(meta: meta, store: store),
  );
  if (action == null) return;
  switch (action) {
    case _ProjectAction.open:
      await onOpen();
      break;
    case _ProjectAction.rename:
      // ignore: use_build_context_synchronously
      final newName = await _promptRename(context, meta.title);
      if (newName != null && newName.trim().isNotEmpty) {
        await LocalStorage.instance.renameProject(meta.id, newName.trim());
        onChanged();
      }
      break;
    case _ProjectAction.duplicate:
      await LocalStorage.instance.duplicateProject(meta);
      onChanged();
      break;
    case _ProjectAction.export:
      if (!store.subscription.hasProAccess) {
        // ignore: use_build_context_synchronously
        await showPaywallSheet(context, store, trigger: 'export');
        break;
      }
      // Pro — 해당 프로젝트를 열어 EditScreen 진입. 사용자는 거기서 우상단 공유 아이콘
      // 으로 MIDI/WAV 내보내기 가능. (별도 export 시트를 여기서 직접 띄우려면 onOpen
      // 의 navigation 종료를 기다린 뒤 EditScreen context 를 받아야 해 흐름이 복잡.)
      await onOpen();
      break;
    case _ProjectAction.delete:
      // ignore: use_build_context_synchronously
      final ok = await _promptDelete(context, meta.title);
      if (ok == true) {
        await LocalStorage.instance.deleteProject(meta.id);
        onChanged();
      }
      break;
    case _ProjectAction.uploadToCloud:
    case _ProjectAction.refreshCloud:
      // Pro 가 아니면 paywall (lock 아이콘 탭).
      if (!store.subscription.hasProAccess) {
        // ignore: use_build_context_synchronously
        await showPaywallSheet(context, store, trigger: 'sync');
        break;
      }
      // 시안 ⑧ — 업로드 진행 모달 → mock 업로드.
      final sizeBytes = (meta.durationSec * 200 * 1024).toInt().clamp(1024 * 1024, 50 * 1024 * 1024);
      if (!context.mounted) break;
      final done = await showSyncProgressSheet(
        context,
        direction: SyncDirection.upload,
        projectTitle: meta.title,
        totalBytes: sizeBytes,
        onRun: () => store.mockUploadToCloud(meta.id, meta.title, sizeBytes: sizeBytes),
      );
      if (done && context.mounted) {
        // 시안 ② — "{title} — 클라우드에 올렸어요" 토스트.
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Row(children: [
              const Icon(Symbols.check_circle, color: AppColors.lime, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(L10n.of(context).projectUploadedToast(meta.title),
                    style: T.body.copyWith(fontSize: 13)),
              ),
            ]),
            backgroundColor: AppColors.surface3,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ));
        onChanged();
      }
      break;
  }
}

class _ProjectOptionsBody extends StatelessWidget {
  const _ProjectOptionsBody({required this.meta, required this.store});
  final ProjectMeta meta;
  final ProjectStore store;

  Widget _row(BuildContext context, IconData ic, String title, String? sub, _ProjectAction action, {bool danger = false, bool pro = false, bool lime = false, bool muted = false}) {
    final color = danger
        ? AppColors.danger
        : (lime ? AppColors.lime : (muted ? AppColors.textSecondary : AppColors.textPrimary));
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.pop(context, action),
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: AppColors.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: danger ? AppColors.dangerBorder : AppColors.border),
        ),
        child: Row(children: [
          Icon(ic, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text(title, style: T.body.copyWith(fontWeight: FontWeight.w600, color: color)),
                  if (pro) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.lime.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('PRO', style: T.label.copyWith(color: AppColors.lime, fontSize: 9)),
                    ),
                  ],
                ]),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(sub, style: T.sub.copyWith(fontSize: 11)),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 같은 id 가 클라우드에 있으면 "최신화" 톤. 없으면 "올리기" lime 강조.
    final cloudExisting = store.cloudProjects.firstWhere(
      (c) => c.id == meta.id,
      orElse: () => CloudProjectMeta(
        id: '',
        title: '',
        uploadedAt: DateTime.now(),
        lastModifiedAt: DateTime.now(),
        sizeBytes: 0,
        onThisDevice: true,
      ),
    );
    final hasCloud = cloudExisting.id.isNotEmpty;
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          _projectHeader(context, meta),
          const SizedBox(height: 16),
          // 클라우드 액션 — 시안 ⑥. Pro 면 lime, 비-Pro 면 lock + paywall.
          if (!hasCloud)
            _row(
              context,
              Symbols.cloud_upload,
              L10n.of(context).projectActionUploadToCloud,
              store.subscription.hasProAccess ? null : L10n.of(context).projectOptionUploadProBadge,
              _ProjectAction.uploadToCloud,
              lime: store.subscription.hasProAccess,
              pro: !store.subscription.hasProAccess,
            )
          else
            _row(
              context,
              Symbols.cloud_sync,
              L10n.of(context).projectActionRefreshCloud,
              L10n.of(context).projectOptionRefreshSyncedAt(_fmtAgo(context, cloudExisting.lastModifiedAt)),
              _ProjectAction.refreshCloud,
              muted: true,
            ),
          _row(context, Symbols.folder_open, L10n.of(context).projectOptionOpen, null, _ProjectAction.open),
          _row(context, Symbols.edit, L10n.of(context).projectOptionRename, null, _ProjectAction.rename),
          _row(context, Symbols.content_copy, L10n.of(context).projectOptionDuplicate, null, _ProjectAction.duplicate),
          _row(context, Symbols.ios_share, L10n.of(context).projectOptionExport, L10n.of(context).projectOptionExportSub, _ProjectAction.export, pro: !store.subscription.hasProAccess),
          _row(context, Symbols.delete, L10n.of(context).projectOptionDelete, L10n.of(context).projectOptionDeleteSub, _ProjectAction.delete, danger: true),
        ],
      ),
    );
  }
}

Widget _projectHeader(BuildContext context, ProjectMeta meta) {
  return Row(children: [
    _ProjectThumb(index: meta.thumbIndex, size: 56),
    const SizedBox(width: 12),
    Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(meta.title, style: T.h2.copyWith(fontSize: 17),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Text(
            L10n.of(context).projectHeaderMeta(
              meta.trackCount,
              _fmtDur(context, meta.durationSec),
              _fmtAgo(context, meta.updatedAt),
            ),
            style: T.sub,
          ),
        ],
      ),
    ),
  ]);
}

class _ProjectThumb extends StatelessWidget {
  const _ProjectThumb({required this.index, this.size = 56});
  final int index;
  final double size;

  // 4 종 그라데이션 — 시안 ② 카드 썸네일과 유사.
  static const _palettes = <List<Color>>[
    [Color(0xFFA3E635), Color(0xFF65A30D)], // lime
    [Color(0xFF7C3AED), Color(0xFF4C1D95)], // violet
    [Color(0xFFF59E0B), Color(0xFFB45309)], // amber
    [Color(0xFF06B6D4), Color(0xFF0E7490)], // cyan
  ];

  @override
  Widget build(BuildContext context) {
    final pal = _palettes[index.clamp(0, _palettes.length - 1)];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: pal,
        ),
      ),
      child: const Icon(Symbols.graphic_eq, color: Colors.white, size: 24),
    );
  }
}

// ─── ㉑ Rename 다이얼로그 ────────────────────────────────────────────
Future<String?> _promptRename(BuildContext context, String initial) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(L10n.of(dctx).rename, style: T.h2.copyWith(fontSize: 17)),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: T.body,
              cursorColor: AppColors.lime,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.bg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lime, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx),
                  child: Container(
                    height: 44, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.bg, borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(L10n.of(dctx).cancel, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, ctrl.text),
                  child: Container(
                    height: 44, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.lime, borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(L10n.of(dctx).save, style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.bg)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
}

// ─── ㉒ Delete 확인 ────────────────────────────────────────────────────
Future<bool?> _promptDelete(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 48, height: 48, alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Symbols.delete, color: AppColors.danger, size: 22),
              ),
            ),
            const SizedBox(height: 12),
            Text(L10n.of(dctx).projectDeleteTitle(title), style: T.h2.copyWith(fontSize: 17), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(L10n.of(dctx).projectDeleteBody,
                style: T.sub, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, false),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.bg, borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(L10n.of(dctx).cancel, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, true),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.danger, borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(L10n.of(dctx).delete, style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
}

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

/// 외부에서 공개 — 카드 위젯에서도 같은 썸네일 색을 쓰기 위해.
class ProjectThumb extends StatelessWidget {
  const ProjectThumb({super.key, required this.index, this.size = 56});
  final int index;
  final double size;
  @override
  Widget build(BuildContext context) => _ProjectThumb(index: index, size: size);
}

/// fmt helpers 외부 공개.
String fmtProjectDuration(BuildContext context, double s) => _fmtDur(context, s);
String fmtProjectAgo(BuildContext context, DateTime dt) => _fmtAgo(context, dt);
