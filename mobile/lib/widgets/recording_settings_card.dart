// "임시 녹음 자동 삭제" 설정 + 녹음 라이브러리 진입 카드.
//
// AccountScreen 하단에 노출. 라이브러리 시트 진입점은 이 카드 안에 함께 둔다 —
// 설정과 데이터 모두 같은 멘탈 모델("내 녹음")에 속하므로.
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/recording_library.dart';
import '../state/local_storage.dart';
import '../state/project_store.dart';
import '../theme/app_theme.dart';
import 'sheets.dart';

class RecordingSettingsCard extends StatefulWidget {
  const RecordingSettingsCard({super.key});

  @override
  State<RecordingSettingsCard> createState() => _RecordingSettingsCardState();
}

class _RecordingSettingsCardState extends State<RecordingSettingsCard> {
  int _ttlDays = 7;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadPref();
  }

  Future<void> _loadPref() async {
    final prefs = await LocalStorage.instance.readAppPrefs();
    final v = (prefs['temp_recording_ttl_days'] as num?)?.toInt() ?? 7;
    if (mounted) {
      setState(() {
        _ttlDays = v;
        _loaded = true;
      });
    }
  }

  Future<void> _setTtl(int days) async {
    setState(() => _ttlDays = days);
    await LocalStorage.instance.writeAppPrefs({'temp_recording_ttl_days': days});
    // 변경 즉시 한 번 정리(필요한 경우만).
    await RecordingLibrary.instance.cleanupExpiredTemp(days);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = L10n.of(context);
    final store = context.read<ProjectStore>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(
            t.settingsRecordingTtl,
            style: T.label.copyWith(
              fontSize: 11,
              letterSpacing: 0.6,
              color: AppColors.textTertiary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(t.settingsRecordingTtlDesc,
                  style: T.sub.copyWith(fontSize: 11, color: AppColors.textTertiary, height: 1.4)),
              const SizedBox(height: 12),
              if (_loaded)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _seg(3, t.settingsTtl3Days),
                    _seg(7, t.settingsTtl7Days),
                    _seg(30, t.settingsTtl30Days),
                    _seg(999, t.settingsTtlForever),
                  ],
                )
              else
                const SizedBox(height: 28),
            ],
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showRecordingLibrarySheet(context, store),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(children: [
              const Icon(Symbols.library_music, color: AppColors.lime, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(t.recordLibraryAccessLabel,
                    style: T.body.copyWith(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const Icon(Symbols.chevron_right, color: AppColors.textTertiary, size: 20),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _seg(int days, String label) {
    final selected = _ttlDays == days;
    return GestureDetector(
      onTap: () => _setTtl(days),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.lime : AppColors.bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? AppColors.lime : AppColors.border),
        ),
        child: Text(label,
            style: T.label.copyWith(
                fontSize: 11,
                color: selected ? AppColors.bg : AppColors.textPrimary,
                fontWeight: FontWeight.w700)),
      ),
    );
  }
}
