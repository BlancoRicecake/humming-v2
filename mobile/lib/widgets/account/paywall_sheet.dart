// ③ Paywall — Pro 구독 결제 시트. trigger 별 헤더 카피 분기.
part of '../account_sheets.dart';

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
