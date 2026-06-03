// ⑱ Logout 확인 시트.
part of '../account_sheets.dart';

// ─── ⑱ Logout 확인 ────────────────────────────────────────────────────
Future<void> showLogoutConfirm(BuildContext context, ProjectStore store) async {
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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _grabber(),
          Text(t.logoutConfirmTitle, style: T.h2.copyWith(fontSize: 18), textAlign: TextAlign.center),
          const SizedBox(height: 6),
          Text(t.logoutConfirmBody,
              style: T.sub, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          GestureDetector(
            onTap: () async {
              if (AuthService.instance.enabled) {
                await AuthService.instance.signOut();
              } else {
                store.mockLogout();
              }
              if (sheetCtx.mounted) Navigator.pop(sheetCtx);
            },
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.15),
                border: Border.all(color: AppColors.dangerBorder),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(t.logoutCta,
                  style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.danger)),
            ),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => Navigator.pop(sheetCtx),
            child: Container(
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.bg,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(t.cancel, style: T.body.copyWith(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
    },
  );
}
