// IapService purchase-update queue: events are processed serially, a receipt
// that is already queued/being verified is not verified twice, and receipts
// delivered before auth is ready are kept (deferred) for a retry on sign-in
// instead of being dropped. Auth is not configured in tests, so every
// purchased/restored item takes the "no token → defer" path.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/services/iap_service.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

PurchaseDetails _purchase(String id, {PurchaseStatus status = PurchaseStatus.purchased}) =>
    PurchaseDetails(
      purchaseID: id,
      productID: kProductYearly,
      verificationData: PurchaseVerificationData(
        localVerificationData: 'local-$id',
        serverVerificationData: 'token-$id',
        source: 'test',
      ),
      transactionDate: '0',
      status: status,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final iap = IapService.instance;

  test('receipts without auth are deferred, duplicates collapse', () async {
    final before = iap.debugDeferredCount;
    final processedBefore = iap.debugProcessedCount;
    final a = _purchase('A');
    // Same receipt delivered twice in a row (startup restore + manual restore)
    // plus a second, distinct receipt.
    final first = iap.debugHandlePurchaseUpdates([a]);
    final dup = iap.debugHandlePurchaseUpdates([_purchase('A', status: PurchaseStatus.restored)]);
    final other = iap.debugHandlePurchaseUpdates([_purchase('B')]);
    await Future.wait([first, dup, other]);
    expect(iap.debugDeferredCount, before + 2);
    expect(iap.debugProcessedCount, processedBefore + 2); // dup skipped

    // Re-delivery after the first finished is processed again (still deferred
    // under the same key — no growth).
    await iap.debugHandlePurchaseUpdates([_purchase('A')]);
    expect(iap.debugDeferredCount, before + 2);
  });

  test('pending updates emit an intermediate result and are not deferred', () async {
    final before = iap.debugDeferredCount;
    final results = <IapResult>[];
    final sub = iap.onPurchaseResult.listen(results.add);
    await iap.debugHandlePurchaseUpdates([_purchase('P', status: PurchaseStatus.pending)]);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(results.single.error, IapError.pending);
    expect(iap.debugDeferredCount, before);
  });

  test('verify-phase timeout budget covers every retry', () {
    final worst = iap.verifyWorstCase;
    // 3 attempts x (connect + send + 30s receive) + 1s/2s backoff.
    expect(worst, greaterThan(const Duration(seconds: 3 * 30 + 3)));
    expect(worst, greaterThan(const Duration(seconds: 60)));
  });
}
