// LoopTap app state — the song list + persistence + auth/IAP integration.
// AuthService(Supabase) 와 IapService(humtrack_pro_*) 를 listen 해 UI 에
// 노출하는 thin facade. 키 미설정 / 스토어 미가용 시 services 가 자체적으로
// 비활성(enabled=false) 되므로 여기서는 그대로 흘려보낸다.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../main.dart' show engineApi;
import '../../services/auth_service.dart';
import '../../services/clarity_service.dart';
import '../../services/entitlement_cache.dart';
import '../../services/iap_service.dart';
import '../../services/observability_service.dart';
import '../models/loop_models.dart';
import '../music/soundfont_catalog.dart';
import '../music/theory.dart';
import 'loop_storage.dart';

enum ProStatus { inactive, active }

/// [LoopStore.restorePurchases] 결과 — UI 가 문구를 고른다 (audit M6).
enum RestoreOutcome { restored, alreadyActive, nothingFound, error }

/// [LoopStore.deleteAccount] 실패 사유 — UI 가 l10n 으로 해석 (audit M9/M12).
enum DeleteAccountFailure { notSignedIn, rejected, network }

class DeleteAccountError {
  const DeleteAccountError(this.kind, {this.code});
  final DeleteAccountFailure kind;
  /// [DeleteAccountFailure.rejected] 일 때 HTTP 상태.
  final int? code;
}

/// GET /iap/status 가 200 이 아닐 때 Sentry 로 보내는 예외 (본문 앞 200자).
class IapStatusHttpException implements Exception {
  IapStatusHttpException(this.status, Object? body) : body = _truncate(body);
  final int status;
  final String body;
  static String _truncate(Object? body) {
    final t = body?.toString() ?? '';
    return t.length <= 200 ? t : t.substring(0, 200);
  }
  @override
  String toString() => 'IapStatusHttpException($status): $body';
}

class LoopStore extends ChangeNotifier {
  final List<Song> _songs = [];
  bool _loaded = false;

  /// UI 가 그대로 사용하던 단순 user map — Supabase 세션에서 derive.
  /// 키: name, provider, email. 비로그인 시 null.
  Map<String, String>? _user;

  ProStatus _pro = ProStatus.inactive;
  DateTime? _renewsAt;
  String? _proStatus; // trial | active | cancelled | expired | null (표시용)
  String? _proProductId;

  /// entitlement.json 의 메모리 사본 — bootstrap 에서 로드.
  EntitlementCacheState _entitlement = EntitlementCacheState.empty;

  StreamSubscription? _authSub;
  StreamSubscription? _iapSub;

  List<Song> get songs => List.unmodifiable(_songs);
  bool get loaded => _loaded;
  Map<String, String>? get user => _user;
  bool get isSignedIn => _user != null;
  // Debug-only Pro override so paywall-gated features (export) can be exercised
  // without a real purchase. Stripped from release builds (kDebugMode == false),
  // so store gating is unaffected in production. Flip to false to test the real
  // paywall flow in debug.
  static const bool _debugProOverride = false;
  bool get proActive => _pro == ProStatus.active || (kDebugMode && _debugProOverride);
  DateTime? get proRenewsAt => _renewsAt;
  /// 서버 status 문자열 (trial/active/cancelled/expired) — 표시용. Pro 판정은
  /// [proActive] 만 쓴다.
  String? get proStatus => _proStatus;
  String? get proProductId => _proProductId;
  bool get authEnabled => AuthService.instance.enabled;
  bool get iapEnabled => IapService.instance.enabled;
  AuthError? get lastAuthError => AuthService.instance.lastError;

  Future<void> bootstrap() async {
    // IAP verify dio 주입 + Bearer 인터셉터는 main_looptap.dart 가 init() 이전에
    // 이미 처리. 여기서는 song / auth / iap 상태만 hydrate.
    await LoopStorage.ensureDirs(); // warm Documents cache for vocal basename resolution
    // Runtime soundfont catalog: warm the cached manifest (instant, offline-ok)
    // then refresh from the backend in the background.
    await SoundfontCatalog.instance.warm();
    unawaited(SoundfontCatalog.instance.refresh());
    final loaded = await LoopStorage.load();
    // Seed the demos exactly once per install (C30): an empty library after
    // the user deleted everything stays empty. NEVER seed + persist over an
    // unreadable songs.json (C1) — that would overwrite the user's data with
    // demos and let the next sweep delete every vocal take.
    final seededBefore = await LoopStorage.seeded();
    final seedNow = loaded.isEmpty && !LoopStorage.loadFailed && !seededBefore;
    _songs
      ..clear()
      ..addAll(seedNow ? _seed() : loaded);
    _songs.sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    _loaded = true;
    if (seedNow) {
      await _persist();
      await LoopStorage.markSeeded();
    } else if (!seededBefore && loaded.isNotEmpty) {
      // pre-marker install that already has songs — record it so a later
      // delete-all doesn't bring the demos back.
      await LoopStorage.markSeeded();
    }

    // 마지막 서버 판정 캐시 (오프라인/장애 시 폴백, M3). 세션 listener 보다
    // 먼저 읽어야 _onSession 이 즉시 폴백을 적용할 수 있다.
    _entitlement = await EntitlementCache.load();

    // Supabase 세션 listener — 부트 시점에 cached session 이 있으면 즉시 발행됨.
    _authSub = AuthService.instance.onSession.listen(_onSession);
    final cur = AuthService.instance.current;
    if (cur.isSignedIn) _onSession(cur);

    // IAP 결제 결과 → proActive 갱신.
    _iapSub = IapService.instance.onPurchaseResult.listen(_onPurchase);

    notifyListeners();
  }

  // ── auth ────────────────────────────────────────────────────────────
  bool _restoredOnSignIn = false;
  void _onSession(AuthSession s) {
    if (s.isSignedIn) {
      final email = s.email ?? '';
      final name = email.isNotEmpty ? email.split('@').first : (s.provider ?? 'User');
      _user = {
        'name': name,
        'provider': _providerLabel(s.provider),
        'email': email,
      };
      final uid = s.userId!;
      final now = DateTime.now().toUtc();
      // 1) 캐시된 판정을 즉시 적용 — 서버 응답 전/오프라인에도 유료 사용자가
      //    paywall 을 보지 않도록 (같은 유저 + 만료 유예 내에서만).
      final cached = _entitlement.verdict;
      if (cached != null && cached.isUsable(uid, now)) {
        _applyVerdict(cached, notify: false);
      }
      // 2) 로그인 직후 1회 restore — IapService 가 토큰 없을 때 큐에 남겨둔
      //    영수증을 재배달받아 verify 한다. /iap/verify 는 서버 throttle 이
      //    있으므로 유저당 24h 에 한 번만 (캐시 판정이 만료됐으면 즉시).
      if (!_restoredOnSignIn && IapService.instance.enabled) {
        _restoredOnSignIn = true;
        if (_entitlement.restoreDue(uid, now)) {
          _markRestore(uid, now);
          unawaited(IapService.instance.restore());
        } else {
          debugPrint('[loopstore] startup restore throttled (last ${_entitlement.lastRestoreAt})');
        }
      }
      // 3) 서버 판정 — 리뷰 계정처럼 IAP 영수증 없이 부여된 Pro 도 이 경로.
      unawaited(refreshSubscription());
    } else {
      _user = null;
      _clearPro();
      _restoredOnSignIn = false;
      _entitlement = EntitlementCacheState.empty;
      unawaited(EntitlementCache.clear());
    }
    notifyListeners();
  }

  void _clearPro() {
    _pro = ProStatus.inactive;
    _renewsAt = null;
    _proStatus = null;
    _proProductId = null;
  }

  /// 서버/캐시 판정을 상태에 반영. 변화가 있을 때만 notify.
  void _applyVerdict(EntitlementVerdict v, {bool notify = true}) {
    final next = v.pro ? ProStatus.active : ProStatus.inactive;
    final changed = _pro != next ||
        _renewsAt != v.expiresAt ||
        _proStatus != v.status ||
        _proProductId != v.productId;
    _pro = next;
    _renewsAt = v.expiresAt;
    _proStatus = v.status;
    _proProductId = v.productId;
    // Clarity: plan 태그는 구매 시점뿐 아니라 판정이 갱신될 때마다.
    ClarityService.instance.tag('plan', v.pro ? (v.productId ?? 'pro') : 'free');
    if (changed && notify) notifyListeners();
  }

  void _markRestore(String uid, DateTime now) {
    _entitlement = _entitlement.copyWith(lastRestoreAt: now, lastRestoreUserId: uid);
    unawaited(EntitlementCache.save(_entitlement));
  }

  String _providerLabel(String? p) {
    switch (p) {
      case 'apple': return 'Apple';
      case 'google': return 'Google';
      case 'email': return 'Email';
      default: return p ?? '';
    }
  }

  /// provider: 'apple' | 'google'. 성공 시 onSession listener 가 _user 갱신.
  /// 반환값은 호출 자체가 시작/완료됐는지 — 실패 시 [lastAuthError] 확인.
  Future<bool> signInWith(String provider) {
    return AuthService.instance.signInWith(provider);
  }

  /// Email + password 로그인 — review-only.
  Future<bool> signInWithEmail(String email, String password) {
    return AuthService.instance.signInWithEmail(email, password);
  }

  Future<void> signOut() async {
    await AuthService.instance.signOut();
    // 사용자 전환 — 리플레이 세션 분리 + 로컬 권한 캐시 폐기.
    ClarityService.instance.startNewSession();
    _entitlement = EntitlementCacheState.empty;
    await EntitlementCache.clear();
    // listener 가 _user=null 로 처리하지만, auth 비활성 환경(_enabled=false) 에서는
    // listener 가 발화하지 않으므로 여기서도 보강.
    if (!AuthService.instance.enabled && _user != null) {
      _user = null;
      _clearPro();
      notifyListeners();
    }
  }

  /// 회원 탈퇴 — backend DELETE /account → Supabase user + 관련 row 삭제 → 로컬
  /// signOut. 실패 시 사유 반환 (문구는 UI 가 l10n 으로).
  Future<DeleteAccountError?> deleteAccount() async {
    if (!AuthService.instance.enabled || _user == null) {
      return const DeleteAccountError(DeleteAccountFailure.notSignedIn);
    }
    try {
      // 전역 engineApi 의 dio 에 Bearer 인터셉터가 자동 부착됨.
      final dio = engineApi.dio;
      final res = await dio.delete<dynamic>(
        '/account',
        options: Options(validateStatus: (_) => true),
      );
      final code = res.statusCode ?? 0;
      if (code != 200 && code != 204) {
        ObservabilityService.instance.captureException(
          StateError('account delete rejected ($code)'),
          StackTrace.current,
          tags: {'http_status': '$code'},
          hint: 'deleteAccount rejected',
        );
        return DeleteAccountError(DeleteAccountFailure.rejected, code: code);
      }
      await signOut();
      return null;
    } catch (e, st) {
      ObservabilityService.instance.captureException(e, st, hint: 'deleteAccount failed');
      return const DeleteAccountError(DeleteAccountFailure.network);
    }
  }

  // ── IAP ─────────────────────────────────────────────────────────────
  void _onPurchase(IapResult r) {
    if (!r.ok) {
      notifyListeners();
      return;
    }
    // 서버 verify 가 pro=true 를 돌려줬다 (IapService 가 이미 판정). 즉시 반영
    // + 캐시, 그리고 /iap/status 로 정본 status/expires_at 동기화.
    final uid = AuthService.instance.current.userId;
    final isYearly = r.productId == kProductYearly;
    final renews = r.renewsAt ??
        DateTime.now().add(Duration(days: isYearly ? 365 : 30));
    final v = EntitlementVerdict(
      userId: uid ?? '',
      pro: true,
      status: 'active',
      productId: r.productId,
      expiresAt: renews,
      checkedAt: DateTime.now().toUtc(),
    );
    _applyVerdict(v, notify: false);
    if (uid != null) {
      _entitlement = _entitlement.copyWith(verdict: v);
      unawaited(EntitlementCache.save(_entitlement));
    }
    notifyListeners();
    unawaited(refreshSubscription());
  }

  Future<void> loadProducts() => IapService.instance.loadProducts();
  /// null = 스토어 시트가 떴음 (결과는 IapService.onPurchaseResult).
  Future<IapError?> buyMonthly() => IapService.instance.buy(kProductMonthly);
  Future<IapError?> buyYearly() => IapService.instance.buy(kProductYearly);

  /// 구매 복원 (audit M6): 스토어 restore 를 요청하고 **첫 결과**(onPurchaseResult)
  /// 또는 pro 가 켜지는 상태 변화를 [timeout] 까지 기다린 뒤 /iap/status 로
  /// 정본을 다시 읽어 결과를 판정한다. 영수증이 없으면 스토어가 아무 것도
  /// 보내지 않으므로 timeout 이 곧 "복원할 것 없음".
  Future<RestoreOutcome> restorePurchases({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final wasActive = proActive;
    final uid = AuthService.instance.current.userId;
    if (!IapService.instance.enabled) {
      // 스토어 없이도 서버에 직접 부여된 Pro 는 잡힌다.
      final ok = await refreshSubscription();
      return _restoreOutcome(wasActive, null, refreshed: ok);
    }
    final first = Completer<IapResult?>();
    late final StreamSubscription<IapResult> sub;
    sub = IapService.instance.onPurchaseResult.listen((r) {
      if (r.error == IapError.pending) return; // 중간 상태 — 계속 대기.
      if (!first.isCompleted) first.complete(r);
    });
    void onFlip() {
      if (proActive && !wasActive && !first.isCompleted) first.complete(null);
    }
    addListener(onFlip);
    IapResult? result;
    var launched = false;
    try {
      if (uid != null) _markRestore(uid, DateTime.now().toUtc());
      launched = await IapService.instance.restore();
      if (launched) {
        try {
          result = await first.future.timeout(timeout);
        } on TimeoutException {
          result = null;
        }
      }
    } finally {
      await sub.cancel();
      removeListener(onFlip);
    }
    if (!launched) {
      ClarityService.instance.event('restore_failed');
      return RestoreOutcome.error; // IapService.restore 가 이미 Sentry 보고.
    }
    final refreshed = await refreshSubscription();
    final outcome = _restoreOutcome(wasActive, result, refreshed: refreshed);
    if (outcome == RestoreOutcome.nothingFound) {
      ClarityService.instance.event('restore_empty');
      ObservabilityService.instance.breadcrumb('restore empty', category: 'iap',
          data: {'had_result': result != null, 'error': result?.error?.name});
    } else if (outcome == RestoreOutcome.error) {
      ClarityService.instance.event('restore_failed');
      ObservabilityService.instance.captureException(
        StateError('restore failed: ${result?.error?.name ?? 'status refresh failed'}'),
        StackTrace.current,
        tags: {'iap_error': result?.error?.name ?? 'none'},
        hint: 'iap restore failed',
      );
    }
    return outcome;
  }

  RestoreOutcome _restoreOutcome(bool wasActive, IapResult? result, {bool refreshed = true}) {
    if (proActive && !wasActive) return RestoreOutcome.restored;
    if (proActive) return RestoreOutcome.alreadyActive;
    final err = result?.error;
    if (err != null && err != IapError.canceled) return RestoreOutcome.error;
    if (!refreshed && result == null) return RestoreOutcome.error;
    return RestoreOutcome.nothingFound;
  }

  /// GET /iap/status — 서버의 권한 판정(`pro`)이 유일한 정본 (audit M2).
  /// 성공하면 캐시 갱신(pro:true) / 폐기(pro:false). 실패(오프라인·5xx·401)
  /// 하면 같은 유저의 유효한 캐시로 폴백하고 false 반환.
  Future<bool> refreshSubscription() async {
    if (!AuthService.instance.enabled) return false;
    final uid = AuthService.instance.current.userId;
    if (uid == null) return false;
    int? httpStatus;
    try {
      final r = await engineApi.dio.get<Map<String, dynamic>>(
        '/iap/status',
        options: Options(
          validateStatus: (_) => true,
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      httpStatus = r.statusCode;
      final data = r.data;
      if (httpStatus != 200 || data == null) {
        throw IapStatusHttpException(httpStatus ?? 0, r.data);
      }
      // 응답이 오는 사이 로그아웃됐으면 무시.
      if (AuthService.instance.current.userId != uid) return false;
      final v = EntitlementVerdict.fromServer(data, userId: uid, now: DateTime.now().toUtc());
      _applyVerdict(v);
      _entitlement = v.pro
          ? _entitlement.copyWith(verdict: v)
          : _entitlement.copyWith(clearVerdict: true); // 확정 pro:false → 캐시 폐기
      unawaited(EntitlementCache.save(_entitlement));
      return true;
    } catch (e, st) {
      debugPrint('[loopstore] refreshSubscription failed: $e');
      ObservabilityService.instance.captureException(
        e, st,
        tags: {'endpoint': '/iap/status', 'http_status': '${httpStatus ?? 0}'},
        hint: 'iap status failed',
      );
      final cached = _entitlement.verdict;
      if (cached != null && cached.isUsable(uid, DateTime.now().toUtc())) {
        _applyVerdict(cached);
      }
      return false;
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _iapSub?.cancel();
    super.dispose();
  }

  // ── songs ──────────────────────────────────────────────────────────
  Future<void> _persist() => LoopStorage.save(_songs);

  Song createNew() {
    final s = Song(
      id: 'lt${DateTime.now().millisecondsSinceEpoch}',
      title: 'Untitled loop',
      updatedAt: DateTime.now(),
    );
    return s;
  }

  Future<void> upsert(Song song) async {
    song.updatedAt = DateTime.now();
    final i = _songs.indexWhere((s) => s.id == song.id);
    if (i >= 0) {
      _songs[i] = song;
    } else {
      _songs.insert(0, song);
    }
    _songs.sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    await _persist();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _songs.removeWhere((s) => s.id == id);
    await _persist();
    // reference-based sweep (NOT prefix delete): a duplicated song shares the
    // source song's vocal files, so only drop files nothing references.
    await LoopStorage.sweepVocals(_songs);
    notifyListeners();
  }

  /// Drop vocal files no song references anymore. Call when an editor session
  /// ends (its undo stack — the last holder of stale paths — is gone).
  Future<void> sweepVocals() => LoopStorage.sweepVocals(_songs);

  /// 새 ID 로 deep-copy + " (copy)" suffix. 새 노래는 grid 맨 앞으로.
  Future<Song> duplicate(Song src) async {
    final dup = Song(
      id: 'lt${DateTime.now().millisecondsSinceEpoch}',
      title: '${src.title} (copy)',
      key: src.key,
      scale: src.scale,
      bpm: src.bpm,
      swing: src.swing,
      bars: src.bars,
      vol: Map.of(src.vol),
      mutes: Map.of(src.mutes),
      instruments: Map.of(src.instruments),
      sections: src.sections.map((s) => s.deepCopy()).toList(),
      wave: List<double>.of(src.wave),
      updatedAt: DateTime.now(),
    );
    await upsert(dup);
    return dup;
  }

  /// 제목만 변경. id 는 보존.
  Future<void> rename(String id, String newTitle) async {
    final i = _songs.indexWhere((s) => s.id == id);
    if (i < 0) return;
    _songs[i].title = newTitle.trim().isEmpty ? 'Untitled loop' : newTitle.trim();
    await upsert(_songs[i]);
  }

  // ── 3 demo songs (parallels index.html seeds) ─────────────────────
  List<Song> _seed() {
    Section drumSection(String id, String name, {int bars = 2}) {
      final steps = stepsForBars(bars);
      final drums = <DrumNote>[];
      for (var s = 0; s < steps; s++) {
        if (s % 8 == 0) drums.add(DrumNote(kind: 'kick', step: s));
        if (s % 8 == 4) drums.add(DrumNote(kind: 'snare', step: s));
        if (s % 2 == 0) drums.add(DrumNote(kind: 'hihat', step: s));
      }
      final sec = Section(id: id, name: name, bars: bars);
      sec.tracks['drums'] = TrackData(drums: drums);
      return sec;
    }

    Song demo(String id, String title, String key, String scale, int bpm, int bars) {
      final song = Song(
        id: id,
        title: title,
        key: key,
        scale: scale,
        bpm: bpm,
        bars: bars,
        sections: [drumSection('A', 'A', bars: bars)],
        updatedAt: DateTime.now(),
      );
      final ladder = buildLadder(key, scale, 4, 8);
      final mel = <PitchNote>[];
      for (var i = 0; i < 4; i++) {
        final r = ladder[(i * 2) % ladder.length];
        mel.add(PitchNote(midi: r.midi, freq: r.freq, step: i * 4, dur: 2));
      }
      song.sections.first.tracks['melody'] = TrackData(notes: mel);
      return song;
    }

    return [
      demo('seed1', 'Midnight Tap', 'A', 'minor', 92, 2),
      demo('seed2', 'Sunrise Penta', 'C', 'pentatonic', 104, 2),
      demo('seed3', 'Dorian Drift', 'D', 'dorian', 88, 4),
    ];
  }
}
