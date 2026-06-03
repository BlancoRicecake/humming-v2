// 법무 문서 뷰어 — assets/legal/*.md 를 flutter_markdown 으로 렌더.
// 로그인 시트의 "서비스 약관 / 개인정보 처리방침" 링크가 풀모달로 푸시한다.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';

enum LegalDoc { terms, privacy, refund }

extension on LegalDoc {
  String titleOf(BuildContext context) => switch (this) {
        LegalDoc.terms => L10n.of(context).termsTitle,
        LegalDoc.privacy => L10n.of(context).privacyTitle,
        LegalDoc.refund => L10n.of(context).refundScreenTitle,
      };
  String get assetPath => switch (this) {
        LegalDoc.terms => 'assets/legal/terms.md',
        LegalDoc.privacy => 'assets/legal/privacy.md',
        LegalDoc.refund => 'assets/legal/refund.md',
      };
}

class LegalDocScreen extends StatelessWidget {
  const LegalDocScreen({super.key, required this.doc});
  final LegalDoc doc;

  /// 로그인 시트 또는 다른 곳에서 풀모달 푸시.
  static Future<void> open(BuildContext context, LegalDoc doc) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => LegalDocScreen(doc: doc),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Symbols.close, size: 22, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(doc.titleOf(context), style: T.h2.copyWith(fontSize: 17)),
        centerTitle: true,
      ),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(doc.assetPath),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const Center(
              child: SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: AppColors.lime),
              ),
            );
          }
          return Markdown(
            data: snap.data!,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            styleSheet: MarkdownStyleSheet(
              p: T.body.copyWith(height: 1.6, fontSize: 14),
              h1: T.h2.copyWith(fontSize: 20),
              h2: T.h2.copyWith(fontSize: 17),
              h3: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 15),
              listBullet: T.body.copyWith(fontSize: 14),
              blockquote: T.sub.copyWith(fontSize: 13, fontStyle: FontStyle.italic),
              code: T.body.copyWith(
                fontFamily: 'Menlo', fontSize: 12,
                backgroundColor: AppColors.surface,
              ),
              a: T.body.copyWith(color: AppColors.lime, decoration: TextDecoration.underline),
              tableHead: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 13),
              tableBody: T.body.copyWith(fontSize: 13),
            ),
            selectable: true,
            softLineBreak: true,
          );
        },
      ),
    );
  }
}
