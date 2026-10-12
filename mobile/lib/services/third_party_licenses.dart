// pub 패키지 LICENSE로 자동 노출되지 않는 서드파티 고지를 Flutter 라이선스 화면에 등록한다
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

const _pluginSource =
    'Plugin source used by this app: '
    'https://github.com/hjm181227/flutter_midi_pro';

const _fluidSynthNotice =
    'HumTrack for Android uses FluidSynth 2.4.8 (https://www.fluidsynth.org) '
    'through the flutter_midi_pro plugin to play SoundFont instruments.\n\n'
    'FluidSynth is licensed under the GNU Lesser General Public License, '
    'version 2.1 (full text below). It is included as a separate shared '
    'library that can be replaced with a compatible version.\n\n'
    'FluidSynth source code: https://github.com/FluidSynth/fluidsynth\n'
    '$_pluginSource';

/// FluidSynth와 함께 별도 .so로 들어가는 LGPL 라이브러리. (패키지명, 고지문)
const _lgplDependencyNotices = [
  (
    'GLib',
    'HumTrack for Android uses GLib 2.72.4 (libglib, libgio, libgmodule, '
        'libgobject, libgthread) as a dependency of FluidSynth.\n\n'
        'GLib is licensed under the GNU Lesser General Public License, '
        'version 2.1 (full text below). It is included as separate shared '
        'libraries that can be replaced with compatible versions.\n\n'
        'GLib source code: https://gitlab.gnome.org/GNOME/glib\n'
        '$_pluginSource',
  ),
  (
    'libsndfile',
    'HumTrack for Android uses libsndfile 1.2.2 as a dependency of '
        'FluidSynth.\n\n'
        'libsndfile is licensed under the GNU Lesser General Public License, '
        'version 2.1 (full text below). It is included as a separate shared '
        'library that can be replaced with a compatible version.\n\n'
        'libsndfile source code: https://github.com/libsndfile/libsndfile\n'
        '$_pluginSource',
  ),
  (
    'libinstpatch',
    'HumTrack for Android uses libinstpatch 1.1.6 as a dependency of '
        'FluidSynth.\n\n'
        'libinstpatch is licensed under the GNU Lesser General Public '
        'License, version 2.1 (full text below). It is included as a separate '
        'shared library that can be replaced with a compatible version.\n\n'
        'libinstpatch source code: https://github.com/swami/libinstpatch\n'
        '$_pluginSource',
  ),
];

const _oboeNotice =
    'HumTrack for Android uses Oboe 1.9.0 (https://github.com/google/oboe) '
    'as the audio output library of FluidSynth.\n\n'
    'Copyright (C) 2016 The Android Open Source Project\n\n'
    'Licensed under the Apache License, Version 2.0 (full text below).\n\n'
    '$_pluginSource';

/// FluidSynth가 쓰는 BSD/MIT 라이브러리. (패키지명, 고지문, 라이선스 원문 asset)
const _permissiveDependencyNotices = [
  (
    'FLAC',
    'HumTrack for Android uses FLAC 1.4.3 (libFLAC) as a dependency of '
        'FluidSynth.\n\n'
        'libFLAC is licensed under the BSD 3-Clause License (full text '
        'below).\n\n'
        'FLAC source code: https://github.com/xiph/flac\n'
        '$_pluginSource',
    'assets/legal/FLAC-BSD-3-Clause.txt',
  ),
  (
    'libogg',
    'HumTrack for Android uses libogg 1.3.5 as a dependency of FluidSynth.\n\n'
        'libogg is licensed under the BSD 3-Clause License (full text '
        'below).\n\n'
        'libogg source code: https://github.com/xiph/ogg\n'
        '$_pluginSource',
    'assets/legal/libogg-BSD-3-Clause.txt',
  ),
  (
    'libvorbis',
    'HumTrack for Android uses libvorbis 1.3.7 (libvorbis, libvorbisenc, '
        'libvorbisfile) as a dependency of FluidSynth.\n\n'
        'libvorbis is licensed under the BSD 3-Clause License (full text '
        'below).\n\n'
        'libvorbis source code: https://github.com/xiph/vorbis\n'
        '$_pluginSource',
    'assets/legal/libvorbis-BSD-3-Clause.txt',
  ),
  (
    'Opus',
    'HumTrack for Android uses the Opus codec library (libopus) as a '
        'dependency of FluidSynth.\n\n'
        'libopus is licensed under the BSD 3-Clause License (full text '
        'below).\n\n'
        'Opus source code: https://github.com/xiph/opus\n'
        '$_pluginSource',
    'assets/legal/opus-BSD-3-Clause.txt',
  ),
  (
    'PCRE',
    'HumTrack for Android uses PCRE 8.45 (libpcre, libpcreposix) as a '
        'dependency of GLib.\n\n'
        'PCRE is licensed under the BSD License (full text below).\n\n'
        'PCRE source code: https://www.pcre.org\n'
        '$_pluginSource',
    'assets/legal/PCRE-BSD-3-Clause.txt',
  ),
  (
    'libffi',
    'HumTrack for Android uses libffi 3.4.4, statically linked into GLib '
        '(libgobject).\n\n'
        'libffi is licensed under the MIT License (full text below).\n\n'
        'libffi source code: https://github.com/libffi/libffi\n'
        '$_pluginSource',
    'assets/legal/libffi-MIT.txt',
  ),
];

const _aviciiPluckNotice =
    '"Avicii Pluck (Waiting For Love)" SoundFont by Simone Piervergili, '
    'licensed under CC BY 3.0 '
    '(https://creativecommons.org/licenses/by/3.0/). '
    'Source: https://musical-artifacts.com/artifacts/5632';

/// FluidSynth와 그 LGPL/Apache/BSD/MIT 의존 라이브러리, CC-BY 사운드폰트 고지를 등록한다. 앱 시작 시 한 번 호출.
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(['FluidSynth'], _fluidSynthNotice);
    for (final (package, notice) in _lgplDependencyNotices) {
      yield LicenseEntryWithLineBreaks([package], notice);
    }
    yield LicenseEntryWithLineBreaks(
      ['FluidSynth', for (final (package, _) in _lgplDependencyNotices) package],
      await rootBundle.loadString('assets/legal/LGPL-2.1.txt'),
    );
    yield const LicenseEntryWithLineBreaks(['Oboe'], _oboeNotice);
    yield LicenseEntryWithLineBreaks(
      const ['Oboe'],
      await rootBundle.loadString('assets/legal/Apache-2.0.txt'),
    );
    for (final (package, notice, asset) in _permissiveDependencyNotices) {
      yield LicenseEntryWithLineBreaks([package], notice);
      yield LicenseEntryWithLineBreaks(
        [package],
        await rootBundle.loadString(asset),
      );
    }
    yield const LicenseEntryWithLineBreaks(
      ['Avicii Pluck (SoundFont)'],
      _aviciiPluckNotice,
    );
  });
}
