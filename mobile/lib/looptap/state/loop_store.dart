// LoopTap app state — the song list + persistence + auth/IAP integration.
// AuthService(Supabase) 와 IapService(humtrack_pro_*) 를 listen 해 UI 에
// 노출하는 thin facade. 키 미설정 / 스토어 미가용 시 services 가 자체적으로
// 비활성(enabled=false) 되므로 여기서는 그대로 흘려보낸다.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../services/auth_service.dart';
import '../../services/iap_service.dart';
import '../models/loop_models.dart';
import '../music/theory.dart';
import 'loop_storage.dart';

enum ProStatus { inactive, active }

class LoopStore extends ChangeNotifier {
  final List<Song> _songs = [];
  bool _loaded = false;

  /// UI 가 그대로 사용하던 단순 user map — Supabase 세션에서 derive.
  /// 키: name, provider, email. 비로그인 시 null.
  Map<String, String>? _user;

  ProStatus _pro = ProStatus.inactive;
  DateTime? _renewsAt;

  StreamSubscription? _authSub;
  StreamSubscription? _iapSub;

  List<Song> get songs => List.unmodifiable(_songs);
  bool get loaded => _loaded;
  Map<String, String>? get user => _user;
  bool get isSignedIn => _user != null;
  bool get proActive => _pro == ProStatus.active;
  DateTime? get proRenewsAt => _renewsAt;
  bool get authEnabled => AuthService.instance.enabled;
  bool get iapEnabled => IapService.instance.enabled;
  AuthError? get lastAuthError => AuthService.instance.lastError;

  Future<void> bootstrap() async {
    // IAP verify dio 주입 + Bearer 인터셉터는 main_looptap.dart 가 init() 이전에
    // 이미 처리. 여기서는 song / auth / iap 상태만 hydrate.
    final loaded = await LoopStorage.load();
    _songs
      ..clear()
      ..addAll(loaded.isEmpty ? _seed() : loaded);
    _songs.sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    _loaded = true;
    if (loaded.isEmpty) await _persist();

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
      // 로그인 직후 1회 restore — IapService 가 토큰 없을 때 큐에 남겨둔 영수증을
      // 재배달받아 verify 한다. 이미 verify 된 정상 구독에는 영향 없음.
      if (!_restoredOnSignIn && IapService.instance.enabled) {
        _restoredOnSignIn = true;
        IapService.instance.restore();
      }
    } else {
      _user = null;
      _pro = ProStatus.inactive;
      _renewsAt = null;
      _restoredOnSignIn = false;
    }
    notifyListeners();
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
    // listener 가 _user=null 로 처리하지만, auth 비활성 환경(_enabled=false) 에서는
    // listener 가 발화하지 않으므로 여기서도 보강.
    if (!AuthService.instance.enabled && _user != null) {
      _user = null;
      _pro = ProStatus.inactive;
      _renewsAt = null;
      notifyListeners();
    }
  }

  // ── IAP ─────────────────────────────────────────────────────────────
  void _onPurchase(IapResult r) {
    if (!r.ok) {
      notifyListeners();
      return;
    }
    _pro = ProStatus.active;
    final isYearly = r.productId == kProductYearly;
    _renewsAt = r.renewsAt ??
        DateTime.now().add(Duration(days: isYearly ? 365 : 30));
    notifyListeners();
  }

  Future<void> loadProducts() => IapService.instance.loadProducts();
  Future<bool> buyMonthly() => IapService.instance.buy(kProductMonthly);
  Future<bool> buyYearly() => IapService.instance.buy(kProductYearly);
  Future<void> restorePurchases() => IapService.instance.restore();

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
    notifyListeners();
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
