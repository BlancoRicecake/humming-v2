// Empty/Songs 화면 — "작업 시작" → 새 프로젝트 → Edit 화면.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import 'edit_screen.dart';

class SongsScreen extends StatelessWidget {
  const SongsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('My Songs', style: T.h1),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(18)),
                    child: const Icon(Symbols.person, size: 20, color: AppColors.textPrimary),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _brandMark(),
                    const SizedBox(height: 28),
                    Text('새 곡 작업을 시작하세요', style: T.h2),
                    const SizedBox(height: 10),
                    Text(
                      '흥얼거리면 악기로 변환되고, 녹음부터 편집까지 한 번에',
                      style: T.sub,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: 240,
                      child: LimeButton(
                        label: '작업 시작',
                        icon: Symbols.arrow_forward,
                        onTap: () {
                          context.read<ProjectStore>().newProject();
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EditScreen()));
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _bottomNav(context),
          ],
        ),
      ),
    );
  }

  Widget _brandMark() {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(34)),
      clipBehavior: Clip.antiAlias,
      child: Image.asset(
        'assets/icon/hummingbird.png',
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) =>
            const Icon(Symbols.flutter_dash, size: 72, color: AppColors.lime),
      ),
    );
  }

  Widget _bottomNav(BuildContext context) {
    Widget tab(IconData ic, String label, bool active, {bool disabled = false}) {
      final w = Expanded(
        child: Container(
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: active ? AppColors.lime : Colors.transparent,
            borderRadius: BorderRadius.circular(26),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(ic, size: 16, color: active ? AppColors.bg : AppColors.textSecondary),
              const SizedBox(height: 4),
              Text(label,
                  style: T.label.copyWith(
                      fontSize: 10, color: active ? AppColors.bg : AppColors.textSecondary)),
            ],
          ),
        ),
      );
      if (disabled) return Expanded(child: Disabled(label: 'Mixer', child: w.child));
      return w;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(21, 12, 21, 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(36),
          border: Border.all(color: AppColors.border),
        ),
        padding: const EdgeInsets.all(4),
        child: Row(children: [
          tab(Symbols.auto_awesome, 'STUDIO', false),
          tab(Symbols.library_music, 'SONGS', true),
          tab(Symbols.tune, 'MIXER', false, disabled: true),
        ]),
      ),
    );
  }
}
