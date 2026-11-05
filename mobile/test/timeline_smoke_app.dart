// Explicit native verification entry point. Never used by the product build.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/audio/melty_synth_backend.dart';
import 'package:humming/audio/pcm_output.dart';
import 'package:humming/audio/synth.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/audition_bar.dart';
import 'package:humming/looptap/widgets/transport_bar.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/solo_status_notice.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/surfaces/velocity_lane.dart';

T? findWidget<T extends Widget>({Key? key}) {
  T? result;
  void visit(Element element) {
    if (element.widget is T && (key == null || element.widget.key == key)) {
      result ??= element.widget as T;
    }
    element.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return result;
}

Future<void> main() async {
  const output = String.fromEnvironment('TIMELINE_SMOKE_OUTPUT');
  const midiPath = String.fromEnvironment('REFERENCE_MIDI');
  if (output.isEmpty || midiPath.isEmpty || !Platform.isWindows) {
    throw StateError('Explicit Windows smoke paths required');
  }
  final dir = await Directory(output).create(recursive: true);
  final report = <String, dynamic>{'passed': false};
  try {
    LoopStorage.rootOverride = Directory('${dir.path}/sandbox');
    await app.main();
    await Future<void>.delayed(const Duration(seconds: 1));
    NavigatorState? navigator;
    void visit(Element element) {
      if (element is StatefulElement && element.state is NavigatorState) {
        navigator ??= element.state as NavigatorState;
      }
      element.visitChildren(visit);
    }

    visit(WidgetsBinding.instance.rootElement!);
    final midi = MidiReference.parse(await File(midiPath).readAsBytes());
    final song = midi.passage(
      title: 'Attention · timeline check',
      startBar: 1,
      lengthBars: 8,
    );
    final saxTrack =
        song.sections.single.tracks.entries
            .firstWhere((e) => e.value.label?.contains('Tenor Sax') == true)
            .key;
    song.sections.single.order.add(saxTrack);
    final capture = GlobalKey();
    navigator!.push(
      MaterialPageRoute<void>(
        builder:
            (_) => RepaintBoundary(key: capture, child: EditScreen(song: song)),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    await SynthEngine().ensureLoaded();
    MeltyEngine().didChangeAppLifecycleState(AppLifecycleState.resumed);
    // Exercise the quiet source passage that previously looked like an audio
    // failure. Opening the hint must not alter any original MIDI expression.
    final quietId =
        song.sections.single.tracks.entries
            .firstWhere((e) => e.value.label?.contains('Piano 1') == true)
            .key;
    findWidget<Arrangement>()!.onToggleSolo!(quietId);
    findWidget<AuditionBar>()!.onRange(const PlaybackRange(64, 128));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final notice = findWidget<SoloStatusNotice>()!;
    if (notice.issues.isEmpty || notice.onOpenVelocity == null) {
      throw StateError('Quiet Solo hint missing');
    }
    notice.onOpenVelocity!(quietId);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Future<void> capturePng(String name) async {
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${dir.path}/$name').writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
    }

    await capturePng('velocity-editor-quiet.png');
    final grid = findWidget<StepGrid>()!;
    final quietNote = grid.notes.firstWhere((n) => n.startSteps >= 64);
    final before = quietNote.toJson();
    final lane = findWidget<VelocityLane>();
    if (lane == null || !lane.onStart(quietNote)) {
      throw StateError('Velocity lane unavailable');
    }
    lane.onDelta(30);
    lane.onEnd();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final edited = findWidget<StepGrid>()!.notes.firstWhere(
      (n) => n.startSteps == quietNote.startSteps && n.midi == quietNote.midi,
    );
    final after = edited.toJson();
    if (edited.velocity != quietNote.velocity! + 30 ||
        jsonEncode(Map.of(after)..remove('velocity')) !=
            jsonEncode(Map.of(before)..remove('velocity'))) {
      throw StateError('Velocity edit altered expressive metadata');
    }
    await capturePng('velocity-editor.png');
    findWidget<DesktopCommands>()!.undo();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (findWidget<SoloStatusNotice>()!.issues.isEmpty) {
      throw StateError('Undo failed to restore quiet source');
    }
    findWidget<DesktopCommands>()!.redo();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (findWidget<SoloStatusNotice>()!.issues.isNotEmpty) {
      throw StateError('Redo failed to restore velocity edit');
    }
    findWidget<DesktopCommands>()!.undo();
    report['quietSoloHint'] = true;
    report['velocityDragUndoRedo'] = true;
    report['velocityBefore'] = quietNote.velocity;
    report['velocityAfter'] = edited.velocity;
    findWidget<AuditionBar>()!.onClearSolo();
    final sax =
        song.sections.single.tracks.entries
            .firstWhere((e) => e.value.label?.contains('Tenor Sax') == true)
            .key;
    findWidget<Arrangement>()!.onSelect(sax);
    findWidget<Arrangement>()!.onToggleSolo!(sax);
    findWidget<AuditionBar>()!.onRange(const PlaybackRange(64, 128));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    findWidget<TextButton>(
      key: const ValueKey('timeline-fit-loop'),
    )!.onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final arrangement = findWidget<Arrangement>()!;
    report['visibleStart'] = arrangement.visible.start;
    report['visibleEnd'] = arrangement.visible.end;
    report['importedTrackName'] =
        arrangement.tracks.firstWhere((t) => t.id == sax).label;
    if ((arrangement.visible.start - 64).abs() > .01 ||
        (arrangement.visible.end - 128).abs() > .01 ||
        findWidget<Text>(key: const ValueKey('timeline-bar-5')) == null ||
        findWidget<Text>(key: const ValueKey('timeline-bar-8')) == null) {
      throw StateError('Loop fit/ruler misaligned');
    }
    findWidget<TransportBar>()!.onPlay();
    var previous = 64.0, maximum = 64.0, wrapped = false;
    for (var i = 0; i < 55; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final current = findWidget<Arrangement>()!.playStep.value;
      if (current > maximum) maximum = current;
      if (previous - current > 32) wrapped = true;
      previous = current;
    }
    report['loopWrapped'] = wrapped;
    report['maximumPlayhead'] = maximum;
    if (!wrapped || maximum < 100) {
      throw StateError('Native clock did not wrap');
    }
    final position = findWidget<Arrangement>()!.playStep.value;
    if (position < 64 || position >= 128) {
      throw StateError('Playback escaped loop');
    }
    report['playheadAfterWrap'] = position;
    report['wasapi'] = await const MethodChannel(
      'humtrack/desktop_pcm',
    ).invokeMapMethod<String, dynamic>('stats');
    final stats = report['wasapi'] as Map?;
    if (stats == null ||
        stats['started'] != true ||
        (stats['peak'] as int) < 100 ||
        (stats['framesWritten'] as int) < 44100) {
      throw StateError('Native audio signal missing');
    }
    findWidget<TransportBar>()!.onStop();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final boundary =
        capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '${dir.path}/timeline-editor.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    report['passed'] = true;
  } catch (e, stack) {
    report['error'] = e.toString();
    report['stack'] = stack.toString();
  } finally {
    await SynthEngine().stopAll();
    try {
      await PcmOutput.release();
    } catch (_) {}
    await File(
      '${dir.path}/native-verification.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }
  exit(report['passed'] == true ? 0 : 1);
}
