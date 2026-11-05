// Interactive launcher for the current product, using a separate local library.
// No mock processing, automatic playback, or automatic exit.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:provider/provider.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/audio/vocal_fx_processor.dart';
import 'package:humming/looptap/music/vocal_fx_catalog.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/sheets/vocal_editor.dart';

Future<void> main() async {
  const session = String.fromEnvironment('VOCAL_TRY_SESSION');
  const sample = String.fromEnvironment('VOCAL_TRY_SAMPLE');
  if (session.isEmpty || sample.isEmpty || !Platform.isWindows) {
    throw StateError('Explicit Windows vocal session paths required');
  }
  final directory = await Directory(session).create(recursive: true);
  LoopStorage.rootOverride = directory;
  await LoopStorage.ensureDirs();
  await app.main();
  NavigatorState? navigator;
  void visit(Element e) {
    if (e is StatefulElement && e.state is NavigatorState) {
      navigator ??= e.state as NavigatorState;
    }
    e.visitChildren(visit);
  }

  for (var i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final root = WidgetsBinding.instance.rootElement;
    if (root != null) visit(root);
    if (navigator != null) break;
  }
  if (navigator == null) throw StateError('HumTrack navigator unavailable');
  final store = Provider.of<LoopStore>(navigator!.context, listen: false);
  for (var i = 0; i < 100 && !store.loaded; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (!store.loaded) throw StateError('Sample library did not load');
  const id = 'vocal_effect_try_20261021';
  final existing = store.songs.where((s) => s.id == id).toList();
  late Song song;
  if (existing.isNotEmpty) {
    song = existing.first;
  } else {
    final bytes = await File(sample).readAsBytes();
    final wav = parseWav(bytes);
    if (wav == null || wav.samples.isEmpty) {
      throw const FormatException('Vocal sample must be PCM16 WAV');
    }
    final filename = await LoopStorage.saveVocalBytes(bytes, id, 'A');
    if (filename == null) throw const FileSystemException('Sample save failed');
    var clip = VocalClip(path: filename, peaks: peaksFromPcm(wav.samples));
    if (const bool.fromEnvironment('VOCAL_TRY_ROBOT')) {
      clip = await vocalFxRenderer(id, 'A').render(
        clip,
        vocalEffectPresets.firstWhere((p) => p.id == 'robot').nodes(),
        bpm: 80,
        bars: 2,
      );
    }
    song = Song(id: id, title: '보컬 이펙트 체험 · 허밍 샘플', bpm: 80, bars: 2);
    song.sections.first.tracks['vocal'] = TrackData(
      vocalPath: clip.path,
      vocalOrigPath: clip.origPath,
      clip: clip.peaks,
      clips: [clip],
      label: '허밍 샘플 · 5.7초',
    );
    await store.upsert(song);
  }
  final capture = GlobalKey();
  final result = navigator!.push<VocalEditorResult>(
    MaterialPageRoute(
      builder:
          (_) => RepaintBoundary(
            key: capture,
            child: VocalEditorScreen(
              vocal: song.sections.first.tracks['vocal']!,
              bpm: song.bpm,
              bars: 2,
              songId: song.id,
              sectionId: song.sections.first.id,
              keyRoot: song.key,
              scale: song.scale,
              swing: song.swing,
            ),
          ),
    ),
  );
  await Future<void>.delayed(const Duration(seconds: 1));
  Element? effects;
  void findEffects(Element e) {
    final w = e.widget;
    if (w is Text && (w.data == '보컬 프리셋' || w.data == 'Vocal presets')) {
      effects ??= e;
    }
    e.visitChildren(findEffects);
  }

  findEffects(WidgetsBinding.instance.rootElement!);
  if (effects != null) await Scrollable.ensureVisible(effects!, alignment: .15);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  final image =
      await (capture.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage();
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(
    '${directory.path}/ready.png',
  ).writeAsBytes(png!.buffer.asUint8List());
  image.dispose();
  await File('${directory.path}/ready.json').writeAsString(
    jsonEncode({
      'ready': true,
      'songId': song.id,
      'title': song.title,
      'screen': 'VocalEditorScreen',
      'effectsVisible': effects != null,
      'libraryPath': directory.path,
    }),
  );
  final edited = await result;
  if (edited != null) {
    song.sections.first.tracks['vocal'] = edited.vocal;
    await store.upsert(song);
    navigator!.push(MaterialPageRoute(builder: (_) => EditScreen(song: song)));
  }
}
