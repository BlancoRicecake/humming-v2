// 변환 중 화면 — /analyze 호출 대기. 완료되면 자동으로 pop(편집으로 복귀).
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';
import '../models/models.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';

class AnalyzingScreen extends StatefulWidget {
  const AnalyzingScreen({super.key, required this.wavPath, required this.role});
  final String wavPath;
  final TrackRole role;

  @override
  State<AnalyzingScreen> createState() => _AnalyzingScreenState();
}

class _AnalyzingScreenState extends State<AnalyzingScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final store = context.read<ProjectStore>();
    await store.recordAnalyzed(widget.wavPath, role: widget.role);
    if (mounted) Navigator.of(context).pop(store.error == null);
  }

  @override
  Widget build(BuildContext context) {
    const steps = ['녹음 정리', '노이즈 제거', '피치 분석', '악기 렌더'];
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(color: AppColors.surface, borderRadius: BorderRadius.circular(60)),
                child: const Icon(Symbols.sync, size: 48, color: AppColors.lime),
              ),
              const SizedBox(height: 24),
              Text('음성을 악기로 변환 중', style: T.h2),
              const SizedBox(height: 8),
              Text('1–5초 소요됩니다', style: T.sub),
              const SizedBox(height: 24),
              const SizedBox(
                width: 200,
                child: LinearProgressIndicator(
                  backgroundColor: AppColors.surface,
                  color: AppColors.lime,
                ),
              ),
              const SizedBox(height: 24),
              for (final s in steps)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Symbols.radio_button_unchecked, size: 16, color: AppColors.textSecondary),
                      const SizedBox(width: 8),
                      Text(s, style: T.sub),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
