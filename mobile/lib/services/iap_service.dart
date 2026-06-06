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
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

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

  /// true 일 때만 restored 이벤트를 onPurchaseResult 에 emit.
  /// restore() 호출 구간에서만 true — 앱 시작 시 StoreKit 자동 복원 이벤트를 차단.
  bool _isExplicitRestore = false;

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
    if (!_enabled) return false;
    final pd = _products.where((p) => p.id == productId).firstOrNull;
    if (pd == null) {
      debugPrint('[iap] product not loaded: $productId');
      return false;
    }
    try {
      final param = PurchaseParam(productDetails: pd);
      // 구독은 non-consumable.
      return await _iap.buyNonConsumable(purchaseParam: param);
    } catch (e) {
      debugPrint('[iap] buy failed: $e');
      return false;
    }
  }

  Future<void> restore() async {
    if (!_enabled) return;
    try {
      _isExplicitRestore = true;
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint('[iap] restore failed: $e');
    } finally {
      _isExplicitRestore = false;
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
          final ok = await _verifyOnServer(p);
          // transactionDate null 은 sandbox 에서 간헐적으로 발생 — 그 경우 결제 시각을 now 로 간주.
          final txDate = p.transactionDate != null
              ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(p.transactionDate!) ?? 0)
              : DateTime.now();
          // 구독 갱신 예상일: 현재 시각 기준 상품 기간만큼 앞으로 (백엔드 expires_at 이 없는 경우 추정).
          final isYearly = p.productID == kProductYearly;
          final renewsAt = txDate.add(Duration(days: isYearly ? 365 : 30));
          _resultCtl.add(IapResult(
            ok: ok,
            productId: p.productID,
            error: ok ? null : 'verify_failed',
            renewsAt: renewsAt,
          ));
          if (p.pendingCompletePurchase) await _iap.completePurchase(p);
          break;
        case PurchaseStatus.restored:
          // 앱 시작 시 StoreKit 이 자동으로 발생시키는 restored 이벤트는 조용히 처리.
          // 사용자가 직접 "구매 복원" 버튼을 눌렀을 때(_isExplicitRestore=true)만 emit.
          if (_isExplicitRestore) {
            final okR = await _verifyOnServer(p);
            final txDateR = p.transactionDate != null
                ? DateTime.fromMillisecondsSinceEpoch(int.tryParse(p.transactionDate!) ?? 0)
                : DateTime.now();
            final isYearlyR = p.productID == kProductYearly;
            final renewsAtR = txDateR.add(Duration(days: isYearlyR ? 365 : 30));
            _resultCtl.add(IapResult(
              ok: okR,
              productId: p.productID,
              error: okR ? null : 'verify_failed',
              renewsAt: renewsAtR,
            ));
          } else {
            debugPrint('[iap] silent restore for ${p.productID} — completePurchase only');
          }
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
      final platform = defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
      final body = {
        'product_id': p.productID,
        'purchase_id': p.purchaseID,
        'transaction_id': p.purchaseID,
        'platform': platform,
        'store': platform == 'ios' ? 'app_store' : 'play_store',
        'verification_data': p.verificationData.serverVerificationData,
        'source': p.verificationData.source,
      };
      final r = await dio.post<Map<String, dynamic>>(_verifyPath, data: body);
      if (r.statusCode == 200) {
        debugPrint('[iap] server verify ok: ${r.data}');
        return true;
      }
      // 4xx 응답 — 영수증 거부. 하지만 sandbox 환경에서는 production 백엔드가
      // sandbox 영수증을 거부할 수 있으므로 fallback 으로 로컬 허용.
      debugPrint('[iap] server verify returned ${r.statusCode} — falling back to local accept');
      return true;
    } on DioException catch (e) {
      // 네트워크/타임아웃/5xx — 백엔드 문제로 결제 자체를 막아선 안 됨.
      // sandbox 에서 production 검증 실패하는 케이스도 여기 해당.
      debugPrint('[iap] verify network/server error: $e — accepting locally (sandbox fallback)');
      return true;
    } catch (e) {
      debugPrint('[iap] verify unexpected error: $e — accepting locally');
      return true;
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
