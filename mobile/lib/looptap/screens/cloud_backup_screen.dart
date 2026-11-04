import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../l10n/generated/app_localizations.dart';
import '../models/loop_models.dart';
import '../state/cloud_backup.dart';
import '../state/loop_store.dart';
import '../theme/tokens.dart';
import '../widgets/cloud_backup_actions.dart';
import '../widgets/sheets/account_sheet.dart';
import '../widgets/sheets/paywall_sheet.dart';

/// Settings › Cloud backup (contract 1, behind HUMTRACK_CLOUD_BACKUP): the
/// account's cloud copies with usage; "Restore to this device" always makes a
/// NEW local song, "Delete from cloud" removes the cloud copy only. Opening
/// this screen reads; it never uploads. Open after a subscription ends too.
///
/// 2026-11-04: a short guide says where the copies live and how to back up /
/// restore / delete; signed out → a sign-in button; without Pro → why
/// uploads are locked (restore and delete still work); a failed load can be
/// retried; each copy says which song on this device it is linked to.
class CloudBackupScreen extends StatefulWidget {
  const CloudBackupScreen({super.key, this.api, this.apiFactory});
  final CloudBackupApi? api;

  /// Test seam: how to make the API for whoever is signed in (default
  /// [cloudApi]); asked again when the user signs in from this screen.
  @visibleForTesting
  final CloudBackupApi? Function()? apiFactory;

  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push<void>(MaterialPageRoute(builder: (_) => const CloudBackupScreen()));

  @override
  State<CloudBackupScreen> createState() => _CloudBackupScreenState();
}

typedef _CloudData = ({
  int used,
  int quota,
  List<CloudCopy> copies,
  Map<String, String> linked, // cloud project id → song title on this device
});

class _CloudBackupScreenState extends State<CloudBackupScreen> {
  // Bound to the account signed in when the screen opened. Opened signed
  // out, it binds to the account that signs in from here (Codex review
  // 2026-11-04); once bound, another account only gets the "account
  // changed" notice — never the previous account's list (C5).
  CloudBackupApi? _api;
  // null until there is an account to load for: a signed-out screen starts
  // no request (and so leaves no unobserved error behind)
  Future<_CloudData>? _data;
  bool _busy = false;
  String? _status;

  CloudBackupApi? _makeApi() => widget.api ?? (widget.apiFactory ?? cloudApi)();

  @override
  void initState() {
    super.initState();
    _api = _makeApi();
    if (_api != null) _data = _start(context.read<LoopStore>().songs);
  }

  // The FutureBuilder shows a failure; marking it handled here keeps a load
  // that fails before the next frame from surfacing as an uncaught error.
  Future<_CloudData> _start(List<Song> songs) => _load(songs)..ignore();

  Future<_CloudData> _load(List<Song> songs) async {
    final api = _api;
    if (api == null) throw const CloudSignInRequired();
    final u = await api.usage();
    final copies = await api.list();
    final links = await CloudLinks.load(api.owner);
    final titles = {for (final s in songs) s.id: s.title};
    return (
      used: u.used,
      quota: u.quota,
      copies: copies,
      linked: {
        for (final e in links.entries)
          if (titles[e.key] case final title?) e.value.projectId: title,
      },
    );
  }

  void _reload() {
    if (_api == null) return;
    final next = _start(context.read<LoopStore>().songs);
    setState(() {
      _data = next; // a block: setState must not get the Future back
    });
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
      _status = message; // stays above a list that failed to reload (retry)
      _data = _start(context.read<LoopStore>().songs);
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

  /// Where the copies live and how to back up / restore / delete.
  Widget _guide(L10n l) {
    Widget line(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: LT.lime),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: LT.t2, fontSize: 12.5, height: 1.4))),
        ],
      ),
    );
    return Container(
      key: const ValueKey('cloud-guide'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(LTRadius.control),
        border: Border.all(color: LT.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.ltCloudGuideTitle, style: const TextStyle(color: LT.t1, fontWeight: FontWeight.w700)),
          line(Icons.cloud_outlined, l.ltCloudGuideWhere),
          line(Icons.cloud_upload_outlined, l.ltCloudGuideUpload),
          line(Icons.download_outlined, l.ltCloudGuideRestore),
          line(Icons.delete_outline, l.ltCloudGuideDelete),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final store = context.watch<LoopStore>();
    final signedIn = store.isSignedIn;
    if (_api == null && signedIn) {
      // signed in from this screen: bind to that account and load its list
      final api = _makeApi();
      if (api != null) {
        _api = api;
        _status = null;
        _data = _start(store.songs);
      }
    }
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
          : _api == null
          ? ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _guide(l),
              const SizedBox(height: 16),
              Text(l.ltCloudSignIn, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Center(
                child: FilledButton(
                  key: const ValueKey('cloud-sign-in'),
                  onPressed: () => showAccountSheet(context),
                  child: Text(l.ltCloudSignInAction),
                ),
              ),
            ],
          )
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
                  future: _data!,
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return ListView(
                        padding: const EdgeInsets.all(16),
                        children: [
                          _guide(l),
                          const SizedBox(height: 16),
                          Text(cloudErrorText(l, snap.error!), textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          Center(
                            child: FilledButton(
                              key: const ValueKey('cloud-retry'),
                              onPressed: _reload,
                              child: Text(l.ltCloudRetry),
                            ),
                          ),
                        ],
                      );
                    }
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final d = snap.data!;
                    return ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        _guide(l),
                        const SizedBox(height: 12),
                        if (!store.proActive) ...[
                          Container(
                            key: const ValueKey('cloud-pro-note'),
                            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                            decoration: BoxDecoration(
                              color: LT.lime.withValues(alpha: .08),
                              borderRadius: BorderRadius.circular(LTRadius.control),
                              border: Border.all(color: LT.lime.withValues(alpha: .4)),
                            ),
                            child: Row(
                              children: [
                                Expanded(child: Text(l.ltCloudProNote, style: const TextStyle(fontSize: 12.5))),
                                TextButton(
                                  key: const ValueKey('cloud-pro-action'),
                                  onPressed: () => showPaywallSheet(context, trigger: PaywallTrigger.upgrade),
                                  child: Text(l.ltCloudProAction),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
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
                                  if (d.linked[c.projectId] case final title?)
                                    Text(
                                      l.ltCloudLinkedTo(title),
                                      key: ValueKey('cloud-linked-${c.projectId}'),
                                      style: const TextStyle(color: LT.lime, fontSize: 12),
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
