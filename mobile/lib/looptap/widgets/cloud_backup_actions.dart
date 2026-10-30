import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../../main.dart' show engineApi;
import '../../services/auth_service.dart';
import '../models/loop_models.dart';
import '../state/cloud_backup.dart';
import '../state/loop_storage.dart';
import '../state/loop_store.dart';
import '../theme/tokens.dart';
import 'sheets/paywall_sheet.dart';

// Cloud backup actions (contract 1, 2026-10-30; behind HUMTRACK_CLOUD_BACKUP).
// Every upload starts from the user's explicit choice in [backupSongToCloud];
// recordings go along only when they tick the box (default off).

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

void _snack(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 6)),
    );
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
  final includeAudio = await showDialog<bool>(
    context: context,
    builder: (_) => _BackupDialog(
      takes: takes,
      cloudHadAudio: link?.audioIncluded ?? false,
    ),
  );
  if (includeAudio == null || !context.mounted) return; // cancelled
  try {
    await backupSong(cloud, song, includeAudio: includeAudio);
    if (context.mounted) {
      _snack(
        context,
        includeAudio ? l.ltCloudBackedUp(song.title) : l.ltCloudBackedUpNoAudio(song.title),
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
          if (context.mounted) _snack(context, l.ltCloudBackedUp(song.title));
        case _Resolve.takeCloud:
          final res = await restoreCopy(cloud, store, c.cloud!);
          if (context.mounted) _snack(context, l.ltCloudRestored(res.song.title));
        case _Resolve.keepBoth:
          await backupAsNewCopy(cloud, song, includeAudio: includeAudio);
          if (context.mounted) _snack(context, l.ltCloudBackedUp(song.title));
      }
    } catch (e) {
      if (context.mounted) _snack(context, cloudErrorText(l, e));
    }
  } catch (e) {
    debugPrint('[cloud] backup failed: ${e.runtimeType}');
    if (context.mounted) _snack(context, cloudErrorText(l, e));
  }
}

class _BackupDialog extends StatefulWidget {
  const _BackupDialog({required this.takes, required this.cloudHadAudio});
  final int takes;
  final bool cloudHadAudio;
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
