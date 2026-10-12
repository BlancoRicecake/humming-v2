// 서드파티 라이선스 고지(FluidSynth와 LGPL/Apache/BSD/MIT 의존 라이브러리, CC-BY 사운드폰트)가 라이선스 화면에 등록되는지 확인하는 테스트
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/services/third_party_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<LicenseEntry> entries;

  setUpAll(() async {
    registerThirdPartyLicenses();
    entries = await LicenseRegistry.licenses.toList();
  });

  String textOf(String package) => entries
      .where((e) => e.packages.contains(package))
      .expand((e) => e.paragraphs)
      .map((p) => p.text)
      .join('\n');

  test('registers FluidSynth LGPL text and CC-BY soundfont credit', () {
    final fluid = textOf('FluidSynth');
    expect(fluid, contains('FluidSynth 2.4.8'));
    expect(fluid, contains('GNU Lesser General Public License'));
    expect(fluid, contains('https://github.com/FluidSynth/fluidsynth'));
    expect(fluid, contains('GNU LESSER GENERAL PUBLIC LICENSE')); // 전문(asset)
    expect(textOf('Avicii Pluck (SoundFont)'), contains('CC BY 3.0'));
  });

  test('registers LGPL dependencies with version, source and full text', () {
    const expected = {
      'GLib': ('GLib 2.72.4', 'https://gitlab.gnome.org/GNOME/glib'),
      'libsndfile': (
        'libsndfile 1.2.2',
        'https://github.com/libsndfile/libsndfile',
      ),
      'libinstpatch': (
        'libinstpatch 1.1.6',
        'https://github.com/swami/libinstpatch',
      ),
    };
    for (final MapEntry(key: package, value: (version, source))
        in expected.entries) {
      final text = textOf(package);
      expect(text, contains(version), reason: package);
      expect(text, contains(source), reason: package);
      expect(text, contains('separate shared'), reason: package);
      expect(
        text,
        contains('GNU LESSER GENERAL PUBLIC LICENSE'),
        reason: package,
      );
    }
  });

  test('registers BSD/MIT dependencies with source and full text', () {
    // 패키지명: (고지문 문구, 소스 위치, 원문(asset)에만 있는 문구)
    const expected = {
      'FLAC': (
        'FLAC 1.4.3',
        'https://github.com/xiph/flac',
        'Xiph.Org Foundation',
      ),
      'libogg': (
        'libogg 1.3.5',
        'https://github.com/xiph/ogg',
        'Xiph.org Foundation',
      ),
      'libvorbis': (
        'libvorbis 1.3.7',
        'https://github.com/xiph/vorbis',
        'Xiph.org Foundation',
      ),
      'Opus': ('libopus', 'https://github.com/xiph/opus', 'Skype Limited'),
      'PCRE': ('PCRE 8.45', 'https://www.pcre.org', 'University of Cambridge'),
      'libffi': (
        'libffi 3.4.4',
        'https://github.com/libffi/libffi',
        'Permission is hereby granted',
      ),
    };
    for (final MapEntry(key: package, value: (notice, source, licenseText))
        in expected.entries) {
      final text = textOf(package);
      expect(text, contains(notice), reason: package);
      expect(text, contains(source), reason: package);
      expect(text, contains(licenseText), reason: package);
    }
  });

  test('registers Oboe with Apache 2.0 full text', () {
    final oboe = textOf('Oboe');
    expect(oboe, contains('Oboe 1.9.0'));
    expect(oboe, contains('https://github.com/google/oboe'));
    expect(oboe, contains('Apache License'));
    expect(oboe, contains('TERMS AND CONDITIONS FOR USE')); // 전문(asset)
  });
}
