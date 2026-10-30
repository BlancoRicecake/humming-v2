// In-app announcements (2026-10-30): reads the public feed straight from
// Supabase REST with the public anon key (not the engine API, so news still
// arrives when the analysis / cloud server is down), keeps the last good
// feed on disk, and remembers per id+revision what was read / confirmed.
//
// Never blocks the app: start() returns after the local cache is read and
// refreshes in the background with short timeouts; overlapping refreshes
// share one request; on resume it refreshes at most every 15 minutes.
// A failed / damaged / oversized response changes nothing; a successful
// empty feed withdraws everything. A cache older than 7 days is shown only
// in the list, marked as old — never as a banner or a popup.
// No account token is sent; nothing about the feed is logged.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../state/atomic_json.dart';
import '../state/loop_storage.dart';
import 'announcement.dart';

/// The feed's body bytes; null = the feature isn't configured in this build.
typedef AnnouncementFetch = Future<List<int>?> Function();

const _columns =
    'id,revision,kind,title_ko,title_en,body_ko,body_en,starts_at,ends_at,'
    'platforms,min_build,max_build,action_label_ko,action_label_en,action_url';

/// GET {SUPABASE_URL}/rest/v1/app_announcements with the public anon key.
Future<List<int>?> supabaseAnnouncementFetch() async {
  const url = String.fromEnvironment('SUPABASE_URL');
  const anon = String.fromEnvironment('SUPABASE_ANON_KEY');
  if (url.isEmpty || anon.isEmpty) return null; // local builds: feature off
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 5),
      receiveTimeout: const Duration(seconds: 8),
      responseType: ResponseType.bytes,
      headers: {
        'apikey': anon,
        'Authorization': 'Bearer $anon', // public key, never a user token
        'Accept': 'application/json',
      },
    ),
  );
  try {
    final r = await dio.get<List<int>>(
      '$url/rest/v1/app_announcements',
      queryParameters: {
        'select': _columns,
        'order': 'starts_at.desc',
        'limit': '$kAnnouncementMaxItems',
      },
    );
    return r.data ?? const [];
  } finally {
    dio.close();
  }
}

AnnouncementPlatform _currentPlatform() {
  if (Platform.isAndroid) return AnnouncementPlatform.android;
  if (Platform.isIOS) return AnnouncementPlatform.ios;
  if (Platform.isMacOS) return AnnouncementPlatform.macos;
  return AnnouncementPlatform.windows;
}

Future<int?> _currentBuild() async {
  try {
    return int.tryParse((await PackageInfo.fromPlatform()).buildNumber);
  } catch (_) {
    return null;
  }
}

class AnnouncementService extends ChangeNotifier {
  AnnouncementService({
    AnnouncementFetch? fetch,
    AnnouncementPlatform? platform,
    int? build,
    bool buildKnown = false,
    DateTime Function()? now,
    this.minRefreshInterval = const Duration(minutes: 15),
    this.fetchTimeout = const Duration(seconds: 12),
    this.staleAfter = const Duration(days: 7),
  }) : _fetch = fetch ?? supabaseAnnouncementFetch,
       _platform = platform,
       _build = build,
       _buildKnown = buildKnown || build != null,
       _now = now ?? DateTime.now;

  static AnnouncementService _instance = AnnouncementService();
  static AnnouncementService get instance => _instance;
  @visibleForTesting
  static set instance(AnnouncementService s) => _instance = s;

  final AnnouncementFetch _fetch;
  final AnnouncementPlatform? _platform;
  int? _build;
  bool _buildKnown;
  final DateTime Function() _now;
  final Duration minRefreshInterval, fetchTimeout, staleAfter;

  List<Announcement> _items = const [];
  List<Object?> _rawRows = const [];
  DateTime? _fetchedAt;
  final Set<String> _read = {}, _acked = {};
  final Set<String> _shownThisRun = {};
  bool _loaded = false;
  bool _disabled = false;
  Future<void>? _starting, _refreshing;
  DateTime? _lastAttempt;

  AtomicJsonFile? _feedFile, _stateFile;
  Timer? _visibilityTimer;
  bool _disposed = false;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    _scheduleVisibilityChange();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _visibilityTimer?.cancel();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    _scheduleVisibilityChange();
    super.notifyListeners();
  }

  // Expiry and cache age change even without a network response or user
  // input. Wake only at the next boundary while a screen is observing us.
  void _scheduleVisibilityChange() {
    _visibilityTimer?.cancel();
    if (_disposed || !hasListeners) return;
    final now = _now().toUtc();
    DateTime? next;
    void consider(DateTime? at) {
      if (at != null && at.isAfter(now) && (next == null || at.isBefore(next!))) {
        next = at;
      }
    }
    for (final a in _items) {
      consider(a.startsAt);
      consider(a.endsAt);
    }
    if (_fetchedAt != null) consider(_fetchedAt!.add(staleAfter));
    if (next != null) {
      _visibilityTimer = Timer(next!.difference(now), notifyListeners);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _visibilityTimer?.cancel();
    super.dispose();
  }

  bool get loaded => _loaded;

  /// False in builds without the feed configured (and no cache).
  bool get enabled => !_disabled || _items.isNotEmpty;
  DateTime? get fetchedAt => _fetchedAt;

  /// The last good feed is old (offline for a long time): list only.
  bool get stale =>
      _fetchedAt != null && _now().toUtc().difference(_fetchedAt!) >= staleAfter;

  /// Active announcements for this device, most important first.
  List<Announcement> get visible {
    final now = _now().toUtc();
    final platform = _platform ?? _currentPlatform();
    final list = [
      for (final a in _items)
        if (a.activeAt(now) && a.targets(platform, _build)) a,
    ]..sort((a, b) {
      final k = b.kind.index.compareTo(a.kind.index);
      return k != 0 ? k : b.startsAt.compareTo(a.startsAt);
    });
    return list;
  }

  /// What the home screen may show (nothing from an old cache).
  List<Announcement> get forHome => stale ? const [] : visible;

  bool isRead(Announcement a) => _read.contains(a.key) || _acked.contains(a.key);
  bool isAcknowledged(Announcement a) => _acked.contains(a.key);
  int get unreadCount => visible.where((a) => !isRead(a)).length;

  /// The critical announcement to show now, once per run per revision.
  Announcement? pendingCritical() {
    for (final a in forHome) {
      if (a.kind == AnnouncementKind.critical &&
          !_acked.contains(a.key) &&
          !_shownThisRun.contains(a.key)) {
        return a;
      }
    }
    return null;
  }

  void markShownThisRun(Announcement a) => _shownThisRun.add(a.key);

  Future<File> _path(String name) async => File(
    '${(await LoopStorage.documentsDirectory()).path}/looptap/announcements/$name',
  );

  /// Read the cache (fast, local) and refresh in the background.
  Future<void> start() => _starting ??= _start();

  Future<void> _start() async {
    try {
      await _load();
    } catch (_) {
      // no storage yet (or unreadable): run without a cache
      debugPrint('[announcements] local cache unavailable');
    }
    _loaded = true;
    notifyListeners();
    unawaited(refresh(force: true));
  }

  Future<void> _load() async {
    _feedFile = AtomicJsonFile(await _path('feed.json'));
    _stateFile = AtomicJsonFile(await _path('state.json'));
    if (!_buildKnown) {
      _build = await _currentBuild();
      _buildKnown = true;
    }
    final cached = await _feedFile!.read();
    if (cached is Map) {
      final rows = cached['rows'];
      final at = DateTime.tryParse('${cached['fetchedAt']}')?.toUtc();
      final parsed = Announcement.parseFeed(rows);
      if (parsed != null && at != null) {
        _items = parsed;
        _rawRows = rows as List;
        _fetchedAt = at;
      }
    }
    final state = await _stateFile!.read();
    if (state is Map) {
      _read.addAll(((state['read'] as List?) ?? const []).whereType<String>());
      _acked.addAll(((state['acked'] as List?) ?? const []).whereType<String>());
    }
  }

  /// Fetch the feed (shared when one is already running; at most every
  /// [minRefreshInterval] unless [force]).
  Future<void> refresh({bool force = false}) {
    final running = _refreshing;
    if (running != null) return running;
    final last = _lastAttempt;
    if (!force && last != null && _now().difference(last) < minRefreshInterval) {
      return Future.value();
    }
    _lastAttempt = _now();
    return _refreshing = _refresh().whenComplete(() => _refreshing = null);
  }

  Future<void> _refresh() async {
    final List<int>? body;
    try {
      body = await _fetch().timeout(fetchTimeout);
    } catch (_) {
      debugPrint('[announcements] refresh failed (kept the last good feed)');
      return;
    }
    if (body == null) {
      _disabled = true;
      return;
    }
    if (body.length > kAnnouncementMaxResponseBytes) return;
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(body));
    } catch (_) {
      return; // damaged: keep the cache
    }
    final parsed = Announcement.parseFeed(json);
    if (parsed == null) return;
    final rows = [
      for (final raw in (json as List).take(kAnnouncementMaxItems))
        if (Announcement.fromJson(raw) != null) raw,
    ];
    final at = _now().toUtc();
    try {
      final file = _feedFile;
      if (file != null) {
        await file.serial(
          () => file.write({'fetchedAt': at.toIso8601String(), 'rows': rows}),
        );
      }
    } catch (_) {
      debugPrint('[announcements] cache write failed (kept the previous one)');
    }
    _items = parsed; // an empty feed withdraws everything
    _rawRows = rows;
    _fetchedAt = at;
    notifyListeners();
  }

  Future<void> markRead(Announcement a) => _remember(read: a);

  /// "Confirm": this revision won't pop up again on this device.
  Future<void> acknowledge(Announcement a) => _remember(read: a, acked: a);

  Future<void> _remember({Announcement? read, Announcement? acked}) async {
    var changed = false;
    if (read != null) changed |= _read.add(read.key);
    if (acked != null) changed |= _acked.add(acked.key);
    if (!changed) return;
    notifyListeners();
    final file = _stateFile;
    if (file == null) return;
    try {
      await file.serial(() async {
        // merge with what is on disk; keep the newest 500 of each
        final disk = await file.read();
        List<String> merged(String k, Set<String> mine) {
          final out = <String>{
            if (disk is Map) ...((disk[k] as List?) ?? const []).whereType<String>(),
            ...mine,
          }.toList();
          return out.length > 500 ? out.sublist(out.length - 500) : out;
        }

        await file.write({'read': merged('read', _read), 'acked': merged('acked', _acked)});
      });
    } catch (_) {
      debugPrint('[announcements] state write failed (kept in memory)');
    }
  }

  @visibleForTesting
  List<Object?> get debugCachedRows => _rawRows;

  /// A refresh (or the first load) is still running.
  @visibleForTesting
  bool get busy => !_loaded || _refreshing != null;
}
