import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/announcements/announcement.dart';
import 'package:humming/looptap/announcements/announcement_image.dart';
import 'package:humming/looptap/announcements/announcement_service.dart';
import 'package:humming/looptap/announcements/announcement_widgets.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import '../support/announcement_fixtures.dart';
import '../support/offline_fonts.dart';

const _url = 'https://hum-track.com/assets/notices/test-image.png';
Map<String, Object?> _row() => {
  ...annRow('image'),
  'image_url': _url,
  'image_alt_ko': '둥지의 새',
  'image_alt_en': 'A bird in a nest',
};

// A real tiny PNG, delivered through Image.network's actual HTTP/decoder path.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

class _Client implements HttpClient {
  final requests = <Uri>[];
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests.add(url);
    return _Request();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() async => _Response();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;
  @override
  int get contentLength => _png.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(
    _png,
  ).listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('old rows work and valid metadata chooses the right localized description', () {
    expect(Announcement.fromJson(annRow('old'))!.image, isNull);
    final a = Announcement.fromJson(_row())!;
    expect(a.image.toString(), _url);
    expect(a.imageAlt('ko'), '둥지의 새');
    expect(a.imageAlt('en'), 'A bird in a nest');
  });

  test('unsafe, half-filled and mistyped images are dropped without hiding the text', () {
    for (final extra in <Map<String, Object?>>[
      {'image_url': 42},
      {'image_alt_en': null},
      {'image_alt_ko': []},
      {'image_alt_en': ' '},
      {'image_alt_ko': 'x' * 301},
      {'image_url': 'https://evil.example/image.png'},
    ]) {
      final a = Announcement.fromJson({..._row(), ...extra});
      expect(a, isNotNull);
      expect(a!.bodyEn, 'Body text.');
      expect(a.image, isNull);
    }
    for (final url in [
      'http://hum-track.com/assets/notices/a.png',
      'https://hum-track.com.evil.io/assets/notices/a.png',
      'https://user@hum-track.com/assets/notices/a.png',
      'https://hum-track.com:443/assets/notices/a.png',
      'https://hum-track.com/assets/notices/a.svg',
      'https://hum-track.com/assets/notices/a.png?track=user',
      'https://hum-track.com/assets/notices/../a.png',
      'https://hum-track.com/assets/notices/%2e%2e.png',
      'data:image/png;base64,x',
      'javascript:alert(1)',
      '$_url\n',
    ]) {
      expect(safeAnnouncementImage(url), isNull, reason: url);
    }
    expect(safeAnnouncementImage('https://www.hum-track.com/assets/notices/cover.webp'), isNotNull);
  });

  test('an image notice survives cache restore while offline', () async {
    final root = await Directory.systemTemp.createTemp('humtrack_image_cache_');
    LoopStorage.rootOverride = root;
    addTearDown(() async {
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });
    final feed = FakeFeed()..rows = [_row()];
    AnnouncementService make() => AnnouncementService(
      fetch: feed.call,
      platform: AnnouncementPlatform.windows,
      build: 43,
      now: () => kFixtureNow,
    );
    final first = make();
    await first.start();
    await first.refresh();
    expect(first.visible.single.image.toString(), _url);
    first.dispose();
    feed.fail = true;
    final offline = make();
    await offline.start();
    await offline.refresh();
    expect(offline.visible.single.imageAlt('ko'), '둥지의 새');
    offline.dispose();
  });

  for (final lang in ['ko', 'en']) {
    testWidgets('network image decodes and fits a narrow $lang detail without cropping', (
      tester,
    ) async {
      useOfflineTestFonts();
      final client = _Client();
      debugNetworkImageHttpClientProvider = () => client;
      addTearDown(() {
        debugNetworkImageHttpClientProvider = null;
      });
      await tester.binding.setSurfaceSize(const Size(320, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final a = Announcement.fromJson(_row())!;
      final service = AnnouncementService(fetch: () async => null);
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(lang),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          builder:
              (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
          home: AnnouncementDetailScreen(announcement: a, service: service),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      final image = tester.widget<Image>(find.byKey(const ValueKey('ann-image')));
      expect(image.fit, BoxFit.contain);
      expect(image.semanticLabel, a.imageAlt(lang));
      expect(client.requests, contains(Uri.parse(_url)));
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      expect(find.byKey(const ValueKey('ann-image-error')), findsNothing);
      expect(find.text(a.body(lang)), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      service.dispose();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      debugNetworkImageHttpClientProvider = null;
    });
  }

  testWidgets('failed image falls back while body remains usable', (tester) async {
    useOfflineTestFonts();
    // The test binding's default HTTP client returns 400, exercising failure.
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: Column(
            children: [
              AnnouncementImage(announcement: Announcement.fromJson(_row())!),
              const Text('Body remains readable'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ann-image-error')), findsOneWidget);
    expect(find.text('Body remains readable'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
