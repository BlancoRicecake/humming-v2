// Native verification of the actual editor and WASAPI path, in a private library.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/audio/melty_synth_backend.dart';
import 'package:humming/audio/pcm_output.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/transport_bar.dart';

T? find<T extends Widget>([Key? key]) {
  T? result;
  void visit(Element e) {
    if (e.widget is T && (key == null || e.widget.key == key)) {
      result ??= e.widget as T;
    }
    e.visitChildren(visit);
  }

  visit(WidgetsBinding.instance.rootElement!);
  return result;
}

Future<void> main() async {
  const output = String.fromEnvironment('GRID_SMOKE_OUTPUT');
  if (output.isEmpty || !Platform.isWindows) {
    throw StateError('Explicit Windows output required');
  }
  final dir = await Directory(output).create(recursive: true);
  final report = <String, dynamic>{'passed': false};
  final errors = <String>[];
  try {
    LoopStorage.rootOverride = Directory('${dir.path}/sandbox');
    await app.main();
    FlutterError.onError = (details) => errors.add(details.toString());
    await Future<void>.delayed(const Duration(seconds: 1));
    LoopPrefs.instance.metro.value = false;
    NavigatorState? navigator;
    void visit(Element e) {
      if (e is StatefulElement && e.state is NavigatorState) {
        navigator ??= e.state as NavigatorState;
      }
      e.visitChildren(visit);
    }

    visit(WidgetsBinding.instance.rootElement!);
    final song = Song(
      id: 'grid-verification',
      title: '그리드 편집 확인',
      bpm: 120,
      bars: 2,
    );
    song.sections.single.tracks['melody']!.label = '그리드 피아노';
    final capture = GlobalKey();
    navigator!.push(
      MaterialPageRoute<void>(
        builder:
            (_) => RepaintBoundary(key: capture, child: EditScreen(song: song)),
      ),
    );
    await Future<void>.delayed(const Duration(seconds: 2));
    find<Arrangement>()!.onSelect('melody');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    void openGrid(Element e) {
      final w = e.widget;
      if (w is Text && w.data == L10n.of(e).ltEditorModeGrid) {
        e.findAncestorWidgetOfExactType<GestureDetector>()?.onTap?.call();
        return;
      }
      e.visitChildren(openGrid);
    }

    openGrid(WidgetsBinding.instance.rootElement!);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final grid = find<StepGrid>()!;
    final rows = grid.ladder.map((r) => r.midi).toList();
    final c = grid.ladder.firstWhere((r) => r.midi == 60);
    grid.onPlace(c, 4, 5);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (jsonEncode(find<StepGrid>()!.ladder.map((r) => r.midi).toList()) !=
        jsonEncode(rows)) {
      throw StateError('Pitch rows remapped');
    }
    report['fixedPitchRows'] = rows.length == 128;
    await Future<void>.delayed(const Duration(seconds: 1));
    await LoopAudio.instance.prewarm();
    MeltyEngine().didChangeAppLifecycleState(AppLifecycleState.resumed);
    await LoopAudio.instance.stopAll();
    // Reset native peak after the click audition, with the synth already quiet.
    await PcmOutput.release();
    await PcmOutput.setup(sampleRate: 44100, channelCount: 1);
    PcmOutput.start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    const pcm = MethodChannel('humtrack/desktop_pcm');
    final silent = await pcm.invokeMapMethod<String, dynamic>('stats');
    if ((silent!['peak'] as int) > 10) {
      throw StateError('Audition leaked into playback measurement');
    }
    find<Arrangement>()!.onSeek!(4);
    find<TransportBar>()!.onPlay();
    await Future<void>.delayed(const Duration(milliseconds: 650));
    final stats = await pcm.invokeMapMethod<String, dynamic>('stats');
    report['wasapi'] = stats;
    if (stats!['started'] != true ||
        (stats['peak'] as int) < 100 ||
        (stats['framesWritten'] as int) < 20000) {
      throw StateError('Drawn note was skipped on the first playback');
    }
    report['firstPlaybackAudible'] = true;
    find<TransportBar>()!.onStop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // Clipboard buttons use the real editor transaction and undo stack.
    find<TextButton>(const ValueKey('note-select-all'))!.onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    find<TextButton>(const ValueKey('note-copy'))!.onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    find<TextButton>(const ValueKey('note-paste'))!.onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (find<StepGrid>()!.notes.length != 2) throw StateError('Paste failed');
    find<DesktopCommands>()!.undo();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (find<StepGrid>()!.notes.length != 1) {
      throw StateError('Paste undo failed');
    }
    find<DesktopCommands>()!.redo();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (find<StepGrid>()!.notes.length != 2) {
      throw StateError('Paste redo failed');
    }
    report['copyPasteUndoRedo'] = true;
    final rendered =
        await (capture.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage();
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '${dir.path}/grid-editor.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    rendered.dispose();
    report['flutterErrors'] = errors;
    if (errors.isNotEmpty) throw StateError('Flutter errors: $errors');
    report['passed'] = true;
  } catch (e, stack) {
    report['error'] = e.toString();
    report['stack'] = stack.toString();
  } finally {
    await LoopAudio.instance.stopAll();
    await PcmOutput.release();
    await File(
      '${dir.path}/native-verification.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }
  exit(report['passed'] == true ? 0 : 1);
}
