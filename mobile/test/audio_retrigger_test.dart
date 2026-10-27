import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/audio/melty_synth_backend.dart';
import 'package:humming/audio/pcm_output.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a held retrigger survives an earlier grid preview release', () async {
    final binding = TestWidgetsFlutterBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final messenger = binding.defaultBinaryMessenger;
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final name = utf8.decode(message!.buffer.asUint8List());
      final file = File(name);
      return file.existsSync()
          ? ByteData.sublistView(await file.readAsBytes())
          : null;
    });
    final blocks = <double>[];
    var feeding = false;
    messenger.setMockMethodCallHandler(
      const MethodChannel('humtrack/desktop_pcm'),
      (call) async {
        if (call.method == 'remainingFrames') return feeding ? 1024 : 2048;
        if (call.method == 'feed') {
          final bytes = ByteData.sublistView(call.arguments as Uint8List);
          var power = 0.0;
          for (var i = 0; i < bytes.lengthInBytes; i += 2) {
            final v = bytes.getInt16(i, Endian.little) / 32768;
            power += v * v;
          }
          blocks.add(math.sqrt(power / (bytes.lengthInBytes / 2)));
        }
        return null;
      },
    );
    final engine = MeltyEngine();
    try {
      await engine.ensureLoaded();
      feeding = true;
      await engine.playNote(
        channel: 0,
        pitch: 60,
        program: 80,
        release: const Duration(milliseconds: 100),
      );
      await Future<void>.delayed(const Duration(milliseconds: 40));
      await engine.noteOn(channel: 0, pitch: 60, program: 80);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(blocks.length, greaterThan(20));
      final held = blocks.skip(blocks.length - 10).reduce((a, b) => a + b) / 10;
      expect(
        held,
        greaterThan(.01),
        reason:
            'The replacement held note must remain audible past the old release',
      );
      await engine.stopAll();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final stopped =
          blocks.skip(blocks.length - 8).reduce((a, b) => a + b) / 8;
      expect(stopped, lessThan(held * .2));
    } finally {
      await engine.stopAll();
      PcmOutput.setFeedCallback(null);
      await PcmOutput.release();
      messenger.setMockMessageHandler('flutter/assets', null);
    }
  }, skip: !Platform.isWindows);
}
