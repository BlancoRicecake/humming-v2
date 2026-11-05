// 2026-11-02: the editor's logo button opens the hum screen and back returns
// to the editor; the song list has an announcements button (dot = unread).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/announcements/announcement.dart';
import 'package:humming/looptap/announcements/announcement_service.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  @override
  Future<void> upsert(Song song) async {}
  @override
  bool get loaded => true;
}

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_logo_');
    LoopStorage.rootOverride = root;
    LoopPrefs.rootOverride = root;
    await LoopStorage.ensureDirs();
    LoopPrefs.instance.metro.value = false;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(channel), (_) async => null);
    }
  });
  tearDown(() async {
    EditScreen.debugDesktopOverride = null;
    LoopStorage.rootOverride = null;
    LoopPrefs.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<EditScreenDebug> openEditor(WidgetTester tester, List<Route<dynamic>> popped) async {
    useOfflineTestFonts();
    EditScreen.debugDesktopOverride = false;
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sec = Section(id: 'A', name: 'A', bars: 2)..tracks['melody'] = TrackData();
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: _Store(),
        child: MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          navigatorObservers: [_PopSpy(popped)],
          home: const Scaffold(body: SizedBox()),
        ),
      ),
    );
    Navigator.of(tester.element(find.byType(Scaffold))).push(
      MaterialPageRoute<void>(
        builder: (_) => EditScreen(song: Song(id: 'logo', title: 'Logo', bars: 2, sections: [sec])),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state(find.byType(EditScreen)) as EditScreenDebug;
  }

  // 2026-11-02 (later): the logo button is gone — "허밍 to MIDI" on the
  // track does the humming
  testWidgets('no logo / star button in the editor; the hum button reads "허밍 to MIDI"', (tester) async {
    final popped = <Route<dynamic>>[];
    await openEditor(tester, popped);
    expect(find.byKey(const ValueKey('editor-logo-hum')), findsNothing);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
    expect(find.text('허밍 to MIDI'), findsWidgets);
    expect(find.text('허밍 → MIDI'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('the QA feed parses into a popup and a notice', () async {
    final feed = Announcement.parseFeed(jsonDecode(utf8.decode((await qaAnnouncementFetch())!)));
    expect(feed!.map((a) => a.kind), [AnnouncementKind.critical, AnnouncementKind.info]);
    expect(feed.every((a) => a.activeAt(DateTime.now().toUtc())), isTrue);
  });
}

class _PopSpy extends NavigatorObserver {
  _PopSpy(this.popped);
  final List<Route<dynamic>> popped;
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => popped.add(route);
}
