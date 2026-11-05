// Explicit native verification entry point for ui-001 stage 0
// (docs/specs/ui/ui-001-desktop-b2-layout.md). Never used by the product build.
//
// Runs the real app (real loopTapTheme on Windows), opens an editor with a
// guitar melody, and opens each theme-default sheet through the editor's own
// buttons / commands (the same callbacks a click runs): 펼치기, 코드 종류,
// 퀀타이즈, 그루브, 기타 스트로크, 자르기, and the MIDI import window via the
// section menu (file picker injected). Each state is captured from the root
// layer (sheet + editor behind it) into UI000_OUTPUT. No mouse/keyboard input.
//
// Build/run (from mobile/, debug only — root layer capture uses debugLayer):
//   flutter build windows --debug -t test/ui000_sheet_smoke_app.dart \
//     --dart-define=UI000_OUTPUT=<dir>
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:humming/main.dart' as app;
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/section_bar.dart';
import 'package:humming/l10n/generated/app_localizations.dart';

T? find<T extends Widget>([Key? key]) {
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

Uint8List _referenceMidi() {
  // format 0, 480 tpq, 120 BPM, 4/4, C4 E4 G4 quarter notes
  final ev = <int>[
    0, 0xff, 0x51, 3, 0x07, 0xa1, 0x20, //
    0, 0xff, 0x58, 4, 4, 2, 24, 8,
    0, 0x90, 60, 90, 0x83, 0x60, 0x80, 60, 0,
    0, 0x90, 64, 90, 0x83, 0x60, 0x80, 64, 0,
    0, 0x90, 67, 90, 0x83, 0x60, 0x80, 67, 0,
    0, 0xff, 0x2f, 0,
  ];
  return Uint8List.fromList([
    ...'MThd'.codeUnits, 0, 0, 0, 6, 0, 0, 0, 1, 0x01, 0xe0, //
    ...'MTrk'.codeUnits, 0, 0, 0, ev.length, ...ev,
  ]);
}

Future<void> main() async {
  const output = String.fromEnvironment('UI000_OUTPUT');
  if (output.isEmpty || !Platform.isWindows) {
    throw StateError('Explicit Windows output required');
  }
  final dir = await Directory(output).create(recursive: true);
  final report = <String, dynamic>{'passed': false, 'captures': <String, dynamic>{}};
  final errors = <String>[];
  try {
    LoopStorage.rootOverride = Directory('${dir.path}/sandbox');
    await app.main();
    FlutterError.onError = (details) => errors.add(details.toString());
    await Future<void>.delayed(const Duration(seconds: 1));
    LoopPrefs.instance.metro.value = false;
    NavigatorState? navigator;
    void visitNav(Element e) {
      if (e is StatefulElement && e.state is NavigatorState) navigator ??= e.state as NavigatorState;
      e.visitChildren(visitNav);
    }

    visitNav(WidgetsBinding.instance.rootElement!);
    final song = Song(id: 'ui000-sheets', title: '시트 테마 확인', bpm: 100, bars: 1);
    song.instruments['melody'] = 25; // GM steel guitar → guitar tools
    song.sections.single.tracks['melody'] = TrackData(
      label: 'Guitar',
      notes: [
        for (final (m, s) in [(60, 0), (64, 0), (67, 0), (62, 8)])
          PitchNote(midi: m, freq: midiToFreq(m), step: s, dur: 4, velocity: 96),
      ],
    );
    navigator!.push(MaterialPageRoute<void>(
      builder: (_) => EditScreen(
        song: song,
        midiFilePicker: () async => (name: 'reference.mid', bytes: _referenceMidi()),
      ),
    ));
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
    await Future<void>.delayed(const Duration(milliseconds: 400));
    find<TextButton>(const ValueKey('note-select-all'))!.onPressed!();
    await Future<void>.delayed(const Duration(milliseconds: 300));

    Future<void> capture(String name) async {
      await Future<void>.delayed(const Duration(milliseconds: 900));
      final view = WidgetsBinding.instance.renderViews.first;
      final layer = view.debugLayer! as OffsetLayer;
      final size = view.size;
      final image = await layer.toImage(Offset.zero & size, pixelRatio: view.flutterView.devicePixelRatio);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('${dir.path}/$name.png');
      await file.writeAsBytes(png!.buffer.asUint8List());
      (report['captures'] as Map<String, dynamic>)[name] = {'file': file.path, 'width': image.width, 'height': image.height};
      image.dispose();
    }

    Future<void> close() async {
      navigator!.pop();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }

    Future<void> sheet(String name, VoidCallback open) async {
      open();
      await capture(name);
      await close();
    }

    await sheet('01-arpeggiate', find<TextButton>(const ValueKey('note-arpeggiate-settings'))!.onPressed!);
    await sheet('02-chord-type', find<TextButton>(const ValueKey('grid-chord-stamp'))!.onLongPress!);
    await sheet('03-quantize', find<TextButton>(const ValueKey('note-quantize-settings'))!.onPressed!);
    await sheet('04-groove', find<DesktopCommands>()!.groove!);
    await sheet('05-guitar-stroke', find<TextButton>(const ValueKey('note-guitar-tools'))!.onPressed!);
    await sheet('06-split', find<TextButton>(const ValueKey('note-split'))!.onPressed!);
    // MIDI import window: section menu → "MIDI 구간을 새 섹션으로" → injected file → dialog
    find<SectionBar>()!.onLongPress(0);
    await capture('07a-section-menu');
    find<GestureDetector>(const ValueKey('section-midi-import'))!.onTap!();
    await capture('07-midi-import');
    await close();

    report['flutterErrors'] = errors;
    if (errors.isNotEmpty) throw StateError('Flutter errors: ${errors.length}');
    report['passed'] = true;
  } catch (e, stack) {
    report['error'] = e.toString();
    report['stack'] = stack.toString();
    report['flutterErrors'] = errors;
  } finally {
    await LoopAudio.instance.stopAll();
    await File('${dir.path}/native-verification.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }
  exit(report['passed'] == true ? 0 : 1);
}
