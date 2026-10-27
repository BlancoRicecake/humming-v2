// Explicit Windows verification entry; the product always uses lib/main.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/audio/vocal_fx_processor.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/vocal_fx_catalog.dart';
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
  const output = String.fromEnvironment('VOCAL_LIBRARY_OUTPUT');
  if (output.isEmpty || !Platform.isWindows) {
    throw StateError('Explicit Windows path required');
  }
  final dir = await Directory(output).create(recursive: true);
  final report = <String, dynamic>{'passed': false};
  final errors = <String>[];
  FlutterError.onError = (details) => errors.add(details.exceptionAsString());
  try {
    LoopStorage.rootOverride = Directory('${dir.path}/sandbox');
    await LoopStorage.ensureDirs();
    final source = encodeWavMono16(
      Float32List.fromList(
        List.generate(
          44100,
          (i) =>
              .4 * math.sin(2 * math.pi * 225 * i / 44100) +
              .06 * math.sin(2 * math.pi * 6700 * i / 44100),
        ),
      ),
      44100,
    );
    await File(
      LoopStorage.resolveVocal('library-source.wav'),
    ).writeAsBytes(source);
    final navigator = GlobalKey<NavigatorState>();
    runApp(
      MaterialApp(
        navigatorKey: navigator,
        locale: const Locale('ko'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        theme: ThemeData.dark(useMaterial3: true),
        home: const Scaffold(),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 1));
    final boundary = GlobalKey();
    Future<VocalEditorResult?> open(TrackData track) =>
        navigator.currentState!.push(
          MaterialPageRoute<VocalEditorResult>(
            builder:
                (_) => RepaintBoundary(
                  key: boundary,
                  child: VocalEditorScreen(
                    autoPreview: false,
                    vocal: track,
                    bpm: 120,
                    bars: 2,
                    songId: 'library',
                    sectionId: 'a',
                    keyRoot: 'C',
                    scale: 'major',
                    swing: 0,
                  ),
                ),
          ),
        );
    Future<void> settle() async {
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final done = find<Pill>((w) => w.label == '완료');
        if (done != null && done.onTap != null) return;
      }
      throw StateError('FX processing timeout');
    }

    Future<void> capture(String name, String anchor) async {
      Element? target;
      void visit(Element e) {
        if (e.widget is Text && (e.widget as Text).data == anchor) target ??= e;
        e.visitChildren(visit);
      }

      visit(WidgetsBinding.instance.rootElement!);
      if (target != null) {
        await Scrollable.ensureVisible(target!, alignment: .1);
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${dir.path}/$name').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    }

    final initial = TrackData(
      clips: [VocalClip(path: 'library-source.wav', startStep: 3, gain: .8)],
    );
    var pending = open(initial);
    await Future<void>.delayed(const Duration(seconds: 1));
    await capture('vocal-library.png', '보컬 프리셋');
    find<Pill>((w) => w.label == '전화 속 목소리')!.onTap!();
    await settle();
    find<Pill>((w) => w.label == '완료')!.onTap!();
    final phone = (await pending)!.vocal;
    if (phone.clips!.single.fx.map((f) => f.type).join(',') !=
        'telephone,saturation') {
      throw StateError('Preset chain mismatch');
    }
    if (base64Encode(
          await File(LoopStorage.resolveVocal(phone.vocalPath!)).readAsBytes(),
        ) ==
        base64Encode(source)) {
      throw StateError('Preset audio unchanged');
    }
    pending = open(phone);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    find<Slider>((w) => w.key == const ValueKey('vocal-fx-amount'))!.onChanged!(
      .4,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    find<Pill>((w) => w.label == '로파이')!.onTap!();
    await settle();
    await capture('vocal-library-applied.png', '1. 전화기');
    find<Pill>((w) => w.label == '완료')!.onTap!();
    final edited = (await pending)!.vocal;
    if (edited.clips!.single.fx.last.params['mix'] != .4) {
      throw StateError('Amount not retained');
    }
    final renderer = vocalFxRenderer('library', 'a');
    final clip = edited.clips!.single;
    final reduced = await renderer.render(
      clip,
      clip.fx.sublist(1),
      bpm: 120,
      bars: 2,
    );
    final dry = await renderer.restoreOriginal(reduced, bpm: 120, bars: 2);
    if (dry.path != 'library-source.wav' ||
        dry.fx.isNotEmpty ||
        dry.startStep != 3) {
      throw StateError('Restore failed');
    }
    if (errors.isNotEmpty) throw StateError(errors.join('\n'));
    report.addAll({
      'passed': true,
      'newEffects': localVocalEffects.length,
      'presets': vocalEffectPresets.length,
      'presetActualPcmChanged': true,
      'amountPersisted': true,
      'offlineRemovalAndRestore': true,
      'originalBytesPreserved':
          base64Encode(source) ==
          base64Encode(
            await File(LoopStorage.resolveVocal(dry.path)).readAsBytes(),
          ),
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
