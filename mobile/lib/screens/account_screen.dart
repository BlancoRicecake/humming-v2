// 계정 화면 — 시안 ⑥ Anonymous/Active 와 ⑦ Expired 둘을 SubscriptionStatus 로 분기.
//
// 진입: SongsScreen 우상단 person chip → push.
// 구성: 헤더(상태 배지 + 이메일/이름) + 구독 카드 + 메뉴(구독 관리/문의/FAQ/약관/개인정보/로그아웃).
// 개발자 모드: 디버그 빌드일 때만 보이는 상태 토글(클릭 한 번에 Anonymous → Trial → Active → Cancelled → Expired 순환).
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/account_sheets.dart';
import 'static_screens.dart';
import 'subscription_screen.dart';

class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProjectStore>();
    final loggedIn = store.accountEmail != null;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text('계정', style: T.h2.copyWith(fontSize: 17)),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            _header(context, store, loggedIn),
            const SizedBox(height: 18),
            _subscriptionCard(context, store),
            const SizedBox(height: 18),
            _menu(context, store, loggedIn),
            if (kDebugMode) ...[
              const SizedBox(height: 28),
              _devModeCard(context, store),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, ProjectStore store, bool loggedIn) {
    final email = store.accountEmail;
    final provider = store.accountProvider;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Container(
          width: 56, height: 56, alignment: Alignment.center,
          decoration: BoxDecoration(
            color: loggedIn ? AppColors.activeLane : AppColors.bg,
            shape: BoxShape.circle,
            border: Border.all(color: loggedIn ? AppColors.lime : AppColors.border, width: loggedIn ? 1.5 : 1),
          ),
          child: Icon(Symbols.person, size: 28, color: loggedIn ? AppColors.lime : AppColors.textSecondary),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(loggedIn ? (email ?? '—') : '로그인되지 않음',
                style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 4),
            Text(loggedIn ? (provider != null ? '${provider.toUpperCase()} 계정' : '계정 연동됨') : '로그인하면 결제와 동기화가 가능해요',
                style: T.sub),
          ]),
        ),
        if (!loggedIn)
          GestureDetector(
            onTap: () => showLoginSheet(context, store),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppColors.lime, borderRadius: BorderRadius.circular(20),
              ),
              child: Text('로그인',
                  style: T.label.copyWith(color: AppColors.bg, fontWeight: FontWeight.w700, fontSize: 12)),
            ),
          ),
      ]),
    );
  }

  Widget _subscriptionCard(BuildContext context, ProjectStore store) {
    final s = store.subscription;
    final renews = store.subscriptionRenewsAt;
    String title;
    String sub;
    Color badgeColor;
    IconData ic;
    switch (s) {
      case SubscriptionStatus.anonymous:
        title = '무료 플랜';
        sub = '내보내기와 클라우드 동기화는 Pro 에서 잠금이 풀려요';
        badgeColor = AppColors.textTertiary;
        ic = Symbols.lock;
        break;
      case SubscriptionStatus.trial:
        title = '무료 체험 중';
        sub = renews != null ? '${_fmtDate(renews)}에 자동 결제 시작' : '7일 체험';
        badgeColor = AppColors.lime;
        ic = Symbols.bolt;
        break;
      case SubscriptionStatus.active:
        title = 'Humming Pro';
        sub = renews != null ? '${_fmtDate(renews)} 자동 갱신' : '모든 기능 활성화됨';
        badgeColor = AppColors.lime;
        ic = Symbols.check_circle;
        break;
      case SubscriptionStatus.cancelled:
        title = 'Pro · 해지 예약';
        sub = renews != null ? '${_fmtDate(renews)}까지 이용 가능' : '만료 전까지 사용 가능';
        badgeColor = AppColors.textSecondary;
        ic = Symbols.schedule;
        break;
      case SubscriptionStatus.expired:
        title = '구독이 만료됐어요';
        sub = '다시 구독하면 즉시 복원돼요';
        badgeColor = AppColors.danger;
        ic = Symbols.error;
        break;
    }
    return GestureDetector(
      onTap: () {
        if (s == SubscriptionStatus.anonymous) {
          showPaywallSheet(context, store, trigger: 'export');
        } else {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SubscriptionScreen()));
        }
      },
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          Container(
            width: 44, height: 44, alignment: Alignment.center,
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(ic, color: badgeColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Text(title, style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 15)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: badgeColor.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(4)),
                child: Text(s.label.toUpperCase(),
                    style: T.label.copyWith(color: badgeColor, fontSize: 9, fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 4),
            Text(sub, style: T.sub),
          ])),
          const Icon(Symbols.chevron_right, color: AppColors.textTertiary, size: 22),
        ]),
      ),
    );
  }

  Widget _menu(BuildContext context, ProjectStore store, bool loggedIn) {
    Widget tile(IconData ic, String title, {String? sub, VoidCallback? onTap, bool danger = false}) {
      final c = danger ? AppColors.danger : AppColors.textPrimary;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: danger ? AppColors.dangerBorder : AppColors.border),
          ),
          child: Row(children: [
            Icon(ic, color: c, size: 20),
            const SizedBox(width: 14),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: T.body.copyWith(fontWeight: FontWeight.w600, color: c)),
              if (sub != null) ...[
                const SizedBox(height: 2),
                Text(sub, style: T.sub.copyWith(fontSize: 11)),
              ],
            ])),
            const Icon(Symbols.chevron_right, color: AppColors.textTertiary, size: 20),
          ]),
        ),
      );
    }

    return Column(children: [
      if (store.subscription != SubscriptionStatus.anonymous)
        tile(Symbols.workspace_premium, '구독 관리', onTap: () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SubscriptionScreen()));
        }),
      if (store.subscription == SubscriptionStatus.expired)
        tile(Symbols.cloud_download, '클라우드에서 가져오기', sub: '만료 전 작업물 30일 동안 보관됨', onTap: () {
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CloudDownloadScreen()));
        }),
      tile(Symbols.help, 'FAQ', onTap: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FaqScreen()));
      }),
      tile(Symbols.support_agent, '문의하기', onTap: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ContactScreen()));
      }),
      tile(Symbols.gavel, '서비스 약관', onTap: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TermsScreen()));
      }),
      tile(Symbols.shield, '개인정보처리방침', onTap: () {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PrivacyScreen()));
      }),
      if (loggedIn)
        tile(Symbols.logout, '로그아웃', danger: true, onTap: () => showLogoutConfirm(context, store)),
    ]);
  }

  Widget _devModeCard(BuildContext context, ProjectStore store) {
    const order = [
      SubscriptionStatus.anonymous,
      SubscriptionStatus.trial,
      SubscriptionStatus.active,
      SubscriptionStatus.cancelled,
      SubscriptionStatus.expired,
    ];
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.lime.withValues(alpha: 0.4)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Icon(Symbols.code, color: AppColors.lime, size: 16),
          const SizedBox(width: 8),
          Text('개발자 모드', style: T.label.copyWith(color: AppColors.lime, fontSize: 11, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 10),
        Text('구독 상태 (디버그 빌드만 노출)', style: T.sub.copyWith(fontSize: 11)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final s in order)
            GestureDetector(
              onTap: () => store.devSetSubscription(s),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: store.subscription == s ? AppColors.lime : AppColors.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: store.subscription == s ? AppColors.lime : AppColors.border),
                ),
                child: Text(s.label,
                    style: T.label.copyWith(fontSize: 10, color: store.subscription == s ? AppColors.bg : AppColors.textPrimary)),
              ),
            ),
        ]),
      ]),
    );
  }
}

String _fmtDate(DateTime d) =>
    '${d.year}.${d.month.toString().padLeft(2, '0')}.${d.day.toString().padLeft(2, '0')}';
