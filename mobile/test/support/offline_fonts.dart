import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
// Google Fonts exposes this manifest seam specifically for widget tests.
// ignore: implementation_imports
import 'package:google_fonts/src/google_fonts_base.dart' as fonts;

class _FontManifest implements AssetManifest {
  @override
  List<String> listAssets() => [
    for (final family in ['Inter', 'JetBrainsMono'])
      for (final name in [
        'Thin',
        'ExtraLight',
        'Light',
        'Regular',
        'Medium',
        'SemiBold',
        'Bold',
        'ExtraBold',
        'Black',
      ])
        'test_fonts/$family-$name.ttf',
  ];
  @override
  List<AssetMetadata>? getAssetVariants(String key) => null;
}

void useOfflineTestFonts() {
  GoogleFonts.config.allowRuntimeFetching = false;
  fonts.assetManifest = _FontManifest();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) async {
    final key = utf8.decode(
      message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
    );
    // Widget tests use Ahem for layout. No font network or font cache I/O.
    if (key.startsWith('test_fonts/')) return ByteData(0);
    return messenger.delegate.send('flutter/assets', message);
  });
}
