import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'product_analytics.dart';

/// Firebase is deliberately configured through release dart-defines so a
/// checkout without console credentials remains buildable. Windows/macOS use
/// this same class as a safe no-op because the first rollout targets mobile.
class FirebaseProductAnalyticsSink implements ProductAnalyticsSink {
  static const _requested = bool.fromEnvironment('FIREBASE_ANALYTICS_ENABLED');
  static const _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const _senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const _measurementId = String.fromEnvironment(
    'FIREBASE_MEASUREMENT_ID',
  );
  static const _androidAppId = String.fromEnvironment(
    'FIREBASE_ANDROID_APP_ID',
  );
  static const _androidApiKey = String.fromEnvironment(
    'FIREBASE_ANDROID_API_KEY',
  );
  static const _iosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const _iosApiKey = String.fromEnvironment('FIREBASE_IOS_API_KEY');

  FirebaseAnalytics? _analytics;
  bool _consent = true;
  bool _initializeRequested = false;
  Map<String, Object> _context = const {};

  bool get _mobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  String get _appId =>
      defaultTargetPlatform == TargetPlatform.iOS ? _iosAppId : _androidAppId;
  String get _apiKey =>
      defaultTargetPlatform == TargetPlatform.iOS ? _iosApiKey : _androidApiKey;

  bool get _configured =>
      _requested &&
      _mobile &&
      _projectId.isNotEmpty &&
      _senderId.isNotEmpty &&
      _appId.isNotEmpty &&
      _apiKey.isNotEmpty;

  @override
  Future<void> initialize() async {
    _initializeRequested = true;
    if (!_consent) return;
    await _initializeFirebase();
  }

  Future<void> _initializeFirebase() async {
    if (_analytics != null) return;
    if (!_configured) {
      debugPrint(
        '[analytics] Firebase sink disabled (configuration absent or unsupported platform)',
      );
      return;
    }
    try {
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
          measurementId: _measurementId.isEmpty ? null : _measurementId,
          iosBundleId:
              defaultTargetPlatform == TargetPlatform.iOS
                  ? 'com.humtrack.app'
                  : null,
        ),
      );
      _analytics = FirebaseAnalytics.instance;
      await _analytics!.setAnalyticsCollectionEnabled(_consent);
      await _applyContext();
      debugPrint('[analytics] Firebase sink enabled');
    } catch (error) {
      _analytics = null;
      debugPrint(
        '[analytics] Firebase initialization failed: ${error.runtimeType}',
      );
    }
  }

  @override
  Future<void> setCollectionEnabled(bool enabled) async {
    _consent = enabled;
    if (enabled && _analytics == null && _initializeRequested) {
      await _initializeFirebase();
    }
    await _analytics?.setAnalyticsCollectionEnabled(enabled);
  }

  @override
  Future<void> setUserId(String? opaqueUserId) async =>
      _analytics?.setUserId(id: opaqueUserId);

  @override
  Future<void> setContext(Map<String, Object> context) async {
    _context = Map.of(context);
    await _applyContext();
  }

  Future<void> _applyContext() async {
    final analytics = _analytics;
    if (analytics == null) return;
    await analytics.setUserProperty(
      name: 'environment',
      value: _context['environment']?.toString(),
    );
    await analytics.setUserProperty(
      name: 'plan',
      value: _context['plan']?.toString(),
    );
  }

  @override
  Future<void> track(String eventName, Map<String, Object> properties) async {
    final analytics = _analytics;
    if (analytics == null || !_consent) return;
    const automatic = <String>{
      'app_id',
      'platform',
      'app_version',
      'build_number',
      'locale',
    };
    final parameters = <String, Object>{};
    for (final entry in properties.entries) {
      if (automatic.contains(entry.key)) continue;
      parameters[entry.key] =
          entry.value is bool ? ((entry.value as bool) ? 1 : 0) : entry.value;
    }
    await analytics.logEvent(name: eventName, parameters: parameters);
  }

  @override
  Future<void> reset() async => _analytics?.setUserId(id: null);
}
