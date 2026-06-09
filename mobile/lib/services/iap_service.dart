// in_app_purchase 통합 — Pro 월/연 구독. 영수증은 백엔드 /iap/verify 로 위임.
//
// 상품 ID (App Store + Play 동일):
//   - humtrack_pro_monthly_v2  (구 humtrack_pro_monthly 는 Apple reservation 잔존 → v2 로 재발급, 2026-06-03)
//   - humtrack_pro_yearly
//
// 호출 흐름:
//   1. init()              — main() 에서 한 번. 스토어 가용성 체크 + listener 부착.
//   2. loadProducts()      — paywall 시트가 진입 시 호출.
//   3. buy(productId)      — paywall 결제 버튼 onTap.
//   4. restore()           — "구매 복원" 버튼.
//   5. onPurchaseResult    — Stream<IapResult>; ProjectStore 에서 listen 후 subscription 갱신.
//
// 스토어 가용성(`isAvailable`) 이 false 면 enabled=false → 호출자는 mockPurchase 폴백.
//
// 백엔드 verify payload (backend/app/models.py:IapVerifyRequest):
//   { store: "app_store" | "play_store",
//     receipt_data: <Apple JWS or transactionId; Google JSON {productId, purchaseToken}>,
//     product_id?: <SKU> }
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'auth_service.dart';

const String kProductMonthly = 'humtrack_pro_monthly_v2';
const String kProductYearly  = 'humtrack_pro_yearly';
const Set<String> kProductIds = {kProductMonthly, kProductYearly};

class IapResult {
  const IapResult({
    required this.ok,
    required this.productId,
    this.error,
    this.renewsAt,
  });
  final bool ok;
  final String productId;
  final String? error;
  final DateTime? renewsAt;
}

class IapService {
  IapService._();
  static final IapService instance = IapService._();

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  final _resultCtl = StreamController<IapResult>.broadcast();
  Stream<IapResult> get onPurchaseResult => _resultCtl.stream;

  bool _enabled = false;
  bool get enabled => _enabled;

  List<ProductDetails> _products = const [];
  List<ProductDetails> get products => _products;

  /// /iap/verify 백엔드 호출용 dio — main 에서 주입. null 이면 receipt 검증 스킵
  /// (개발 모드: 결제 성공만으로 subscription=active 처리).
  Dio? _verifyDio;
  String _verifyPath = '/iap/verify';
  void configureVerify(Dio dio, {String path = '/iap/verify'}) {
    _verifyDio = dio;
    _verifyPath = path;
  }

  Future<void> init() async {
    try {
      final available = await _iap.isAvailable();
      if (!available) {
        debugPrint('[iap] store not available — disabled (mock fallback)');
        return;
      }
      _sub = _iap.purchaseStream.listen(
        _onPurchaseUpdated,
        onError: (e) => debugPrint('[iap] stream error: $e'),
      );
      _enabled = true;
    } catch (e) {
      debugPrint('[iap] init failed: $e');
    }
  }

  Future<void> loadProducts() async {
    if (!_enabled) return;
    try {
      final r = await _iap.queryProductDetails(kProductIds);
      _products = r.productDetails;
      if (r.notFoundIDs.isNotEmpty) {
        debugPrint('[iap] products not found: ${r.notFoundIDs}');
      }
    } catch (e) {
      debugPrint('[iap] loadProducts failed: $e');
    }
  }

  Future<bool> buy(String productId) async {
    debugPrint('[iap] buy() enabled=$_enabled products=${_products.map((p) => p.id).toList()} requested=$productId');
    if (!_enabled) return false;
    if (_products.isEmpty) {
      // 부트 시 loadProducts 가 아직 안 끝났거나 실패 — 한 번 더 시도.
      debugPrint('[iap] buy() products empty → reload');
      await loadProducts();
    }
    final pd = _products.where((p) => p.id == productId).firstOrNull;
    if (pd == null) {
      debugPrint('[iap] product not loaded: $productId (have ${_products.length})');
      return false;
    }
    try {
      final param = PurchaseParam(productDetails: pd);
      final ok = await _iap.buyNonConsumable(purchaseParam: param);
      debugPrint('[iap] buyNonConsumable returned=$ok for $productId');
      return ok;
    } catch (e) {
      debugPrint('[iap] buy failed: $e');
      return false;
    }
  }

  Future<void> restore() async {
    if (!_enabled) return;
    try {
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('[iap] restore failed: $e');
    }
  }

  Future<void> _onPurchaseUpdated(List<PurchaseDetails> list) async {
    for (final p in list) {
      switch (p.status) {
        case PurchaseStatus.pending:
          continue;
        case PurchaseStatus.canceled:
          _resultCtl.add(IapResult(ok: false, productId: p.productID, error: 'canceled'));
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);
          break;
        case PurchaseStatus.error:
          _resultCtl.add(IapResult(
            ok: false, productId: p.productID,
            error: p.error?.message ?? 'unknown',
          ));
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          // 로그인 안 된 상태에서 StoreKit 이 부팅 시 기존 영수증을 auto-replay
          // 하는 경우(iOS sandbox 의 정상 동작) → 토큰이 없으므로 verify 가 무조건
          // 401. 이때는 receipt 도 complete 하지 않고 큐에 남겨두어, 사용자가
          // 로그인 + restore 했을 때 정상 흐름으로 복원되도록 한다.
          final token = await AuthService.instance.currentAccessToken();
          if (token == null || token.isEmpty) {
            debugPrint('[iap] purchase delivered without auth — deferring (left in queue): ${p.productID}');
            // 결과 emit 도 하지 않음 (paywall completer 가 의미 없는 false 로 풀리는 것 방지).
            continue;
          }
          final ok = await _verifyOnServer(p);
          _resultCtl.add(IapResult(
            ok: ok,
            productId: p.productID,
            error: ok ? null : 'verify_failed',
          ));
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);
          break;
      }
    }
  }

  Future<bool> _verifyOnServer(PurchaseDetails p) async {
    final dio = _verifyDio;
    if (dio == null) {
      // 검증 백엔드 미연결 → 결제 성공만으로 통과 처리(dev/staging).
      debugPrint('[iap] verify dio not configured — accepting locally');
      return true;
    }
    try {
      final isIos = defaultTargetPlatform == TargetPlatform.iOS;
      final receipt = isIos
          // App Store: StoreKit JWS / transactionId / legacy receipt — 그대로.
          ? p.verificationData.serverVerificationData
          // Play Store: backend 가 JSON {productId, purchaseToken} 으로 기대.
          : jsonEncode({
              'productId': p.productID,
              'purchaseToken': p.verificationData.serverVerificationData,
            });
      final body = {
        'store': isIos ? 'app_store' : 'play_store',
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
        ),
      );
      if (r.statusCode != 200) {
        debugPrint('[iap] verify non-200: ${r.statusCode} body=${r.data}');
        return false;
      }
      // backend response: { status: SubStatus, product_id, expires_at, ... }
      final status = (r.data?['status'] as String?)?.toLowerCase();
      final ok = status == 'active' || status == 'trial';
      debugPrint('[iap] verify ok=$ok status=$status data=${r.data}');
      return ok;
    } catch (e) {
      debugPrint('[iap] verify exception: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _resultCtl.close();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
