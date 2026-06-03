// 세그먼트 컨트롤 — pill 안의 두 탭. lime fill = active.
// 시안: cloud-sync-p3.html .segment / .seg-tab
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SegmentedControl extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onChanged,
  });

  /// 각 탭의 (icon, label). icon=null 이면 라벨만.
  final List<({IconData? icon, String label})> tabs;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          for (int i = 0; i < tabs.length; i++)
            Expanded(child: _tab(i, tabs[i])),
        ],
      ),
    );
  }

  Widget _tab(int i, ({IconData? icon, String label}) t) {
    final active = i == selectedIndex;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onChanged(i),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        height: 38,
        margin: EdgeInsets.symmetric(horizontal: i == 0 ? 0 : 2),
        decoration: BoxDecoration(
          color: active ? AppColors.lime : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (t.icon != null) ...[
              Icon(t.icon, size: 16, color: active ? AppColors.bg : AppColors.textSecondary),
              const SizedBox(width: 6),
            ],
            Text(
              t.label,
              style: T.body.copyWith(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: active ? AppColors.bg : AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
