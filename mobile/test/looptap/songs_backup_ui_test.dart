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

  /// The last delete, so a test can let storage go idle before the next.
  Future<void>? lastDelete;
  @override
  Future<void> delete(String id) => lastDelete = super.delete(id);
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

  // 2026-11-02: the list's top bar has no "open backup" icon any more (the
  // check icon selects songs); it is in Settings
  Future<void> openSettingsBackup(WidgetTester tester) async {
    // a message still showing would be hidden mid-sheet: drop it first
    ScaffoldMessenger.of(tester.element(find.byType(SongsScreen))).removeCurrentSnackBar();
    await tester.pump();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-open-backup')));
    await tester.pumpAndSettle();
  }

  testWidgets('make a backup from the card menu, then open it as a new song', (tester) async {
    final store = await show(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Make backup file'));
    await tester.pumpAndSettle(); // the menu closes, then the action starts
    final made = File('${root.path}/looptap/exports/Mine.humtrack');
    for (var i = 0; i < 40 && !find.textContaining('Backup file made').evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(made.existsSync(), isTrue);
    expect(find.textContaining('Backup file made: Mine.humtrack'), findsOneWidget);
    expect(find.text('Show files'), findsOneWidget);

    picker.path = made.path;
    await openSettingsBackup(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('settings-open-backup')));
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
    await openSettingsBackup(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('settings-open-backup')));
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
    await openSettingsBackup(tester);
    await tester.tap(find.byKey(const ValueKey('settings-open-backup')));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(store.songs.map((s) => s.id), ['lt1']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the card menu has Export', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-export')), findsOneWidget);
    expect(find.text('Export'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Last in the file: its deletes run through LoopStorage's static save
  // queue in this test's fake time, which a later test could wait on.
  // 2026-11-02: the top bar's check icon selects songs; picked songs are
  // deleted (after a confirm) or exported as backups together.
  testWidgets('select mode: pick songs, export them as backups, delete them', (tester) async {
    final store = await show(tester);
    await tester.runAsync(() async {
      await store.upsert(Song(id: 'lt2', title: 'Two'));
      await store.upsert(Song(id: 'lt3', title: 'Three'));
    });
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('songs-import-midi')), findsOneWidget);
    expect(find.text('MIDI +'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('songs-select')));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    expect(find.byTooltip('More'), findsNothing, reason: 'no card menus while picking');
    await tester.tap(find.text('Mine'));
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('songs-export-picked')));
      await Future<void>.delayed(const Duration(milliseconds: 800));
    });
    await tester.pumpAndSettle();
    expect(File('${root.path}/looptap/exports/Mine.humtrack').existsSync(), isTrue);
    expect(File('${root.path}/looptap/exports/Two.humtrack').existsSync(), isTrue);
    expect(find.textContaining('Made 2 backup files'), findsOneWidget);
    expect(find.byKey(const ValueKey('songs-select-bar')), findsNothing, reason: 'done after export');
    ScaffoldMessenger.of(tester.element(find.byType(SongsScreen))).removeCurrentSnackBar();
    await tester.pump();
    // a long press starts picking with that song
    await tester.longPress(find.text('Three'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Two'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('songs-delete-picked')));
    await tester.pumpAndSettle();
    expect(find.text('Delete 2 songs?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('songs-delete-confirm')));
    for (var i = 0; i < 200 && (store.songs.length > 1 || find.byKey(const ValueKey('songs-select-bar')).evaluate().isNotEmpty); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(store.songs.map((s) => s.title), ['Mine']);
    expect(find.byKey(const ValueKey('songs-select-bar')), findsNothing);
    await tester.runAsync(() async => store.lastDelete);
    await tester.pumpWidget(const SizedBox.shrink());
  });

}
