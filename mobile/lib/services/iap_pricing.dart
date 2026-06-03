// IAP 가격 표시 — *스토어 우선*, 폴백 상수.
//
// 정책:
//   - **표시 가격은 항상 스토어 ProductDetails.price 를 우선 사용.**
//     Apple/Google 이 디바이스 locale 에 맞춰 자동 환율 변환 + 통화 기호 + 형식까지 처리.
//   - IAP 환경 미가용(시뮬레이터/네트워크 오류/스토어 미등록) 시에만 KRW 상수로 폴백.
//   - 폴백 상수는 한국 시장 기준값 — 다른 국가에 출시될 때마다 수동 추가 ❌, 스토어가 알아서 함.
//
// 가격 결정 (2026-06-03):
//   - 월: USD 3.49 / KRW 5,500
//   - 연: USD 33.49 / KRW 55,000 (월 환산 ≈ USD 2.79 / KRW 4,583, 약 20% 할인 — USD 기준)
//
// 변경 시 함께 갱신:
//   - backend/.env.secrets 의 APPLE_IAP_PRICE_*
//   - infra/scripts/asc_create_iap.py (App Store Connect 자동 등록 스크립트)
//   - mobile/ios/fastlane/Fastfile sync_iap lane (해당 있으면)

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:intl/intl.dart';

import 'iap_service.dart';

class IapPricing {
  IapPricing._();

  // 월 구독.
  static const int monthlyKrw = 5500;
  static const double monthlyUsd = 3.49;

  // 연 구독.
  static const int yearlyKrw = 55000;
  static const double yearlyUsd = 33.49;

  // 무료 체험 기간.
  static const int trialDays = 7;

  // ─── 표시 헬퍼 — 스토어 우선, 폴백 KRW ────────────────────────────────

  /// 월 구독 가격 — 사용자가 화면에서 보는 문자열.
  /// 스토어에 등록된 ProductDetails 가 있으면 그 .price (디바이스 locale + 통화),
  /// 없으면 KRW 폴백 ('₩5,500').
  static String monthlyLabel() {
    final p = _find(kProductMonthly);
    if (p != null) return p.price;
    return '₩${_fmt(monthlyKrw)}';
  }

  /// 연 구독 가격.
  static String yearlyLabel() {
    final p = _find(kProductYearly);
    if (p != null) return p.price;
    return '₩${_fmt(yearlyKrw)}';
  }

  /// 연 → 월 환산 — 스토어 rawPrice 가 있으면 그걸로 12등분 + intl 포맷,
  /// 없으면 KRW 폴백 ('₩4,400').
  static String yearlyAsMonthlyLabel() {
    final p = _find(kProductYearly);
    if (p != null && p.rawPrice > 0) {
      final monthly = p.rawPrice / 12;
      return _formatCurrency(monthly, p.currencyCode);
    }
    final monthly = (yearlyKrw / 12).round();
    return '₩${_fmt(monthly)}';
  }

  /// 연 대비 월 결제 할인율(%) — **USD 기준 20% 고정**.
  ///
  /// Apple tier 매핑 특성상 territory 별 KRW/USD 비율이 정확히 일치하지 않음
  /// (예: KRW ₩5,500 → ₩55,000 = 16.67% 할인, USD $3.49 → $33.49 = 20% 할인).
  /// 마케팅 일관성 + paywall UX 통일을 위해 **모든 locale 에서 20% 표시**.
  static int yearlyDiscountPercent() => 20;

  // ─── 내부 ───────────────────────────────────────────────────────────

  static ProductDetails? _find(String id) {
    if (!IapService.instance.enabled) return null;
    for (final p in IapService.instance.products) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// rawPrice + currencyCode → 로컬라이즈된 통화 문자열.
  /// intl 의 NumberFormat.simpleCurrency 가 통화별 decimalDigits (KRW=0, USD=2, JPY=0)
  /// 까지 자동 처리.
  static String _formatCurrency(double amount, String currencyCode) {
    try {
      return NumberFormat.simpleCurrency(name: currencyCode).format(amount);
    } catch (_) {
      // 알 수 없는 currency code 면 그냥 숫자 + code.
      return '${currencyCode.toUpperCase()} ${amount.toStringAsFixed(2)}';
    }
  }

  static String _fmt(int n) {
    // 천 단위 콤마. intl 없이 단순 처리.
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
