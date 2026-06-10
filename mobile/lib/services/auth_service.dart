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
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;

class AuthSession {
  const AuthSession({this.userId, this.email, this.provider});
  final String? userId;
  final String? email;
  final String? provider;
  bool get isSignedIn => userId != null;
}

/// 사용자 표시용 인증 에러 — UI 에서 L10n 으로 해석.
/// code 가 known 이면 ARB 키, 아니면 'generic' (raw 사용).
class AuthError {
  const AuthError._({required this.code, this.provider, this.providers = const [], this.raw, this.appleCode, this.appleMessage});
  final String code;
  final String? provider;       // 'Apple' | 'Google' | …
  final List<String> providers; // for identityBlockedSpecific
  final String? raw;
  final String? appleCode;
  final String? appleMessage;

  factory AuthError.disabled() => const AuthError._(code: 'disabled');
  factory AuthError.googleNoIdToken() => const AuthError._(code: 'googleNoIdToken');
  factory AuthError.identityBlockedGeneric() =>
      const AuthError._(code: 'identityBlockedGeneric');
  factory AuthError.identityBlockedSpecific(List<String> providers) =>
      AuthError._(code: 'identityBlockedSpecific', providers: providers);
  factory AuthError.appleCode(String code, String? message) =>
      AuthError._(code: 'appleCode', appleCode: code, appleMessage: message ?? '');
  factory AuthError.generic(String provider, String raw) =>
      AuthError._(code: 'generic', provider: provider, raw: raw);
}

/// 인증 관련 알림 이벤트 — UI 가 onAuthEvent 로 수신해 사용자에게 표시.
enum AuthEventKind { sessionExpired, refreshFailed }

class AuthEvent {
  const AuthEvent(this.kind, {this.detail});
  final AuthEventKind kind;
  final String? detail;
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

  /// 세션 만료/리프레시 실패 등 사용자 안내가 필요한 이벤트 채널.
  /// UI(account_sheet, paywall 등)가 이 stream 을 listen 해 dialog/snackbar 표시.
  final _authEventCtl = StreamController<AuthEvent>.broadcast();
  Stream<AuthEvent> get onAuthEvent => _authEventCtl.stream;

  /// signInWith 가 false 반환했을 때 진단용 에러 — 사용자 취소면 null.
  /// UI 단에서 L10n 으로 해석해 snackbar/dialog 등으로 표시.
  AuthError? lastError;

  /// 가장 최근 signInWith 의 provider — appMetadata['provider'] 는 최초 가입 provider
  /// 만 가리키므로, 같은 이메일로 다른 provider 로그인 시 UI 표시를 정확히 하기 위해 별도 추적.
  /// bootstrap 시 cached session 복원이면 null → identities[latest] 로 폴백.
  String? _lastSignInProvider;

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
    // 우선순위:
    //   1) _lastSignInProvider — 방금 사용한 provider (이번 세션에서 signInWith 호출이 있었음)
    //   2) identities 의 가장 최근 updated_at provider — cached session 복원 케이스
    //   3) appMetadata['provider'] — 최초 가입 provider 폴백
    String? provider = _lastSignInProvider;
    if (provider == null) {
      final ids = u.identities;
      if (ids != null && ids.isNotEmpty) {
        final latest = ids.reduce((a, b) {
          final at = a.updatedAt ?? a.lastSignInAt ?? '';
          final bt = b.updatedAt ?? b.lastSignInAt ?? '';
          return at.compareTo(bt) >= 0 ? a : b;
        });
        provider = latest.provider;
      }
      provider ??= u.appMetadata['provider'] as String?;
    }
    _current = AuthSession(userId: u.id, email: u.email, provider: provider);
    _sessionCtl.add(_current);
  }

  /// Email + password 로그인 — 스토어 리뷰용 사전 생성 계정 전용.
  /// public sign-up 은 백엔드에서 비활성. 사용자 취소가 따로 없으므로 실패
  /// 시 [lastError] 가 채워진다.
  Future<bool> signInWithEmail(String email, String password) async {
    lastError = null;
    _lastSignInProvider = 'email';
    if (!_enabled) {
      lastError = AuthError.disabled();
      return false;
    }
    try {
      final r = await sb.Supabase.instance.client.auth
          .signInWithPassword(email: email, password: password);
      return r.session != null;
    } on sb.AuthException catch (e) {
      debugPrint('[supabase] email signIn failed: ${e.message} (status=${e.statusCode})');
      lastError = AuthError.generic('Email', e.message);
      return false;
    } catch (e) {
      debugPrint('[supabase] email signIn error: $e');
      lastError = AuthError.generic('Email', '$e');
      return false;
    }
  }

  /// provider: 'apple' | 'google'.
  /// iOS 에서는 native AuthenticationServices(Apple) / GoogleSignIn(SDK) 으로
  /// idToken 을 받아 supabase.signInWithIdToken 호출 — Safari deep-link 라운드트립
  /// 없이 native sheet 만으로 인증 → 앱 자동 복귀.
  /// 그 외 플랫폼(Android/web) 은 기존 signInWithOAuth (browser redirect) 사용.
  /// 반환값 true: 흐름 시작/완료 성공. 실제 세션은 onSession 으로 도착.
  Future<bool> signInWith(String provider) async {
    lastError = null;
    _lastSignInProvider = provider;
    if (!_enabled) {
      lastError = AuthError.disabled();
      return false;
    }
    try {
      // iOS native Apple Sign In — 자동 복귀 문제 해결.
      if (Platform.isIOS && provider == 'apple') {
        return await _nativeAppleSignIn();
      }
      // Google native flow (iOS/Android 공통) — Safari 라운드트립 없이 native sheet.
      if (provider == 'google' && (Platform.isIOS || Platform.isAndroid)) {
        return await _nativeGoogleSignIn();
      }
      // Fallback: browser-based OAuth (Android Apple, web 등).
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
      lastError = AuthError.generic(provider, '$e');
      return false;
    }
  }

  Future<bool> _nativeAppleSignIn() async {
    String? email;
    try {
      final rawNonce = _randomNonce();
      final hashedNonce = sha256.convert(utf8.encode(rawNonce)).toString();
      final credential = await SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
        nonce: hashedNonce,
      );
      email = credential.email; // Apple 은 첫 가입 때만 채워주고 그 이후 null.
      final idToken = credential.identityToken;
      if (idToken == null) return false;
      await sb.Supabase.instance.client.auth.signInWithIdToken(
        provider: sb.OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );
      return true;
    } on SignInWithAppleAuthorizationException catch (e) {
      debugPrint('[supabase] apple native cancel/fail: ${e.code}');
      if (e.code != AuthorizationErrorCode.canceled) {
        lastError = AuthError.appleCode(e.code.name, e.message);
      }
      return false;
    } catch (e) {
      debugPrint('[supabase] apple native error: $e');
      lastError = await _humanizeAuthError('Apple', e, email: email);
      return false;
    }
  }

  Future<bool> _nativeGoogleSignIn() async {
    String? email;
    const webClientId = String.fromEnvironment('GOOGLE_WEB_CLIENT_ID');
    final googleSignIn = GoogleSignIn(
      serverClientId: webClientId.isEmpty ? null : webClientId,
      scopes: const ['email', 'profile'],
    );
    try {
      final account = await googleSignIn.signIn();
      if (account == null) return false;
      email = account.email;
      final auth = await account.authentication;
      final idToken = auth.idToken;
      final accessToken = auth.accessToken;
      if (idToken == null) {
        lastError = AuthError.googleNoIdToken();
        // 캐시 비워서 다음 시도 시 chooser 표시.
        await googleSignIn.signOut().catchError((_) => null);
        return false;
      }
      await sb.Supabase.instance.client.auth.signInWithIdToken(
        provider: sb.OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      return true;
    } catch (e) {
      debugPrint('[supabase] google native error: $e');
      lastError = await _humanizeAuthError('Google', e, email: email);
      // 실패 시 Google SDK 의 cached account 를 비워야 다음 탭에서 chooser 가 다시 뜸.
      // 안 비우면 같은 계정으로 silent 재시도 → 같은 에러 반복.
      await googleSignIn.signOut().catchError((_) => null);
      return false;
    }
  }

  /// auth provider 의 raw 에러 메시지를 사용자 친화적 한국어로 변환.
  /// Trigger(`prevent_oauth_auto_link`) 차단 시 GoTrue 가 wrap 해서 보내는
  /// **정확한 시그니처** 만 매칭 — 다른 server 에러를 잘못 흡수하지 않도록 보수적으로.
  ///
  /// 차단으로 판정되고 email 이 있으면 Supabase RPC `providers_for_email` 로
  /// 실제 가입된 provider 목록을 조회해서 구체적으로 안내. RPC 실패 시 generic fallback.
  Future<AuthError> _humanizeAuthError(
    String triedProvider,
    Object e, {
    String? email,
  }) async {
    final raw = e.toString();
    final isCreateIdentityErr = raw.contains('"message":"Error creating identity"');
    final is500 = raw.contains('statusCode: 500');
    if (!(isCreateIdentityErr && is500)) {
      return AuthError.generic(triedProvider, raw);
    }
    // 차단 확정 — RPC 로 실제 provider 목록 조회.
    List<String> providers = [];
    if (email != null && email.isNotEmpty) {
      try {
        final result = await sb.Supabase.instance.client
            .rpc('providers_for_email', params: {'target_email': email});
        if (result is List) {
          providers = result.cast<String>();
        }
      } catch (rpcErr) {
        debugPrint('[supabase] providers_for_email RPC failed: $rpcErr');
      }
    }
    if (providers.isEmpty) {
      return AuthError.identityBlockedGeneric();
    }
    return AuthError.identityBlockedSpecific(providers);
  }

  String _randomNonce([int length = 32]) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  /// 현재 세션의 access token — 백엔드 API 호출 시 Authorization: Bearer 로.
  ///
  /// 만료된(or 곧 만료될) 토큰이면 자동으로 refreshSession() 호출. Supabase SDK
  /// 의 background auto-refresh 가 실패한 케이스(앱이 오래 백그라운드, 디바이스
  /// 시계 점프 등)에서도 안전하게 fresh 토큰을 돌려주도록 보강.
  Future<String?> currentAccessToken() async {
    if (!_enabled) return null;
    final auth = sb.Supabase.instance.client.auth;
    var session = auth.currentSession;
    if (session == null) return null;
    // expiresAt: epoch seconds. 60초 미만 남았으면 refresh.
    final expSec = session.expiresAt;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = expSec == null ? 0 : (expSec - now);
    if (remaining <= 60) {
      try {
        debugPrint('[supabase] session expiring (remaining=${remaining}s) → refresh');
        final r = await auth.refreshSession();
        session = r.session ?? auth.currentSession;
      } catch (e) {
        debugPrint('[supabase] refreshSession failed: $e');
        // Refresh 실패 = refresh_token 도 만료/무효 → 복구 불가. 자동 signOut +
        // UI 에 안내. (legacy 의 UnauthorizedException 대응을 LoopTap 에서는
        // AuthEvent stream 으로 발행.)
        _authEventCtl.add(AuthEvent(
          AuthEventKind.refreshFailed,
          detail: e.toString(),
        ));
        try {
          await auth.signOut();
        } catch (_) {}
        return null;
      }
    }
    return session?.accessToken;
  }

  Future<void> signOut() async {
    _lastSignInProvider = null;
    // GoogleSignIn 패키지가 native 단에서 별도 account 캐시를 들고 있어 Supabase 만
    // signOut 하면 다음 시도 시 화면 없이 즉시 재로그인 됨. 양쪽 모두 비워야 함.
    try {
      await GoogleSignIn().signOut();
    } catch (e) {
      debugPrint('[supabase] GoogleSignIn.signOut failed: $e');
    }
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
    await _authEventCtl.close();
  }
}
