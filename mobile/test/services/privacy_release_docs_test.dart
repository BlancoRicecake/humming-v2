import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'all published privacy-policy sources contain the Firebase disclosure',
    () {
      final policyFiles = <File>[
        File('assets/legal/privacy.md'),
        File('../docs/legal/privacy-policy.md'),
        File('../landing/privacy/index.html'),
      ];

      for (final file in policyFiles) {
        final text = file.readAsStringSync();
        expect(text, contains('1.4-draft'), reason: file.path);
        expect(text, contains('2026-11-01'), reason: file.path);
        expect(text, contains('Firebase Analytics'), reason: file.path);
        expect(text, contains('익명 사용 분석'), reason: file.path);
        expect(text, contains('Anonymous usage analytics'), reason: file.path);
        expect(text, contains('app instance identifier'), reason: file.path);
        expect(text, contains('2 months'), reason: file.path);
        expect(text, contains('advertising'), reason: file.path);
      }
    },
  );

  test('store and physical-device draft records the production gate', () {
    final text =
        File(
          '../docs/release/HUMTRACK-FIREBASE-PRIVACY-SUBMISSION-DRAFTS.md',
        ).readAsStringSync();

    for (final requiredText in <String>[
      'App Store Privacy draft',
      'Google Play Data safety draft',
      'Physical-device DebugView validation',
      'FIREBASE_ANALYTICS_ENABLED=true',
      'HUMTRACK_FIREBASE_DISCLOSURES_READY=true',
      'Do not submit',
      'app_started',
      'guided_song_failed',
      'purchase_completed',
      'Android advertising ID and iOS IDFA are disabled',
    ]) {
      expect(text, contains(requiredText), reason: requiredText);
    }
  });
}
