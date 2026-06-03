// ㉒ 프로젝트 삭제 확인 다이얼로그.
part of '../account_sheets.dart';

// ─── ㉒ Delete 확인 ────────────────────────────────────────────────────
Future<bool?> _promptDelete(BuildContext context, String title) {
  return showDialog<bool>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 48, height: 48, alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Symbols.delete, color: AppColors.danger, size: 22),
              ),
            ),
            const SizedBox(height: 12),
            Text(L10n.of(dctx).projectDeleteTitle(title), style: T.h2.copyWith(fontSize: 17), textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(L10n.of(dctx).projectDeleteBody,
                style: T.sub, textAlign: TextAlign.center),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, false),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.bg, borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(L10n.of(dctx).cancel, style: T.body.copyWith(fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx, true),
                  child: Container(
                    height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.danger, borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(L10n.of(dctx).delete, style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                  ),
                ),
              ),
            ]),
          ],
        ),
      ),
    ),
  );
}
