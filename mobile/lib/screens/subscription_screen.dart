// 구독 관리 — 시안 ⑧ Active, ⑨ Cancelled, ⑩ Expired 세 상태를 SubscriptionStatus 로 분기.
// Active: 자동갱신 안내 + 해지 버튼. Cancelled: 만료일 + 재구독. Expired: 재구독 CTA.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

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
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('구독 관리', style: T.h2.copyWith(fontSize: 17)),
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
    String headline;
    String body;
    Color color;
    IconData ic;
    switch (s) {
      case SubscriptionStatus.active:
        headline = 'Humming Pro · 활성';
        body = store.subscriptionRenewsAt != null
            ? '${_fmtDate(store.subscriptionRenewsAt!)}에 자동 갱신돼요'
            : '자동 갱신 활성';
        color = AppColors.lime;
        ic = Symbols.check_circle;
        break;
      case SubscriptionStatus.trial:
        headline = '무료 체험 중';
        body = store.subscriptionRenewsAt != null
            ? '${_fmtDate(store.subscriptionRenewsAt!)}에 자동 결제'
            : '7일 무료 체험';
        color = AppColors.lime;
        ic = Symbols.bolt;
        break;
      case SubscriptionStatus.cancelled:
        headline = '해지 예약됨';
        body = store.subscriptionRenewsAt != null
            ? '${_fmtDate(store.subscriptionRenewsAt!)}까지 Pro 사용 가능'
            : '만료 전까지 사용 가능';
        color = AppColors.textSecondary;
        ic = Symbols.schedule;
        break;
      case SubscriptionStatus.expired:
        headline = '구독이 만료됐어요';
        body = '다시 구독하면 클라우드 작업물이 즉시 복원돼요';
        color = AppColors.danger;
        ic = Symbols.error;
        break;
      case SubscriptionStatus.anonymous:
        headline = '구독 정보 없음';
        body = '먼저 로그인하고 결제를 시작해 주세요';
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
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('현재 권한', style: T.label.copyWith(fontSize: 11, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        row(Symbols.cloud_done, '클라우드 동기화', hasPro),
        row(Symbols.download, '무제한 내보내기 (WAV / MIDI)', hasPro),
        row(Symbols.shield, '보컬 영구 보관', hasPro),
        row(Symbols.bolt, '우선 처리 (빠른 분석)', hasPro),
      ]),
    );
  }

  Widget _actions(BuildContext context, ProjectStore store, SubscriptionStatus s) {
    if (s == SubscriptionStatus.active || s == SubscriptionStatus.trial) {
      return Column(children: [
        LimeButton(
          label: '결제 정보 관리',
          icon: Symbols.credit_card,
          onTap: () => comingSoon(context, 'App Store / Google Play 결제 관리'),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () => _confirmCancel(context, store),
          child: Container(
            height: 52, alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.transparent, borderRadius: BorderRadius.circular(26),
              border: Border.all(color: AppColors.dangerBorder),
            ),
            child: Text('구독 해지', style: T.body.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700)),
          ),
        ),
      ]);
    }
    if (s == SubscriptionStatus.cancelled) {
      return Column(children: [
        LimeButton(
          label: '해지 취소하고 계속 사용',
          onTap: () async {
            await store.mockPurchase();
          },
        ),
        const SizedBox(height: 10),
        Center(child: Text('만료일까지 모든 기능을 그대로 쓸 수 있어요',
            style: T.sub.copyWith(fontSize: 11))),
      ]);
    }
    if (s == SubscriptionStatus.expired) {
      return Column(children: [
        LimeButton(
          label: 'Pro 다시 구독하기',
          icon: Symbols.workspace_premium,
          onTap: () => showPaywallSheet(context, store, trigger: 'export'),
        ),
        const SizedBox(height: 10),
        Center(child: Text('이전 작업물은 30일 안에 클라우드에서 가져올 수 있어요',
            style: T.sub.copyWith(fontSize: 11))),
      ]);
    }
    return LimeButton(
      label: '구독 시작',
      onTap: () => showPaywallSheet(context, store, trigger: 'export'),
    );
  }

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
            Text('정말 해지하시겠어요?', style: T.h2.copyWith(fontSize: 17)),
            const SizedBox(height: 8),
            Text('만료일까지는 모든 Pro 기능을 그대로 사용하실 수 있어요.',
                style: T.sub),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(10), border: Border.all(color: AppColors.border)),
                    child: Text('취소', style: T.body.copyWith(fontWeight: FontWeight.w600)),
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
                    child: Text('해지', style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
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
