import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final sourceAvailable in [true, false]) {
    test(
      'same-sized corrupt cache ${sourceAvailable ? 'is repaired from bundled bytes' : 'is never exposed when repair is unavailable'}',
      () async {
        final dir = await Directory.systemTemp.createTemp('sf_integrity_');
        addTearDown(() => dir.delete(recursive: true));
        final good = Uint8List.fromList([82, 73, 70, 70, 1, 2, 3, 4]);
        final cache = File('${dir.path}/qa_font.sf2');
        await cache.writeAsBytes(List.filled(good.length, 9));
        await File('${dir.path}/catalog.json').writeAsString(
          jsonEncode([
            {
              'id': 'qa_font',
              'slot': 1990,
              'label': 'QA',
              'role': 'melody',
              'bytes': good.length,
              'sha256': sha256.convert(good).toString(),
              'asset': 'qa/font.sf2',
            },
          ]),
        );
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMessageHandler('flutter/assets', (message) {
          final name = utf8.decode(
            message!.buffer.asUint8List(
              message.offsetInBytes,
              message.lengthInBytes,
            ),
          );
          if (name == 'qa/font.sf2' && sourceAvailable) {
            return SynchronousFuture(ByteData.sublistView(good));
          }
          return SynchronousFuture(null);
        });
        addTearDown(
          () => messenger.setMockMessageHandler('flutter/assets', null),
        );
        final catalog = SoundfontCatalog.forTesting()..debugSetDirectory(dir);
        await catalog.warm();
        final result = await catalog.ensureDownloaded(1990);
        if (sourceAvailable) {
          expect(result, cache.path);
          expect(await cache.readAsBytes(), good);
          // Repeat after installation to cover the validated-cache path too.
          expect(await catalog.ensureDownloaded(1990), cache.path);
        } else {
          expect(result, isNull);
          expect(catalog.localPath(1990), isNull);
        }
        expect(catalog.downloadProgress.value, isEmpty);
      },
    );
  }
}
