// LoopTap — Pro paywall sheet. humtrack_pro_monthly_v2 / yearly 구독을 띄움.
// 가격은 IapPricing 헬퍼가 스토어 ProductDetails 우선, 폴백 KRW 상수.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../services/iap_pricing.dart';
import '../../../services/iap_service.dart';
import '../../app.dart' show rootMessengerKey;
import '../../state/loop_store.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'account_sheet.dart';
import 'lt_modal.dart';

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

class _PaywallSheet extends StatefulWidget {
  const _PaywallSheet({required this.trigger});

  final PaywallTrigger trigger;

  @override
  State<_PaywallSheet> createState() => _PaywallSheetState();
}

class _PaywallSheetState extends State<_PaywallSheet> {
  bool _busy = false;
  String _selected = kProductYearly;

  @override
  void initState() {
    super.initState();
    // 시트 진입 시점에 ProductDetails 로드 — 라벨이 KRW 폴백 → 스토어 가격으로 갱신.
    final store = context.read<LoopStore>();
    store.loadProducts().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _buy(LoopStore store, String productId) async {
    if (_busy) return;
    // legacy paywall (widgets/account/paywall_sheet.dart:64) 와 동일 — 로그인이
    // 안 돼 있으면 /iap/verify 가 401 로 떨어진다. 결제 진입 전에 로그인 강제.
    if (!store.isSignedIn) {
      await showAccountSheet(context);
      if (!mounted) return;
      if (!store.isSignedIn) return; // 사용자가 로그인 안 하고 닫음 — 조용히 종료.
    }
    setState(() => _busy = true);
    // legacy 의 Completer + listener 패턴 — buy() 호출 직전에 listener 부착,
    // 해당 productId 의 결과를 60초 timeout 으로 await.
    final completer = Completer<bool>();
    late StreamSubscription sub;
    sub = IapService.instance.onPurchaseResult.listen((r) {
      if (r.productId != productId) return;
      if (!completer.isCompleted) completer.complete(r.ok);
      sub.cancel();
    });
    final launched = productId == kProductYearly ? await store.buyYearly() : await store.buyMonthly();
    bool ok;
    if (!launched) {
      sub.cancel();
      ok = false;
    } else {
      ok = await completer.future.timeout(
        const Duration(seconds: 60),
        onTimeout: () { sub.cancel(); return false; },
      );
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      Navigator.of(context).maybePop();
    } else {
      final reason = !store.iapEnabled
          ? 'Store unavailable on this device.'
          : 'Could not complete purchase. Please try again.';
      // rootMessenger 사용 — paywall (showGeneralDialog) 위에서도 보이도록.
      rootMessengerKey.currentState?.showSnackBar(SnackBar(
        backgroundColor: LT.surface2,
        content: Text(reason, style: LTType.inter(size: 13, color: LT.t1)),
      ));
    }
  }

  Future<void> _restore(LoopStore store) async {
    if (_busy) return;
    // restore 도 verify 가 필요 — 로그인 게이트.
    if (!store.isSignedIn) {
      await showAccountSheet(context);
      if (!mounted) return;
      if (!store.isSignedIn) return;
    }
    setState(() => _busy = true);
    await store.restorePurchases();
    // restore 결과는 onPurchaseResult 로 흐름 → 4초 후 안전 폴백으로 _busy 해제.
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => _busy = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LoopStore>();
    final disabled = !store.iapEnabled;
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
                Text('LoopTap Pro', style: LTType.inter(size: 17, weight: FontWeight.w800, color: LT.t1)),
              ],
            ),
            IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).maybePop()),
          ],
        ),
        // 진입점 contextual banner — Export 같은 특정 기능에서 들어왔을 때
        // "왜 결제 화면이 떴는지" 즉시 인지시키는 핀포인트 메시지.
        if (widget.trigger.hint(L10n.of(context)) != null) ...[
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
                    widget.trigger.hint(L10n.of(context))!,
                    style: LTType.inter(size: 12, weight: FontWeight.w600, color: LT.t1, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Text(
          'Unlock stems, unlimited cloud loops, and priority sync.',
          style: LTType.inter(size: 12, color: LT.t2, height: 1.5),
        ),
        const SizedBox(height: 18),
        _PlanCard(
          productId: kProductYearly,
          title: 'Yearly',
          price: IapPricing.yearlyLabel(),
          per: '${IapPricing.yearlyAsMonthlyLabel()} / month',
          selected: _selected == kProductYearly,
          onTap: () => setState(() => _selected = kProductYearly),
        ),
        const SizedBox(height: 10),
        _PlanCard(
          productId: kProductMonthly,
          title: 'Monthly',
          price: IapPricing.monthlyLabel(),
          per: 'Billed every month',
          selected: _selected == kProductMonthly,
          onTap: () => setState(() => _selected = kProductMonthly),
        ),
        const SizedBox(height: 16),
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
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: LT.bg),
                    )
                  : Text(
                      'Start ${IapPricing.trialDays}-day free trial',
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
              disabled ? 'Store unavailable' : 'Restore purchases',
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
  final VoidCallback onTap;

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
