// Explicit native verification entry. Uses real local audio and player output.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/audio/vocal_fx_processor.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/vocal_fx_catalog.dart';
import 'package:humming/looptap/music/vocal_comparison.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/theme/atoms.dart';
import 'package:humming/looptap/widgets/sheets/vocal_editor.dart';

T? find<T extends Widget>(bool Function(T) match) {
  T? result;
  void visit(Element e) {
    if (e.widget is T && match(e.widget as T)) result ??= e.widget as T;
    e.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return result;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const output = String.fromEnvironment('COMPARISON_OUTPUT');
  const sourcePath = String.fromEnvironment('VOCAL_SAMPLE');
  if (output.isEmpty || sourcePath.isEmpty) {
    throw StateError('Explicit paths required');
  }
  final dir = await Directory(output).create(recursive: true);
  final report = <String, dynamic>{'passed': false};
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  try {
    LoopStorage.rootOverride = Directory('${dir.path}/sandbox');
    await LoopStorage.ensureDirs();
    final originalBytes = await File(sourcePath).readAsBytes();
    await File(
      LoopStorage.resolveVocal('original.wav'),
    ).writeAsBytes(originalBytes);
    final dry = VocalClip(path: 'original.wav');
    final wet = await vocalFxRenderer('compare', 'A').render(
      dry,
      vocalEffectPresets.firstWhere((p) => p.id == 'robot').nodes(),
      bpm: 80,
      bars: 2,
    );
    final wetBytes =
        await File(LoopStorage.resolveVocal(wet.path)).readAsBytes();
    final comparison = vocalComparison(
      [wet],
      {dry.path: parseWav(originalBytes)!, wet.path: parseWav(wetBytes)!},
      bars: 2,
      bpm: 80,
    );
    await File(
      '${dir.path}/original.wav',
    ).writeAsBytes(encodeWavMono16(comparison.original, 44100));
    await File(
      '${dir.path}/robot.wav',
    ).writeAsBytes(encodeWavMono16(comparison.processed, 44100));
    var sum = 0.0;
    for (var i = 0; i < comparison.original.length; i++) {
      final d = comparison.processed[i] - comparison.original[i];
      sum += d * d;
    }
    report['levelMatchedDifferenceRms'] = math.sqrt(
      sum / comparison.original.length,
    );
    final capture = GlobalKey();
    runApp(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        theme: ThemeData.dark(useMaterial3: true),
        home: RepaintBoundary(
          key: capture,
          child: VocalEditorScreen(
            autoPreview: false,
            vocal: TrackData(clips: [wet]),
            bpm: 80,
            bars: 2,
            songId: 'compare',
            sectionId: 'A',
            keyRoot: 'C',
            scale: 'major',
            swing: 0,
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    Future<void> play(String key, String status) async {
      find<Pill>((w) => w.key == ValueKey(key))!.onTap!();
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (find<Text>(
              (w) => w.key == const ValueKey('vocal-preview-status'),
            )?.data ==
            status) {
          return;
        }
      }
      throw StateError('Preview never reached $status');
    }

    await play('vocal-preview-processed', '효과음 재생 중');
    await Future<void>.delayed(const Duration(milliseconds: 650));
    final before = await LoopAudio.instance.vocalPosition();
    if (before == null || before.inMilliseconds < 300) {
      throw StateError('Player position did not advance');
    }
    await play('vocal-preview-original', '원음 재생 중');
    final after = await LoopAudio.instance.vocalPosition();
    if (after == null ||
        (after.inMilliseconds - before.inMilliseconds).abs() > 1000) {
      throw StateError('Comparison did not retain phrase position');
    }
    await play('vocal-preview-processed', '효과음 재생 중');
    final image =
        await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '${dir.path}/comparison.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
    report.addAll({
      'passed': true,
      'actualPlayerAdvanced': true,
      'beforeSwitchMs': before.inMilliseconds,
      'afterSwitchMs': after.inMilliseconds,
      'originalAndProcessedSwitched': true,
      'flutterErrors': errors,
    });
  } catch (e, stack) {
    report['error'] = e.toString();
    report['stack'] = stack.toString();
  }
  await LoopAudio.instance.stopVocal();
  await File(
    '${dir.path}/native-verification.json',
  ).writeAsString(jsonEncode(report));
  exit(report['passed'] == true ? 0 : 1);
}
