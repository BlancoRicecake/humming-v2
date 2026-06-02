// Supabase 인증 통합. dart-define SUPABASE_URL/SUPABASE_ANON_KEY 미설정 시 비활성.
//
// 외부에 노출하는 인터페이스:
//   - bootstrap()        — main() 에서 한 번 호출 (Supabase.initialize)
//   - enabled            — 키 설정 완료 여부
//   - signInWith(...)    — apple / google OAuth (글로벌 타겟 — Kakao 미지원)
//   - signOut()          — 세션 종료
//   - onSession          — Stream<({email?, provider?, userId?})>; ProjectStore 에서 listen
//
// 비활성(키 미설정) 상태에서는 모든 호출이 false 반환 — 호출자는 mockLogin 으로 폴백.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

class AuthSession {
  const AuthSession({this.userId, this.email, this.provider});
  final String? userId;
  final String? email;
  final String? provider;
  bool get isSignedIn => userId != null;
}

class AuthService {
  AuthService._();
  static final AuthService instance = AuthService._();

  bool _enabled = false;
  bool get enabled => _enabled;

  final _sessionCtl = StreamController<AuthSession>.broadcast();
  Stream<AuthSession> get onSession => _sessionCtl.stream;
  AuthSession _current = const AuthSession();
  AuthSession get current => _current;

  StreamSubscription? _sub;

  Future<void> bootstrap() async {
    const url = String.fromEnvironment('SUPABASE_URL');
    const anon = String.fromEnvironment('SUPABASE_ANON_KEY');
    if (url.isEmpty || anon.isEmpty) {
      debugPrint('[supabase] keys not set — auth disabled (mock fallback)');
      return;
    }
    try {
      await sb.Supabase.initialize(url: url, anonKey: anon, debug: kDebugMode);
      _enabled = true;
      _sub = sb.Supabase.instance.client.auth.onAuthStateChange.listen(_onChange);
      // 부트 시점에 이미 세션이 있으면 즉시 발행.
      final cur = sb.Supabase.instance.client.auth.currentSession;
      if (cur != null) _emitFromSession(cur);
    } catch (e) {
      debugPrint('[supabase] init failed: $e');
    }
  }

  void _onChange(sb.AuthState s) {
    final session = s.session;
    if (session == null) {
      _current = const AuthSession();
    } else {
      _emitFromSession(session);
      return;
    }
    _sessionCtl.add(_current);
  }

  void _emitFromSession(sb.Session session) {
    final u = session.user;
    final provider = u.appMetadata['provider'] as String?;
    _current = AuthSession(userId: u.id, email: u.email, provider: provider);
    _sessionCtl.add(_current);
  }

  /// provider: 'apple' | 'google'.
  /// Returns true if the OAuth flow successfully launched (browser redirect 시작).
  /// 실제 세션 도착은 onSession 으로 비동기 통지.
  Future<bool> signInWith(String provider) async {
    if (!_enabled) return false;
    try {
      sb.OAuthProvider p;
      switch (provider) {
        case 'apple':  p = sb.OAuthProvider.apple; break;
        case 'google': p = sb.OAuthProvider.google; break;
        default: return false;
      }
      await sb.Supabase.instance.client.auth.signInWithOAuth(
        p,
        redirectTo: 'humtrack://auth/callback',
      );
      return true;
    } catch (e) {
      debugPrint('[supabase] signIn($provider) failed: $e');
      return false;
    }
  }

  Future<void> signOut() async {
    if (!_enabled) return;
    try {
      await sb.Supabase.instance.client.auth.signOut();
    } catch (e) {
      debugPrint('[supabase] signOut failed: $e');
    }
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _sessionCtl.close();
  }
}
