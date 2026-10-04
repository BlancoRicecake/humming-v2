import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'clarity_service.dart';

abstract interface class ProductAnalyticsSink {
  Future<void> initialize();
  Future<void> setCollectionEnabled(bool enabled);
  Future<void> setUserId(String? opaqueUserId);
  Future<void> setContext(Map<String, Object> context);
  Future<void> track(String eventName, Map<String, Object> properties);
  Future<void> reset();
}

abstract final class ProductEvent {
  static const appStarted = 'app_started';
  static const signedIn = 'signed_in';
  static const guidedStarted = 'guided_started';
  static const recordingStarted = 'recording_started';
  static const recordingInterrupted = 'recording_interrupted';
  static const vocalRecordingInterrupted = 'vocal_recording_interrupted';
  static const analyzeCompleted = 'analyze_completed';
  static const analyzeFailed = 'analyze_failed';
  static const guidedConversionCompleted = 'guided_conversion_completed';
  static const guidedBackingPreviewed = 'guided_backing_previewed';
  static const guidedBackingApplied = 'guided_backing_applied';
  static const guidedSongSaved = 'guided_song_saved';
  static const guidedSongFailed = 'guided_song_failed';
  static const songSaveFailed = 'song_save_failed';
  static const exportMidi = 'export_midi';
  static const exportWav = 'export_wav';
  static const exportStems = 'export_stems';
  static const exportFailed = 'export_failed';
  static const paywallViewed = 'paywall_viewed';
  static const purchaseStarted = 'purchase_started';
  static const purchaseCompleted = 'purchase_completed';
  static const purchaseFailed = 'purchase_failed';
  static const purchaseRestored = 'purchase_restored';

  static const allowed = <String>{
    appStarted,
    signedIn,
    guidedStarted,
    recordingStarted,
    recordingInterrupted,
    vocalRecordingInterrupted,
    analyzeCompleted,
    analyzeFailed,
    guidedConversionCompleted,
    guidedBackingPreviewed,
    guidedBackingApplied,
    guidedSongSaved,
    guidedSongFailed,
    songSaveFailed,
    exportMidi,
    exportWav,
    exportStems,
    exportFailed,
    paywallViewed,
    purchaseStarted,
    purchaseCompleted,
    purchaseFailed,
    purchaseRestored,
  };
}

/// One privacy boundary for product funnels. Feature code never talks to an
/// analytics SDK directly. Only enum-like values from [_allowedStringValues]
/// cross this boundary; user text, titles, paths, audio and musical content do
/// not have a representable field.
class ProductAnalytics {
  ProductAnalytics({Iterable<ProductAnalyticsSink> sinks = const []})
    : _sinks = List.of(sinks);

  static final ProductAnalytics instance = ProductAnalytics();

  static const _environment = String.fromEnvironment(
    'APP_ENVIRONMENT',
    defaultValue: kReleaseMode ? 'production' : 'development',
  );

  static const _allowedStringValues = <String, Set<String>>{
    'feature': {
      'guided_creation',
      'editor',
      'guided_backing',
      'export',
      'subscription',
      'restore',
      'hum_recording',
      'vocal_recording',
    },
    'entry_source': {'new_song', 'export', 'songQuota', 'upgrade'},
    'error_code': {
      'unknown',
      'no_notes',
      'too_long',
      'busy',
      'connection',
      'server',
      'local_save',
      'render',
      'lifecycle',
      'launch_exception',
      'store_error',
      'verify_failed',
      'store_unavailable',
      'restore_failed',
      'pending',
      'paymentPending',
      'verifyFailed',
      'network',
      'throttled',
      'notSignedIn',
      'storeError',
    },
    'role': {'drum', 'melodic'},
    'backing_style': {'calm', 'bounce', 'drive'},
    'trigger': {'export', 'songQuota', 'upgrade'},
    'export_type': {'midi', 'wav', 'stems'},
    'scope': {'song', 'section'},
    'store': {'app_store', 'play_store'},
    'auth_provider': {'apple', 'google', 'email', 'unknown'},
  };

  final List<ProductAnalyticsSink> _sinks;
  final ValueNotifier<bool> collectionEnabled = ValueNotifier(true);
  final Map<String, Object> _context = <String, Object>{
    'app_id': 'humtrack',
    'environment': _environment,
    'plan': 'free',
  };
  bool _bootstrapped = false;
  String? _userId;

  @visibleForTesting
  Map<String, Object> get contextSnapshot => Map.unmodifiable(_context);

  void installSinks(Iterable<ProductAnalyticsSink> sinks) {
    if (_bootstrapped) {
      throw StateError('Analytics sinks must be installed before bootstrap');
    }
    _sinks.addAll(sinks);
  }

  Future<void> bootstrap({
    required bool enabled,
    String? locale,
    PackageInfo? packageInfo,
  }) async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    collectionEnabled.value = enabled;
    _context['platform'] = _platformName();
    _context['locale'] =
        locale ?? PlatformDispatcher.instance.locale.toLanguageTag();
    try {
      final info = packageInfo ?? await PackageInfo.fromPlatform();
      _context['app_version'] = info.version;
      _context['build_number'] = info.buildNumber;
    } catch (error) {
      _context['app_version'] = 'unknown';
      _context['build_number'] = 'unknown';
      debugPrint(
        '[analytics] package metadata unavailable: ${error.runtimeType}',
      );
    }
    for (final sink in _sinks) {
      try {
        await sink.setCollectionEnabled(enabled);
        await sink.initialize();
        await sink.setContext(_context);
      } catch (error) {
        debugPrint('[analytics] sink bootstrap failed: ${error.runtimeType}');
      }
    }
  }

  Future<void> setConsent(bool enabled) async {
    if (collectionEnabled.value == enabled) return;
    collectionEnabled.value = enabled;
    for (final sink in _sinks) {
      try {
        await sink.setCollectionEnabled(enabled);
        if (enabled) {
          await sink.setContext(_context);
          await sink.setUserId(_userId);
        } else {
          await sink.reset();
        }
      } catch (error) {
        debugPrint('[analytics] consent update failed: ${error.runtimeType}');
      }
    }
  }

  Future<void> setUserId(String? opaqueUserId) async {
    final safeId = opaqueUserId?.trim();
    if (safeId != null && safeId.isNotEmpty && !_looksOpaque(safeId)) {
      debugPrint('[analytics] rejected non-opaque user id');
      return;
    }
    _userId = safeId == null || safeId.isEmpty ? null : safeId;
    if (!collectionEnabled.value && _userId != null) return;
    for (final sink in _sinks) {
      try {
        await sink.setUserId(_userId);
      } catch (error) {
        debugPrint('[analytics] user update failed: ${error.runtimeType}');
      }
    }
  }

  Future<void> reset() async {
    for (final sink in _sinks) {
      try {
        await sink.reset();
      } catch (error) {
        debugPrint('[analytics] reset failed: ${error.runtimeType}');
      }
    }
  }

  Future<void> setPlan(bool pro) =>
      _updateContext('plan', pro ? 'pro' : 'free');

  Future<void> setLocale(String locale) =>
      _updateContext('locale', locale.trim().isEmpty ? 'und' : locale.trim());

  Future<void> track(
    String eventName, {
    Map<String, Object?> properties = const {},
  }) async {
    if (!collectionEnabled.value) return;
    if (!ProductEvent.allowed.contains(eventName)) {
      debugPrint('[analytics] rejected unknown event: $eventName');
      return;
    }
    final safe = <String, Object>{};
    for (final entry in properties.entries) {
      final value = _safeProperty(entry.key, entry.value);
      if (value != null) safe[entry.key] = value;
    }
    final payload = <String, Object>{..._context, ...safe};
    for (final sink in _sinks) {
      try {
        await sink.track(eventName, payload);
      } catch (error) {
        debugPrint('[analytics] event delivery failed: ${error.runtimeType}');
      }
    }
  }

  Widget wrapSessionReplay(Widget app) =>
      ClarityService.instance.wrap(app, collectionEnabled: collectionEnabled);

  Future<void> _updateContext(String key, Object value) async {
    _context[key] = value;
    for (final sink in _sinks) {
      try {
        await sink.setContext(_context);
      } catch (error) {
        debugPrint('[analytics] context update failed: ${error.runtimeType}');
      }
    }
  }

  static Object? _safeProperty(String key, Object? value) {
    if (key == 'candidate' && value is int && value >= 1 && value <= 10) {
      return value;
    }
    if (value is! String) return null;
    final allowed = _allowedStringValues[key];
    return allowed != null && allowed.contains(value) ? value : null;
  }

  static bool _looksOpaque(String value) {
    if (value.contains('@') || value.contains(' ')) return false;
    return RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(value);
  }

  static String _platformName() {
    if (kIsWeb) return 'web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }
}

class ClarityProductAnalyticsSink implements ProductAnalyticsSink {
  @override
  Future<void> initialize() async {}

  @override
  Future<void> reset() async => ClarityService.instance.startNewSession();

  @override
  Future<void> setCollectionEnabled(bool enabled) async =>
      ClarityService.instance.setCollectionEnabled(enabled);

  @override
  Future<void> setContext(Map<String, Object> context) async {
    for (final entry in context.entries) {
      ClarityService.instance.tag(entry.key, entry.value.toString());
    }
  }

  @override
  Future<void> setUserId(String? opaqueUserId) async {
    if (opaqueUserId == null) {
      ClarityService.instance.startNewSession();
    } else {
      ClarityService.instance.setUserId(opaqueUserId);
    }
  }

  @override
  Future<void> track(String eventName, Map<String, Object> properties) async {
    for (final entry in properties.entries) {
      ClarityService.instance.tag(entry.key, entry.value.toString());
    }
    ClarityService.instance.event(eventName);
  }
}
