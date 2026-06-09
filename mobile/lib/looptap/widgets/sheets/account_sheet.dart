// LoopTap — My Page / Sign-in sheet (README §2). Logged out: Apple + Google
// native OAuth (Supabase). Logged in: avatar, provider chip, Pro / restore rows,
// sign out.
//
// 글로벌 Apple+Google 만 지원 (legacy auth_service.dart 와 동일). Kakao/Naver 는
// 백엔드 미연동.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/auth_service.dart';
import '../../../widgets/social_sign_in_buttons.dart';
import '../../state/loop_store.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import 'lt_modal.dart';
import 'paywall_sheet.dart';

/// AuthError → 사용자 표시용 영어 문자열 (legacy _localizedAuthError 의 LoopTap
/// 버전). LoopTap 은 L10n 미사용이라 inline 영어.
String authErrorMessage(AuthError? e, {required bool authEnabled}) {
  if (!authEnabled) return 'Sign-in is not configured in this build.';
  if (e == null) return 'Sign-in failed. Please try again.';
  switch (e.code) {
    case 'disabled':
      return 'Sign-in is not available right now.';
    case 'googleNoIdToken':
      return 'Google sign-in did not return an ID token. Try again, or use Apple sign-in.';
    case 'identityBlockedGeneric':
      return 'This email is already linked to another sign-in method. Use the original provider.';
    case 'identityBlockedSpecific':
      final providers = e.providers.join(', ');
      return 'This email is already registered with: $providers. Sign in with the original provider.';
    case 'appleCode':
      return 'Apple sign-in failed (${e.appleCode}). ${e.appleMessage ?? ''}'.trim();
    case 'generic':
    default:
      return 'Could not sign in${e.provider != null ? ' with ${e.provider}' : ''}. Please try again.';
  }
}

/// Modal sheet 위에 dialog 띄우기 — SnackBar 는 모달 아래에 깔려 안 보임.
Future<void> showAuthErrorDialog(BuildContext context, AuthError? err, {required bool authEnabled}) {
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (dctx) => AlertDialog(
      backgroundColor: LT.surface,
      title: Text('Sign-in failed', style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.danger)),
      content: SelectableText(
        authErrorMessage(err, authEnabled: authEnabled),
        style: LTType.inter(size: 13, color: LT.t1),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(),
          child: Text('OK', style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.lime)),
        ),
      ],
    ),
  );
}

Future<void> showAccountSheet(BuildContext context) {
  return showLtModal(context, width: 400, child: const _AccountSheet());
}

class _AccountSheet extends StatefulWidget {
  const _AccountSheet();
  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  String? _busyProvider; // 'apple' / 'google' — 진행 중 표시.

  Future<void> _signIn(LoopStore store, String providerId) async {
    if (_busyProvider != null) return;
    setState(() => _busyProvider = providerId);
    final ok = await store.signInWith(providerId);
    if (!mounted) return;
    setState(() => _busyProvider = null);
    if (!ok) {
      final err = store.lastAuthError;
      // 사용자 취소(err == null) 면 silent.
      if (err == null && store.authEnabled) return;
      await showAuthErrorDialog(context, err, authEnabled: store.authEnabled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<LoopStore>();
    final user = store.user;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('My page', style: LTType.inter(size: 17, weight: FontWeight.w800, color: LT.t1)),
            IconBtn(icon: LtIcons.close, tooltip: 'Close', onTap: () => Navigator.of(context).pop()),
          ],
        ),
        const SizedBox(height: 18),
        if (user != null) ..._signedIn(context, store, user) else ..._signedOut(context, store),
      ],
    );
  }

  List<Widget> _signedIn(BuildContext context, LoopStore store, Map<String, String> user) {
    final name = user['name'] ?? 'User';
    final provider = user['provider'] ?? '';
    final email = user['email'] ?? '';
    return [
      Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: const BoxDecoration(color: LT.lime, shape: BoxShape.circle),
            alignment: Alignment.center,
            child: Text(name.isNotEmpty ? name[0].toUpperCase() : 'U',
                style: LTType.inter(size: 22, weight: FontWeight.w900, color: LT.bg)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
                if (email.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: LTType.inter(size: 11, color: LT.t3)),
                ],
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: LT.surface2,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: LT.border),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(width: 7, height: 7, decoration: const BoxDecoration(color: LT.lime, shape: BoxShape.circle)),
                      const SizedBox(width: 5),
                      Text('Signed in${provider.isEmpty ? '' : ' · $provider'}',
                          style: LTType.inter(size: 10, weight: FontWeight.w700, color: LT.t2)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 18),
      const _AccRow(icon: LtIcons.cloudDone, title: 'Cloud backup', sub: 'Loops synced across devices'),
      if (store.proActive)
        const _AccRow(
          icon: LtIcons.workspacePremium,
          title: 'LoopTap Pro · active',
          sub: 'Stems · unlimited cloud',
          accent: true,
        )
      else
        _AccRow(
          icon: LtIcons.workspacePremium,
          title: 'Upgrade to Pro',
          sub: 'Stems · unlimited cloud',
          onTap: () => showPaywallSheet(context),
        ),
      _AccRow(
        icon: LtIcons.restore,
        title: 'Restore purchases',
        sub: store.iapEnabled ? '' : 'Store unavailable',
        onTap: store.iapEnabled ? () => store.restorePurchases() : null,
      ),
      const SizedBox(height: 10),
      GestureDetector(
        onTap: () => store.signOut(),
        child: Container(
          height: 46,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(LTRadius.control),
            border: Border.all(color: LT.border),
          ),
          child: Text('Sign out', style: LTType.inter(size: 14, weight: FontWeight.w700, color: LT.danger)),
        ),
      ),
    ];
  }

  List<Widget> _signedOut(BuildContext context, LoopStore store) {
    return [
      Column(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: LT.surface2,
              shape: BoxShape.circle,
              border: Border.all(color: LT.border),
            ),
            child: const Center(child: Ms(LtIcons.person, size: 30, color: LT.t2)),
          ),
          const SizedBox(height: 10),
          Text('Sign in to LoopTap', style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
          const SizedBox(height: 4),
          Text('Back up your loops and sync across devices.',
              textAlign: TextAlign.center, style: LTType.inter(size: 12, color: LT.t2)),
        ],
      ),
      const SizedBox(height: 18),
      // 공식 브랜드 가이드라인 준수 버튼 (legacy widgets/social_sign_in_buttons.dart 재사용).
      // Apple HIG: white background variant, Google Identity: dark variant +4색 G 로고.
      _SocialButtonWrapper(
        busy: _busyProvider == 'apple',
        disabled: _busyProvider != null && _busyProvider != 'apple',
        child: AppleSignInButton(
          label: 'Continue with Apple',
          onPressed: () => _signIn(store, 'apple'),
        ),
      ),
      _SocialButtonWrapper(
        busy: _busyProvider == 'google',
        disabled: _busyProvider != null && _busyProvider != 'google',
        child: GoogleSignInButton(
          label: 'Continue with Google',
          onPressed: () => _signIn(store, 'google'),
        ),
      ),
      const SizedBox(height: 3),
      GestureDetector(
        onTap: _busyProvider == null ? () => Navigator.of(context).pop() : null,
        child: Container(
          height: 42,
          alignment: Alignment.center,
          child: Text('Continue as guest', style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t3)),
        ),
      ),
    ];
  }
}

/// busy / disabled 상태를 공식 브랜드 버튼 위에 입히는 얇은 wrapper.
/// (legacy 버튼은 자체적인 로딩/비활성 상태가 없어서 IgnorePointer + opacity 로 처리.)
class _SocialButtonWrapper extends StatelessWidget {
  const _SocialButtonWrapper({
    required this.child,
    this.busy = false,
    this.disabled = false,
  });
  final Widget child;
  final bool busy;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: busy || disabled,
      child: Opacity(
        opacity: disabled ? 0.45 : 1,
        child: Stack(
          alignment: Alignment.center,
          children: [
            child,
            if (busy)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: LT.bg),
              ),
          ],
        ),
      ),
    );
  }
}

class _AccRow extends StatelessWidget {
  const _AccRow({
    required this.icon,
    required this.title,
    required this.sub,
    this.onTap,
    this.accent = false,
  });
  final IconData icon;
  final String title;
  final String sub;
  final VoidCallback? onTap;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null && !accent;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: Container(
          height: 54,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: LT.surface2,
            borderRadius: BorderRadius.circular(LTRadius.control),
            border: Border.all(color: accent ? LT.lime : LT.border),
          ),
          child: Row(
            children: [
              Ms(icon, size: 20, color: accent || onTap != null ? LT.lime : LT.t2),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: LTType.inter(size: 13, weight: FontWeight.w700, color: LT.t1)),
                    if (sub.isNotEmpty) Text(sub, style: LTType.inter(size: 11, color: LT.t3)),
                  ],
                ),
              ),
              if (disabled) const Ms(LtIcons.lock, size: 16, color: LT.t3),
            ],
          ),
        ),
      ),
    );
  }
}
