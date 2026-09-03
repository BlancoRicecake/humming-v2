// iap_types — HTTP status → IapError mapping used by the /iap/verify path
// (audit M5), the retry policy, and the store "manage subscription" links
// (audit M9). Pure Dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/services/iap_types.dart';

void main() {
  group('iapErrorFromHttpStatus', () {
    test('maps the backend contract', () {
      expect(iapErrorFromHttpStatus(null), IapError.network);
      expect(iapErrorFromHttpStatus(400), IapError.verifyFailed);
      expect(iapErrorFromHttpStatus(401), IapError.notSignedIn);
      expect(iapErrorFromHttpStatus(409), IapError.paymentPending);
      expect(iapErrorFromHttpStatus(429), IapError.throttled);
      expect(iapErrorFromHttpStatus(500), IapError.verifyFailed);
      expect(iapErrorFromHttpStatus(503), IapError.verifyFailed);
    });
  });

  group('iapVerifyShouldRetry', () {
    test('retries only transient failures', () {
      expect(iapVerifyShouldRetry(null), isTrue); // exception / unreachable
      expect(iapVerifyShouldRetry(429), isTrue);
      expect(iapVerifyShouldRetry(500), isTrue);
      expect(iapVerifyShouldRetry(502), isTrue);
      expect(iapVerifyShouldRetry(400), isFalse); // receipt rejected
      expect(iapVerifyShouldRetry(401), isFalse); // not signed in
      expect(iapVerifyShouldRetry(409), isFalse); // payment pending
      expect(iapVerifyShouldRetry(200), isFalse);
    });
  });

  group('IapResult', () {
    test('isPending covers store pending and server 409', () {
      const a = IapResult(ok: false, productId: 'p', error: IapError.pending);
      const b = IapResult(ok: false, productId: 'p', error: IapError.paymentPending);
      const c = IapResult(ok: false, productId: 'p', error: IapError.canceled);
      expect(a.isPending, isTrue);
      expect(b.isPending, isTrue);
      expect(c.isPending, isFalse);
    });
  });

  group('IapVerifyHttpException', () {
    test('keeps only the first 200 chars of the body', () {
      final e = IapVerifyHttpException(500, 'x' * 500);
      expect(e.body.length, 200);
      expect(e.toString(), startsWith('IapVerifyHttpException(500): '));
      expect(IapVerifyHttpException(400, null).body, '');
    });
  });

  group('manageSubscriptionUri', () {
    test('iOS → App Store subscriptions page', () {
      expect(
        manageSubscriptionUri(isIOS: true).toString(),
        'https://apps.apple.com/account/subscriptions',
      );
    });

    test('Android → Play subscriptions with sku + package', () {
      final u = manageSubscriptionUri(isIOS: false, productId: kProductYearly);
      expect(u.host, 'play.google.com');
      expect(u.path, '/store/account/subscriptions');
      expect(u.queryParameters['sku'], kProductYearly);
      expect(u.queryParameters['package'], kAndroidPackageName);
    });

    test('Android without a known product falls back to the monthly sku', () {
      expect(manageSubscriptionUri(isIOS: false).queryParameters['sku'], kProductMonthly);
      expect(manageSubscriptionUri(isIOS: false, productId: '').queryParameters['sku'], kProductMonthly);
    });
  });
}
