import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../main.dart' show engineApi;
import '../../services/auth_service.dart';
import '../models/loop_models.dart';
import '../screens/cloud_backup_screen.dart';
import '../state/cloud_backup.dart';
import '../state/loop_storage.dart';
import '../state/loop_store.dart';
import '../theme/tokens.dart';
import 'sheets/paywall_sheet.dart';

// Cloud backup actions (contract 1, 2026-10-30; behind HUMTRACK_CLOUD_BACKUP).
// Every upload starts from the user's explicit choice in [backupSongToCloud];
// recordings go along only when they tick the box (default off).
// 2026-11-04: the upload shows its progress, a network failure offers
// "try again", success offers "view" (the cloud list), and the dialog says
// when this song was last backed up.

/// The API for the account signed in now (null when signed out). It stays
/// bound to that account: a switch mid-action stops it (CloudAccountChanged).
CloudBackupApi? cloudApi() {
  final owner = AuthService.instance.current.userId;
  if (owner == null) return null;
  return CloudBackupApi(
    engineApi.dio,
    owner: owner,
    currentOwner: () => AuthService.instance.current.userId,
  );
}

void _snack(BuildContext context, String text, {SnackBarAction? action}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), action: action, duration: const Duration(seconds: 6)),
    );
}

/// Runs an upload under a blocking progress dialog ("preparing", then the
/// percent sent); the dialog closes however the upload ends.
Future<T> _withProgress<T>(
  BuildContext context,
  Future<T> Function(void Function(int sent, int total) onProgress) run,
) async {
  final l = L10n.of(context);
  final progress = ValueNotifier<double?>(null);
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  unawaited(
    showDialog<void>(
      context: context,
      useRootNavigator: true,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          key: const ValueKey('cloud-progress'),
          content: ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (_, p, __) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(p == null ? l.ltCloudPreparing : l.ltCloudUploading((p * 100).round())),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: p),
              ],
            ),
          ),
        ),
      ),
    ).whenComplete(() => open = false),
  );
  try {
    return await run((sent, total) {
      if (total > 0) progress.value = (sent / total).clamp(0.0, 1.0);
    });
  } finally {
    if (open) nav.pop();
  }
}

/// The message for a cloud error (null: handled elsewhere).
String cloudErrorText(L10n l, Object e) => switch (e) {
  CloudUnavailable() => l.ltCloudUnavailable,
  CloudSignInRequired() => l.ltCloudSignIn,
  CloudProRequired() => l.ltCloudProRequired,
  CloudQuotaExceeded() => l.ltCloudQuotaExceeded,
  CloudDamaged() => l.ltCloudDamaged,
  CloudAccountChanged() => l.ltCloudAccountChanged,
  _ => l.ltCloudFailed,
};

enum _Resolve { keepDevice, takeCloud, keepBoth }

/// Song menu › "Back up to cloud".
Future<void> backupSongToCloud(
  BuildContext context,
  Song song, {
  @visibleForTesting CloudBackupApi? api,
}) async {
  final l = L10n.of(context);
  final store = context.read<LoopStore>();
  if (!store.isSignedIn) {
    _snack(context, l.ltCloudSignIn);
    return;
  }
  if (!store.proActive) {
    await showPaywallSheet(context, trigger: PaywallTrigger.upgrade);
    if (!context.mounted || !context.read<LoopStore>().proActive) return;
  }
  final cloud = api ?? cloudApi();
  if (cloud == null) {
    if (context.mounted) _snack(context, l.ltCloudSignIn);
    return;
  }
  final link = (await CloudLinks.load(cloud.owner))[song.id];
  final takes = LoopStorage.audioNamesOf(song).length;
  if (!context.mounted) return;
  final last = link == null ? null : DateTime.tryParse(link.updatedAt);
  final includeAudio = await showDialog<bool>(
    context: context,
    builder: (_) => _BackupDialog(
      takes: takes,
      cloudHadAudio: link?.audioIncluded ?? false,
      lastBackup: last,
    ),
  );
  if (includeAudio == null || !context.mounted) return; // cancelled
  // after a success: open the cloud list; after a network failure: again
  SnackBarAction view() => SnackBarAction(
    label: l.ltCloudOpen,
    onPressed: () {
      if (context.mounted) CloudBackupScreen.open(context);
    },
  );
  SnackBarAction? retry(Object e) => e is CloudFailed
      ? SnackBarAction(
        label: l.ltCloudRetry,
        onPressed: () {
          if (context.mounted) backupSongToCloud(context, song, api: api);
        },
      )
      : null;
  try {
    await _withProgress(
      context,
      (onProgress) => backupSong(cloud, song, includeAudio: includeAudio, onProgress: onProgress),
    );
    if (context.mounted) {
      _snack(
        context,
        includeAudio ? l.ltCloudBackedUp(song.title) : l.ltCloudBackedUpNoAudio(song.title),
        action: view(),
      );
    }
  } on CloudConflict catch (c) {
    if (!context.mounted) return;
    final choice = await showDialog<_Resolve>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('cloud-conflict'),
        title: Text(l.ltCloudConflictTitle),
        content: Text(
          c.cloud == null ? l.ltCloudConflictGone : l.ltCloudConflictBody,
        ),
        actions: [
          TextButton(
            key: const ValueKey('cloud-keep-both'),
            onPressed: () => Navigator.pop(ctx, _Resolve.keepBoth),
            child: Text(l.ltCloudKeepBoth),
          ),
          if (c.cloud != null)
            TextButton(
              key: const ValueKey('cloud-take-cloud'),
              onPressed: () => Navigator.pop(ctx, _Resolve.takeCloud),
              child: Text(l.ltCloudTakeCloud),
            ),
          TextButton(
            key: const ValueKey('cloud-keep-device'),
            onPressed: () => Navigator.pop(ctx, _Resolve.keepDevice),
            child: Text(l.ltCloudKeepDevice),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return; // nothing changes
    try {
      switch (choice) {
        case _Resolve.keepDevice:
          await keepThisDevice(cloud, song, c);
          if (context.mounted) _snack(context, l.ltCloudBackedUp(song.title), action: view());
        case _Resolve.takeCloud:
          final res = await restoreCopy(cloud, store, c.cloud!);
          if (context.mounted) _snack(context, l.ltCloudRestored(res.song.title));
        case _Resolve.keepBoth:
          if (!context.mounted) return;
          await _withProgress(
            context,
            (onProgress) => backupAsNewCopy(cloud, song, includeAudio: includeAudio, onProgress: onProgress),
          );
          if (context.mounted) _snack(context, l.ltCloudBackedUp(song.title), action: view());
      }
    } catch (e) {
      if (context.mounted) _snack(context, cloudErrorText(l, e), action: retry(e));
    }
  } catch (e) {
    debugPrint('[cloud] backup failed: ${e.runtimeType}');
    if (context.mounted) _snack(context, cloudErrorText(l, e), action: retry(e));
  }
}

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({required this.takes, required this.cloudHadAudio, this.lastBackup});
  final int takes;
  final bool cloudHadAudio;

  /// When this song was last backed up from this device (null: never).
  final DateTime? lastBackup;
  @override
  State<_BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<_BackupDialog> {
  bool _audio = false; // recordings only by explicit choice

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return AlertDialog(
      key: const ValueKey('cloud-backup-dialog'),
      title: Text(l.ltCloudBackupTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.ltCloudBackupBody),
          if (widget.lastBackup case final last?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.ltCloudLastBackup(DateFormat.yMd().add_Hm().format(last.toLocal())),
                key: const ValueKey('cloud-last-backup'),
                style: const TextStyle(color: LT.t3, fontSize: 12),
              ),
            ),
          const SizedBox(height: 12),
          CheckboxListTile(
            key: const ValueKey('cloud-include-audio'),
            contentPadding: EdgeInsets.zero,
            value: _audio,
            onChanged: widget.takes == 0 ? null : (v) => setState(() => _audio = v ?? false),
            title: Text(l.ltCloudIncludeAudio(widget.takes)),
            subtitle: Text(_audio ? l.ltCloudAudioOn : l.ltCloudAudioOff),
          ),
          if (!_audio && widget.cloudHadAudio)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                l.ltCloudAudioOptOut,
                key: const ValueKey('cloud-optout-warning'),
                style: const TextStyle(color: LT.danger),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.cancel),
        ),
        FilledButton(
          key: const ValueKey('cloud-backup-confirm'),
          onPressed: () => Navigator.pop(context, _audio),
          child: Text(l.ltCloudBackupConfirm),
        ),
      ],
    );
  }
}
