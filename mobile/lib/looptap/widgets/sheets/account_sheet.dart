// LoopTap — My Page / Sign-in sheet. Logged out: Apple + Google native OAuth
// (Supabase) plus a discreet "Sign in with email" path (review accounts only).
// Logged in: avatar, provider chip, Pro/Restore rows, sign out.
//
// 글로벌 Apple+Google 만 지원 (legacy auth_service.dart 와 동일). Kakao/Naver 는
// 백엔드 미연동. Email/password 는 스토어 리뷰용 사전 생성 계정 전용 — 백엔드
// 가 public sign-up 을 차단한 상태에서만 안전하게 노출.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../services/auth_service.dart';
import '../../app.dart' show rootMessengerKey;
import '../../state/loop_store.dart';
import '../../theme/atoms.dart';
import '../../theme/tokens.dart';
import '../social_sign_in_buttons.dart';
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
  String? _busyProvider; // 'apple' / 'google' / 'email' — 진행 중 표시.

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

  /// Email sign-in 진입 — _EmailLoginForm 이 직접 호출.
  Future<bool> _signInEmail(LoopStore store, String email, String pw) async {
    if (_busyProvider != null) return false;
    setState(() => _busyProvider = 'email');
    final ok = await store.signInWithEmail(email, pw);
    if (!mounted) return ok;
    setState(() => _busyProvider = null);
    if (!ok) {
      await showAuthErrorDialog(context, store.lastAuthError, authEnabled: store.authEnabled);
    }
    return ok;
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
        if (user != null)
          ..._signedIn(context, store, user)
        else
          _SignedOutView(
            busyProvider: _busyProvider,
            onSocial: (providerId) => _signIn(store, providerId),
            onEmail: (email, pw) => _signInEmail(store, email, pw),
          ),
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
      // TODO: Cloud backup 기능 미구현 — 백엔드 sync 연결 후 노출.
      // const _AccRow(icon: LtIcons.cloudDone, title: 'Cloud backup', sub: 'Loops synced across devices'),
      if (store.proActive)
        const _AccRow(
          icon: LtIcons.workspacePremium,
          title: 'HumTrack Pro · active',
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
        onTap: store.iapEnabled ? () => _handleRestore(context, store) : null,
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
}

/// Restore purchases 처리 — 시각 피드백 제공. proActive 변화 전/후를 비교해
/// 새로 복원된 경우와 이미 활성인 경우, 활성 구독 없음을 구분해서 안내.
///
/// rootMessenger 사용 — account sheet (showGeneralDialog) 위에서도 보이도록.
Future<void> _handleRestore(BuildContext context, LoopStore store) async {
  final wasActive = store.proActive;
  await store.restorePurchases();
  if (!context.mounted) return;
  final isActive = store.proActive;
  final String msg;
  if (isActive && !wasActive) {
    msg = 'Pro restored. Welcome back!';
  } else if (isActive) {
    msg = 'You are already Pro.';
  } else {
    msg = 'No active subscription found.';
  }
  rootMessengerKey.currentState
    ?..clearSnackBars()
    ..showSnackBar(SnackBar(
      backgroundColor: LT.surface2,
      content: Text(msg, style: LTType.inter(size: 13, color: LT.t1)),
      duration: const Duration(seconds: 3),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.all(16),
    ));
}

/// Logged-out view: 공식 Apple/Google 브랜드 버튼 + 보일 듯 말 듯한 email login
/// 진입 ("Sign in with email"). public sign-up 은 백엔드에서 차단되어 있으므로
/// 사전 생성된 review 계정만 이 path 로 로그인 가능 — 사인업 버튼은 의도적
/// 으로 없음.
class _SignedOutView extends StatefulWidget {
  const _SignedOutView({
    required this.busyProvider,
    required this.onSocial,
    required this.onEmail,
  });
  final String? busyProvider;
  final void Function(String providerId) onSocial;
  final Future<bool> Function(String email, String password) onEmail;

  @override
  State<_SignedOutView> createState() => _SignedOutViewState();
}

class _SignedOutViewState extends State<_SignedOutView> {
  bool _emailOpen = false;

  @override
  Widget build(BuildContext context) {
    final busy = widget.busyProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
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
            Text('Sign in to HumTrack', style: LTType.inter(size: 16, weight: FontWeight.w800, color: LT.t1)),
            const SizedBox(height: 4),
            Text('Back up your loops and sync across devices.',
                textAlign: TextAlign.center, style: LTType.inter(size: 12, color: LT.t2)),
          ],
        ),
        const SizedBox(height: 18),
        // 공식 브랜드 가이드라인 준수 버튼 (legacy widgets/social_sign_in_buttons.dart 재사용).
        _SocialButtonWrapper(
          busy: busy == 'apple',
          disabled: busy != null && busy != 'apple',
          child: AppleSignInButton(
            label: 'Continue with Apple',
            onPressed: () => widget.onSocial('apple'),
          ),
        ),
        _SocialButtonWrapper(
          busy: busy == 'google',
          disabled: busy != null && busy != 'google',
          child: GoogleSignInButton(
            label: 'Continue with Google',
            onPressed: () => widget.onSocial('google'),
          ),
        ),
        const SizedBox(height: 3),
        // Discreet email login (review-only). 탭 시 email/password 폼이 열림.
        if (!_emailOpen)
          GestureDetector(
            onTap: busy != null ? null : () => setState(() => _emailOpen = true),
            child: Container(
              height: 36,
              alignment: Alignment.center,
              child: Text('Sign in with email',
                  style: LTType.inter(size: 12, weight: FontWeight.w700, color: LT.t2)),
            ),
          )
        else
          _EmailLoginForm(
            busy: busy == 'email',
            onSubmit: widget.onEmail,
          ),
      ],
    );
  }
}

/// Email/password sign-in — login only, NO sign-up. Supabase
/// signInWithPassword 로 실제 인증. public sign-up 은 backend에서 비활성
/// 이므로 사전 생성된 review 계정만 통과.
class _EmailLoginForm extends StatefulWidget {
  const _EmailLoginForm({required this.busy, required this.onSubmit});
  final bool busy;
  final Future<bool> Function(String email, String password) onSubmit;

  @override
  State<_EmailLoginForm> createState() => _EmailLoginFormState();
}

class _EmailLoginFormState extends State<_EmailLoginForm> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pw = _password.text;
    if (email.isEmpty || pw.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    setState(() => _error = null);
    await widget.onSubmit(email, pw);
    // 성공 시 LoopStore._user 가 채워져 부모 sheet 가 signed-in 뷰로 재빌드.
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        _Field(controller: _email, hint: 'Email', keyboardType: TextInputType.emailAddress),
        const SizedBox(height: 8),
        _Field(controller: _password, hint: 'Password', obscure: true),
        if (_error != null) ...[
          const SizedBox(height: 6),
          Text(_error!, style: LTType.inter(size: 11, weight: FontWeight.w600, color: LT.danger)),
        ],
        const SizedBox(height: 10),
        GestureDetector(
          onTap: widget.busy ? null : _submit,
          child: Container(
            height: 46,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: LT.lime,
              borderRadius: BorderRadius.circular(LTRadius.control),
            ),
            child: Text(widget.busy ? 'Signing in…' : 'Sign in',
                style: LTType.inter(size: 14, weight: FontWeight.w800, color: LT.bg)),
          ),
        ),
        // Intentionally NO sign-up button — accounts are social-only / invite-only.
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.hint,
    this.obscure = false,
    this.keyboardType,
  });
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      autocorrect: false,
      enableSuggestions: false,
      style: LTType.inter(size: 14, weight: FontWeight.w600, color: LT.t1),
      cursorColor: LT.lime,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: LTType.inter(size: 14, color: LT.t3),
        filled: true,
        fillColor: LT.surface2,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LTRadius.control),
          borderSide: const BorderSide(color: LT.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(LTRadius.control),
          borderSide: const BorderSide(color: LT.lime),
        ),
      ),
    );
  }
}

/// busy / disabled 상태를 공식 브랜드 버튼 위에 입히는 얇은 wrapper.
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
