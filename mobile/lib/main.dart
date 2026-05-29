// Humming — 벌새 voice-to-MIDI 앱.
// 흐름: Songs(작업 시작) → Edit(녹음→분석→편집→내보내기).
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'state/project_store.dart';
import 'theme/app_theme.dart';
import 'screens/songs_screen.dart';

void main() => runApp(const HummingApp());

class HummingApp extends StatelessWidget {
  const HummingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ProjectStore(),
      child: MaterialApp(
        title: 'Humming',
        theme: hummingTheme(),
        debugShowCheckedModeBanner: false,
        home: const SongsScreen(),
      ),
    );
  }
}
