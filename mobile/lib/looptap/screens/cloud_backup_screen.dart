import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../state/cloud_backup.dart';
import '../state/loop_store.dart';
import '../theme/tokens.dart';
import '../widgets/cloud_backup_actions.dart';

/// Settings › Cloud backup (contract 1, behind HUMTRACK_CLOUD_BACKUP): the
/// account's cloud copies with usage; "Restore to this device" always makes a
/// NEW local song, "Delete from cloud" removes the cloud copy only. Opening
/// this screen reads; it never uploads. Open after a subscription ends too.
class CloudBackupScreen extends StatefulWidget {
  const CloudBackupScreen({super.key, this.api});
  final CloudBackupApi? api;

  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push<void>(MaterialPageRoute(builder: (_) => const CloudBackupScreen()));

  @override
  State<CloudBackupScreen> createState() => _CloudBackupScreenState();
}

class _CloudBackupScreenState extends State<CloudBackupScreen> {
  // bound to the account signed in when the screen opened
  late final CloudBackupApi? _api = widget.api ?? cloudApi();
  late Future<({int used, int quota, List<CloudCopy> copies})> _data = _load();
  bool _busy = false;
  String? _status;

  Future<({int used, int quota, List<CloudCopy> copies})> _load() async {
    final api = _api;
    if (api == null) throw const CloudSignInRequired();
    final u = await api.usage();
    final copies = await api.list();
    return (used: u.used, quota: u.quota, copies: copies);
  }

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    String message;
    try {
      message = await action();
    } catch (e) {
      message = mounted ? cloudErrorText(L10n.of(context), e) : '';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = message;
      _data = _load();
    });
  }

  Future<void> _restore(CloudCopy copy) => _run(() async {
    final l = L10n.of(context);
    final res = await restoreCopy(_api!, context.read<LoopStore>(), copy);
    return [
      l.ltCloudRestored(res.song.title),
      if (!copy.audioIncluded) l.ltCloudRestoredNoAudio,
    ].join('\n');
  });

  Future<void> _delete(CloudCopy copy) async {
    final l = L10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const ValueKey('cloud-delete-confirm'),
        title: Text(l.ltCloudDeleteTitle(copy.title)),
        content: Text(l.ltCloudDeleteBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l.cancel)),
          TextButton(
            key: const ValueKey('cloud-delete-yes'),
            style: TextButton.styleFrom(foregroundColor: LT.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.ltCloudDeleteYes),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(() async {
      await deleteCopy(_api!, copy.projectId);
      return l.ltCloudDeleted;
    });
  }

  String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final signedIn = context.watch<LoopStore>().isSignedIn;
    // the account changed since this screen opened: nothing of the previous
    // account stays on screen (Codex C5, cached list)
    final switched = _api?.ownerChanged ?? false;
    return Scaffold(
      backgroundColor: LT.bg,
      appBar: AppBar(title: Text(l.ltCloudTitle)),
      body: switched
          ? Center(
            key: const ValueKey('cloud-account-changed'),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(l.ltCloudAccountChanged, textAlign: TextAlign.center),
            ),
          )
          : !signedIn && widget.api == null
          ? Center(child: Text(l.ltCloudSignIn))
          : Column(
            children: [
              if (_status != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Semantics(liveRegion: true, child: Text(_status!)),
                ),
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                child: FutureBuilder(
                  future: _data,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(child: Text(cloudErrorText(l, snap.error!)));
                    }
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final d = snap.data!;
                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        Text(
                          l.ltCloudUsage(_mb(d.used), _mb(d.quota)),
                          key: const ValueKey('cloud-usage'),
                        ),
                        const SizedBox(height: 6),
                        LinearProgressIndicator(
                          value: d.quota == 0 ? 0 : (d.used / d.quota).clamp(0.0, 1.0),
                        ),
                        const SizedBox(height: 8),
                        Text(l.ltCloudPrivacyNote, style: const TextStyle(color: LT.t3, fontSize: 12)),
                        const SizedBox(height: 16),
                        if (d.copies.isEmpty) Text(l.ltCloudEmpty),
                        for (final c in d.copies)
                          Card(
                            key: ValueKey('cloud-copy-${c.projectId}'),
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(c.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                                  Text(
                                    '${DateFormat.yMd().add_Hm().format(c.updatedAt.toLocal())} · ${_mb(c.sizeBytes)} · '
                                    '${c.audioIncluded ? l.ltCloudWithAudio : l.ltCloudNoAudio}',
                                    style: const TextStyle(color: LT.t3, fontSize: 12),
                                  ),
                                  // wraps onto a second line on narrow
                                  // screens / large text (Codex C6)
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 0,
                                    children: [
                                      TextButton(
                                        key: ValueKey('cloud-restore-${c.projectId}'),
                                        onPressed: _busy ? null : () => _restore(c),
                                        child: Text(l.ltCloudRestore),
                                      ),
                                      TextButton(
                                        key: ValueKey('cloud-delete-${c.projectId}'),
                                        style: TextButton.styleFrom(foregroundColor: LT.danger),
                                        onPressed: _busy ? null : () => _delete(c),
                                        child: Text(l.ltCloudDelete),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
    );
  }
}
