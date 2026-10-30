// Storage audit 2026-10-30: what loading the library had to do is reported
// (LoopStorage.lastIssue → LoopStore.loadIssue → a banner on the song list)
// instead of only a debug log; the files themselves are never overwritten.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/library_notice.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Store extends LoopStore {
  _Store(this._issue);
  LoadIssue _issue;
  @override
  LoadIssue get loadIssue => _issue;
  @override
  void dismissLoadIssue() {
    _issue = LoadIssue.none;
    notifyListeners();
  }
}

void main() {
  late Directory root;
  late File main, bak;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_library_notice_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    main = File('${root.path}/looptap/songs.json');
    bak = File('${root.path}/looptap/songs.json.bak');
  });
  tearDown(() async {
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  String lib(List<Object> songs, {int v = Song.kSchemaVersion}) =>
      jsonEncode({'v': v, 'songs': songs});
  Map<String, dynamic> song(String id) => Song(id: id, title: id).toJson();

  group('LoopStorage.lastIssue', () {
    test('a clean library: none', () async {
      await main.writeAsString(lib([song('a')]));
      expect((await LoopStorage.load()).map((s) => s.id), ['a']);
      expect(LoopStorage.lastIssue, LoadIssue.none);
    });

    test('an unreadable file with a good backup: recovered, both kept', () async {
      await main.writeAsString('{"v":3,"songs":[');
      await bak.writeAsString(lib([song('b')]));
      expect((await LoopStorage.load()).map((s) => s.id), ['b']);
      expect(LoopStorage.lastIssue, LoadIssue.recoveredFromBackup);
      expect(await bak.readAsString(), lib([song('b')]));
    });

    test('one unreadable song: skipped, the original preserved', () async {
      await main.writeAsString(lib([song('a'), {'id': 7}]));
      expect((await LoopStorage.load()).map((s) => s.id), ['a']);
      expect(LoopStorage.lastIssue, LoadIssue.skippedSongs);
      final kept = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.contains('.corrupt-'));
      expect(kept, isNotEmpty);
    });

    test('nothing readable and no backup: unreadable, the file left as is', () async {
      await main.writeAsString('not json');
      expect(await LoopStorage.load(), isEmpty);
      expect(LoopStorage.lastIssue, LoadIssue.unreadable);
      expect(LoopStorage.loadFailed, isTrue);
    });

    test('a newer app wrote it: newerSchema', () async {
      await main.writeAsString(lib([song('a')], v: Song.kSchemaVersion + 1));
      await LoopStorage.load();
      expect(LoopStorage.lastIssue, LoadIssue.newerSchema);
    });
  });

  group('banner', () {
    Future<void> show(WidgetTester tester, _Store store, String lang) async {
      useOfflineTestFonts();
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            locale: Locale(lang),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: const Scaffold(body: LibraryNoticeBanner()),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('nothing to tell: no banner', (tester) async {
      await show(tester, _Store(LoadIssue.none), 'en');
      expect(find.byKey(const ValueKey('library-notice')), findsNothing);
    });

    for (final lang in ['en', 'ko']) {
      testWidgets('$lang: each issue has its message; closing hides it', (
        tester,
      ) async {
        final seen = <String>{};
        for (final issue in LoadIssue.values.where(
          (i) => i != LoadIssue.none,
        )) {
          final store = _Store(issue);
          await show(tester, store, lang);
          expect(find.byKey(const ValueKey('library-notice')), findsOneWidget);
          final text = tester
              .widgetList<Text>(
                find.descendant(
                  of: find.byKey(const ValueKey('library-notice')),
                  matching: find.byType(Text),
                ),
              )
              .first
              .data!;
          expect(text, isNotEmpty);
          seen.add(text);
          await tester.tap(find.byKey(const ValueKey('library-notice-close')));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('library-notice')), findsNothing);
        }
        expect(seen, hasLength(4), reason: 'a distinct message per issue');
      });
    }
  });
}
