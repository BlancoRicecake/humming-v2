// Which store a build buys through: iOS and the Mac App Store build use
// StoreKit (`app_store`), Android uses Play, and the direct-download Mac build
// has no store channel (server account Pro only).
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/services/iap_types.dart';

void main() {
  test('iOS always uses the App Store', () {
    expect(usesAppStore(TargetPlatform.iOS, macAppStore: false), isTrue);
    expect(hasStorePurchases(TargetPlatform.iOS, macAppStore: false), isTrue);
  });

  test('Android uses Play, not the App Store', () {
    expect(usesAppStore(TargetPlatform.android), isFalse);
    expect(hasStorePurchases(TargetPlatform.android), isTrue);
  });

  test('macOS uses the App Store only in the Mac App Store build', () {
    expect(usesAppStore(TargetPlatform.macOS, macAppStore: true), isTrue);
    expect(hasStorePurchases(TargetPlatform.macOS, macAppStore: true), isTrue);
    expect(usesAppStore(TargetPlatform.macOS, macAppStore: false), isFalse);
    expect(hasStorePurchases(TargetPlatform.macOS, macAppStore: false), isFalse);
  });

  test('default builds leave the Mac store channel off', () {
    expect(kMacAppStoreBuild, isFalse);
    expect(hasStorePurchases(TargetPlatform.macOS), isFalse);
  });

  test('other desktops have no store channel', () {
    for (final p in [TargetPlatform.windows, TargetPlatform.linux]) {
      expect(hasStorePurchases(p, macAppStore: true), isFalse, reason: '$p');
    }
  });
}
