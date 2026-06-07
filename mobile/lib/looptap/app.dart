// LoopTap app root — landscape DAW. Wraps the song store + theme and routes
// Songs (home) -> Edit. Kept self-contained so the legacy app stays untouched
// until switchover.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/songs_screen.dart';
import 'state/loop_store.dart';
import 'theme/tokens.dart';

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
        home: const SongsScreen(),
      ),
    );
  }
}
