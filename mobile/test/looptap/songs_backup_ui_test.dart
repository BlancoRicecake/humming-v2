// Storage audit 2026-10-30: the song list's backup actions. The card menu's
// "Make backup file" writes a .humtrack into the in-app exported files and
// says where it is; "Open backup" (system picker, faked here) adds the song
// as a new one; a refused file says why and leaves the list as it was.
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/songs_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';

class _Picker extends FileSelectorPlatform with MockPlatformInterfaceMixin {
  String? path;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => path == null ? null : XFile(path!);
}

class _Store extends LoopStore {
  @override
  bool get loaded => true;
  @override
  bool get proActive => true; // no quota gate in the way
}

void main() {
  late Directory root;
  late _Picker picker;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_backup_ui_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    await LoopStorage.load();
    picker = _Picker();
    FileSelectorPlatform.instance = picker;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => root.path,
        );
  });
  tearDown(() async {
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  Future<_Store> show(WidgetTester tester) async {
    useOfflineTestFonts();
    final store = _Store();
    await tester.runAsync(() => store.upsert(Song(id: 'lt1', title: 'Mine')));
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const SongsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('make a backup from the card menu, then open it as a new song', (tester) async {
    final store = await show(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make backup file'));
    await tester.pumpAndSettle(); // the menu closes, then the action starts
    final made = File('${root.path}/looptap/exports/Mine.humtrack');
    for (var i = 0; i < 40 && !find.textContaining('Backup file made').hasFound; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(made.existsSync(), isTrue);
    expect(find.textContaining('Backup file made: Mine.humtrack'), findsOneWidget);
    expect(find.text('Show files'), findsOneWidget);

    picker.path = made.path;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('songs-open-backup')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(store.songs.where((s) => s.title == 'Mine'), hasLength(2));
    expect(find.text('Backup added as a new song: Mine'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a file that is not a backup is refused with a reason', (tester) async {
    final store = await show(tester);
    final junk = File('${root.path}/notes.humtrack')..writeAsStringSync('hello');
    picker.path = junk.path;
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('songs-open-backup')));
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining("isn't a HumTrack backup"), findsOneWidget);
    expect(store.songs.map((s) => s.id), ['lt1']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('cancelling the picker changes nothing and says nothing', (tester) async {
    final store = await show(tester);
    picker.path = null;
    await tester.tap(find.byKey(const ValueKey('songs-open-backup')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(store.songs.map((s) => s.id), ['lt1']);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
