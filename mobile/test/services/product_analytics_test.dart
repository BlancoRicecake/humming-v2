import 'package:flutter_test/flutter_test.dart';
import 'package:humming/services/product_analytics.dart';
import 'package:package_info_plus/package_info_plus.dart';

class _FakeSink implements ProductAnalyticsSink {
  bool initialized = false;
  bool? enabled;
  String? userId;
  int resets = 0;
  Map<String, Object> context = {};
  final events = <(String, Map<String, Object>)>[];
  final calls = <String>[];

  @override
  Future<void> initialize() async {
    initialized = true;
    calls.add('initialize');
  }

  @override
  Future<void> reset() async {
    resets += 1;
    userId = null;
  }

  @override
  Future<void> setCollectionEnabled(bool value) async {
    enabled = value;
    calls.add('enabled:$value');
  }

  @override
  Future<void> setContext(Map<String, Object> value) async {
    context = Map.of(value);
  }

  @override
  Future<void> setUserId(String? value) async => userId = value;

  @override
  Future<void> track(String name, Map<String, Object> properties) async {
    events.add((name, Map.of(properties)));
  }
}

PackageInfo _packageInfo() => PackageInfo(
  appName: 'HumTrack',
  packageName: 'com.humtrack.app',
  version: '1.0.7',
  buildNumber: '37',
);

void main() {
  test('bootstrap supplies common context without secrets', () async {
    final sink = _FakeSink();
    final analytics = ProductAnalytics(sinks: [sink]);

    await analytics.bootstrap(
      enabled: true,
      locale: 'ko-KR',
      packageInfo: _packageInfo(),
    );

    expect(sink.initialized, isTrue);
    expect(sink.enabled, isTrue);
    expect(sink.context['app_id'], 'humtrack');
    expect(sink.context['app_version'], '1.0.7');
    expect(sink.context['build_number'], '37');
    expect(sink.context['locale'], 'ko-KR');
    expect(sink.context['plan'], 'free');
  });

  test('only allowlisted enum properties reach sinks', () async {
    final sink = _FakeSink();
    final analytics = ProductAnalytics(sinks: [sink]);
    await analytics.bootstrap(enabled: true, packageInfo: _packageInfo());

    await analytics.track(
      ProductEvent.analyzeFailed,
      properties: const {
        'feature': 'guided_creation',
        'error_code': 'connection',
        'role': 'a user supplied sentence',
        'candidate': 2,
        'email': 'person@example.com',
        'song_title': 'private title',
        'audio_path': r'C:\private\voice.wav',
      },
    );

    expect(sink.events, hasLength(1));
    final payload = sink.events.single.$2;
    expect(payload['feature'], 'guided_creation');
    expect(payload['error_code'], 'connection');
    expect(payload['candidate'], 2);
    expect(payload, isNot(contains('role')));
    expect(payload, isNot(contains('email')));
    expect(payload, isNot(contains('song_title')));
    expect(payload, isNot(contains('audio_path')));
  });

  test('consent off stops delivery and clears sink identity', () async {
    final sink = _FakeSink();
    final analytics = ProductAnalytics(sinks: [sink]);
    await analytics.bootstrap(enabled: true, packageInfo: _packageInfo());
    await analytics.setUserId('7b00d69c_opaque_user');

    await analytics.setConsent(false);
    await analytics.track(ProductEvent.guidedStarted);

    expect(sink.enabled, isFalse);
    expect(sink.resets, 1);
    expect(sink.userId, isNull);
    expect(sink.events, isEmpty);

    await analytics.setUserId('7b00d69c_second_user');
    expect(sink.userId, isNull);
    await analytics.setConsent(true);
    expect(sink.userId, '7b00d69c_second_user');
  });

  test('existing opt-out is applied before a sink initializes', () async {
    final sink = _FakeSink();
    final analytics = ProductAnalytics(sinks: [sink]);

    await analytics.bootstrap(enabled: false, packageInfo: _packageInfo());

    expect(sink.calls.take(2), ['enabled:false', 'initialize']);
    expect(sink.enabled, isFalse);
  });

  test('unknown events and direct identifiers are rejected', () async {
    final sink = _FakeSink();
    final analytics = ProductAnalytics(sinks: [sink]);
    await analytics.bootstrap(enabled: true, packageInfo: _packageInfo());

    await analytics.setUserId('person@example.com');
    await analytics.track('free_form_event');

    expect(sink.userId, isNull);
    expect(sink.events, isEmpty);
  });

  test('beginner success funnel preserves the product step order', () async {
    final sink = _FakeSink();
    final analytics = ProductAnalytics(sinks: [sink]);
    await analytics.bootstrap(
      enabled: true,
      locale: 'ko-KR',
      packageInfo: _packageInfo(),
    );

    await analytics.track(ProductEvent.appStarted);
    await analytics.track(
      ProductEvent.guidedStarted,
      properties: const {
        'feature': 'guided_creation',
        'entry_source': 'new_song',
      },
    );
    await analytics.track(
      ProductEvent.recordingStarted,
      properties: const {'feature': 'hum_recording'},
    );
    await analytics.track(
      ProductEvent.analyzeCompleted,
      properties: const {'feature': 'guided_creation', 'role': 'melodic'},
    );
    await analytics.track(
      ProductEvent.guidedBackingPreviewed,
      properties: const {
        'feature': 'guided_backing',
        'backing_style': 'drive',
        'candidate': 1,
      },
    );
    await analytics.track(
      ProductEvent.guidedBackingApplied,
      properties: const {
        'feature': 'guided_backing',
        'backing_style': 'drive',
        'candidate': 1,
      },
    );
    await analytics.track(
      ProductEvent.guidedSongSaved,
      properties: const {'feature': 'guided_creation'},
    );
    // A free user reaches the subscription screen from Export. Successful
    // export events follow entitlement activation.
    await analytics.track(
      ProductEvent.paywallViewed,
      properties: const {
        'feature': 'subscription',
        'entry_source': 'export',
        'trigger': 'export',
      },
    );
    await analytics.track(
      ProductEvent.purchaseStarted,
      properties: const {
        'feature': 'subscription',
        'entry_source': 'export',
        'store': 'play_store',
      },
    );
    await analytics.track(
      ProductEvent.purchaseCompleted,
      properties: const {'feature': 'subscription', 'store': 'play_store'},
    );
    await analytics.track(
      ProductEvent.exportMidi,
      properties: const {
        'feature': 'export',
        'export_type': 'midi',
        'scope': 'song',
      },
    );
    await analytics.track(
      ProductEvent.exportWav,
      properties: const {
        'feature': 'export',
        'export_type': 'wav',
        'scope': 'song',
      },
    );

    expect(sink.events.map((event) => event.$1), [
      ProductEvent.appStarted,
      ProductEvent.guidedStarted,
      ProductEvent.recordingStarted,
      ProductEvent.analyzeCompleted,
      ProductEvent.guidedBackingPreviewed,
      ProductEvent.guidedBackingApplied,
      ProductEvent.guidedSongSaved,
      ProductEvent.paywallViewed,
      ProductEvent.purchaseStarted,
      ProductEvent.purchaseCompleted,
      ProductEvent.exportMidi,
      ProductEvent.exportWav,
    ]);
    for (final event in sink.events) {
      expect(event.$2['app_id'], 'humtrack');
      expect(event.$2['app_version'], '1.0.7');
      expect(event.$2['build_number'], '37');
      expect(event.$2['locale'], 'ko-KR');
      expect(event.$2.keys, isNot(contains('email')));
      expect(event.$2.keys, isNot(contains('song_title')));
      expect(event.$2.keys, isNot(contains('audio_path')));
    }
  });

  test('beginner recovery funnel records fixed failure reasons', () async {
    final sink = _FakeSink();
    final analytics = ProductAnalytics(sinks: [sink]);
    await analytics.bootstrap(enabled: true, packageInfo: _packageInfo());

    await analytics.track(
      ProductEvent.analyzeFailed,
      properties: const {
        'feature': 'guided_creation',
        'error_code': 'connection',
      },
    );
    await analytics.track(
      ProductEvent.guidedSongFailed,
      properties: const {
        'feature': 'guided_creation',
        'error_code': 'local_save',
      },
    );
    await analytics.track(
      ProductEvent.exportFailed,
      properties: const {
        'feature': 'export',
        'export_type': 'wav',
        'error_code': 'render',
      },
    );
    await analytics.track(
      ProductEvent.purchaseFailed,
      properties: const {
        'feature': 'subscription',
        'entry_source': 'export',
        'error_code': 'storeError',
        'store': 'play_store',
      },
    );

    expect(sink.events.map((event) => event.$1), [
      ProductEvent.analyzeFailed,
      ProductEvent.guidedSongFailed,
      ProductEvent.exportFailed,
      ProductEvent.purchaseFailed,
    ]);
    expect(sink.events.map((event) => event.$2['error_code']), [
      'connection',
      'local_save',
      'render',
      'storeError',
    ]);
  });
}
