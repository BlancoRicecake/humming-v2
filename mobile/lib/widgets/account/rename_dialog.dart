// ㉑ Rename 다이얼로그.
part of '../account_sheets.dart';

// ─── ㉑ Rename 다이얼로그 ────────────────────────────────────────────
Future<String?> _promptRename(BuildContext context, String initial) {
  final ctrl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (dctx) => Dialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(L10n.of(dctx).rename, style: T.h2.copyWith(fontSize: 17)),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: T.body,
              cursorColor: AppColors.lime,
              decoration: InputDecoration(
                filled: true,
                fillColor: AppColors.bg,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.lime, width: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.pop(dctx),
                  child: Container(
                    height: 44, alignment: Alignment.center,
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
                  onTap: () => Navigator.pop(dctx, ctrl.text),
                  child: Container(
                    height: 44, alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.lime, borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(L10n.of(dctx).save, style: T.body.copyWith(fontWeight: FontWeight.w700, color: AppColors.bg)),
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
