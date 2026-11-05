// Local cache of the last server entitlement verdict (audit M3/M13).
//
// The backend's GET /iap/status is the only source of truth for Pro. This file
// remembers the last answer so a paying user is not thrown to the paywall when
// the phone is offline or the API is down. It is a *fallback*, never a grant:
//   - it only counts while the cached userId matches the signed-in user,
//   - and only until `expiresAt + grace` (3 days) has passed,
//   - and a cached `pro: true` only while the server confirmed it within the
//     last 7 days ([EntitlementVerdict.maxOfflineAge]) — bounds offline Pro,
//   - it is wiped on sign-out and dropped on a definitive `pro: false`.
//
// The same file also records when the startup restore()+verify last ran so it
// can be throttled to once per 24h per user (M13 — /iap/verify is rate
// limited server-side).
//
// Stored at <Application Support>/looptap/entitlement.json — NOT Documents,
// which iOS exposes in the Files app (UIFileSharingEnabled). Builds that wrote
// <Documents>/looptap/entitlement.json are migrated once on first access (the
// old file is copied over, then deleted). The parsing / eligibility
// logic is pure Dart so it is unit-testable without platform channels
// ([EntitlementCache.rootOverride] mirrors LoopStorage's test hook).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One server verdict, as persisted.
@immutable
class EntitlementVerdict {
  const EntitlementVerdict({
    required this.userId,
    required this.pro,
    required this.checkedAt,
    this.status,
    this.productId,
    this.expiresAt,
  });

  /// How long past `expiresAt` a cached `pro: true` is still honoured while
  /// the server cannot be reached (covers billing retry / grace windows).
  static const Duration grace = Duration(days: 3);

  /// A cached `pro: true` is honoured only this long after the server last
  /// confirmed it — beyond that the user must reach the server again.
  static const Duration maxOfflineAge = Duration(days: 7);

  final String userId;
  final bool pro;
  final DateTime checkedAt;
  final String? status; // trial | active | cancelled | expired | null
  final String? productId;
  final DateTime? expiresAt;

  /// Whether this cached verdict may stand in for the server for [userId] at
  /// [now]. False for a different (or no) user, once the entitlement is
  /// past `expiresAt + grace`, or (for `pro: true`) once the verdict is older
  /// than [maxOfflineAge].
  bool isUsable(String? userId, DateTime now) {
    if (userId == null || userId != this.userId) return false;
    if (pro && now.difference(checkedAt) > maxOfflineAge) return false;
    final exp = expiresAt;
    if (exp == null) return true;
    return exp.add(grace).isAfter(now);
  }

  /// True once the store-side expiry has passed (renewal may have happened
  /// but we haven't heard about it) — a reason to run restore() again even
  /// inside the 24h throttle window.
  bool isExpired(DateTime now) {
    final exp = expiresAt;
    return exp != null && !exp.isAfter(now);
  }

  Map<String, dynamic> toJson() => {
        'userId': userId,
        'pro': pro,
        'status': status,
        'productId': productId,
        'expiresAt': expiresAt?.toUtc().toIso8601String(),
        'checkedAt': checkedAt.toUtc().toIso8601String(),
      };

  static EntitlementVerdict? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final userId = raw['userId'];
    final checkedAt = _parseTs(raw['checkedAt']);
    if (userId is! String || userId.isEmpty || checkedAt == null) return null;
    return EntitlementVerdict(
      userId: userId,
      pro: raw['pro'] == true,
      status: raw['status'] is String ? raw['status'] as String : null,
      productId: raw['productId'] is String ? raw['productId'] as String : null,
      expiresAt: _parseTs(raw['expiresAt']),
      checkedAt: checkedAt,
    );
  }

  /// Build a verdict from a GET /iap/status (or POST /iap/verify) body.
  static EntitlementVerdict fromServer(
    Map<String, dynamic> body, {
    required String userId,
    required DateTime now,
  }) {
    return EntitlementVerdict(
      userId: userId,
      pro: body['pro'] == true,
      status: (body['status'] as String?)?.toLowerCase(),
      productId: body['product_id'] as String?,
      expiresAt: _parseTs(body['expires_at']),
      checkedAt: now,
    );
  }

  static DateTime? _parseTs(Object? v) {
    if (v is! String || v.isEmpty) return null;
    return DateTime.tryParse(v)?.toUtc();
  }
}

/// Whole contents of entitlement.json: the verdict (nullable) plus the
/// restore throttle bookkeeping.
@immutable
class EntitlementCacheState {
  const EntitlementCacheState({
    this.verdict,
    this.lastRestoreAt,
    this.lastRestoreUserId,
  });

  static const EntitlementCacheState empty = EntitlementCacheState();

  /// Minimum spacing between automatic startup restore()+verify runs.
  static const Duration restoreEvery = Duration(hours: 24);

  final EntitlementVerdict? verdict;
  final DateTime? lastRestoreAt;
  final String? lastRestoreUserId;

  /// Whether the automatic startup restore should run for [userId] at [now]:
  /// always when it never ran for this user or ran more than 24h ago; also
  /// when the cached verdict says the entitlement has expired (a renewal may
  /// be waiting on the store side).
  bool restoreDue(String userId, DateTime now) {
    final v = verdict;
    if (v != null && v.userId == userId && v.isExpired(now)) return true;
    final at = lastRestoreAt;
    if (at == null || lastRestoreUserId != userId) return true;
    return now.difference(at) >= restoreEvery;
  }

  EntitlementCacheState copyWith({
    EntitlementVerdict? verdict,
    bool clearVerdict = false,
    DateTime? lastRestoreAt,
    String? lastRestoreUserId,
  }) {
    return EntitlementCacheState(
      verdict: clearVerdict ? null : (verdict ?? this.verdict),
      lastRestoreAt: lastRestoreAt ?? this.lastRestoreAt,
      lastRestoreUserId: lastRestoreUserId ?? this.lastRestoreUserId,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'verdict': verdict?.toJson(),
        'lastRestoreAt': lastRestoreAt?.toUtc().toIso8601String(),
        'lastRestoreUserId': lastRestoreUserId,
      };

  static EntitlementCacheState fromJson(Object? raw) {
    if (raw is! Map) return empty;
    final at = raw['lastRestoreAt'];
    return EntitlementCacheState(
      verdict: EntitlementVerdict.fromJson(raw['verdict']),
      lastRestoreAt: at is String ? DateTime.tryParse(at)?.toUtc() : null,
      lastRestoreUserId:
          raw['lastRestoreUserId'] is String ? raw['lastRestoreUserId'] as String : null,
    );
  }

  static EntitlementCacheState decode(String text) {
    try {
      return fromJson(jsonDecode(text));
    } catch (_) {
      return empty;
    }
  }
}

/// File IO for [EntitlementCacheState]. Never throws — a cache that can't be
/// read is just "no cache".
class EntitlementCache {
  EntitlementCache._();

  /// Test hook: replaces the platform Application Support dir.
  @visibleForTesting
  static Directory? rootOverride;

  /// Test hook: replaces the legacy Documents dir (migration source). When
  /// only [rootOverride] is set, migration is skipped so tests never touch
  /// the real Documents dir.
  @visibleForTesting
  static Directory? legacyRootOverride;

  static const String _rel = 'looptap/entitlement.json';

  static Future<File?> _legacyFile() async {
    try {
      final dir = legacyRootOverride ??
          (rootOverride == null ? await getApplicationDocumentsDirectory() : null);
      return dir == null ? null : File('${dir.path}/$_rel');
    } catch (_) {
      return null;
    }
  }

  static Future<File> _file() async {
    final dir = rootOverride ?? await getApplicationSupportDirectory();
    final folder = Directory('${dir.path}/looptap');
    if (!await folder.exists()) await folder.create(recursive: true);
    final f = File('${folder.path}/entitlement.json');
    await _migrateLegacy(f);
    return f;
  }

  /// One-time move Documents → Application Support. New file wins if both
  /// exist; the old copy is deleted either way so the Files app no longer
  /// shows it.
  static Future<void> _migrateLegacy(File target) async {
    final legacy = await _legacyFile();
    if (legacy == null) return;
    try {
      if (!await legacy.exists()) return;
      if (!await target.exists()) {
        await target.writeAsString(await legacy.readAsString(), flush: true);
      }
      await legacy.delete();
    } catch (e) {
      debugPrint('[entitlement] legacy migration failed: $e');
    }
  }

  static Future<EntitlementCacheState> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return EntitlementCacheState.empty;
      return EntitlementCacheState.decode(await f.readAsString());
    } catch (e) {
      debugPrint('[entitlement] load failed: $e');
      return EntitlementCacheState.empty;
    }
  }

  static Future<void> save(EntitlementCacheState state) async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(state.toJson()), flush: true);
    } catch (e) {
      debugPrint('[entitlement] save failed: $e');
    }
  }

  /// Sign-out: forget everything (verdict + throttle) — the next user must
  /// not inherit either.
  static Future<void> clear() async {
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('[entitlement] clear failed: $e');
    }
  }
}
