// 구독 관리 — 시안 ⑧ Active, ⑨ Cancelled, ⑩ Expired 세 상태를 SubscriptionStatus 로 분기.
// IAP 정책상 구독 변경/해지/결제수단은 스토어에서만 가능 — 앱 안에는 안내 문구만.
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/iap_pricing.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/account_sheets.dart';
import '../widgets/common.dart';

class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProjectStore>();
    final s = store.subscription;
    final t = L10n.of(context);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(t.subScreenTitle, style: T.h2.copyWith(fontSize: 17)),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            _statusCard(context, store, s),
            const SizedBox(height: 18),
            _featuresCard(s),
            const SizedBox(height: 18),
            _actions(context, store, s),
          ],
        ),
      ),
    );
  }

  Widget _statusCard(BuildContext context, ProjectStore store, SubscriptionStatus s) {
    final t = L10n.of(context);
    String headline;
    String body;
    Color color;
    IconData ic;
    switch (s) {
      case SubscriptionStatus.active:
        headline = t.subStatusActive;
        body = store.subscriptionRenewsAt != null
            ? t.subStatusActiveRenewsOn(_fmtDate(store.subscriptionRenewsAt!))
            : t.subStatusActiveAutoOn;
        color = AppColors.lime;
        ic = Symbols.check_circle;
        break;
      case SubscriptionStatus.trial:
        headline = t.subTrial;
        body = store.subscriptionRenewsAt != null
            ? t.subStatusTrialBillsOn(_fmtDate(store.subscriptionRenewsAt!))
            : t.subStatusTrialNDays(IapPricing.trialDays);
        color = AppColors.lime;
        ic = Symbols.bolt;
        break;
      case SubscriptionStatus.cancelled:
        headline = t.subStatusCancelled;
        body = store.subscriptionRenewsAt != null
            ? t.subStatusCancelledUntil(_fmtDate(store.subscriptionRenewsAt!))
            : t.subCancelledUntilExpiry;
        color = AppColors.textSecondary;
        ic = Symbols.schedule;
        break;
      case SubscriptionStatus.expired:
        headline = t.subExpired;
        body = t.subStatusExpiredBody;
        color = AppColors.danger;
        ic = Symbols.error;
        break;
      case SubscriptionStatus.anonymous:
        headline = t.subStatusAnonymous;
        body = t.subStatusAnonymousBody;
        color = AppColors.textTertiary;
        ic = Symbols.lock;
        break;
    }
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.2),
      ),
      child: Row(children: [
        Container(
          width: 52, height: 52, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(ic, color: color, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(headline, style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 4),
          Text(body, style: T.sub),
        ])),
      ]),
    );
  }

  Widget _featuresCard(SubscriptionStatus s) {
    final hasPro = s.hasProAccess;
    Widget row(IconData ic, String label, bool on) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(children: [
        Container(
          width: 28, height: 28, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? AppColors.activeLane : AppColors.bg,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(ic, color: on ? AppColors.lime : AppColors.textTertiary, size: 16),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label,
            style: T.body.copyWith(fontWeight: FontWeight.w500,
                color: on ? AppColors.textPrimary : AppColors.textTertiary))),
        Icon(on ? Symbols.check : Symbols.lock, size: 18,
            color: on ? AppColors.lime : AppColors.textTertiary),
      ]),
    );
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Builder(builder: (context) {
        final t = L10n.of(context);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.subCurrentEntitlements, style: T.label.copyWith(fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        row(Symbols.cloud_done, t.subFeatureCloudSync, hasPro),
        row(Symbols.download, t.subFeatureExport, hasPro),
        row(Symbols.shield, t.subFeatureVocalBackup, hasPro),
        row(Symbols.bolt, t.subFeaturePriority, hasPro),
      ]);
      }),
    );
  }

  Widget _actions(BuildContext context, ProjectStore store, SubscriptionStatus s) {
    final t = L10n.of(context);
    if (s == SubscriptionStatus.active || s == SubscriptionStatus.trial) {
      return _storeNotice(t.subStoreNoticeActive(_storeName()));
    }
    if (s == SubscriptionStatus.cancelled) {
      return _storeNotice(t.subStoreNoticeCancelled(_storeName()));
    }
    if (s == SubscriptionStatus.expired) {
      return Column(children: [
        LimeButton(
          label: t.subResubCta,
          icon: Symbols.workspace_premium,
          onTap: () => showPaywallSheet(context, store, trigger: 'export'),
        ),
        const SizedBox(height: 10),
        Center(child: Text(t.subResubHint, style: T.sub.copyWith(fontSize: 11))),
      ]);
    }
    return LimeButton(
      label: t.subStartCta,
      onTap: () => showPaywallSheet(context, store, trigger: 'export'),
    );
  }

  String _storeName() => Platform.isIOS ? 'App Store' : 'Google Play';

  Widget _storeNotice(String msg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Symbols.info, size: 16, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(msg,
                style: T.sub.copyWith(fontSize: 12, height: 1.5, color: AppColors.textSecondary)),
          ),
        ]),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            onTap: _openStoreSubscriptions,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: AppColors.bg,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Symbols.open_in_new, size: 13, color: AppColors.textPrimary),
                const SizedBox(width: 6),
                Text(_openStoreLabel(),
                    style: T.label.copyWith(fontSize: 12, color: AppColors.textPrimary, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        ),
      ]),
    );
  }

  /// 디바이스 OS 에 맞춰 store 구독 관리 페이지 열기.
  /// iOS: itms-apps deep link → App Store 앱 직접 진입
  /// Android: https → Play Store 자동 처리
  Future<void> _openStoreSubscriptions() async {
    final url = Platform.isIOS
        ? Uri.parse('itms-apps://apps.apple.com/account/subscriptions')
        : Uri.parse('https://play.google.com/store/account/subscriptions');
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      // fallback — https 로 재시도
      await launchUrl(Uri.parse(
        Platform.isIOS
            ? 'https://apps.apple.com/account/subscriptions'
            : 'https://play.google.com/store/account/subscriptions',
      ));
    }
  }

  String _openStoreLabel() => Platform.isIOS
      ? 'App Store 에서 관리'
      : 'Google Play 에서 관리';

  // ignore: unused_element
  void _confirmCancel(BuildContext context, ProjectStore store) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (dctx) => Dialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(L10n.of(dctx).subCancelConfirmTitle, style: T.h2.copyWith(fontSize: 17)),
            const SizedBox(height: 8),
            Text(L10n.of(dctx).subCancelConfirmBody,
                style: T.sub),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
                    child: Text(L10n.of(dctx).cancel, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () { store.mockCancel(); Navigator.pop(dctx); },
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.danger, borderRadius: BorderRadius.circular(10)),
                    child: Text(L10n.of(dctx).subCancelConfirmAction, style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

String _fmtDate(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
