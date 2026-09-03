// Pure IAP types + mappings — no platform imports so they can be unit-tested
// (in_app_purchase / supabase pull in platform channels). Re-exported by
// iap_service.dart; import that from app code.

const String kProductMonthly = 'humtrack_pro_monthly_v2';
const String kProductYearly  = 'humtrack_pro_yearly';
const Set<String> kProductIds = {kProductMonthly, kProductYearly};

/// Android applicationId (android/app/build.gradle.kts) — Play 구독 관리
/// deep link 에 필요.
const String kAndroidPackageName = 'com.humtrack.app';

/// 결제/검증 실패 사유 — UI 가 이걸로 문구를 고른다 (audit M5).
enum IapError {
  /// 사용자가 스토어 시트에서 취소. 조용히 버튼만 다시 활성화.
  canceled,
  /// 스토어가 아직 승인 대기(PurchaseStatus.pending — Ask to Buy, 편의점 결제).
  /// 최종 결과가 아니며, 이후 purchased/error 가 따라온다.
  pending,
  /// 스토어 오류 / 상품 미로드 / 스토어 미가용.
  storeError,
  /// 결제는 됐는데 백엔드 검증이 실패(4xx/5xx). 사용자에게는 "결제 확인됨,
  /// 활성화 중 — 안 보이면 구매 복원" 안내.
  verifyFailed,
  /// 로그인 안 됨 (또는 verify 401).
  notSignedIn,
  /// verify 409 — Google 측 결제 승인 대기.
  paymentPending,
  /// verify 429.
  throttled,
  /// 네트워크 예외 (verify 도달 실패).
  network,
}

class IapResult {
  const IapResult({
    required this.ok,
    required this.productId,
    this.error,
    this.message,
    this.renewsAt,
    this.restored = false,
  });
  final bool ok;
  final String productId;
  final IapError? error;
  /// 진단용 원문 (스토어 에러 메시지 등). 사용자에게 직접 보이지 않는다.
  final String? message;
  /// 서버 expires_at (verify 응답) — 없으면 null.
  final DateTime? renewsAt;
  /// PurchaseStatus.restored 로 들어온 결과인지.
  final bool restored;

  /// 최종 결과가 아닌 중간 상태(승인 대기)인지.
  bool get isPending => error == IapError.pending || error == IapError.paymentPending;
}

/// /iap/verify 가 200 이 아닐 때 Sentry 로 보내는 예외 (본문 앞 200자만).
class IapVerifyHttpException implements Exception {
  IapVerifyHttpException(this.status, Object? body) : body = truncateBody(body);
  final int status;
  final String body;

  static String truncateBody(Object? body, [int max = 200]) {
    final s = body == null ? '' : body.toString();
    return s.length <= max ? s : s.substring(0, max);
  }

  @override
  String toString() => 'IapVerifyHttpException($status): $body';
}

/// HTTP 상태 → [IapError]. null = 예외(서버에 도달 못 함).
IapError iapErrorFromHttpStatus(int? status) {
  if (status == null) return IapError.network;
  switch (status) {
    case 401:
      return IapError.notSignedIn;
    case 409:
      return IapError.paymentPending;
    case 429:
      return IapError.throttled;
    default:
      // 400(영수증 거절) 과 그 외 4xx, 5xx 는 모두 "검증 실패" 로 취급.
      return IapError.verifyFailed;
  }
}

/// verify 재시도 여부: 일시적 원인(네트워크, 5xx, 429)만. 400/401/409 는
/// 재시도해도 결과가 같다.
bool iapVerifyShouldRetry(int? status) {
  if (status == null) return true;
  if (status == 429) return true;
  return status >= 500;
}

/// 스토어 구독 관리 페이지 (audit M9). 계정 삭제는 구독을 해지하지 않으므로
/// 사용자가 직접 스토어에서 해지하도록 안내할 때 연다.
Uri manageSubscriptionUri({required bool isIOS, String? productId}) {
  if (isIOS) return Uri.parse('https://apps.apple.com/account/subscriptions');
  return Uri.https('play.google.com', '/store/account/subscriptions', {
    'sku': (productId == null || productId.isEmpty) ? kProductMonthly : productId,
    'package': kAndroidPackageName,
  });
}
