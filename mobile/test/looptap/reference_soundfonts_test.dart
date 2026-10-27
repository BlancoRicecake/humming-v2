import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_melty_soundfont/dart_melty_soundfont.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'eight bundled sounds (incl. the nylon guitar) install offline, retain metadata and produce audio',
    () async {
      final tmp = await Directory.systemTemp.createTemp(
        'humtrack_reference_fonts_',
      );
      addTearDown(() async => tmp.delete(recursive: true));
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMessageHandler('flutter/assets', (message) {
        final path = utf8.decode(
          message!.buffer.asUint8List(
            message.offsetInBytes,
            message.lengthInBytes,
          ),
        );
        final file = File(path);
        return SynchronousFuture(
          file.existsSync()
              ? ByteData.sublistView(file.readAsBytesSync())
              : null,
        );
      });
      addTearDown(
        () => messenger.setMockMessageHandler('flutter/assets', null),
      );
      // Simulate an old server cache, whose row lacks the offline asset source.
      await File('${tmp.path}/catalog.json').writeAsString(
        jsonEncode([
          {
            'id': 'freepats_bass_lately',
            'slot': 1020,
            'label': 'Old cached bass',
            'role': 'bass',
          },
        ]),
      );
      final catalog = SoundfontCatalog.forTesting()..debugSetDirectory(tmp);
      await catalog.warm();
      expect(catalog.all.length, 8);
      expect(catalog.all.map((e) => e.id).toSet(), {
        'freepats_bass_lately',
        'freepats_bass_synth1',
        'freepats_bass_synth2',
        'freepats_pad_choir',
        'freepats_pad_sweep',
        'freepats_pad_newage',
        'freepats_pad_bowed',
        'freepats_nylon',
      });
      expect(catalog.all.where((e) => e.role == 'bass').length, 3);
      // The first guitar works offline: slot 1001 = FreePats nylon (CC0).
      final nylon = catalog.bySlot(1001)!;
      expect(nylon.id, 'freepats_nylon');
      expect(nylon.category, 'Guitar');
      expect(nylon.assetPath, 'assets/sounds/reference/freepats_nylon.sf2');
      expect(catalog.midiFallback(1001), 24); // GM Nylon Guitar
      for (final e in catalog.all) {
        expect(e.assetPath, startsWith('assets/sounds/reference/'));
        final path = await catalog
            .ensureDownloaded(e.slot)
            .timeout(const Duration(seconds: 5));
        expect(path, isNotNull, reason: e.id);
        final bytes = await File(path!).readAsBytes();
        expect(sha256.convert(bytes).toString(), e.sha256);
        final synth = Synthesizer.loadByteData(
          ByteData.sublistView(bytes),
          SynthesizerSettings(sampleRate: 22050),
        );
        synth.processMidiMessage(
          channel: 0,
          command: 0xb0,
          data1: 0,
          data2: e.sfBank,
        );
        synth.processMidiMessage(
          channel: 0,
          command: 0xc0,
          data1: e.sfProgram,
          data2: 0,
        );
        synth.noteOn(
          channel: 0,
          // guitar: open low E (E2), inside the real 6-string range
          key: e.role == 'bass' || e.category == 'Guitar' ? 40 : 60,
          velocity: 100,
        );
        final left = Float32List(22050), right = Float32List(22050);
        synth.render(left, right);
        final peak = [
          ...left,
          ...right,
        ].fold<double>(0, (p, v) => v.abs() > p ? v.abs() : p);
        expect(peak, greaterThan(.001), reason: '${e.label} rendered silence');
        expect(left.every((v) => v.isFinite), isTrue);
        if (e.category == 'Guitar') {
          // A plucked string decays: the second half of the second must be
          // quieter than the first (a sustained/looped pad would not be).
          double rms(Float32List x, int a, int b) {
            var acc = 0.0;
            for (var i = a; i < b; i++) {
              acc += x[i] * x[i];
            }
            return acc / (b - a);
          }
          expect(
            rms(left, 11025, 22050),
            lessThan(rms(left, 0, 11025)),
            reason: 'nylon guitar should decay like a plucked string',
          );
        }
        debugPrint('rendered ${e.id}: peak=$peak');
      }
      expect(catalog.midiFallback(1032), 88); // GM New Age, zero-based
      expect(catalog.midiFallback(1030), 91); // GM Choir Pad
      expect(catalog.midiFallback(1033), 92); // GM Bowed Pad
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
