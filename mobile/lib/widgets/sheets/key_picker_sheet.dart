// 키 선택 시트 (Auto / 수동 major·minor).
part of '../sheets.dart';

// ─── 키 선택 (Auto / 수동) ────────────────────────────────────────────
void showKeyPicker(BuildContext context, ProjectStore store) {
  const tonics = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  final opt = store.active.options;

  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) {
      final l = L10n.of(sheetCtx);
      Widget chip(String label, bool active, VoidCallback onTap) => GestureDetector(
            onTap: () {
              onTap();
              Navigator.pop(context);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
              decoration: BoxDecoration(
                color: active ? AppColors.lime : AppColors.bg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: active ? AppColors.lime : AppColors.border),
              ),
              child: Text(label,
                  style: T.body.copyWith(
                      fontSize: 13, fontWeight: FontWeight.w600, color: active ? AppColors.bg : AppColors.textPrimary)),
            ),
          );

      Widget section(String mode, String modeLabel) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(modeLabel, style: T.label),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in tonics)
                    chip(t, !opt.autoKey && opt.keyTonic == t && opt.scale == mode,
                        () => store.setAutoKey(false, tonic: t, scale: mode)),
                ],
              ),
              const SizedBox(height: 16),
            ],
          );

      return Container(
        decoration: _sheetDeco(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _grabber(),
              Text(l.keyPickerTitle, style: T.h2.copyWith(fontSize: 18)),
              const SizedBox(height: 4),
              Text(l.keyPickerSub, style: T.sub),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: chip(l.keyPickerAuto, opt.autoKey, () => store.setAutoKey(true)),
              ),
              const SizedBox(height: 16),
              Text(l.keyPickerMainRole, style: T.label),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final r in [TrackRole.keys, TrackRole.bass, TrackRole.vocal])
                    chip(r.label, store.mainKeyRole == r, () => store.setMainKeyFromRole(r)),
                ],
              ),
              const SizedBox(height: 16),
              section('major', l.keyPickerMajor),
              section('minor', l.keyPickerMinor),
            ],
          ),
        ),
      );
    },
  );
}
