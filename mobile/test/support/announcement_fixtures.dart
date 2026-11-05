// Fixture announcements (2026-10-30) — test data only, never published.
import 'dart:async';
import 'dart:convert';

final kFixtureNow = DateTime.utc(2026, 11, 2, 12);

Map<String, Object?> annRow(
  String id, {
  int revision = 1,
  String kind = 'info',
  String? titleEn,
  String? titleKo,
  String bodyEn = 'Body text.',
  String bodyKo = '본문입니다.',
  DateTime? startsAt,
  DateTime? endsAt,
  List<String> platforms = const ['android', 'ios', 'windows', 'macos'],
  int? minBuild,
  int? maxBuild,
  String? actionUrl,
}) => {
  'id': id,
  'revision': revision,
  'kind': kind,
  'title_ko': titleKo ?? '제목 $id',
  'title_en': titleEn ?? 'Title $id',
  'body_ko': bodyKo,
  'body_en': bodyEn,
  'starts_at': (startsAt ?? kFixtureNow.subtract(const Duration(days: 1))).toIso8601String(),
  'ends_at': endsAt?.toIso8601String(),
  'platforms': platforms,
  'min_build': minBuild,
  'max_build': maxBuild,
  'action_label_ko': actionUrl == null ? null : '열기',
  'action_label_en': actionUrl == null ? null : 'Open',
  'action_url': actionUrl,
};

/// A feed stand-in: answers [rows] (or [body] bytes), counts calls, can fail
/// or hang.
class FakeFeed {
  List<Object?> rows = [];
  List<int>? body;
  bool fail = false;
  Completer<void>? hold;
  int calls = 0;

  Future<List<int>?> call() async {
    calls++;
    final h = hold;
    if (h != null) await h.future;
    if (fail) throw StateError('offline (fixture)');
    return body ?? utf8.encode(jsonEncode(rows));
  }
}
