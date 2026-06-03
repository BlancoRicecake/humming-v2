// Pro 환영 화면 — IAP 결제 완료 직후 1회.
// 시안 ⑫ — cloud-sync-p3.html. "클라우드 둘러보기" CTA → SongsScreen 클라우드 탭.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../l10n/generated/app_localizations.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

class ProWelcomeScreen extends StatelessWidget {
  const ProWelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () => Navigator.maybePop(context),
                  child: Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.surface2,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Symbols.close, color: AppColors.textSecondary, size: 16),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                height: 170,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF1F2A0F), AppColors.surface],
                  ),
                  border: Border.all(color: const Color(0xFF2E3D18)),
                ),
                alignment: Alignment.center,
                child: Container(
                  width: 130,
                  height: 90,
                  decoration: BoxDecoration(
                    color: AppColors.lime,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '☁ 5GB',
                        style: T.h2.copyWith(
                            color: AppColors.bg, fontWeight: FontWeight.w800, fontSize: 22),
                      ),
                      const SizedBox(height: 4),
                      Text(t.proWelcomeBadgeLabel,
                          style: T.label.copyWith(
                              color: AppColors.bg, fontSize: 11, letterSpacing: 0.5)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: Text(t.proWelcomeTitle,
                    style: T.h2.copyWith(fontSize: 24, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(t.proWelcomeBody,
                    style: T.sub, textAlign: TextAlign.center),
              ),
              const SizedBox(height: 22),
              _step('1', t.proWelcomeStep1Prefix, t.proWelcomeStep1Bold),
              const SizedBox(height: 8),
              _step('2', t.proWelcomeStep2, null),
              const SizedBox(height: 8),
              _step('3', t.proWelcomeStep3, null),
              const Spacer(),
              LimeButton(
                label: t.proWelcomeCta,
                onTap: () => Navigator.maybePop(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _step(String n, String text, String? bold) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.activeLane,
              shape: BoxShape.circle,
            ),
            child: Text(n,
                style: T.label.copyWith(
                    fontSize: 13, color: AppColors.lime, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: T.body.copyWith(fontSize: 13, height: 1.4),
                children: [
                  TextSpan(text: text),
                  if (bold != null)
                    TextSpan(
                        text: bold,
                        style: T.body.copyWith(fontWeight: FontWeight.w700, fontSize: 13)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
