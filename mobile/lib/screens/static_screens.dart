// 정적 정보 화면들 — 시안 ⑬ FAQ, ⑭ 문의하기, ⑮ 약관, ⑯ 개인정보처리방침, ⑰ 클라우드 다운로드.
// 상세 본문은 placeholder — 출시 전 법무 검토본으로 교체 예정.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../theme/app_theme.dart';
import '../widgets/common.dart';

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

  static const _items = <(String, String)>[
    ('무료로 어디까지 쓸 수 있나요?',
        '녹음 → 분석 → 편집까지 모든 기능을 자유롭게 써 보실 수 있어요. 내보내기 · 클라우드 동기화 · 보컬 영구 보관은 Pro 구독에서 잠금이 풀려요.'),
    ('어떤 악기로 변환되나요?',
        '피아노 · 신스 · 어쿠스틱 기타 · 일렉 기타 · 베이스 · 드럼 그리고 보컬 원본까지 — 카드 탭으로 즉시 전환할 수 있어요.'),
    ('내 목소리는 누가 들을 수 있나요?',
        '기본은 기기 안에서만 처리됩니다. Pro 사용자에 한해 본인 계정의 암호화된 클라우드 보관함에 보컬을 동기화해요.'),
    ('구독을 해지하면 만든 곡은 어떻게 되나요?',
        '로컬 프로젝트는 그대로 남아 편집할 수 있어요. 클라우드 동기화 · 새로운 내보내기는 일시 정지되고, 다시 구독하면 즉시 복원됩니다.'),
    ('환불은 가능한가요?',
        '결제는 App Store · Google Play 정책을 따릅니다. 결제 페이지에서 직접 요청해 주세요.'),
  ];

  @override
  Widget build(BuildContext context) {
    return _BaseInfoScaffold(
      title: 'FAQ',
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final it = _items[i];
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
    return _BaseInfoScaffold(
      title: '문의하기',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Text('무엇을 도와드릴까요?', style: T.h2.copyWith(fontSize: 18)),
          const SizedBox(height: 4),
          Text('대부분의 답변은 FAQ 에 있어요. 그 외엔 아래로 알려주세요.',
              style: T.sub),
          const SizedBox(height: 18),
          _row(context, Symbols.mail, '이메일', 'support@humming.app'),
          _row(context, Symbols.bug_report, '버그 신고', '재현 단계와 함께 적어주시면 큰 도움이 돼요'),
          _row(context, Symbols.lightbulb, '기능 제안', '이런 기능이 있었으면 좋겠어요'),
        ],
      ),
    );
  }
}

// ─── ⑮ 약관 / ⑯ 개인정보처리방침 ────────────────────────────────────
class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const _BaseInfoScaffold(
      title: '서비스 약관',
      child: _LegalBody(
        sections: [
          ('1조 (목적)', '본 약관은 Humming(이하 "서비스")의 이용과 관련하여 회사와 회원의 권리·의무 및 책임사항을 규정함을 목적으로 합니다.'),
          ('2조 (용어 정의)', '"회원"이란 본 약관에 동의하고 서비스에 가입한 자를 말합니다. "콘텐츠"란 회원이 제작·녹음한 모든 결과물을 의미합니다.'),
          ('3조 (계정과 보안)', '회원은 본인 계정과 비밀번호를 안전하게 관리해야 합니다.'),
          ('4조 (콘텐츠의 소유권)', '회원이 제작한 모든 콘텐츠의 저작권은 회원에게 귀속됩니다.'),
          ('5조 (구독과 결제)', '유료 구독은 결제 즉시 활성화되며, 자동 갱신은 만료 24시간 전까지 해지할 수 있습니다.'),
          ('6조 (서비스 변경 및 중단)', '회사는 운영상·기술상 필요한 경우 서비스의 일부 또는 전부를 변경할 수 있습니다.'),
        ],
      ),
    );
  }
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return const _BaseInfoScaffold(
      title: '개인정보처리방침',
      child: _LegalBody(
        sections: [
          ('수집 항목', '이메일 주소, OAuth 식별자, 결제 영수증, 녹음 파일(클라우드 보관 동의 시).'),
          ('이용 목적', '서비스 제공, 결제 처리, 클라우드 동기화, 고객 지원.'),
          ('보관 기간', '회원 탈퇴 즉시 파기. 단, 관련 법령에 따라 일정 기간 보관이 필요한 정보는 분리 보관합니다.'),
          ('제3자 제공', '법령에 따른 요청 외에는 제3자에게 제공하지 않습니다.'),
          ('보안', '저장 시 AES-256 암호화, 전송 시 TLS 1.2 이상.'),
          ('이용자 권리', '언제든지 본인의 개인정보 조회, 수정, 삭제, 처리 정지를 요청할 수 있습니다.'),
        ],
      ),
    );
  }
}

class _LegalBody extends StatelessWidget {
  const _LegalBody({required this.sections});
  final List<(String, String)> sections;
  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      itemCount: sections.length,
      separatorBuilder: (_, __) => const SizedBox(height: 18),
      itemBuilder: (_, i) {
        final s = sections[i];
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s.$1, style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 14, color: AppColors.lime)),
          const SizedBox(height: 6),
          Text(s.$2, style: T.body.copyWith(height: 1.55, color: AppColors.textSecondary)),
        ]);
      },
    );
  }
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
    return _BaseInfoScaffold(
      title: '클라우드에서 가져오기',
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
                '구독이 만료된 동안엔 새 동기화는 멈춰요. 이전 작업은 30일 동안 다운로드할 수 있어요.',
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
                  onTap: () => comingSoon(context, '다운로드'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.lime, borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text('받기', style: T.label.copyWith(color: AppColors.bg, fontSize: 11)),
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
