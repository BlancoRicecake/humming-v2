// LoopTap app root — landscape DAW. Wraps the song store + theme and routes
// Songs (home) -> Edit. Kept self-contained so the legacy app stays untouched
// until switchover.
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/generated/app_localizations.dart';
import '../services/locale_service.dart';
import 'screens/songs_screen.dart';
import 'state/loop_store.dart';
import 'theme/tokens.dart';

class LoopTapApp extends StatelessWidget {
  const LoopTapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => LoopStore()..bootstrap(),
      // Rebuild on language change so the Settings detail text + legal-doc
      // titles switch ko/en. null locale = follow the system language.
      child: ValueListenableBuilder<Locale?>(
        valueListenable: LocaleService.instance.selected,
        builder: (_, locale, __) => MaterialApp(
          title: 'HumTrack',
          debugShowCheckedModeBanner: false,
          theme: loopTapTheme(),
          locale: locale,
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const SongsScreen(),
        ),
      ),
    );
  }
}
