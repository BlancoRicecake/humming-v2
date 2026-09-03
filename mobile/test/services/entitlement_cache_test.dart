// entitlement_cache — offline/outage fallback for the Pro verdict (audit
// M3/M13): a cached verdict only stands in for the server for the same user
// and until expiresAt + 3 days; the startup restore() is throttled to once per
// 24h per user unless the cached entitlement has expired. Pure Dart + a temp
// dir (no path_provider).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/services/entitlement_cache.dart';

void main() {
  final now = DateTime.utc(2026, 9, 4, 12);

  EntitlementVerdict verdict({
    String userId = 'u1',
    bool pro = true,
    DateTime? expiresAt,
    String? status = 'active',
  }) =>
      EntitlementVerdict(
        userId: userId,
        pro: pro,
        status: status,
        productId: 'humtrack_pro_yearly',
        expiresAt: expiresAt,
        checkedAt: now,
      );

  group('EntitlementVerdict.isUsable', () {
    test('same user, no expiry → usable', () {
      expect(verdict().isUsable('u1', now), isTrue);
    });

    test('different or missing user → never usable', () {
      expect(verdict().isUsable('u2', now), isFalse);
      expect(verdict().isUsable(null, now), isFalse);
    });

    test('future expiry → usable', () {
      final v = verdict(expiresAt: now.add(const Duration(days: 20)));
      expect(v.isUsable('u1', now), isTrue);
    });

    test('expired but inside the 3-day grace → still usable', () {
      final v = verdict(expiresAt: now.subtract(const Duration(days: 2)));
      expect(v.isUsable('u1', now), isTrue);
      expect(v.isExpired(now), isTrue);
    });

    test('expired past the grace → not usable', () {
      final v = verdict(expiresAt: now.subtract(const Duration(days: 3, minutes: 1)));
      expect(v.isUsable('u1', now), isFalse);
    });

    test('grace boundary is exclusive', () {
      final v = verdict(expiresAt: now.subtract(EntitlementVerdict.grace));
      expect(v.isUsable('u1', now), isFalse);
    });
  });

  group('EntitlementVerdict JSON', () {
    test('round-trips', () {
      final v = verdict(expiresAt: DateTime.utc(2027, 1, 1));
      final back = EntitlementVerdict.fromJson(jsonDecode(jsonEncode(v.toJson())));
      expect(back, isNotNull);
      expect(back!.userId, 'u1');
      expect(back.pro, isTrue);
      expect(back.status, 'active');
      expect(back.productId, 'humtrack_pro_yearly');
      expect(back.expiresAt, DateTime.utc(2027, 1, 1));
      expect(back.checkedAt, now);
    });

    test('rejects malformed input instead of throwing', () {
      expect(EntitlementVerdict.fromJson(null), isNull);
      expect(EntitlementVerdict.fromJson('nope'), isNull);
      expect(EntitlementVerdict.fromJson({'pro': true}), isNull); // no userId
      expect(EntitlementVerdict.fromJson({'userId': 'u1'}), isNull); // no checkedAt
    });

    test('fromServer maps the /iap/status contract (pro is the verdict)', () {
      final v = EntitlementVerdict.fromServer({
        'pro': true,
        'status': 'Cancelled',
        'product_id': 'humtrack_pro_monthly_v2',
        'expires_at': '2026-10-01T00:00:00+00:00',
        'server_time': '2026-09-04T12:00:00+00:00',
      }, userId: 'u1', now: now);
      expect(v.pro, isTrue);
      expect(v.status, 'cancelled');
      expect(v.productId, 'humtrack_pro_monthly_v2');
      expect(v.expiresAt, DateTime.utc(2026, 10, 1));

      final none = EntitlementVerdict.fromServer({'pro': false, 'server_time': 'x'}, userId: 'u1', now: now);
      expect(none.pro, isFalse);
      expect(none.status, isNull);
      expect(none.expiresAt, isNull);
    });
  });

  group('EntitlementCacheState.restoreDue', () {
    test('never ran → due', () {
      expect(EntitlementCacheState.empty.restoreDue('u1', now), isTrue);
    });

    test('ran recently for the same user → throttled', () {
      final s = EntitlementCacheState(
        lastRestoreAt: now.subtract(const Duration(hours: 2)),
        lastRestoreUserId: 'u1',
      );
      expect(s.restoreDue('u1', now), isFalse);
    });

    test('ran recently for another user → due', () {
      final s = EntitlementCacheState(
        lastRestoreAt: now.subtract(const Duration(hours: 2)),
        lastRestoreUserId: 'u2',
      );
      expect(s.restoreDue('u1', now), isTrue);
    });

    test('ran 24h+ ago → due', () {
      final s = EntitlementCacheState(
        lastRestoreAt: now.subtract(const Duration(hours: 24)),
        lastRestoreUserId: 'u1',
      );
      expect(s.restoreDue('u1', now), isTrue);
    });

    test('cached entitlement expired → due even inside the throttle window', () {
      final s = EntitlementCacheState(
        verdict: verdict(expiresAt: now.subtract(const Duration(hours: 1))),
        lastRestoreAt: now.subtract(const Duration(minutes: 5)),
        lastRestoreUserId: 'u1',
      );
      expect(s.restoreDue('u1', now), isTrue);
    });

    test('cached entitlement still valid → throttled', () {
      final s = EntitlementCacheState(
        verdict: verdict(expiresAt: now.add(const Duration(days: 10))),
        lastRestoreAt: now.subtract(const Duration(minutes: 5)),
        lastRestoreUserId: 'u1',
      );
      expect(s.restoreDue('u1', now), isFalse);
    });
  });

  group('EntitlementCacheState JSON', () {
    test('round-trips and clearVerdict keeps the throttle', () {
      final s = EntitlementCacheState(
        verdict: verdict(),
        lastRestoreAt: now,
        lastRestoreUserId: 'u1',
      );
      final back = EntitlementCacheState.decode(jsonEncode(s.toJson()));
      expect(back.verdict?.userId, 'u1');
      expect(back.lastRestoreAt, now);
      expect(back.lastRestoreUserId, 'u1');

      final cleared = back.copyWith(clearVerdict: true);
      expect(cleared.verdict, isNull);
      expect(cleared.lastRestoreAt, now);
    });

    test('garbage decodes to empty', () {
      expect(EntitlementCacheState.decode('{not json').verdict, isNull);
      expect(EntitlementCacheState.decode('[]').lastRestoreAt, isNull);
    });
  });

  group('EntitlementCache file IO', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('lt_entitlement_');
      EntitlementCache.rootOverride = root;
    });

    tearDown(() async {
      EntitlementCache.rootOverride = null;
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    });

    test('missing file → empty; save → load; clear → empty', () async {
      expect((await EntitlementCache.load()).verdict, isNull);

      await EntitlementCache.save(EntitlementCacheState(
        verdict: verdict(expiresAt: DateTime.utc(2027, 1, 1)),
        lastRestoreAt: now,
        lastRestoreUserId: 'u1',
      ));
      expect(await File('${root.path}/looptap/entitlement.json').exists(), isTrue);

      final loaded = await EntitlementCache.load();
      expect(loaded.verdict?.pro, isTrue);
      expect(loaded.verdict?.isUsable('u1', now), isTrue);
      expect(loaded.restoreDue('u1', now), isFalse);

      await EntitlementCache.clear();
      expect(await File('${root.path}/looptap/entitlement.json').exists(), isFalse);
      expect((await EntitlementCache.load()).verdict, isNull);
    });

    test('corrupt file → empty, no throw', () async {
      final f = File('${root.path}/looptap/entitlement.json');
      await f.create(recursive: true);
      await f.writeAsString('{{{');
      final loaded = await EntitlementCache.load();
      expect(loaded.verdict, isNull);
    });
  });
}
