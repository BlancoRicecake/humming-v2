import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android keeps Firebase collection and advertising signals off by default',
    () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

      expect(
        manifest,
        contains('android:name="firebase_analytics_collection_enabled"'),
      );
      expect(
        manifest,
        contains('android:name="google_analytics_adid_collection_enabled"'),
      );
      expect(
        manifest,
        contains(
          'android:name="google_analytics_default_allow_ad_personalization_signals"',
        ),
      );
      expect(
        RegExp(
          r'android:name="(?:firebase_analytics_collection_enabled|google_analytics_adid_collection_enabled|google_analytics_default_allow_ad_personalization_signals)"\s+android:value="false"',
        ).allMatches(manifest),
        hasLength(3),
      );
    },
  );

  test('iOS keeps Firebase collection and identifiers off by default', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final podfile = File('ios/Podfile').readAsStringSync();

    for (final key in [
      'FIREBASE_ANALYTICS_COLLECTION_ENABLED',
      'GOOGLE_ANALYTICS_DEFAULT_ALLOW_AD_PERSONALIZATION_SIGNALS',
      'GOOGLE_ANALYTICS_IDFV_COLLECTION_ENABLED',
    ]) {
      expect(plist, matches(RegExp('<key>$key</key>\\s*<false/>')));
    }
    expect(podfile, contains(r'$FirebaseAnalyticsWithoutAdIdSupport = true'));
  });
}
