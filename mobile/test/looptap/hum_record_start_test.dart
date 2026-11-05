// QA 2026-10-30 P1-01: the hum modal starts the recorder with the codec the
// platform supports (Windows: WAV — record_windows 1.0.7 has no Opus output),
// falls back to WAV when the plugin rejects the chosen encoder, says "no
// format" when nothing fits, and logs only platform / codec / error code.
//
// ignore_for_file: depend_on_referenced_packages
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/audio/container.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/widgets/sheets/hum_modal.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:record/record.dart';
import 'package:record_platform_interface/record_platform_interface.dart';

import '../support/offline_fonts.dart';

class _FakeRecord extends RecordPlatform with MockPlatformInterfaceMixin {
  _FakeRecord(this.supported);
  final Set<AudioEncoder> supported;
  final List<AudioEncoder> asked = [];
  RecordConfig? started;
  String? path;
  Object? startError;

  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async => true;
  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) async {
    asked.add(encoder);
    return supported.contains(encoder);
  }

  @override
  Future<void> start(String recorderId, RecordConfig config, {required String path}) async {
    if (startError != null) throw startError!;
    started = config;
    this.path = path;
  }

  @override
  Future<String?> stop(String recorderId) async => path;
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  Future<bool> isRecording(String recorderId) async => started != null;
  @override
  Future<Amplitude> getAmplitude(String recorderId) async => Amplitude(current: -40, max: -40);
  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

void main() {
  late Directory temp;
  late RecordPlatform realRecord;
  late PathProviderPlatform realPaths;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('humtrack_hum_start_');
    realRecord = RecordPlatform.instance;
    realPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(temp.path);
  });

  // the editor's audio-session channel (sample rate / headset route): no
  // answer in a widget test = a never-completing call; the desktop answer is
  // "nothing to report"
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('humming/audio'),
      (call) async => null,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('humming/audio'),
      null,
    );
  });
  tearDown(() async {
    RecordPlatform.instance = realRecord;
    PathProviderPlatform.instance = realPaths;
    await temp.delete(recursive: true);
  });

  /// Opens the hum modal (1-beat count-in) and runs it to the recorder start.
  Future<void> openAndCount(WidgetTester tester) async {
    useOfflineTestFonts();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Builder(
          builder:
              (context) => Scaffold(
                body: TextButton(
                  onPressed:
                      () => showHumModal(
                        context,
                        trackLabel: 'Melody',
                        accent: Colors.green,
                        onConvert: (_) async {},
                        bpm: 120,
                        bars: 1,
                        countInBeats: 1,
                      ),
                  child: const Text('hum'),
                ),
              ),
        ),
      ),
    );
    await tester.tap(find.text('hum'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1)); // the count-in beat
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> close(WidgetTester tester) async {
    Navigator.of(tester.element(find.byWidgetPredicate((w) => w.runtimeType.toString() == '_HumModal'))).pop();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    // the modal's recorder teardown holds record's global semaphore until its
    // real async work (file cleanup) ends: let it finish before the next test
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  testWidgets('starts with the platform choice: codec and extension together (Windows: WAV)', (tester) async {
    final fake = _FakeRecord({AudioEncoder.wav, AudioEncoder.aacLc, AudioEncoder.flac, AudioEncoder.opus});
    RecordPlatform.instance = fake;
    await openAndCount(tester);
    final expected = selectHumRecording(platform: RecordingPlatform.current());
    expect(fake.started, isNotNull, reason: 'the recorder started');
    expect(fake.started!.encoder, expected.encoder);
    expect(fake.path, endsWith(expected.extension));
    if (Platform.isWindows) {
      expect(fake.started!.encoder, AudioEncoder.wav);
      expect(fake.asked, isNot(contains(AudioEncoder.opus)), reason: 'Opus is never requested on Windows');
    }
    await close(tester);
  });

  testWidgets('an encoder the plugin rejects falls back to WAV (.wav)', (tester) async {
    final expected = selectHumRecording(platform: RecordingPlatform.current());
    final fake = _FakeRecord({AudioEncoder.wav});
    RecordPlatform.instance = fake;
    await openAndCount(tester);
    expect(fake.asked.first, expected.encoder, reason: 'the platform choice is asked first');
    expect(fake.started?.encoder, AudioEncoder.wav);
    expect(fake.path, endsWith('.wav'));
    await close(tester);
  });

  testWidgets('no usable encoder at all: a clear "no format" message, start() never called', (tester) async {
    final none = _FakeRecord({});
    RecordPlatform.instance = none;
    await openAndCount(tester);
    expect(none.started, isNull);
    expect(find.text('This device has no recording format the app can use'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a start() failure: "unavailable" + a diagnostic line without paths', (tester) async {
    final fake = _FakeRecord({AudioEncoder.wav, AudioEncoder.opus})
      ..startError = PlatformException(code: 'Record', message: 'boom at C:\\Users\\someone\\x.wav');
    RecordPlatform.instance = fake;
    final logs = <String>[];
    final print = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
    try {
      await openAndCount(tester);
    } finally {
      debugPrint = print;
    }
    expect(find.text('Recording unavailable'), findsOneWidget);
    final line = logs.firstWhere((l) => l.contains('rec start failed'));
    expect(line, contains('platform=${RecordingPlatform.current().name}'));
    expect(line, contains('code=Record'));
    expect(line, isNot(contains('Users')), reason: 'no paths / user data');
    await close(tester);
  });
}
