// 정적 정보 화면들 — 시안 ⑬ FAQ, ⑭ 문의하기, ⑮ 약관, ⑯ 개인정보처리방침, ⑰ 클라우드 다운로드, 환불 정책.
// 약관/개인정보/환불은 LegalDocScreen (assets/legal/*.md, flutter_markdown) 으로 위임.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

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

  Widget _row(BuildContext context, IconData ic, String t, String s, {VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap ?? () => comingSoon(context, t),
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
class CloudDownloadScreen extends StatelessWidget {
  const CloudDownloadScreen({super.key});

  // mock 목록 — 실제로는 backend `/cloud/projects` 에서 가져옴.
  static const _items = <(String, String, String)>[
    ('첫 데모', '3분 12초 · 2026.04.18', '14.2 MB'),
    ('Bridge sketch', '1분 45초 · 2026.04.30', '8.1 MB'),
    ('Verse idea v2', '2분 28초 · 2026.05.11', '11.4 MB'),
  ];

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
          const SizedBox(height: 16),
          ..._items.map((it) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(children: [
              Container(
                width: 40, height: 40, alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.activeLane, borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Symbols.cloud_download, color: AppColors.lime, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(it.$1, style: T.body.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(it.$2, style: T.sub.copyWith(fontSize: 11)),
              ])),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                GestureDetector(
                  onTap: () => comingSoon(context, t.cloudDownloadActionLabel),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.lime, borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(t.cloudDownloadCta, style: T.label.copyWith(color: AppColors.bg, fontSize: 11)),
                  ),
                ),
                const SizedBox(height: 4),
                Text(it.$3, style: T.sub.copyWith(fontSize: 10, color: AppColors.textTertiary)),
              ]),
            ]),
          )),
        ],
      ),
    );
  }
}
