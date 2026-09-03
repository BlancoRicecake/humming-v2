// paywall_sheet — IapError / RestoreOutcome → user copy (audit M5/M6/M12):
// cancel stays silent, pending shows the waiting copy, post-payment verify
// failures reassure ("payment received") instead of "purchase failed", and
// restore outcomes each get their own line. Uses the generated English
// localisation directly (no widget tree).
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations_en.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/sheets/paywall_sheet.dart';
import 'package:humming/services/iap_types.dart';

void main() {
  final l = L10nEn();

  test('user cancel is silent', () {
    expect(paywallMessageFor(l, IapError.canceled, storeEnabled: true), isNull);
    expect(paywallMessageFor(l, null, storeEnabled: true), isNull);
  });

  test('pending (store or server 409) → waiting copy', () {
    expect(paywallMessageFor(l, IapError.pending, storeEnabled: true), l.payPendingApproval);
    expect(paywallMessageFor(l, IapError.paymentPending, storeEnabled: true), l.payPendingApproval);
  });

  test('post-payment verify problems → "payment received" reassurance', () {
    for (final e in [IapError.verifyFailed, IapError.network, IapError.throttled]) {
      expect(paywallMessageFor(l, e, storeEnabled: true), l.payVerifyFailed);
    }
    expect(l.payVerifyFailed, contains('Restore purchases'));
  });

  test('store errors distinguish unavailable store', () {
    expect(paywallMessageFor(l, IapError.storeError, storeEnabled: true), l.payPurchaseFailed);
    expect(paywallMessageFor(l, IapError.storeError, storeEnabled: false), l.payStoreUnavailableDevice);
    expect(paywallMessageFor(l, IapError.notSignedIn, storeEnabled: true), l.paySignInRequired);
  });

  test('restore outcomes each map to a distinct message', () {
    final msgs = RestoreOutcome.values.map((o) => restoreMessageFor(l, o)).toSet();
    expect(msgs.length, RestoreOutcome.values.length);
    expect(restoreMessageFor(l, RestoreOutcome.restored), l.payRestoreDone);
    expect(restoreMessageFor(l, RestoreOutcome.nothingFound), l.payRestoreEmpty);
  });

  test('trial disclosure is conditional on eligibility and names the price', () {
    final t = l.payDisclosureTrial(7, r'$33.49', 'year');
    expect(t, contains('new subscribers'));
    expect(t, contains(r'$33.49'));
    expect(t, contains('Auto-renews'));
    expect(l.payDisclosureNoTrial(r'$3.49', 'month'), isNot(contains('trial')));
  });

  test('benefit copy names only real Pro features', () {
    final b = l.payBenefits(4).toLowerCase();
    expect(b, contains('unlimited songs'));
    expect(b, contains('export'));
    expect(b, isNot(contains('cloud')));
    expect(b, isNot(contains('sync')));
    expect(l.acctProBenefits.toLowerCase(), isNot(contains('cloud')));
    expect(l.acctSignInSub.toLowerCase(), isNot(contains('sync')));
  });
}
