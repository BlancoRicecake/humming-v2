import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:humming/audio/pcm_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('humtrack/desktop_pcm');
  testWidgets('Windows refill stops after release and sends PCM bytes', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    var callbacks = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'remainingFrames' ? 512 : null;
        });
    PcmOutput.setFeedCallback((_) => callbacks++);
    await PcmOutput.setFeedThreshold(1024);
    await PcmOutput.setup(sampleRate: 44100, channelCount: 1);
    await tester.pump(const Duration(milliseconds: 11));
    expect(callbacks, 1);
    await PcmOutput.feed(PcmArrayInt16.fromList([100, -100]));
    final bytes = calls.last.arguments as Uint8List;
    expect(bytes, [100, 0, 156, 255]);
    await PcmOutput.release();
    await tester.pump(const Duration(milliseconds: 50));
    expect(callbacks, 1);
    PcmOutput.setFeedCallback(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isWindows);

  testWidgets('late old-device reply cannot refill released device', (
    tester,
  ) async {
    final pending = Completer<int>();
    var callbacks = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'remainingFrames') return pending.future;
          return null;
        });
    PcmOutput.setFeedCallback((_) => callbacks++);
    await PcmOutput.setup(sampleRate: 44100, channelCount: 1);
    await tester.pump(const Duration(milliseconds: 11));
    await PcmOutput.release();
    pending.complete(0);
    await tester.pump();
    expect(callbacks, 0);
    PcmOutput.setFeedCallback(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }, skip: !Platform.isWindows);
}
