// 구독 관리 — 시안 ⑧ Active, ⑨ Cancelled, ⑩ Expired 세 상태를 SubscriptionStatus 로 분기.
// IAP 정책상 구독 변경/해지/결제수단은 스토어에서만 가능 — 앱 안에는 안내 문구만.
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:dio/dio.dart';

import '../api/engine_api.dart';
import '../l10n/generated/app_localizations.dart';
import '../services/auth_service.dart';
import '../services/iap_pricing.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/account_sheets.dart';
import '../widgets/common.dart';

// ─── 구매 이력 데이터 모델 ────────────────────────────────────────────────
class _HistoryItem {
  const _HistoryItem({
    required this.productId,
    required this.status,
    required this.startedAt,
    this.expiresAt,
    this.transactionId,
    required this.store,
  });
  final String productId;
  final String status;
  final DateTime? startedAt;
  final DateTime? expiresAt;
  final String? transactionId;
  final String store;

  static _HistoryItem fromJson(Map<String, dynamic> j) => _HistoryItem(
        productId: (j['product_id'] ?? '') as String,
        status: (j['status'] ?? 'expired') as String,
        startedAt: _parseDt(j['started_at']),
        expiresAt: _parseDt(j['expires_at']),
        transactionId: j['transaction_id'] as String?,
        store: (j['store'] ?? 'app_store') as String,
      );

  static DateTime? _parseDt(dynamic v) {
    if (v == null) return null;
    try { return DateTime.parse(v as String).toLocal(); } catch (_) { return null; }
  }
}

class SubscriptionScreen extends StatefulWidget {
  const SubscriptionScreen({super.key});

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  List<_HistoryItem>? _history;
  bool _historyLoading = false;
  String? _historyError;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() { _historyLoading = true; _historyError = null; });
    try {
      final token = await AuthService.instance.currentAccessToken();
      if (token == null) {
        setState(() { _historyLoading = false; _history = []; });
        return;
      }
      final dio = Dio(BaseOptions(
        baseUrl: EngineConfig.baseUrl,
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 15),
        validateStatus: (_) => true,
      ));
      final res = await dio.get<Map<String, dynamic>>(
        '/iap/history',
        options: Options(headers: {'Authorization': 'Bearer $token'}),
      );
      if (res.statusCode == 200) {
        final items = ((res.data?['items'] ?? []) as List)
            .map((e) => _HistoryItem.fromJson(e as Map<String, dynamic>))
            .toList();
        setState(() { _history = items; _historyLoading = false; });
      } else {
        setState(() { _historyError = 'HTTP ${res.statusCode}'; _historyLoading = false; _history = []; });
      }
    } catch (e) {
      setState(() { _historyError = e.toString(); _historyLoading = false; _history = []; });
    }
  }

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
            const SizedBox(height: 24),
            _historyCard(context),
            const SizedBox(height: 18),
            _receiptButton(context),
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

  // ─── 구매 이력 카드 ────────────────────────────────────────────────────
  Widget _historyCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(L10n.of(context).subHistoryTitle,
                  style: T.label.copyWith(fontSize: 11, color: AppColors.textSecondary)),
            ),
            if (_historyLoading)
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: AppColors.textTertiary),
              )
            else
              GestureDetector(
                onTap: _loadHistory,
                child: const Icon(Symbols.refresh, size: 16, color: AppColors.textTertiary),
              ),
          ]),
          const SizedBox(height: 8),
          if (_historyLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.textTertiary),
              )),
            )
          else if (_historyError != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Text(L10n.of(context).subHistoryLoadFailed,
                    style: T.sub.copyWith(color: AppColors.textTertiary)),
              ),
            )
          else if (_history == null || _history!.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: Text(L10n.of(context).subHistoryEmpty,
                    style: T.sub.copyWith(color: AppColors.textTertiary)),
              ),
            )
          else
            ...(_history!.map((item) => _historyRow(context, item))),
        ],
      ),
    );
  }

  Widget _historyRow(BuildContext context, _HistoryItem item) {
    final t = L10n.of(context);
    final planLabel = item.productId.contains('yearly') ? t.subPlanYearly : t.subPlanMonthly;
    final statusLabel = _statusLabel(context, item.status);
    final statusColor = _statusColor(item.status);
    final startedStr = item.startedAt != null ? _fmtDate(item.startedAt!) : '-';
    final txShort = item.transactionId != null && item.transactionId!.length >= 6
        ? '...${item.transactionId!.substring(item.transactionId!.length - 6)}'
        : (item.transactionId ?? '-');

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 32, height: 32, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.bg, borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(Symbols.receipt_long, size: 16, color: AppColors.textSecondary),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(planLabel,
                  style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w600))),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(statusLabel,
                    style: T.label.copyWith(fontSize: 10, color: statusColor)),
              ),
            ]),
            const SizedBox(height: 3),
            Text(t.subHistoryRowStarted(startedStr), style: T.sub.copyWith(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 2),
            GestureDetector(
              onTap: item.transactionId != null ? () {
                Clipboard.setData(ClipboardData(text: item.transactionId!));
                if (context.mounted) {
                  infoToast(context, t.subHistoryTxCopied);
                }
              } : null,
              child: Row(children: [
                Text(t.subHistoryRowTxId(txShort),
                    style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary)),
                if (item.transactionId != null) ...[
                  const SizedBox(width: 4),
                  const Icon(Symbols.content_copy, size: 11, color: AppColors.textTertiary),
                ],
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  String _statusLabel(BuildContext context, String status) {
    final t = L10n.of(context);
    switch (status) {
      case 'active': return t.subBadgeActive;
      case 'trial': return t.subBadgeTrial;
      case 'cancelled': return t.subBadgeCancelled;
      case 'expired': return t.subBadgeExpired;
      default: return status;
    }
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'active':
      case 'trial': return AppColors.lime;
      case 'cancelled': return AppColors.textSecondary;
      case 'expired': return AppColors.danger;
      default: return AppColors.textTertiary;
    }
  }

  // ─── 영수증 확인 버튼 ─────────────────────────────────────────────────
  Widget _receiptButton(BuildContext context) {
    final t = L10n.of(context);
    final label = Platform.isIOS ? t.subReceiptButtonIos : t.subReceiptButtonAndroid;
    return GestureDetector(
      onTap: _openReceiptPage,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          const Icon(Symbols.receipt, size: 18, color: AppColors.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                style: T.body.copyWith(fontSize: 13, fontWeight: FontWeight.w500)),
          ),
          const Icon(Symbols.open_in_new, size: 15, color: AppColors.textTertiary),
        ]),
      ),
    );
  }

  Future<void> _openReceiptPage() async {
    final uri = Platform.isIOS
        ? Uri.parse('itms-apps://apps.apple.com/account/subscriptions')
        : Uri.parse('https://play.google.com/store/account/orderhistory');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      final fallback = Platform.isIOS
          ? Uri.parse('https://apps.apple.com/account/subscriptions')
          : Uri.parse('https://play.google.com/store/account/orderhistory');
      await launchUrl(fallback);
    }
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
                Text(_openStoreLabel(context),
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

  String _openStoreLabel(BuildContext context) {
    final l = L10n.of(context);
    return Platform.isIOS ? l.subOpenStoreIos : l.subOpenStoreAndroid;
  }

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
                  onTap: () { if (kDebugMode) store.mockCancel(); Navigator.pop(dctx); },
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
