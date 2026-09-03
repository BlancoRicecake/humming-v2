// auth_service — token refresh failure classification (audit M7): only a
// definitive "refresh token invalid/expired" answer from GoTrue may sign the
// user out; network / timeout / 5xx keep the session. Static pure function,
// no Supabase initialisation.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:humming/services/auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final isDefinitive = AuthService.isDefinitiveRefreshFailure;

  group('retryable (keep session)', () {
    test('AuthRetryableFetchException', () {
      expect(isDefinitive(AuthRetryableFetchException()), isFalse);
    });

    test('socket / timeout / unknown exceptions', () {
      expect(isDefinitive(const SocketException('offline')), isFalse);
      expect(isDefinitive(TimeoutException('slow')), isFalse);
      expect(isDefinitive(Exception('boom')), isFalse);
    });

    test('5xx from GoTrue', () {
      expect(isDefinitive(AuthApiException('bad gateway', statusCode: '502')), isFalse);
      expect(isDefinitive(const AuthException('internal', statusCode: '500')), isFalse);
    });

    test('4xx without a token-related message or code (e.g. 404 misroute)', () {
      expect(isDefinitive(const AuthException('not here', statusCode: '404')), isFalse);
    });
  });

  group('definitive (sign out)', () {
    test('known GoTrue error codes', () {
      expect(
        isDefinitive(AuthApiException('Invalid Refresh Token: Already Used',
            statusCode: '400', code: 'refresh_token_already_used')),
        isTrue,
      );
      expect(
        isDefinitive(AuthApiException('x', statusCode: '400', code: 'refresh_token_not_found')),
        isTrue,
      );
      expect(isDefinitive(AuthApiException('x', statusCode: '403', code: 'session_not_found')), isTrue);
    });

    test('message heuristics when no code is present', () {
      expect(isDefinitive(const AuthException('Invalid Refresh Token: Refresh Token Not Found')), isTrue);
      expect(isDefinitive(const AuthException('invalid_grant')), isTrue);
      expect(isDefinitive(const AuthException('Session expired')), isTrue);
    });

    test('400/401/403 auth responses', () {
      expect(isDefinitive(const AuthException('nope', statusCode: '401')), isTrue);
      expect(isDefinitive(const AuthException('nope', statusCode: '403')), isTrue);
    });

    test('missing session', () {
      expect(isDefinitive(AuthSessionMissingException()), isTrue);
    });
  });
}
