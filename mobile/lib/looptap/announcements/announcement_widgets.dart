// In-app announcements UI (2026-10-30):
// - [AnnouncementHomeBanner] on the song list: ONE banner (the most
//   important unread announcement, with "all (N)"), or a small link to the
//   list once everything is read. It is also the critical-popup gate: a
//   critical announcement pops up only when the song list is the top route
//   (no sheet, dialog or editor above it — so never during editing,
//   playback, count-in or recording) and the app is in the foreground; once
//   per run per revision; "Confirm" stores it, "Later" doesn't.
// - [AnnouncementCenterScreen] (home link + Settings › Announcements): every
//   active announcement, read ones too, old-cache notice; detail pages
//   scroll. Plain text only; a button opens only a vetted link, on tap.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/generated/app_localizations.dart';
import '../theme/tokens.dart';
import 'announcement.dart';
import 'announcement_service.dart';

String _lang(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'ko' ? 'ko' : 'en';

IconData _icon(AnnouncementKind k) => switch (k) {
  AnnouncementKind.critical => Icons.warning_amber_rounded,
  AnnouncementKind.important => Icons.priority_high_rounded,
  AnnouncementKind.info => Icons.campaign_outlined,
};

Color _color(AnnouncementKind k) => switch (k) {
  AnnouncementKind.critical => LT.danger,
  AnnouncementKind.important => LT.lime,
  AnnouncementKind.info => LT.t2,
};

String _kindLabel(L10n l, AnnouncementKind k) => switch (k) {
  AnnouncementKind.critical => l.annKindCritical,
  AnnouncementKind.important => l.annKindImportant,
  AnnouncementKind.info => l.annKindInfo,
};

/// Open a vetted action (https on our domain / stores, mail to support).
Future<void> openAnnouncementAction(Announcement a) async {
  final uri = a.action;
  if (uri == null) return;
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
}

class AnnouncementHomeBanner extends StatefulWidget {
  const AnnouncementHomeBanner({super.key, this.service});
  final AnnouncementService? service;
  @override
  State<AnnouncementHomeBanner> createState() => _AnnouncementHomeBannerState();
}

class _AnnouncementHomeBannerState extends State<AnnouncementHomeBanner>
    with WidgetsBindingObserver {
  late final AnnouncementService _s = widget.service ?? AnnouncementService.instance;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _s.addListener(_changed);
    _s.start();
  }

  @override
  void dispose() {
    _s.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // read new announcements on resume; show them at the next safe moment
    if (state == AppLifecycleState.resumed) {
      _s.refresh();
      if (mounted) setState(() {});
    }
  }

  bool get _safeToInterrupt {
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return (route?.isCurrent ?? true) &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
  }

  void _maybeShowCritical() {
    if (_showing || !_safeToInterrupt) return;
    final a = _s.pendingCritical();
    if (a == null) return;
    _s.markShownThisRun(a); // once per run, even if dismissed
    _showing = true;
    showDialog<void>(
      context: context,
      builder: (ctx) => _CriticalDialog(announcement: a, service: _s),
    ).whenComplete(() => _showing = false);
  }

  @override
  Widget build(BuildContext context) {
    // re-checked on every rebuild: feed updates, and the route becoming top
    // again (ModalRoute.of depends on it)
    ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowCritical());
    final l = L10n.of(context);
    final lang = _lang(context);
    final home = _s.forHome;
    final all = _s.visible;
    if (all.isEmpty) return const SizedBox.shrink();
    final unread = home.where((a) => !_s.isRead(a)).toList();
    if (unread.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const ValueKey('ann-home-link'),
          onPressed: () => AnnouncementCenterScreen.open(context, service: _s),
          icon: const Icon(Icons.campaign_outlined, size: 18),
          label: Text(l.annHomeLink(all.length)),
        ),
      );
    }
    final top = unread.first;
    return Padding(
      key: const ValueKey('ann-home-banner'),
      padding: const EdgeInsets.only(top: 10),
      child: Material(
        color: LT.surface2,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => AnnouncementDetailScreen.open(context, top, service: _s),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 4,
              children: [
                Icon(_icon(top.kind), color: _color(top.kind), size: 20),
                Text(
                  '${_kindLabel(l, top.kind)} · ${top.title(lang)}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: LT.t1, fontSize: 13, fontWeight: FontWeight.w600),
                ),
                TextButton(
                  key: const ValueKey('ann-home-all'),
                  onPressed: () => AnnouncementCenterScreen.open(context, service: _s),
                  child: Text(unread.length > 1 ? l.annAllWithCount(unread.length) : l.annAll),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CriticalDialog extends StatelessWidget {
  const _CriticalDialog({required this.announcement, required this.service});
  final Announcement announcement;
  final AnnouncementService service;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final lang = _lang(context);
    final a = announcement;
    return AlertDialog(
      key: const ValueKey('ann-critical'),
      icon: Icon(_icon(a.kind), color: _color(a.kind)),
      title: Text(a.title(lang)),
      scrollable: true,
      content: Text(a.body(lang)),
      actions: [
        if (a.action != null)
          TextButton(
            onPressed: () => openAnnouncementAction(a),
            child: Text(a.actionLabel(lang)!),
          ),
        TextButton(
          key: const ValueKey('ann-critical-later'),
          onPressed: () {
            service.markRead(a); // seen; NOT confirmed
            Navigator.pop(context);
          },
          child: Text(l.annLater),
        ),
        FilledButton(
          key: const ValueKey('ann-critical-confirm'),
          onPressed: () {
            service.acknowledge(a);
            Navigator.pop(context);
          },
          child: Text(l.annConfirm),
        ),
      ],
    );
  }
}

class AnnouncementCenterScreen extends StatefulWidget {
  const AnnouncementCenterScreen({super.key, this.service});
  final AnnouncementService? service;

  static Future<void> open(BuildContext context, {AnnouncementService? service}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => AnnouncementCenterScreen(service: service)),
      );

  @override
  State<AnnouncementCenterScreen> createState() => _AnnouncementCenterScreenState();
}

class _AnnouncementCenterScreenState extends State<AnnouncementCenterScreen> {
  late final AnnouncementService _s = widget.service ?? AnnouncementService.instance;

  @override
  void initState() {
    super.initState();
    _s.addListener(_changed);
    _s.start();
  }

  @override
  void dispose() {
    _s.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final lang = _lang(context);
    final items = _s.visible;
    final fmt = DateFormat.yMd(lang);
    return Scaffold(
      backgroundColor: LT.bg,
      appBar: AppBar(title: Text(l.annTitle)),
      body: RefreshIndicator(
        onRefresh: () => _s.refresh(force: true),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (_s.stale && _s.fetchedAt != null)
              Padding(
                key: const ValueKey('ann-stale'),
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  l.annStale(fmt.format(_s.fetchedAt!.toLocal())),
                  style: const TextStyle(color: LT.t3, fontSize: 12),
                ),
              ),
            if (items.isEmpty) Text(l.annEmpty, key: const ValueKey('ann-empty')),
            for (final a in items)
              Card(
                key: ValueKey('ann-item-${a.id}'),
                child: ListTile(
                  leading: Icon(_icon(a.kind), color: _color(a.kind)),
                  title: Text(
                    a.title(lang),
                    style: TextStyle(fontWeight: _s.isRead(a) ? FontWeight.w400 : FontWeight.w700),
                  ),
                  subtitle: Text(
                    [
                      _kindLabel(l, a.kind),
                      fmt.format(a.startsAt.toLocal()),
                      if (!_s.isRead(a)) l.annUnread,
                    ].join(' · '),
                  ),
                  onTap: () => AnnouncementDetailScreen.open(context, a, service: _s),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AnnouncementDetailScreen extends StatefulWidget {
  const AnnouncementDetailScreen({super.key, required this.announcement, this.service});
  final Announcement announcement;
  final AnnouncementService? service;

  static Future<void> open(BuildContext context, Announcement a, {AnnouncementService? service}) =>
      Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => AnnouncementDetailScreen(announcement: a, service: service)),
      );

  @override
  State<AnnouncementDetailScreen> createState() => _AnnouncementDetailScreenState();
}

class _AnnouncementDetailScreenState extends State<AnnouncementDetailScreen> {
  late final AnnouncementService _s = widget.service ?? AnnouncementService.instance;

  @override
  void initState() {
    super.initState();
    _s.addListener(_changed);
    // after this frame: marking read notifies the banner / list, which must
    // not be rebuilt while this page is being built
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _s.markRead(widget.announcement);
    });
  }

  @override
  void dispose() {
    _s.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final lang = _lang(context);
    final a = widget.announcement;
    final needsConfirm = a.kind == AnnouncementKind.critical && !_s.isAcknowledged(a);
    return Scaffold(
      backgroundColor: LT.bg,
      appBar: AppBar(title: Text(_kindLabel(l, a.kind))),
      body: SafeArea(
        child: ListView(
          key: const ValueKey('ann-detail'),
          padding: const EdgeInsets.all(16),
          children: [
            Text(a.title(lang), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: LT.t1)),
            const SizedBox(height: 4),
            Text(DateFormat.yMd(lang).format(a.startsAt.toLocal()), style: const TextStyle(color: LT.t3, fontSize: 12)),
            const SizedBox(height: 16),
            SelectableText(a.body(lang), style: const TextStyle(color: LT.t1, height: 1.5)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (a.action != null)
                  OutlinedButton(
                    key: const ValueKey('ann-action'),
                    onPressed: () => openAnnouncementAction(a),
                    child: Text(a.actionLabel(lang)!),
                  ),
                if (needsConfirm)
                  FilledButton(
                    key: const ValueKey('ann-detail-confirm'),
                    onPressed: () => _s.acknowledge(a),
                    child: Text(l.annConfirm),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
