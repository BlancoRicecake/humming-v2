// QA-only Windows probe for the hum recording failure (docs/specs/ui/
// qa-handoff-2026-10-30.md, P1-01). Never part of the product build.
//
// The REAL app (app.main()) with every path_provider location redirected into
// a sandbox inside the repo and in-memory shared_preferences. Then, with the
// real `record` / `audioplayers` Windows plugins:
//   1. which encoders `isEncoderSupported` reports (opus / wav / aacLc / flac),
//   2. the exact exception of the old hum start config (Opus into .ogg),
//   3. the codec the product now picks (selectHumRecording) — a 2 s take:
//      start, stop, the file's container header, size and duration,
//   4. that take played back with audioplayers (duration / completion),
//   5. the product's hum modal end to end: count-in, recording, the automatic
//      stop after one loop, and the take handed to onConvert (checked here,
//      never uploaded).
// The take is deleted afterwards; only metadata is written (no audio, no
// tokens). Results: <root>/hum-record-probe.json, then the app exits unless
// QA_WAIT=1.
//
// ignore_for_file: depend_on_referenced_packages, invalid_use_of_visible_for_testing_member
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:humming/audio/container.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/widgets/sheets/hum_modal.dart';
import 'package:humming/main.dart' as app;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _workspace = r'C:\src\humming-v2';
const _root = String.fromEnvironment(
  'QA_ROOT',
  defaultValue: r'C:\src\humming-v2\artifacts\qa-fix-2026-10-30\record-probe',
);

String _inside(String path) {
  final full = p.normalize(p.absolute(path));
  if (!p.isWithin(p.normalize(_workspace), full)) {
    throw StateError('QA path escapes $_workspace: $path -> $full');
  }
  return full;
}

class _QaPathProvider extends PathProviderPlatform {
  _QaPathProvider(this.dirs);
  final Map<String, String> dirs;
  @override
  Future<String?> getApplicationDocumentsPath() async => dirs['documents'];
  @override
  Future<String?> getApplicationSupportPath() async => dirs['support'];
  @override
  Future<String?> getApplicationCachePath() async => dirs['cache'];
  @override
  Future<String?> getTemporaryPath() async => dirs['temp'];
  @override
  Future<String?> getLibraryPath() async => dirs['library'];
  @override
  Future<String?> getDownloadsPath() async => dirs['downloads'];
  @override
  Future<String?> getExternalStoragePath() async => dirs['documents'];
  @override
  Future<List<String>?> getExternalCachePaths() async => [dirs['cache']!];
  @override
  Future<List<String>?> getExternalStoragePaths({StorageDirectory? type}) async => [dirs['documents']!];
}

/// A recorder failure without paths or user data: type, code, message head.
Map<String, Object?> _error(Object e) => {
  'type': e.runtimeType.toString(),
  if (e is PlatformException) 'code': e.code,
  'message': (e is PlatformException ? e.message : e.toString())?.split('\n').first,
};

Future<void> main() async {
  final root = _inside(_root);
  final dirs = {
    for (final name in ['documents', 'support', 'cache', 'temp', 'library', 'downloads'])
      name: _inside(p.join(root, 'data', name)),
  };
  for (final d in dirs.values) {
    await Directory(d).create(recursive: true);
  }
  final sysTemp = p.normalize(p.absolute(Directory.systemTemp.path));
  if (!p.isWithin(p.normalize(_workspace), sysTemp)) {
    throw StateError('Set TMP/TEMP inside $_workspace before launching (currently $sysTemp)');
  }
  PathProviderPlatform.instance = _QaPathProvider(dirs);
  SharedPreferences.setMockInitialValues({});
  LoopStorage.rootOverride = Directory(dirs['documents']!);
  final report = <String, Object?>{
    'mode': kReleaseMode ? 'release' : 'debug',
    'os': Platform.operatingSystemVersion,
  };
  try {
    await app.main();
    await Future<void>.delayed(const Duration(seconds: 1));
    final rec = AudioRecorder();
    report['hasPermission'] = await rec.hasPermission();
    report['isEncoderSupported'] = {
      for (final e in [AudioEncoder.opus, AudioEncoder.wav, AudioEncoder.aacLc, AudioEncoder.flac])
        e.name: await rec.isEncoderSupported(e),
    };

    // 2. the old hum config: Opus into .ogg (opusSupported(null) == true)
    final oldPath = p.join(dirs['temp']!, 'probe_old.ogg');
    try {
      await rec.start(
        const RecordConfig(encoder: AudioEncoder.opus, sampleRate: 16000, numChannels: 1),
        path: oldPath,
      );
      report['oldOpusStart'] = 'started';
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await rec.stop();
    } catch (e) {
      report['oldOpusStart'] = _error(e);
    }
    if (File(oldPath).existsSync()) File(oldPath).deleteSync();

    // 3. what the product picks now
    final pick = selectHumRecording(platform: RecordingPlatform.current(), androidSdkInt: null);
    report['selected'] = {'codec': pick.codec.name, 'ext': pick.extension};
    final path = p.join(dirs['temp']!, 'probe_take${pick.extension}');
    final take = <String, Object?>{};
    report['take'] = take;
    try {
      await rec.start(
        RecordConfig(encoder: pick.encoder, sampleRate: 16000, numChannels: 1),
        path: path,
      );
      take['started'] = true;
      await Future<void>.delayed(const Duration(seconds: 2));
      final stopped = await rec.stop();
      take['stopped'] = stopped != null;
      final f = File(stopped ?? path);
      final bytes = f.existsSync() ? f.readAsBytesSync() : Uint8List(0);
      take['bytes'] = bytes.length;
      String tag(int at) => bytes.length >= at + 4 ? String.fromCharCodes(bytes.sublist(at, at + 4)) : '';
      take['header'] = '${tag(0)}/${tag(8)}'; // RIFF/WAVE for a WAV take
      if (tag(0) == 'RIFF' && bytes.length >= 44) {
        final b = ByteData.sublistView(bytes);
        final rate = b.getUint32(24, Endian.little);
        final blockAlign = b.getUint16(32, Endian.little);
        final dataLen = bytes.length - 44;
        take['sampleRate'] = rate;
        take['channels'] = b.getUint16(22, Endian.little);
        take['seconds'] = blockAlign == 0 ? null : dataLen / blockAlign / rate;
      }

      // 4. play it back
      final player = AudioPlayer();
      final done = Completer<void>();
      final sub = player.onPlayerComplete.listen((_) {
        if (!done.isCompleted) done.complete();
      });
      try {
        await player.play(DeviceFileSource(f.path));
        final d = await player.getDuration();
        take['playDurationMs'] = d?.inMilliseconds;
        await done.future.timeout(const Duration(seconds: 6));
        take['playCompleted'] = true;
      } catch (e) {
        take['play'] = _error(e);
      } finally {
        await sub.cancel();
        await player.dispose();
      }
      if (f.existsSync()) f.deleteSync(); // no audio kept
      take['deleted'] = !f.existsSync();
    } catch (e) {
      take['error'] = _error(e);
    }
    await rec.dispose();

    // 5. the hum modal itself (no upload: onConvert only inspects the take)
    final modal = <String, Object?>{};
    report['modal'] = modal;
    NavigatorState? nav;
    void visit(Element e) {
      if (e is StatefulElement && e.state is NavigatorState) nav ??= e.state as NavigatorState;
      e.visitChildren(visit);
    }

    visit(WidgetsBinding.instance.rootElement!);
    final converted = Completer<String>();
    final ctx = nav!.context;
    // ignore: use_build_context_synchronously
    unawaited(
      showHumModal(
        ctx,
        trackLabel: 'Melody',
        accent: const Color(0xFFB8F34A),
        onConvert: (path) async {
          if (!converted.isCompleted) converted.complete(path);
        },
        bpm: 120,
        bars: 1,
        countInBeats: 2,
      ),
    );
    try {
      final path = await converted.future.timeout(const Duration(seconds: 15));
      final f = File(path);
      final bytes = f.existsSync() ? f.readAsBytesSync() : Uint8List(0);
      modal['ext'] = p.extension(path);
      modal['bytes'] = bytes.length;
      modal['header'] = bytes.length >= 12
          ? '${String.fromCharCodes(bytes.sublist(0, 4))}/${String.fromCharCodes(bytes.sublist(8, 12))}'
          : '';
      if (bytes.length >= 44) {
        final b = ByteData.sublistView(bytes);
        final rate = b.getUint32(24, Endian.little);
        final blockAlign = b.getUint16(32, Endian.little);
        modal['seconds'] = blockAlign == 0 ? null : (bytes.length - 44) / blockAlign / rate;
      }
      final player = AudioPlayer();
      try {
        await player.setSource(DeviceFileSource(path));
        modal['playDurationMs'] = (await player.getDuration())?.inMilliseconds;
      } catch (e) {
        modal['play'] = _error(e);
      } finally {
        await player.dispose();
      }
      if (f.existsSync()) f.deleteSync(); // no audio kept
      modal['deleted'] = !f.existsSync();
    } catch (e) {
      modal['error'] = _error(e);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    nav!.popUntil((r) => r.isFirst);
  } catch (e, s) {
    report['error'] = e.toString();
    report['stack'] = s.toString().split('\n').take(8).join('\n');
  }
  await File(p.join(root, 'hum-record-probe.json')).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  debugPrint('[qa-probe] done');
  if (Platform.environment['QA_WAIT'] == '1') return;
  exit(0);
}
