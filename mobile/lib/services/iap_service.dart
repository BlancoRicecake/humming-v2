// in_app_purchase 통합 — Pro 월/연 구독. 영수증은 백엔드 /iap/verify 로 위임.
//
// 상품 ID (App Store + Play 동일):
//   - humtrack_pro_monthly_v2  (구 humtrack_pro_monthly 는 Apple reservation 잔존 → v2 로 재발급, 2026-06-03)
//   - humtrack_pro_yearly
//
// 호출 흐름:
//   1. init()              — main() 에서 한 번. 스토어 가용성 체크 + listener 부착.
//   2. loadProducts()      — paywall 시트가 진입 시 호출.
//   3. buy(productId)      — paywall 결제 버튼 onTap. null 이면 스토어 시트가 떴음.
//   4. restore()           — "구매 복원" 버튼.
//   5. onPurchaseResult    — Stream<IapResult>; LoopStore 에서 listen 후 subscription 갱신.
//   6. onVerifyStarted     — Stream<String productId>; 스토어 결과가 도착해 서버
//                            verify 가 시작됨 (paywall 이 여기서부터 타임아웃을 잰다).
//
// purchaseStream 이벤트는 직렬 Future 체인으로 하나씩 처리한다 (각 항목
// try/catch). 같은 영수증이 이미 verify 대기/진행 중이면 건너뛰고, 직전에
// pro 로 확정된 영수증은 서버를 다시 부르지 않고 그 결과를 재발행한다 —
// 부팅 restore + 수동 restore 가 겹쳐 /iap/verify 10/min 제한에 걸리는 것 방지.
// 로그인 전에 도착한 영수증(StoreKit 부팅 replay)은 보류 목록에 두었다가
// AuthService.onSession 이 로그인 세션을 발행하면 다시 처리한다.
//
// 스토어 가용성(`isAvailable`) 이 false 면 enabled=false → 호출자는 안내만.
//
// 백엔드 verify payload (backend/app/models.py:IapVerifyRequest):
//   { store: "app_store" | "play_store",
//     receipt_data: <Apple JWS or transactionId; Google JSON {productId, purchaseToken}>,
//     product_id?: <SKU> }
// 응답 (IapVerifyResponse): { pro: bool, status, product_id, expires_at, ... }
//   → `pro` 가 유일한 권한 판정 (audit M2). 400 영수증 거절 / 401 미로그인 /
//   409 Google 결제 승인 대기 / 429 throttle.
//
// 구매 시 applicationUserName = Supabase user id (audit M1) → Apple
// appAccountToken / Play obfuscatedAccountId 로 전달되어 서버 웹훅이 유저를
// 매핑할 수 있다. 로그인 없이는 결제를 시작하지 않는다.
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'auth_service.dart';
import 'iap_types.dart';
import 'observability_service.dart';
import 'product_analytics.dart';

export 'iap_types.dart';

class IapService {
  IapService._();
  static final IapService instance = IapService._();

  InAppPurchase get _iap => InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final _resultCtl = StreamController<IapResult>.broadcast();
  Stream<IapResult> get onPurchaseResult => _resultCtl.stream;

  /// 스토어 결과(purchased/restored)가 도착해 서버 verify 를 시작한 productId.
  final _verifyStartedCtl = StreamController<String>.broadcast();
  Stream<String> get onVerifyStarted => _verifyStartedCtl.stream;

  StreamSubscription<AuthSession>? _authSub;

  /// purchaseStream 처리 직렬화 체인 — 항목 처리는 절대 throw 하지 않는다.
  Future<void> _chain = Future<void>.value();

  /// verify 대기(큐)/진행 중인 영수증 key.
  final Set<String> _inFlight = {};

  /// 로그인 전에 도착해 보류된 영수증 (key → details).
  final Map<String, PurchaseDetails> _deferred = {};

  /// 최근 pro 로 확정된 영수증 → (시각, 결과). [_recentTtl] 안의 중복 배달은
  /// 서버를 다시 부르지 않는다.
  final Map<String, (DateTime, IapResult)> _recent = {};
  static const Duration _recentTtl = Duration(minutes: 2);

  bool _enabled = false;
  bool get enabled => _enabled;

  List<ProductDetails> _products = const [];
  List<ProductDetails> get products => _products;

  /// /iap/verify 백엔드 호출용 dio — main 에서 주입. null 이면 receipt 검증 불가:
  /// debug/profile 빌드에서만 결제 성공을 통과시키고 release 는 항상 거절 (M13).
  Dio? _verifyDio;
  String _verifyPath = '/iap/verify';
  void configureVerify(Dio dio, {String path = '/iap/verify'}) {
    _verifyDio = dio;
    _verifyPath = path;
  }

  /// verify 재시도 횟수/백오프 (1s, 2s, 4s). 테스트/디버그에서 조정 가능.
  @visibleForTesting
  int verifyMaxAttempts = 3;
  @visibleForTesting
  Duration verifyBackoffBase = const Duration(seconds: 1);

  /// /iap/verify 1회 요청의 receiveTimeout.
  static const Duration _verifyReceiveTimeout = Duration(seconds: 30);

  /// verify 단계 최악 소요 시간 — 시도마다 connect+send+receive 타임아웃을
  /// 다 쓰고 백오프까지 기다린 경우 + 토큰 갱신 여유. paywall 의 verify 단계
  /// 타임아웃은 이 값을 써서, 정상 재시도 중인 결제를 "실패" 로 끊지 않는다.
  Duration get verifyWorstCase {
    final o = _verifyDio?.options;
    final perAttempt = (o?.connectTimeout ?? const Duration(seconds: 10)) +
        (o?.sendTimeout ?? const Duration(seconds: 30)) +
        _verifyReceiveTimeout;
    var backoff = Duration.zero;
    for (var a = 1; a < verifyMaxAttempts; a++) {
      backoff += verifyBackoffBase * (1 << (a - 1));
    }
    return perAttempt * verifyMaxAttempts + backoff + const Duration(seconds: 30);
  }

  Future<void> init() async {
    // Desktop purchases are not configured; server account entitlements remain authoritative.
    if (defaultTargetPlatform != TargetPlatform.android && defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      final available = await _iap.isAvailable();
      if (!available) {
        debugPrint('[iap] store not available — disabled');
        ObservabilityService.instance.breadcrumb('iap store unavailable', category: 'iap');
        return;
      }
      _sub = _iap.purchaseStream.listen(
        _onPurchaseUpdated,
        onError: (Object e, StackTrace st) {
          debugPrint('[iap] stream error: $e');
          ObservabilityService.instance.captureException(e, st, hint: 'iap purchaseStream error');
        },
      );
      // 로그인 전에 도착해 보류된 영수증을 로그인 직후 다시 처리.
      _authSub = AuthService.instance.onSession.listen((s) {
        if (!s.isSignedIn || _deferred.isEmpty) return;
        final retry = _deferred.values.toList();
        _deferred.clear();
        debugPrint('[iap] signed in — reprocessing ${retry.length} deferred purchase(s)');
        unawaited(_enqueue(retry));
      });
      _enabled = true;
    } catch (e, st) {
      debugPrint('[iap] init failed: $e');
      ObservabilityService.instance.captureException(e, st, hint: 'iap init failed');
    }
  }

  Future<void> loadProducts() async {
    if (!_enabled) return;
    try {
      final r = await _iap.queryProductDetails(kProductIds);
      _products = r.productDetails;
      if (r.notFoundIDs.isNotEmpty) {
        debugPrint('[iap] products not found: ${r.notFoundIDs}');
        ObservabilityService.instance.captureException(
          StateError('iap products not found: ${r.notFoundIDs}'),
          StackTrace.current,
          tags: {'store': _storeName, 'product_id': r.notFoundIDs.join(',')},
          hint: 'iap products not found',
        );
      }
      if (r.error != null) {
        ObservabilityService.instance.captureException(
          StateError('iap queryProductDetails error: ${r.error!.code} ${r.error!.message}'),
          StackTrace.current,
          tags: {'store': _storeName},
          hint: 'iap queryProductDetails error',
        );
      }
    } catch (e, st) {
      debugPrint('[iap] loadProducts failed: $e');
      ObservabilityService.instance.captureException(e, st,
          tags: {'store': _storeName}, hint: 'iap loadProducts failed');
    }
  }

  /// 결제 시트를 띄운다. null = 시트가 떴음 (결과는 [onPurchaseResult]);
  /// 그 외 = 시작조차 못 한 사유.
  ///
  /// Android: 이미 자동 갱신 중인 Pro 구독이 있으면 두 번째 구독을 시작하지
  /// 않고 그 영수증을 verify 한다 (이중 결제 방지). 이때도 null 을 반환하며,
  /// 결과는 소유 중인 상품 id 로 [onPurchaseResult] 에 도착한다 —
  /// [onAlreadyOwned] 가 그 id 로 먼저 호출된다.
  Future<IapError?> buy(
    String productId, {
    void Function(String ownedProductId)? onAlreadyOwned,
  }) async {
    debugPrint('[iap] buy() enabled=$_enabled products=${_products.map((p) => p.id).toList()} requested=$productId');
    if (!_enabled) return IapError.storeError;
    // M1: applicationUserName = Supabase uid. 로그인 없이는 결제 시작 금지 —
    // 웹훅이 유저를 매핑할 수 없고 verify 도 401 로 떨어진다.
    final userId = AuthService.instance.current.userId;
    if (userId == null || userId.isEmpty) {
      debugPrint('[iap] buy() refused — not signed in');
      return IapError.notSignedIn;
    }
    if (_products.isEmpty) {
      // 부트 시 loadProducts 가 아직 안 끝났거나 실패 — 한 번 더 시도.
      debugPrint('[iap] buy() products empty → reload');
      await loadProducts();
    }
    final pd = _products.where((p) => p.id == productId).firstOrNull;
    if (pd == null) {
      debugPrint('[iap] product not loaded: $productId (have ${_products.length})');
      ObservabilityService.instance.captureException(
        StateError('iap buy: product not loaded $productId'),
        StackTrace.current,
        tags: {'store': _storeName, 'product_id': productId},
        hint: 'iap buy product not loaded',
      );
      return IapError.storeError;
    }
    if (pd is GooglePlayProductDetails) {
      final owned = await _ownedAndroidSubscription(userId);
      if (owned != null) {
        debugPrint('[iap] buy() $productId refused — already subscribed to ${owned.productID}; verifying it');
        ObservabilityService.instance.breadcrumb('iap buy already owned', category: 'iap',
            data: {'product_id': productId, 'owned_product_id': owned.productID});
        onAlreadyOwned?.call(owned.productID);
        unawaited(_enqueue([owned]));
        return null;
      }
    }
    try {
      final PurchaseParam param;
      if (pd is GooglePlayProductDetails) {
        // Subscriptions expose multiple offers (base plan + a "freetrial"
        // offer). A plain PurchaseParam defaults to the base plan = immediate
        // charge, which made the Play checkout say "Starting today" while the
        // paywall advertised a 7-day free trial — Google rejected that as a
        // mismatched purchase experience. Pass the trial offer's token so the
        // checkout actually applies the trial.
        param = GooglePlayPurchaseParam(
          productDetails: pd,
          applicationUserName: userId, // → obfuscatedAccountId
          offerToken: _androidOfferToken(pd),
        );
      } else {
        param = PurchaseParam(
          productDetails: pd,
          applicationUserName: userId, // → StoreKit appAccountToken (UUID)
        );
      }
      ObservabilityService.instance.breadcrumb('iap buy', category: 'iap',
          data: {'product_id': productId, 'store': _storeName});
      final ok = await _iap.buyNonConsumable(purchaseParam: param);
      debugPrint('[iap] buyNonConsumable returned=$ok for $productId');
      if (!ok) {
        ObservabilityService.instance.captureException(
          StateError('iap buyNonConsumable returned false'),
          StackTrace.current,
          tags: {'store': _storeName, 'product_id': productId},
          hint: 'iap buy not launched',
        );
        return IapError.storeError;
      }
      return null;
    } catch (e, st) {
      debugPrint('[iap] buy failed: $e');
      ObservabilityService.instance.captureException(e, st,
          tags: {'store': _storeName, 'product_id': productId}, hint: 'iap buy failed');
      ProductAnalytics.instance.track(
        ProductEvent.purchaseFailed,
        properties: {
          'feature': 'subscription',
          'error_code': 'launch_exception',
          'store': _storeName,
        },
      );
      return IapError.storeError;
    }
  }

  /// Play 에서 이미 소유 중(구매 완료 + 자동 갱신 중)인 Pro 구독. 조회 실패 시
  /// null — 결제를 막지 않는다 (Play 자체도 같은 상품 재구매는 거절한다).
  Future<GooglePlayPurchaseDetails?> _ownedAndroidSubscription(String userId) async {
    try {
      final addition = _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
      final r = await addition.queryPastPurchases(applicationUserName: userId);
      if (r.error != null) {
        debugPrint('[iap] queryPastPurchases error: ${r.error!.code} ${r.error!.message}');
      }
      for (final p in r.pastPurchases) {
        if (!kProductIds.contains(p.productID)) continue;
        if (p.status != PurchaseStatus.purchased) continue;
        // 해지(자동 갱신 꺼짐)된 구독은 곧 끝나므로 새 구독을 막지 않는다.
        if (!p.billingClientPurchase.isAutoRenewing) continue;
        return p;
      }
    } catch (e, st) {
      debugPrint('[iap] queryPastPurchases failed: $e');
      ObservabilityService.instance.captureException(e, st,
          tags: {'store': _storeName}, hint: 'iap queryPastPurchases failed');
    }
    return null;
  }

  /// Picks which Play offer to launch billing with. Prefers an offer that
  /// contains a free ($0) phase (the 7-day trial) so eligible users actually
  /// get it; falls back to the base plan. Google Play only returns offers the
  /// user is eligible for, so a returning user (trial already used) has no free
  /// phase here and is billed immediately — matching the paywall, which hides
  /// the trial line in the same case (see IapPricing.hasFreeTrial).
  String? _androidOfferToken(GooglePlayProductDetails pd) {
    final offers = pd.productDetails.subscriptionOfferDetails ?? const [];
    if (offers.isEmpty) return null;
    for (final o in offers) {
      if (o.pricingPhases.any((ph) => ph.priceAmountMicros == 0)) {
        return o.offerIdToken;
      }
    }
    final base = offers.firstWhere(
      (o) => o.offerId == null,
      orElse: () => offers.first,
    );
    return base.offerIdToken;
  }

  /// 스토어에 영수증 재전달을 요청. true = 요청 자체는 성공 (결과는
  /// [onPurchaseResult] 로 비동기 도착, 없으면 아무 것도 안 옴).
  Future<bool> restore() async {
    if (!_enabled) return false;
    try {
      ObservabilityService.instance.breadcrumb('iap restore', category: 'iap');
      await _iap.restorePurchases();
      return true;
    } catch (e, st) {
      debugPrint('[iap] restore failed: $e');
      ObservabilityService.instance.captureException(e, st,
          tags: {'store': _storeName}, hint: 'iap restore failed');
      return false;
    }
  }

  void _onPurchaseUpdated(List<PurchaseDetails> list) {
    unawaited(_enqueue(list));
  }

  /// Test hook: purchaseStream 이벤트를 흉내 낸다 (배치 처리 완료 시 완료).
  @visibleForTesting
  Future<void> debugHandlePurchaseUpdates(List<PurchaseDetails> list) =>
      _enqueue(list);

  /// Test hook: 로그인 대기로 보류된 영수증 수.
  @visibleForTesting
  int get debugDeferredCount => _deferred.length;

  /// Test hook: 체인에서 실제로 처리된 항목 수 (중복 배달은 세지 않음).
  @visibleForTesting
  int debugProcessedCount = 0;

  static bool _needsVerify(PurchaseDetails p) =>
      p.status == PurchaseStatus.purchased || p.status == PurchaseStatus.restored;

  /// 영수증 식별 key — 같은 거래의 중복 배달 판정용.
  static String _keyOf(PurchaseDetails p) {
    final id = p.purchaseID;
    return id != null && id.isNotEmpty
        ? '${p.productID}#$id'
        : '${p.productID}#${p.verificationData.serverVerificationData}';
  }

  /// [list] 를 직렬 체인 뒤에 붙인다. 이미 verify 대기/진행 중인 영수증은
  /// 건너뛴다. 반환 Future 는 이 배치 처리가 끝나면 완료 (throw 하지 않음).
  Future<void> _enqueue(List<PurchaseDetails> list) {
    final batch = <PurchaseDetails>[];
    for (final p in list) {
      if (_needsVerify(p) && !_inFlight.add(_keyOf(p))) {
        debugPrint('[iap] ${p.productID} already being verified — skip duplicate delivery');
        continue;
      }
      batch.add(p);
    }
    if (batch.isEmpty) return _chain;
    return _chain = _chain.then((_) async {
      for (final p in batch) {
        try {
          await _processPurchase(p);
        } catch (e, st) {
          debugPrint('[iap] purchase update failed: $e');
          ObservabilityService.instance.captureException(e, st,
              tags: {'store': _storeName, 'product_id': p.productID},
              hint: 'iap purchase update failed');
        } finally {
          if (_needsVerify(p)) _inFlight.remove(_keyOf(p));
        }
      }
    });
  }

  Future<void> _processPurchase(PurchaseDetails p) async {
    debugProcessedCount++;
    switch (p.status) {
      case PurchaseStatus.pending:
        // 최종 결과 아님 — paywall 이 "승인 대기" 를 표시하고 계속 기다린다.
        debugPrint('[iap] pending: ${p.productID}');
        _resultCtl.add(IapResult(ok: false, productId: p.productID, error: IapError.pending));
        return;
      case PurchaseStatus.canceled:
        _resultCtl.add(IapResult(ok: false, productId: p.productID, error: IapError.canceled));
        if (p.pendingCompletePurchase) await _complete(p);
        break;
      case PurchaseStatus.error:
        final msg = p.error?.message ?? 'unknown';
        debugPrint('[iap] purchase error: ${p.error?.code} $msg');
        ObservabilityService.instance.captureException(
          StateError('iap purchase error: ${p.error?.code} $msg'),
          StackTrace.current,
          tags: {'store': _storeName, 'product_id': p.productID},
          hint: 'iap purchase error',
        );
        ProductAnalytics.instance.track(
          ProductEvent.purchaseFailed,
          properties: {
            'feature': 'subscription',
            'error_code': 'store_error',
            'store': _storeName,
          },
        );
        _resultCtl.add(IapResult(
          ok: false, productId: p.productID,
          error: IapError.storeError, message: msg,
        ));
        if (p.pendingCompletePurchase) await _complete(p);
        break;
      case PurchaseStatus.purchased:
      case PurchaseStatus.restored:
        // 로그인 안 된 상태에서 StoreKit 이 부팅 시 기존 영수증을 auto-replay
        // 하는 경우(iOS sandbox 의 정상 동작) → 토큰이 없으므로 verify 가 무조건
        // 401. 이때는 receipt 도 complete 하지 않고 큐에 남겨두어, 사용자가
        // 로그인 + restore 했을 때 정상 흐름으로 복원되도록 한다.
        // Supabase 초기화 전(부팅 race) 이거나 미로그인 — 보류 목록에 두고
        // AuthService.onSession 의 로그인 세션에서 재처리한다.
        final token = await AuthService.instance.currentAccessToken();
        if (token == null || token.isEmpty) {
          debugPrint('[iap] purchase delivered without auth — deferring (left in queue): ${p.productID}');
          // 결과 emit 도 하지 않음 (paywall completer 가 의미 없는 false 로 풀리는 것 방지).
          _deferred[_keyOf(p)] = p;
          return;
        }
        final restored = p.status == PurchaseStatus.restored;
        final key = _keyOf(p);
        final recent = _recent[key];
        if (recent != null && DateTime.now().difference(recent.$1) < _recentTtl) {
          // 방금 pro 로 확정된 같은 영수증 — 서버 재호출 없이 결과만 재발행.
          debugPrint('[iap] ${p.productID} verified moments ago — reusing result');
          final r = recent.$2;
          _resultCtl.add(IapResult(
            ok: r.ok, productId: r.productId, renewsAt: r.renewsAt, restored: restored,
          ));
          if (p.pendingCompletePurchase) await _complete(p);
          return;
        }
        _verifyStartedCtl.add(p.productID);
        final v = await _verifyWithRetry(p);
        // 200 + pro:false 는 "검증 실패" 가 아니라 확정된 "권한 없음" (예: iOS
        // restore 가 만료된 옛 영수증까지 재생). 복원 경로에서는 에러 없이
        // 흘려보내 LoopStore 가 nothingFound 로 판정하게 한다.
        final notEntitled = !v.pro && v.httpStatus == 200;
        final IapError? error;
        if (v.pro) {
          error = null;
        } else if (notEntitled) {
          error = restored ? null : IapError.verifyFailed;
        } else {
          error = v.error ?? IapError.verifyFailed;
        }
        final result = IapResult(
          ok: v.pro,
          productId: p.productID,
          error: error,
          renewsAt: v.expiresAt,
          restored: restored,
        );
        _resultCtl.add(result);
        if (v.pro) {
          _recent.removeWhere((_, e) => DateTime.now().difference(e.$1) >= _recentTtl);
          _recent[key] = (DateTime.now(), result);
          ProductAnalytics.instance.track(
            restored
                ? ProductEvent.purchaseRestored
                : ProductEvent.purchaseCompleted,
            properties: {
              'feature': 'subscription',
              'store': _storeName,
            },
          );
          ProductAnalytics.instance.setPlan(true);
        } else if (!notEntitled) {
          ProductAnalytics.instance.track(
            ProductEvent.purchaseFailed,
            properties: {
              'feature': 'subscription',
              'error_code': 'verify_failed',
              'store': _storeName,
            },
          );
        }
        // 409(결제 승인 대기) 는 아직 소유 확정 전 — 스토어 큐에 남겨 승인 후
        // 다시 배달받는다. 그 외에는 항상 complete (검증 실패여도 영수증은
        // 스토어에 남아 있어 "구매 복원" 으로 재검증 가능).
        if (v.error != IapError.paymentPending && p.pendingCompletePurchase) {
          await _complete(p);
        }
        break;
    }
  }

  /// completePurchase (Android: acknowledge) 실패를 삼키지 않고 한 번 재시도.
  /// 미승인 구독은 3일 뒤 Google 이 자동 환불 — 서버 /iap/verify 도 승인하지만
  /// 여기서도 최대한 확정한다.
  Future<void> _complete(PurchaseDetails p) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await _iap.completePurchase(p);
        return;
      } catch (e, st) {
        debugPrint('[iap] completePurchase attempt $attempt failed: $e');
        if (attempt == 2) {
          ObservabilityService.instance.captureException(e, st,
              tags: {'store': _storeName, 'product_id': p.productID},
              hint: 'iap completePurchase failed');
        } else {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
      }
    }
  }

  Future<_VerifyOutcome> _verifyWithRetry(PurchaseDetails p) async {
    _VerifyOutcome last = const _VerifyOutcome(pro: false, error: IapError.verifyFailed);
    for (var attempt = 1; attempt <= verifyMaxAttempts; attempt++) {
      last = await _verifyOnServer(p);
      if (last.pro || !iapVerifyShouldRetry(last.httpStatus)) return last;
      if (attempt < verifyMaxAttempts) {
        final wait = verifyBackoffBase * (1 << (attempt - 1));
        debugPrint('[iap] verify attempt $attempt failed (${last.httpStatus}) — retry in ${wait.inMilliseconds}ms');
        await Future<void>.delayed(wait);
      }
    }
    return last;
  }

  Future<_VerifyOutcome> _verifyOnServer(PurchaseDetails p) async {
    final dio = _verifyDio;
    if (dio == null) {
      // 검증 백엔드 미연결: release 에서는 절대 통과시키지 않는다 (M13).
      debugPrint('[iap] verify dio not configured — ${kReleaseMode ? 'REJECTING (release)' : 'accepting locally (debug)'}');
      return _VerifyOutcome(pro: !kReleaseMode, error: kReleaseMode ? IapError.verifyFailed : null);
    }
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final storeTag = isIos ? 'app_store' : 'play_store';
    try {
      final receipt = isIos
          // App Store: StoreKit JWS / transactionId / legacy receipt — 그대로.
          ? p.verificationData.serverVerificationData
          // Play Store: backend 가 JSON {productId, purchaseToken} 으로 기대.
          : jsonEncode({
              'productId': p.productID,
              'purchaseToken': p.verificationData.serverVerificationData,
            });
      final body = {
        'store': storeTag,
        'receipt_data': receipt,
        'product_id': p.productID,
      };
      debugPrint('[iap] verify POST product=${p.productID} receipt.len=${receipt.length} source=${p.verificationData.source}');
      final r = await dio.post<Map<String, dynamic>>(
        _verifyPath,
        data: body,
        options: Options(
          // 4xx/5xx 도 throw 안 하고 응답으로 받아 body 까지 로깅.
          validateStatus: (_) => true,
          receiveTimeout: _verifyReceiveTimeout,
        ),
      );
      final status = r.statusCode;
      if (status != 200) {
        debugPrint('[iap] verify non-200: $status body=${r.data}');
        ObservabilityService.instance.captureException(
          IapVerifyHttpException(status ?? 0, r.data),
          StackTrace.current,
          tags: {
            'store': storeTag,
            'product_id': p.productID,
            'http_status': '${status ?? 0}',
          },
          hint: 'iap verify non-200',
        );
        return _VerifyOutcome(
          pro: false,
          error: iapErrorFromHttpStatus(status),
          httpStatus: status,
        );
      }
      // backend response: { pro, status, product_id, expires_at, ... } — `pro`
      // 가 판정 (M2). status 는 표시용.
      final data = r.data ?? const <String, dynamic>{};
      final pro = data['pro'] == true;
      final expiresRaw = data['expires_at'];
      final expiresAt = expiresRaw is String ? DateTime.tryParse(expiresRaw) : null;
      debugPrint('[iap] verify pro=$pro status=${data['status']} expires_at=$expiresRaw');
      return _VerifyOutcome(
        pro: pro,
        error: pro ? null : IapError.verifyFailed,
        httpStatus: 200,
        expiresAt: expiresAt,
      );
    } catch (e, st) {
      debugPrint('[iap] verify exception: $e');
      ObservabilityService.instance.captureException(e, st,
          tags: {'store': storeTag, 'product_id': p.productID}, hint: 'iap verify exception');
      return const _VerifyOutcome(pro: false, error: IapError.network);
    }
  }

  String get _storeName =>
      defaultTargetPlatform == TargetPlatform.iOS ? 'app_store' : 'play_store';

  Future<void> dispose() async {
    await _sub?.cancel();
    await _authSub?.cancel();
    await _resultCtl.close();
    await _verifyStartedCtl.close();
  }
}

class _VerifyOutcome {
  const _VerifyOutcome({required this.pro, this.error, this.httpStatus, this.expiresAt});
  final bool pro;
  final IapError? error;
  /// null = 요청이 서버에 도달하지 못함(예외).
  final int? httpStatus;
  final DateTime? expiresAt;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
