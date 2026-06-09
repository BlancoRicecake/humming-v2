// LoopTap app root — landscape DAW. Wraps the song store + theme and routes
// Songs (home) -> Edit. Kept self-contained so the legacy app stays untouched
// until switchover.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import 'screens/songs_screen.dart';
import 'state/loop_store.dart';
import 'theme/tokens.dart';

/// 전역 ScaffoldMessenger key — modal sheet 가 떠있어도 root scaffold 위에
/// snackbar 띄울 수 있도록. (예: 세션 만료 시 paywall/account sheet 위에 표시.)
final GlobalKey<ScaffoldMessengerState> rootMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

class LoopTapApp extends StatelessWidget {
  const LoopTapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => LoopStore()..bootstrap(),
      child: MaterialApp(
        title: 'LoopTap',
        debugShowCheckedModeBanner: false,
        theme: loopTapTheme(),
        scaffoldMessengerKey: rootMessengerKey,
        home: const _AuthEventListener(child: SongsScreen()),
      ),
    );
  }
}

/// AuthService 의 onAuthEvent stream 을 listen 해서 root snackbar 로 표시.
/// (refreshSession 실패 = refresh_token 도 만료 → 자동 signOut + "다시 로그인
/// 해주세요" 안내. legacy ProjectStore 가 UnauthorizedException 으로 던지던 것을
/// LoopTap 에선 전역 이벤트로 단일화.)
class _AuthEventListener extends StatefulWidget {
  const _AuthEventListener({required this.child});
  final Widget child;

  @override
  State<_AuthEventListener> createState() => _AuthEventListenerState();
}

class _AuthEventListenerState extends State<_AuthEventListener> {
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = AuthService.instance.onAuthEvent.listen((e) {
      final messenger = rootMessengerKey.currentState;
      if (messenger == null) return;
      String msg;
      switch (e.kind) {
        case AuthEventKind.sessionExpired:
        case AuthEventKind.refreshFailed:
          msg = 'Session expired. Please sign in again.';
          break;
      }
      messenger.showSnackBar(SnackBar(
        backgroundColor: LT.surface2,
        content: Text(msg, style: LTType.inter(size: 13, color: LT.t1)),
        duration: const Duration(seconds: 5),
      ));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
