// 도움말 시트 — 음악·DSP 용어 짧은 설명. 카드 헤더의 ⓘ 탭 → 모달.
part of '../sheets.dart';

// ─── 도움말 시트 ───────────────────────────────────────────────────────
// 5-3: 음악·DSP 용어(키/AUTO/피치 어시스트/단음·코드 등)에 짧은 설명.
// 카드 헤더의 ⓘ 아이콘 탭 → 이 시트가 모달로 노출. 닫기 버튼 1개.
void showHelpSheet(BuildContext context, String title, String body) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => Container(
      decoration: _sheetDeco(),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _grabber(),
          Row(
            children: [
              const Icon(Symbols.info, size: 18, color: AppColors.lime),
              const SizedBox(width: 8),
              Expanded(child: Text(title, style: T.h2.copyWith(fontSize: 17))),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: T.body.copyWith(fontSize: 13.5, height: 1.5, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            child: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.bg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(L10n.of(context).close, style: T.body.copyWith(fontWeight: FontWeight.w600)),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
