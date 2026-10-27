import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/audio/loop_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'vocal seeks use phrase time; Stop cancels a source still loading',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      const codec = StandardMethodCodec();
      Completer<void>? blocked, entered;
      for (final channel in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
      }
      messenger.setMockMethodCallHandler(
        const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
          calls.add(call);
          final args = call.arguments as Map;
          final id = args['playerId'];
          if (call.method == 'create') {
            messenger.setMockMethodCallHandler(
              MethodChannel('xyz.luan/audioplayers/events/$id'),
              (_) async => null,
            );
          }
          if (call.method == 'setSourceUrl') {
            entered?.complete();
            await blocked?.future;
            ServicesBinding.instance.channelBuffers.push(
              'xyz.luan/audioplayers/events/$id',
              codec.encodeSuccessEnvelope({
                'event': 'audio.onPrepared',
                'value': true,
              }),
              (_) {},
            );
          }
          if (call.method == 'seek') {
            ServicesBinding.instance.channelBuffers.push(
              'xyz.luan/audioplayers/events/$id',
              codec.encodeSuccessEnvelope({'event': 'audio.onSeekComplete'}),
              (_) {},
            );
          }
          if (call.method == 'getCurrentPosition') return 0;
          return null;
        },
      );
      final dir = await Directory.systemTemp.createTemp(
        'humtrack_audition_audio_',
      );
      try {
        final file = File('${dir.path}/take.wav');
        await file.writeAsBytes([0, 1, 2, 3]);
        final audio = LoopAudio.instance;
        await audio.playVocal(file.path, position: const Duration(seconds: 4));
        expect(
          (calls.lastWhere((c) => c.method == 'seek').arguments
              as Map)['position'],
          4000,
        );
        await audio.seekVocal(const Duration(seconds: 2));
        expect(
          (calls.lastWhere((c) => c.method == 'seek').arguments
              as Map)['position'],
          2000,
        );
        await audio.stopVocal();
        calls.clear();
        blocked = Completer<void>();
        entered = Completer<void>();
        final pending = audio.playVocal(
          file.path,
          position: const Duration(seconds: 6),
        );
        await entered.future;
        final stopped = audio.stopVocal();
        blocked.complete();
        await pending;
        await stopped;
        expect(
          calls.where((c) => c.method == 'resume'),
          isEmpty,
          reason: 'An obsolete file load must not resume audio after Stop',
        );
        expect(
          calls.where((c) => c.method != 'getCurrentPosition').last.method,
          'stop',
        );
      } finally {
        final resolved = await dir.resolveSymbolicLinks();
        final temp = await Directory.systemTemp.resolveSymbolicLinks();
        if (!resolved.startsWith(
          '$temp${Platform.pathSeparator}humtrack_audition_audio_',
        )) {
          throw StateError('Unexpected test cleanup path');
        }
        await dir.delete(recursive: true);
      }
    },
  );
}
