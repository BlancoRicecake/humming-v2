// 계정 정보 상세 — AccountScreen 의 헤더 카드 탭 시 진입.
// 이메일/provider/가입일 등 표시 + 맨 아래 회원 탈퇴 버튼.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/auth_service.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';

class AccountDetailScreen extends StatelessWidget {
  const AccountDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<ProjectStore>();
    final email = store.accountEmail;
    final provider = store.accountProvider;
    final userId = AuthService.instance.current.userId;
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
        title: Text(t.accountDetailTitle, style: T.h2.copyWith(fontSize: 17)),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            _infoCard(
              icon: Symbols.mail,
              label: t.labelEmail,
              value: email ?? '—',
            ),
            const SizedBox(height: 10),
            _infoCard(
              icon: Symbols.fingerprint,
              label: t.labelSignInMethod,
              value: _providerLabel(provider),
            ),
            if (userId != null) ...[
              const SizedBox(height: 10),
              _infoCard(
                icon: Symbols.tag,
                label: t.labelAccountId,
                value: userId,
                mono: true,
              ),
            ],
            const SizedBox(height: 32),
            _withdrawSection(context, store),
          ],
        ),
      ),
    );
  }

  Widget _infoCard({
    required IconData icon,
    required String label,
    required String value,
    bool mono = false,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(children: [
        Icon(icon, color: AppColors.textSecondary, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: T.label.copyWith(fontSize: 11, color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            SelectableText(
              value,
              style: T.body.copyWith(
                fontSize: mono ? 12 : 14,
                fontWeight: FontWeight.w600,
                fontFamily: mono ? 'Menlo' : null,
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _withdrawSection(BuildContext context, ProjectStore store) {
    final t = L10n.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(
        t.withdrawHint,
        style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary, height: 1.5),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 14),
      GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _confirmWithdraw(context, store),
        child: Container(
          height: 52,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppColors.dangerBorder),
          ),
          child: Text(
            t.withdrawCta,
            style: T.body.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    ]);
  }

  Future<void> _confirmWithdraw(BuildContext context, ProjectStore store) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black54,
      builder: (dctx) {
        final t = L10n.of(dctx);
        return AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(t.withdrawConfirmTitle, style: T.h2.copyWith(fontSize: 17)),
        content: Text(
          t.withdrawConfirmBody,
          style: T.body.copyWith(fontSize: 13, color: AppColors.textSecondary, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(t.cancel, style: T.body.copyWith(color: AppColors.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(t.withdrawConfirmAction, style: T.body.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700)),
          ),
        ],
      );
      },
    );
    if (ok != true || !context.mounted) return;
    // 진행 표시 + 실 탈퇴.
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: SizedBox(
          width: 36, height: 36,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: AppColors.lime),
        ),
      ),
    );
    final err = await store.deleteAccount();
    // 로컬 + Supabase 정리 후 모든 화면 pop.
    if (!context.mounted) return;
    nav.pop(); // close spinner
    if (err != null) {
      final l = L10n.of(context);
      String msg;
      switch (err.code) {
        case 'noSession':
          msg = l.accountErrNoSession;
          break;
        case 'serverDelete':
          final det = (err.detail != null && err.detail!.isNotEmpty) ? '\n${err.detail}' : '';
          msg = l.accountErrServerDelete(err.status ?? 0, det);
          break;
        case 'raw':
        default:
          msg = err.raw ?? '';
          break;
      }
      messenger.showSnackBar(SnackBar(
        content: Text(l.withdrawFailed(msg), style: T.body.copyWith(fontSize: 12)),
        backgroundColor: AppColors.danger,
      ));
      return;
    }
    // 성공 — Songs 화면까지 pop.
    nav.popUntil((r) => r.isFirst);
    messenger.showSnackBar(SnackBar(
      content: Text(L10n.of(context).withdrawCompleted, style: T.body.copyWith(fontSize: 12)),
      backgroundColor: AppColors.surface,
    ));
  }

  String _providerLabel(String? provider) {
    if (provider == null) return '—';
    switch (provider.toLowerCase()) {
      case 'apple':    return 'Apple';
      case 'google':   return 'Google';
      case 'kakao':    return '카카오';
      case 'naver':    return '네이버';
      case 'github':   return 'GitHub';
      case 'facebook': return 'Facebook';
      default:         return provider;
    }
  }
}
