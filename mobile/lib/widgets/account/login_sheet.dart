// ⑤ Login — Apple / Google 소셜 로그인 시트 + 약관 동의.
part of '../account_sheets.dart';

// ─── ⑤ Login ──────────────────────────────────────────────────────────
Future<bool> showLoginSheet(BuildContext context, ProjectStore store) async {
  final ok = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetCtx) => _LoginBody(store: store),
  );
  return ok == true;
}

class _LoginBody extends StatelessWidget {
  const _LoginBody({required this.store});
  final ProjectStore store;

  Future<void> _login(BuildContext context, String provider, String email) async {
    if (AuthService.instance.enabled) {
      final launched = await AuthService.instance.signInWith(provider);
      if (!context.mounted) return;
      if (launched) {
        Navigator.pop(context, true);
        return;
      }
      // 실패 — lastError 있으면 표시. 사용자 취소면 null 이라 silent.
      final err = AuthService.instance.lastError;
      if (err != null) {
        // SnackBar 는 모달 시트 아래에 깔려 안 보이므로 dialog 로 — 모달 위 보장.
        await showDialog<void>(
          context: context,
          builder: (dctx) => AlertDialog(
            backgroundColor: AppColors.surface,
            title: Text(L10n.of(dctx).loginFailedTitle, style: const TextStyle(color: AppColors.danger)),
            content: SelectableText(
              _localizedAuthError(L10n.of(dctx), err),
              style: T.body.copyWith(fontSize: 12),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dctx),
                child: Text(L10n.of(dctx).ok),
              ),
            ],
          ),
        );
      }
      return;
    }
    store.mockLogin(provider: provider, email: email);
    if (context.mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final t = L10n.of(context);
    return Container(
      decoration: _sheetDeco(),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + mq.viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          Text(t.loginTitle, style: T.h2.copyWith(fontSize: 20), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(t.loginSub,
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          // App Store Review Guideline 5.1.5: Sign in with Apple 는 다른 소셜
          // 로그인보다 prominence 동등 이상 — 시안 ⑤ 와 동일하게 최상단 배치.
          AppleSignInButton(
            label: t.appleSignInCta,
            onPressed: () => _login(context, 'apple', 'me@privaterelay.appleid.com'),
          ),
          GoogleSignInButton(
            label: t.googleSignInCta,
            onPressed: () => _login(context, 'google', 'me@gmail.com'),
          ),
          const SizedBox(height: 8),
          Center(
            child: GestureDetector(
              onTap: () => Navigator.pop(context, false),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Text(t.later, style: T.sub.copyWith(fontSize: 13, color: AppColors.textSecondary)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const _TermsAgreement(),
        ],
      ),
    );
  }
}

/// 로그인 시트 하단 약관 동의 안내.
/// "서비스 약관", "개인정보 처리방침" 은 풀모달로 해당 문서를 연다.
class _TermsAgreement extends StatelessWidget {
  const _TermsAgreement();

  @override
  Widget build(BuildContext context) {
    final base = T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary, height: 1.5);
    final link = base.copyWith(
      color: AppColors.textSecondary,
      decoration: TextDecoration.underline,
      decorationColor: AppColors.textSecondary.withValues(alpha: 0.6),
    );
    final t = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text.rich(
        TextSpan(
          style: base,
          children: [
            TextSpan(text: t.loginTermsPrefix),
            TextSpan(
              text: t.loginTermsLinkTerms,
              style: link,
              recognizer: TapGestureRecognizer()
                ..onTap = () => LegalDocScreen.open(context, LegalDoc.terms),
            ),
            TextSpan(text: t.loginTermsBetween),
            TextSpan(
              text: t.loginTermsLinkPrivacy,
              style: link,
              recognizer: TapGestureRecognizer()
                ..onTap = () => LegalDocScreen.open(context, LegalDoc.privacy),
            ),
            TextSpan(text: t.loginTermsSuffix),
          ],
        ),
        textAlign: TextAlign.center,
      ),
    );
  }
}
