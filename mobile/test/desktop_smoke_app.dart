// Explicit developer entry point; never used by the production entry point.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/audio/synth.dart';
import 'package:humming/audio/melty_synth_backend.dart';
import 'package:humming/audio/pcm_output.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/beginner_backing.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/music/wav_codec.dart';
import 'package:humming/looptap/state/loop_storage.dart';

Future<void> main() async {
  const output = String.fromEnvironment('DESKTOP_SMOKE_OUTPUT');
  if (output.isEmpty || !Platform.isWindows) {
    throw StateError('Explicit Windows smoke output is required');
  }
  final dir = await Directory(output).create(recursive: true);
  final report = <String, dynamic>{'passed': false};
  final timer = Stopwatch()..start();
  try {
    LoopStorage.rootOverride = Directory('${dir.path}/sandbox');
    await app.main();
    await Future<void>.delayed(const Duration(seconds: 2));
    final synth = SynthEngine();
    final loading = Stopwatch()..start();
    await synth.ensureLoaded();
    report['soundfontLoadMs'] = loading.elapsedMilliseconds;
    MeltyEngine().didChangeAppLifecycleState(AppLifecycleState.resumed);
    for (final pitch in [60, 64, 67]) {
      await synth.playNote(
        pitch: pitch,
        velocity: 50,
        release: const Duration(milliseconds: 200),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    await synth.ensureDrumChannel();
    await synth.noteOn(channel: 9, pitch: 36, velocity: 45);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await synth.stopAll();
    final stats = await const MethodChannel(
      'humtrack/desktop_pcm',
    ).invokeMapMethod<String, dynamic>('stats');
    report['wasapi'] = stats;
    if (stats == null ||
        stats['started'] != true ||
        (stats['peak'] as int) <= 0 ||
        (stats['framesWritten'] as int) < 44100) {
      throw StateError('Native output did not consume non-silent PCM');
    }
    final section = Section(id: 'A', name: 'A', bars: 1);
    section.tracks['melody']!.pitchNotes.add(
      PitchNote(midi: 60, freq: 261.63, step: 0, dur: 8),
    );
    final backed = withBeginnerBacking(
      section,
      'C',
      'major',
      BackingStyle.bounce,
    );
    final midi = buildMidi(flattenSong([backed]), 100);
    await File('${dir.path}/desktop-demo.mid').writeAsBytes(midi);
    final sf = await rootBundle.load('assets/sounds/GeneralUser-GS.sf2');
    final sfFile = File('${dir.path}/test-soundfont.sf2');
    await sfFile.writeAsBytes(
      sf.buffer.asUint8List(sf.offsetInBytes, sf.lengthInBytes),
    );
    final rendered = await compute(renderWavForExport, <String, dynamic>{
      'sf2s': [sfFile.path],
      'jobs': [
        {'sf2': 0, 'midi': midi},
      ],
      'sampleRate': 44100,
      'tail': 1.2,
      'mix': true,
    });
    await File('${dir.path}/desktop-demo.wav').writeAsBytes(rendered.single);
    final wave = parseWav(rendered.single)!;
    final peak = wave.samples.fold<double>(
      0,
      (a, b) => a > b.abs() ? a : b.abs(),
    );
    report['exportPeak'] = peak;
    if (peak < 0.001) throw StateError('Export is silent');
    await sfFile.delete();
    NavigatorState? navigator;
    void findNavigator(Element element) {
      if (element is StatefulElement && element.state is NavigatorState) {
        navigator ??= element.state as NavigatorState;
      }
      element.visitChildren(findNavigator);
    }

    WidgetsBinding.instance.rootElement!.visitChildren(findNavigator);
    if (navigator == null) throw StateError('App navigator missing');
    final song = Song(
      id: 'desktop-smoke',
      title: 'Desktop prototype',
      key: 'C',
      scale: 'major',
      bpm: 100,
      bars: 1,
      sections: [backed],
    );
    navigator!.push(
      MaterialPageRoute<void>(
        builder: (_) => EditScreen(song: song, guidedStart: true),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 800));
    GuidedHumPanel? panel;
    Element? panelElement;
    void findPanel(Element element) {
      if (element.widget is GuidedHumPanel) {
        panel = element.widget as GuidedHumPanel;
        panelElement = element;
      }
      element.visitChildren(findPanel);
    }

    WidgetsBinding.instance.rootElement!.visitChildren(findPanel);
    if (panel == null) throw StateError('Guided editor did not open');
    panel!.onBacking!(BackingStyle.drive);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    WidgetsBinding.instance.rootElement!.visitChildren(findPanel);
    if (!panel!.playing) throw StateError('Backing did not start transport');
    panel!.onListen();
    panel!.onSave();
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final saved = navigator!.context.read<LoopStore>().songs.where(
      (s) => s.id == song.id,
    );
    if (saved.isEmpty ||
        saved.first.sections.first.tracks['drums']!.drumNotes.isEmpty) {
      throw StateError('Editor save failed');
    }
    report['guidedEditorSave'] = true;
    RenderRepaintBoundary? boundary =
        panelElement?.findAncestorRenderObjectOfType<RenderRepaintBoundary>();
    void visit(RenderObject node) {
      if (boundary != null) return;
      if (node is RenderRepaintBoundary && !node.debugNeedsPaint) {
        boundary = node;
        return;
      }
      node.visitChildren(visit);
    }

    visit(RendererBinding.instance.renderViews.first);
    if (boundary != null) {
      final image = await boundary!.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png != null) {
        await File(
          '${dir.path}/desktop-editor.png',
        ).writeAsBytes(png.buffer.asUint8List());
      }
      image.dispose();
    }
    report['rssBytes'] = ProcessInfo.currentRss;
    report['peakRssBytes'] = ProcessInfo.maxRss;
    report['elapsedMs'] = timer.elapsedMilliseconds;
    report['passed'] = true;
  } catch (e, st) {
    report['error'] = e.toString();
    report['stack'] = st.toString();
  } finally {
    try {
      await PcmOutput.release();
    } catch (_) {}
    await File(
      '${dir.path}/smoke.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }
  exit(report['passed'] == true ? 0 : 1);
}
