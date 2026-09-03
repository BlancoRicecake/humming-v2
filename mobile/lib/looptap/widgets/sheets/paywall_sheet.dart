// LoopTap — Pro paywall sheet. humtrack_pro_monthly_v2 / yearly 구독을 띄움.
// 가격은 IapPricing 헬퍼가 스토어 ProductDetails 우선, 폴백 KRW 상수.
//
// 결제 결과 처리 (audit M5/M6):
//   - canceled          → 조용히 버튼만 복구.
//   - pending           → "승인 대기" 표시, 타임아웃 없이 최종 결과를 기다림.
//   - verifyFailed 등   → "결제 확인됨 — 활성화 중, 안 보이면 구매 복원" 안내.
//   - restore           → LoopStore.restorePurchases() 의 결과(enum)로 문구 결정.
// 모든 사용자 문구는 L10n (pay*) — audit M12.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/clarity_service.dart';
import '../../../services/iap_pricing.dart';
import '../../../services/iap_service.dart';
import '../../app.dart' show rootMessengerKey;
import '../../state/loop_store.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'account_sheet.dart';
import 'lt_modal.dart';

/// Free-plan song quota shown in the benefits line. Keep in sync with
/// `kFreeSongQuota` in screens/songs_screen.dart (not imported to avoid a
/// screen → sheet → screen import cycle).
const int _kFreeSongQuota = 4;

/// Paywall 진입점 — 어떤 기능 시도가 Pro 게이트에 막혀 시트가 떴는지.
/// 상단 contextual banner 의 문구가 이걸로 결정됨. 사용자가 "왜 결제 화면이
/// 떴는지" 즉시 인지하게 해주는 게 목적.
enum PaywallTrigger {
  /// 트랙 export 시도 (MIDI/오디오 내보내기).
  export,
  /// 무료 플랜 곡 개수 한도 도달.
  songQuota,
  /// 일반 업그레이드 진입 (계정/설정에서 직접 진입). 별도 banner 표시 없음.
  upgrade;

  /// banner 에 표시할 한 줄 — null 이면 banner 미노출.
  String? hint(L10n l) => switch (this) {
        PaywallTrigger.export => l.looptapPaywallTriggerExport,
        PaywallTrigger.songQuota => l.looptapPaywallTriggerSongQuota,
        PaywallTrigger.upgrade => null,
      };
}

Future<void> showPaywallSheet(
  BuildContext context, {
  PaywallTrigger trigger = PaywallTrigger.upgrade,
}) {
  return showLtModal(context, width: 440, child: _PaywallSheet(trigger: trigger));
}

/// 사용자에게 보여줄 결제 실패 문구 — null 이면 조용히 (취소). 순수 매핑이라
/// 테스트 가능.
String? paywallMessageFor(L10n l, IapError? e, {required bool storeEnabled}) {
  switch (e) {
    case null:
    case IapError.canceled:
      return null;
    case IapError.pending:
    case IapError.paymentPending:
      return l.payPendingApproval;
    case IapError.verifyFailed:
    case IapError.network:
    case IapError.throttled:
      return l.payVerifyFailed;
    case IapError.notSignedIn:
      return l.paySignInRequired;
    case IapError.storeError:
      return storeEnabled ? l.payPurchaseFailed : l.payStoreUnavailableDevice;
  }
}

/// 복원 결과 문구.
String restoreMessageFor(L10n l, RestoreOutcome o) => switch (o) {
      RestoreOutcome.restored => l.payRestoreDone,
      RestoreOutcome.alreadyActive => l.payRestoreAlready,
      RestoreOutcome.nothingFound => l.payRestoreEmpty,
      RestoreOutcome.error => l.payRestoreError,
    };

class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet({required this.trigger});

  final PaywallTrigger trigger;

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  bool _busy = false;
  /// 스토어가 "승인 대기"(Ask to Buy 등) 를 알려온 상태 — 타임아웃 없이 대기.
  bool _pending = false;
  String _selected = kProductYearly;

  StreamSubscription<IapResult>? _sub;
  Completer<IapResult>? _purchase;

  /// pending 이 아닐 때만 적용되는 결제 결과 대기 시간.
  static const Duration _resultTimeout = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    // Clarity: paywall 노출 + 진입 트리거(export/songQuota/upgrade) 태깅.
    ClarityService.instance.event('paywall_viewed');
    ClarityService.instance.tag('paywall_trigger', widget.trigger.name);
    // 시트 진입 시점에 ProductDetails 로드 — 라벨이 KRW 폴백 → 스토어 가격으로 갱신.
    final store = context.read<LoopStore>();
    store.loadProducts().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    // 시트가 닫혀도 대기 루프가 영원히 남지 않도록 — 결과는 LoopStore 가
    // onPurchaseResult 로 계속 받아 Pro 를 켠다.
    final c = _purchase;
    if (c != null && !c.isCompleted) {
      c.complete(const IapResult(ok: false, productId: '', error: IapError.canceled));
    }
    super.dispose();
  }

  void _toast(String msg) {
    // rootMessenger 사용 — paywall (showGeneralDialog) 위에서도 보이도록.
    rootMessengerKey.currentState
      ?..clearSnackBars()
      ..showSnackBar(SnackBar(
        backgroundColor: LT.surface2,
        content: Text(msg, style: LTType.inter(size: 13, color: LT.t1)),
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
      ));
  }

  Future<void> _buy(LoopStore store, String productId) async {
    if (_busy) return;
    final l = L10n.of(context);
    // 로그인이 안 돼 있으면 /iap/verify 가 401 이고 applicationUserName 도 못
    // 채운다 (M1). 결제 진입 전에 로그인 강제.
    if (!store.isSignedIn) {
      await showAccountSheet(context);
      if (!mounted) return;
      if (!store.isSignedIn) return; // 사용자가 로그인 안 하고 닫음 — 조용히 종료.
    }
    setState(() {
      _busy = true;
      _pending = false;
    });
    // buy() 호출 직전에 listener 부착 — 해당 productId 의 결과만 받는다.
    final completer = Completer<IapResult>();
    _purchase = completer;
    _sub?.cancel();
    _sub = IapService.instance.onPurchaseResult.listen((r) {
      if (r.productId != productId) return;
      if (r.error == IapError.pending) {
        // 중간 상태 — 최종 purchased/error 가 뒤따른다.
        if (mounted) setState(() => _pending = true);
        return;
      }
      if (!completer.isCompleted) completer.complete(r);
    });
    final launchErr = productId == kProductYearly ? await store.buyYearly() : await store.buyMonthly();
    final IapResult result;
    if (launchErr != null) {
      result = IapResult(ok: false, productId: productId, error: launchErr);
    } else {
      result = await _awaitResult(completer, productId);
    }
    _sub?.cancel();
    _sub = null;
    _purchase = null;
    if (!mounted) return;
    setState(() {
      _busy = false;
      _pending = false;
    });
    if (result.ok) {
      Navigator.of(context).maybePop();
      return;
    }
    final msg = paywallMessageFor(l, result.error, storeEnabled: store.iapEnabled);
    if (msg != null) _toast(msg);
  }

  /// 결과 대기. 60초 타임아웃은 스토어가 pending 을 알리지 않은 경우에만 —
  /// 승인 대기 중이면 최종 결과가 올 때까지 기다린다 (M5).
  Future<IapResult> _awaitResult(Completer<IapResult> c, String productId) async {
    while (true) {
      try {
        return await c.future.timeout(_resultTimeout);
      } on TimeoutException {
        if (!mounted) {
          return IapResult(ok: false, productId: productId, error: IapError.canceled);
        }
        if (_pending) continue;
        return IapResult(ok: false, productId: productId, error: IapError.storeError, message: 'timeout');
      }
    }
  }

  Future<void> _restore(LoopStore store) async {
    if (_busy) return;
    final l = L10n.of(context);
    // restore 도 verify 가 필요 — 로그인 게이트.
    if (!store.isSignedIn) {
      await showAccountSheet(context);
      if (!mounted) return;
      if (!store.isSignedIn) return;
    }
    setState(() => _busy = true);
    final outcome = await store.restorePurchases();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(restoreMessageFor(l, outcome));
    if (outcome == RestoreOutcome.restored || outcome == RestoreOutcome.alreadyActive) {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LoopStore>();
    final l = L10n.of(context);
    final disabled = !store.iapEnabled;
    final hint = widget.trigger.hint(l);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: LT.lime, borderRadius: BorderRadius.circular(8)),
                  child: const Center(child: Ms(LtIcons.workspacePremium, size: 18, color: LT.bg)),
                ),
                const SizedBox(width: 10),
                Text(l.payTitle, style: LTType.inter(size: 17, weight: FontWeight.w800, color: LT.t1)),
              ],
            ),
            IconBtn(icon: LtIcons.close, tooltip: l.close, onTap: () => Navigator.of(context).maybePop()),
          ],
        ),
        // 진입점 contextual banner — Export 같은 특정 기능에서 들어왔을 때
        // "왜 결제 화면이 떴는지" 즉시 인지시키는 핀포인트 메시지.
        if (hint != null) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: LT.lime.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(LTRadius.control),
              border: Border.all(color: LT.lime.withValues(alpha: 0.35)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Ms(LtIcons.workspacePremium, size: 16, color: LT.lime),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hint,
                    style: LTType.inter(size: 12, weight: FontWeight.w600, color: LT.t1, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        // 실제 제공 혜택만 (M10): 무제한 곡 + WAV/MIDI/스템 내보내기.
        Text(
          l.payBenefits(_kFreeSongQuota),
          style: LTType.inter(size: 12, color: LT.t2, height: 1.5),
        ),
        const SizedBox(height: 18),
        _PlanCard(
          productId: kProductYearly,
          title: l.payPlanYearly,
          price: IapPricing.yearlyLabel(),
          per: l.payPerMonthEquiv(IapPricing.yearlyAsMonthlyLabel()),
          selected: _selected == kProductYearly,
          onTap: _busy ? null : () => setState(() => _selected = kProductYearly),
        ),
        const SizedBox(height: 10),
        _PlanCard(
          productId: kProductMonthly,
          title: l.payPlanMonthly,
          price: IapPricing.monthlyLabel(),
          per: l.payBilledMonthly,
          selected: _selected == kProductMonthly,
          onTap: _busy ? null : () => setState(() => _selected = kProductMonthly),
        ),
        const SizedBox(height: 16),
        // Billed amount is the most prominent pricing element (App Store
        // Guideline 3.1.2(c)); free-trial wording is kept subordinate to it —
        // smaller, dimmer, and below the total. Apple rejected the prior layout
        // where the lime CTA promoted only "Start free trial" with no billed
        // amount or auto-renewal disclosure.
        () {
          final isYearly = _selected == kProductYearly;
          final billed = isYearly ? IapPricing.yearlyLabel() : IapPricing.monthlyLabel();
          final period = isYearly ? l.payPeriodYear : l.payPeriodMonth;
          // Trial wording (M11): iOS cannot tell intro-offer eligibility
          // client-side, so the line is explicitly "for new subscribers" and
          // StoreKit decides at checkout. On Android, Google Play drops the
          // trial offer once used, so a returning user sees plain billing
          // terms instead — the purchase flow bills them immediately to match
          // (see IapService._androidOfferToken).
          final hasTrial = IapPricing.hasFreeTrial(_selected);
          final disclosure = hasTrial
              ? l.payDisclosureTrial(IapPricing.trialDays, billed, period)
              : l.payDisclosureNoTrial(billed, period);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: billed,
                    style: LTType.inter(size: 22, weight: FontWeight.w800, color: LT.t1),
                  ),
                  TextSpan(
                    text: l.payPerPeriod(period),
                    style: LTType.inter(size: 13, weight: FontWeight.w600, color: LT.t2),
                  ),
                ]),
              ),
              const SizedBox(height: 4),
              Text(
                disclosure,
                style: LTType.inter(size: 11, color: LT.t3, height: 1.45),
              ),
            ],
          );
        }(),
        const SizedBox(height: 14),
        GestureDetector(
          onTap: disabled || _busy ? null : () => _buy(store, _selected),
          child: Opacity(
            opacity: disabled || _busy ? 0.55 : 1,
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: LT.lime,
                borderRadius: BorderRadius.circular(LTRadius.control),
              ),
              child: _busy
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5, color: LT.bg),
                        ),
                        if (_pending) ...[
                          const SizedBox(width: 10),
                          Text(
                            l.payPendingButton,
                            style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.bg),
                          ),
                        ],
                      ],
                    )
                  : Text(
                      l.paySubscribe,
                      style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.bg),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: disabled || _busy ? null : () => _restore(store),
          child: Container(
            height: 42,
            alignment: Alignment.center,
            child: Text(
              disabled ? l.payStoreUnavailable : l.payRestore,
              style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t3),
            ),
          ),
        ),
      ],
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.productId,
    required this.title,
    required this.price,
    required this.per,
    required this.selected,
    required this.onTap,
  });
  final String productId;
  final String title;
  final String price;
  final String per;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? LT.surface3 : LT.surface2,
          borderRadius: BorderRadius.circular(LTRadius.control),
          border: Border.all(color: selected ? LT.lime : LT.border, width: selected ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Container(
              width: 18, height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: selected ? LT.lime : LT.borderStrong, width: 2),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 8, height: 8,
                        decoration: const BoxDecoration(color: LT.lime, shape: BoxShape.circle),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.t1)),
                  const SizedBox(height: 2),
                  Text(per, style: LTType.inter(size: 11, color: LT.t3)),
                ],
              ),
            ),
            Text(price, style: LTType.mono(size: 14, weight: FontWeight.w700, color: LT.t1)),
          ],
        ),
      ),
    );
  }
}
