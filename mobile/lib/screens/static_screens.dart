// 정적 정보 화면들 — 시안 ⑬ FAQ, ⑭ 문의하기, ⑮ 약관, ⑯ 개인정보처리방침, ⑰ 클라우드 다운로드, 환불 정책.
// 약관/개인정보/환불은 LegalDocScreen (assets/legal/*.md, flutter_markdown) 으로 위임.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'legal_doc_screen.dart';

class _BaseInfoScaffold extends StatelessWidget {
  const _BaseInfoScaffold({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.arrow_back_ios, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(title, style: T.h2.copyWith(fontSize: 17)),
        centerTitle: true,
      ),
      body: SafeArea(top: false, child: child),
    );
  }
}

// ─── ⑬ FAQ ────────────────────────────────────────────────────────────
class FaqScreen extends StatelessWidget {
  const FaqScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    final items = <(String, String)>[
      (t.faq1Q, t.faq1A),
      (t.faq2Q, t.faq2A),
      (t.faq3Q, t.faq3A),
      (t.faq4Q, t.faq4A),
      (t.faq5Q, t.faq5A),
    ];
    return _BaseInfoScaffold(
      title: t.faqTitle,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final it = items[i];
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(it.$1, style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 14)),
              const SizedBox(height: 8),
              Text(it.$2, style: T.sub.copyWith(height: 1.5)),
            ]),
          );
        },
      ),
    );
  }
}

// ─── ⑭ 문의하기 ─────────────────────────────────────────────────────
class ContactScreen extends StatelessWidget {
  const ContactScreen({super.key});

  Future<void> _openMail(BuildContext context, String subject) async {
    const email = 'heobusy@gmail.com';
    final uri = Uri(
      scheme: 'mailto',
      path: email,
      query: 'subject=${Uri.encodeComponent(subject)}',
    );
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      await Clipboard.setData(const ClipboardData(text: email));
      if (context.mounted) infoToast(context, '$email (copied)');
    }
  }

  Widget _row(BuildContext context, IconData ic, String t, String s, {VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap ?? () => _openMail(context, t),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(children: [
          Icon(ic, color: AppColors.lime, size: 22),
          const SizedBox(width: 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(t, style: T.body.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(s, style: T.sub),
          ])),
          const Icon(Symbols.chevron_right, color: AppColors.textTertiary, size: 22),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    return _BaseInfoScaffold(
      title: t.contactTitle,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text(t.contactHeadline, style: T.h2.copyWith(fontSize: 18)),
          const SizedBox(height: 4),
          Text(t.contactSub, style: T.sub),
          const SizedBox(height: 18),
          _row(context, Symbols.mail, t.contactEmail, 'heobusy@gmail.com'),
          _row(context, Symbols.bug_report, t.contactBug, t.contactBugSub),
          _row(context, Symbols.lightbulb, t.contactFeature, t.contactFeatureSub),
        ],
      ),
    );
  }
}

// ─── ⑮ 약관 / ⑯ 개인정보처리방침 / 환불 정책 ─────────────────────────────
// 본문은 assets/legal/{terms,privacy,refund}.md 의 1.2-draft 본문을 그대로 렌더.
// 시행일·최종개정 메타는 마크다운 본문 상단에 이미 포함되어 있다.
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});
  @override
  Widget build(BuildContext context) => const LegalDocScreen(doc: LegalDoc.terms);
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context) => const LegalDocScreen(doc: LegalDoc.privacy);
}

class RefundScreen extends StatelessWidget {
  const RefundScreen({super.key});
  @override
  Widget build(BuildContext context) => const LegalDocScreen(doc: LegalDoc.refund);
}

// ─── ⑰ 클라우드 다운로드 (Expired 유저) ───────────────────────────────
// 구독 만료 유저가 클라우드 파일을 확인하는 화면.
// 실제 파일 목록은 backend `/cloud/projects` API 연동 전까지 빈 상태 표시.
// 재구독 후 클라우드 탭에서 정상 다운로드 가능 — 다운로드 CTA 는 v1.1.
class CloudDownloadScreen extends StatelessWidget {
  const CloudDownloadScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    return _BaseInfoScaffold(
      title: t.cloudDownloadTitle,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              const Icon(Symbols.info, color: AppColors.lime, size: 20),
              const SizedBox(width: 10),
              Expanded(child: Text(
                t.cloudDownloadBanner,
                style: T.sub.copyWith(height: 1.4),
              )),
            ]),
          ),
          const SizedBox(height: 40),
          // 실제 파일 목록은 backend `/cloud/projects` 연동 후 표시 (v1.1).
          Column(children: [
            const Icon(Symbols.cloud_off, color: AppColors.textTertiary, size: 48),
            const SizedBox(height: 12),
            Text(
              t.cloudDownloadEmptyTitle,
              style: T.body.copyWith(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              t.cloudDownloadEmptySub,
              style: T.sub.copyWith(height: 1.5, color: AppColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ]),
        ],
      ),
    );
  }
}
