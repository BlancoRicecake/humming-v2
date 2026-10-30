// In-app announcements (2026-10-30): one row of the public feed
// (backend/migrations/005_app_announcements.sql), validated again here —
// a bad row is skipped, the others still show.

/// info: news; important: worth a look; critical: shown once per revision
/// on the home screen until the user confirms it.
enum AnnouncementKind { info, important, critical }

/// The platforms a row can target (the feed's `platforms`).
enum AnnouncementPlatform { android, ios, windows, macos }

/// Limits the app enforces whatever the server sent.
const kAnnouncementMaxItems = 50;
const kAnnouncementMaxResponseBytes = 256 * 1024;
const kAnnouncementMaxTitle = 120;
const kAnnouncementMaxBody = 4000;
const kAnnouncementSupportEmail = 'humtrack@gmail.com';

final _id = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

/// The only links an announcement may open (on the user's tap): https on
/// hum-track.com (or a subdomain), the App Store / Google Play, or mail to
/// support. Anything else (other hosts, http, file paths, custom schemes)
/// is dropped — the announcement shows without a button.
Uri? safeAnnouncementAction(String? raw) {
  if (raw == null || raw.isEmpty || raw.length > 300) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null) return null;
  if (uri.scheme == 'mailto') {
    return uri.path.toLowerCase() == kAnnouncementSupportEmail && uri.query.isEmpty
        ? Uri(scheme: 'mailto', path: kAnnouncementSupportEmail)
        : null;
  }
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasPort) return null;
  final host = uri.host.toLowerCase();
  final ok = host == 'hum-track.com' ||
      host.endsWith('.hum-track.com') ||
      host == 'apps.apple.com' ||
      host == 'play.google.com';
  return ok ? uri : null;
}

class Announcement {
  const Announcement({
    required this.id,
    required this.revision,
    required this.kind,
    required this.titleKo,
    required this.titleEn,
    required this.bodyKo,
    required this.bodyEn,
    required this.startsAt,
    this.endsAt,
    required this.platforms,
    this.minBuild,
    this.maxBuild,
    this.actionLabelKo,
    this.actionLabelEn,
    this.action,
  });

  final String id;
  final int revision;
  final AnnouncementKind kind;
  final String titleKo, titleEn, bodyKo, bodyEn;
  final DateTime startsAt; // UTC
  final DateTime? endsAt; // UTC
  final Set<AnnouncementPlatform> platforms;
  final int? minBuild, maxBuild;
  final String? actionLabelKo, actionLabelEn;
  final Uri? action;

  /// "read" / "acknowledged" are per id AND revision: an edited announcement
  /// counts as new.
  String get key => '$id@$revision';

  String title(String lang) => lang == 'ko' ? titleKo : titleEn;
  String body(String lang) => lang == 'ko' ? bodyKo : bodyEn;
  String? actionLabel(String lang) => lang == 'ko' ? actionLabelKo : actionLabelEn;

  bool activeAt(DateTime now) =>
      !now.isBefore(startsAt) && (endsAt == null || now.isBefore(endsAt!));

  bool targets(AnnouncementPlatform platform, int? build) {
    if (!platforms.contains(platform)) return false;
    if (build == null) return minBuild == null && maxBuild == null;
    if (minBuild != null && build < minBuild!) return false;
    if (maxBuild != null && build > maxBuild!) return false;
    return true;
  }

  /// A feed row, or null when anything about it is invalid.
  static Announcement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? text(String k, int max) {
      final v = raw[k];
      if (v is! String) return null;
      final t = v.trim();
      return t.isEmpty || t.length > max ? null : t;
    }

    DateTime? time(String k) {
      final v = raw[k];
      return v is String ? DateTime.tryParse(v)?.toUtc() : null;
    }

    int? build(String k) {
      final v = raw[k];
      if (v == null) return null;
      return v is int && v >= 0 ? v : -1;
    }

    final id = raw['id'];
    final revision = raw['revision'];
    if (id is! String || !_id.hasMatch(id)) return null;
    if (revision is! int || revision < 1) return null;
    final kind = switch (raw['kind']) {
      'info' => AnnouncementKind.info,
      'important' => AnnouncementKind.important,
      'critical' => AnnouncementKind.critical,
      _ => null,
    };
    final titleKo = text('title_ko', kAnnouncementMaxTitle);
    final titleEn = text('title_en', kAnnouncementMaxTitle);
    final bodyKo = text('body_ko', kAnnouncementMaxBody);
    final bodyEn = text('body_en', kAnnouncementMaxBody);
    final startsAt = time('starts_at');
    final endsAt = raw['ends_at'] == null ? null : time('ends_at');
    if (kind == null ||
        titleKo == null ||
        titleEn == null ||
        bodyKo == null ||
        bodyEn == null ||
        startsAt == null) {
      return null;
    }
    if (raw['ends_at'] != null && (endsAt == null || !endsAt.isAfter(startsAt))) {
      return null;
    }
    final rawPlatforms = raw['platforms'];
    if (rawPlatforms is! List || rawPlatforms.isEmpty) return null;
    final platforms = <AnnouncementPlatform>{};
    for (final p in rawPlatforms) {
      final match = AnnouncementPlatform.values.where((v) => v.name == p);
      if (match.isEmpty) return null;
      platforms.add(match.first);
    }
    final minBuild = build('min_build'), maxBuild = build('max_build');
    if (minBuild == -1 || maxBuild == -1) return null;
    if (minBuild != null && maxBuild != null && maxBuild < minBuild) return null;
    // an unsafe or half-filled action is dropped, the announcement stays
    final rawAction = raw['action_url'];
    final action = safeAnnouncementAction(rawAction is String ? rawAction : null);
    final labelKo = text('action_label_ko', 40), labelEn = text('action_label_en', 40);
    final hasAction = action != null && labelKo != null && labelEn != null;
    return Announcement(
      id: id,
      revision: revision,
      kind: kind,
      titleKo: titleKo,
      titleEn: titleEn,
      bodyKo: bodyKo,
      bodyEn: bodyEn,
      startsAt: startsAt,
      endsAt: endsAt,
      platforms: platforms,
      minBuild: minBuild,
      maxBuild: maxBuild,
      actionLabelKo: hasAction ? labelKo : null,
      actionLabelEn: hasAction ? labelEn : null,
      action: hasAction ? action : null,
    );
  }

  /// The valid rows of a feed body (first [kAnnouncementMaxItems] rows), or
  /// null when the body itself isn't a feed (then the cache is kept).
  static List<Announcement>? parseFeed(Object? body) {
    if (body is! List) return null;
    final out = <Announcement>[];
    final seen = <String>{};
    for (final raw in body.take(kAnnouncementMaxItems)) {
      final a = fromJson(raw);
      if (a != null && seen.add(a.id)) out.add(a);
    }
    return out;
  }
}
