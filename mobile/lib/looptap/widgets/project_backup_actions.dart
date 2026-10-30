import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../models/loop_models.dart';
import '../state/loop_storage.dart';
import '../state/loop_store.dart';
import '../state/project_backup.dart';
import '../screens/songs_screen.dart' show atFreeQuota;
import 'sheets/export_library_screen.dart';
import 'sheets/paywall_sheet.dart';

// Storage audit 2026-10-30: the song list's "back up" (song menu) and "open
// backup" actions for `.humtrack` project files. A backup lands in the in-app
// "Exported files" list first (app storage); from there the user saves it
// to a folder they choose or shares it — the message says so, with a button.

void _snack(BuildContext context, String text, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(text),
        action: action,
        duration: const Duration(seconds: 6),
      ),
    );
}

/// Make a `.humtrack` of [song] and tell the user where it went.
Future<void> backupSong(BuildContext context, Song song) async {
  final l = L10n.of(context);
  try {
    final res = await createProjectBackup(song);
    if (!context.mounted) return;
    final name = res.file.uri.pathSegments.last;
    final text = [
      l.ltBackupMade(name),
      if (res.missing > 0) l.ltBackupMissingTakes(res.missing),
    ].join('\n');
    _snack(
      context,
      text,
      action: SnackBarAction(
        label: l.ltBackupShowFiles,
        onPressed: () => showExportLibrary(context),
      ),
    );
  } catch (e) {
    debugPrint('[backup] create failed: ${e.runtimeType}');
    if (context.mounted) _snack(context, l.ltBackupFailed);
  }
}

enum BackupPickerPlatform { android, ios, desktop }

BackupPickerPlatform get _pickerPlatform =>
    !kIsWeb && Platform.isAndroid
        ? BackupPickerPlatform.android
        : !kIsWeb && Platform.isIOS
        ? BackupPickerPlatform.ios
        : BackupPickerPlatform.desktop;

/// The picker filter for `.humtrack` per platform (Codex review B5). Mobile
/// systems don't know the extension, so they offer any file and the content
/// decides (decodeProjectBackup): Android needs a MIME filter (`*/*`; a
/// UTI-only group is rejected by file_selector_android before the picker
/// opens), iOS a UTI (`public.data`). Desktop pickers filter by extension.
@visibleForTesting
List<XTypeGroup> backupTypeGroups(BackupPickerPlatform platform) =>
    switch (platform) {
      BackupPickerPlatform.android => const [
        XTypeGroup(label: 'HumTrack', mimeTypes: ['*/*']),
      ],
      BackupPickerPlatform.ios => const [
        XTypeGroup(label: 'HumTrack', uniformTypeIdentifiers: ['public.data']),
      ],
      BackupPickerPlatform.desktop => const [
        XTypeGroup(label: 'HumTrack', extensions: [kBackupExtension]),
      ],
    };

/// Pick a `.humtrack` file; null when cancelled.
Future<({String name, Uint8List bytes})?> _pickBackup() async {
  final file = await openFile(
    acceptedTypeGroups: backupTypeGroups(_pickerPlatform),
  );
  if (file == null) return null;
  if (await file.length() > kBackupMaxBytes) {
    throw const ProjectBackupException(BackupProblem.tooLarge);
  }
  return (name: file.name, bytes: await file.readAsBytes());
}

/// "Open backup" (song list header, Settings): a backup becomes a new song,
/// so it passes the same free-quota gate as "New song" first.
Future<Song?> openBackupAsNewSong(BuildContext context) async {
  final store = context.read<LoopStore>();
  if (atFreeQuota(store)) {
    await showPaywallSheet(context, trigger: PaywallTrigger.songQuota);
    if (!context.mounted || !store.proActive) return null;
  }
  return importBackup(context);
}

/// Open a `.humtrack` and add it as a new song. Returns it, or null when
/// cancelled / refused (the reason is shown; the library is untouched).
Future<Song?> importBackup(BuildContext context) async {
  final l = L10n.of(context);
  final store = context.read<LoopStore>();
  try {
    final picked = await _pickBackup();
    if (picked == null || !context.mounted) return null;
    final res = await importProjectBackup(store, picked.bytes);
    if (context.mounted) {
      _snack(
        context,
        [
          l.ltBackupImported(res.song.title),
          // takes already gone on the source device stay silent here (B1)
          if (res.missing > 0) l.ltBackupImportedMissing(res.missing),
        ].join('\n'),
      );
    }
    return res.song;
  } on ProjectBackupException catch (e) {
    debugPrint('[backup] import refused: $e');
    if (context.mounted) {
      _snack(context, switch (e.problem) {
        BackupProblem.notBackup => l.ltBackupNotBackup,
        BackupProblem.newerVersion => l.ltBackupNewer,
        BackupProblem.unsafeEntry => l.ltBackupUnsafe,
        BackupProblem.tooLarge => l.ltBackupTooLarge,
        BackupProblem.missingAudio => l.ltBackupMissingAudio,
        BackupProblem.damaged => l.ltBackupDamaged,
      });
    }
  } on NewerSongsSchemaException {
    if (context.mounted) _snack(context, l.ltLibraryNewer);
  } catch (e) {
    debugPrint('[backup] import failed: ${e.runtimeType}');
    if (context.mounted) _snack(context, l.ltBackupImportFailed);
  }
  return null;
}
