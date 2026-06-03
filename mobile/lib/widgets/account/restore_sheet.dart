// ⑲ 구매 복원 결과 시트.
part of '../account_sheets.dart';

// ─── ⑲ 구매 복원 결과 ────────────────────────────────────────────────
Future<void> showRestoreResult(BuildContext context, {required bool ok, String? message}) async {
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (sheetCtx) {
      final t = L10n.of(sheetCtx);
      return Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _grabber(),
          Icon(ok ? Symbols.check_circle : Symbols.error,
              color: ok ? AppColors.lime : AppColors.danger, size: 48),
          const SizedBox(height: 12),
          Text(ok ? t.restoreOkTitle : t.restoreEmptyTitle,
              style: T.h2.copyWith(fontSize: 18)),
          const SizedBox(height: 6),
          Text(message ?? (ok ? t.restoreOkBody : t.restoreEmptyBody),
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: LimeButton(label: t.ok, onTap: () => Navigator.pop(sheetCtx)),
          ),
        ],
      ),
    );
    },
  );
}
