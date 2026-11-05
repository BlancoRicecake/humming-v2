// Storage audit 2026-10-30: closing the desktop window (System.requestAppExit)
// saves the editor's last edits first. The window closes only after the save
// lands (or a back-save already in flight lands); a failed save keeps the
// window and the edits, retrying never discards anything, and quitting without
// saving is a separate explicit choice (not the default). Repeated close
// requests share one answer, and an older save finishing late never marks
// newer edits as saved.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/surfaces/pitch_grid_surface.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/desktop_view.dart';
import '../support/offline_fonts.dart';

/// In-memory store: records the melody note steps of every save; can fail or
/// hold a save open until [gate] completes.
class _Store extends LoopStore {
  final saves = <List<int>>[];
  bool fail = false;
  Completer<void>? gate;

  @override
  Future<void> upsert(Song song) async {
    final steps = [
      for (final n in song.sections.first.tracks['melody']!.pitchNotes) n.step,
    ];
    final g = gate;
    if (g != null) await g.future;
    if (fail) throw const FileSystemException('disk full (test)');
    saves.add(steps);
  }

  @override
  Future<void> sweepVocals() async {}
  @override
  bool get loaded => true;
}

PitchNote _n(int midi, int step) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: 2);

void main() {
  late Directory root;
  late _Store store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('humtrack_exit_save_');
    LoopStorage.rootOverride = root;
    await LoopStorage.ensureDirs();
    LoopPrefs.instance.metro.value = false;
    store = _Store();
  });
  tearDown(() async {
    LoopPrefs.instance.resetGridLayout();
    EditScreen.debugDesktopOverride = null;
    LoopStorage.rootOverride = null;
    await root.delete(recursive: true);
  });

  void editorTest(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      try {
        await body(tester);
      } finally {
        FlutterError.onError = onError;
      }
    });
  }

  /// The editor pushed over a placeholder home (so a back-save can pop),
  /// on the melody piano roll.
  Future<void> open(WidgetTester tester) async {
    useOfflineTestFonts();
    EditScreen.debugDesktopOverride = true;
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sec = Section(id: 'A', name: 'A', bars: 2)
      ..tracks['melody'] = TrackData(notes: [_n(62, 0)]);
    final song = Song(
      id: 'exit',
      title: 'Exit',
      bpm: 120,
      bars: 2,
      key: 'C',
      scale: 'chromatic',
      sections: [sec],
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<LoopStore>.value(
        value: store,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => EditScreen(song: song)));
    await tester.pumpAndSettle();
    await editTrack(tester, 'melody');
    await tester.pumpAndSettle();
    if (find.byType(StepGrid).evaluate().isEmpty) {
      tester
          .widget<GestureDetector>(
            find
                .ancestor(
                  of: find.text('Grid'),
                  matching: find.byType(GestureDetector),
                )
                .first,
          )
          .onTap!();
      await tester.pumpAndSettle();
    }
  }

  StepGrid grid(WidgetTester tester) =>
      tester.widget<StepGrid>(find.byType(StepGrid));

  /// Draw a note on C4 at [step] (a real edit through the grid).
  Future<void> draw(WidgetTester tester, int step) async {
    final ladder = grid(tester).ladder.reversed.toList();
    final row = ladder.indexWhere((r) => r.midi == 60);
    final scroll = tester
        .widget<SingleChildScrollView>(
          find.byKey(const ValueKey('pitch-grid-viewport')),
        )
        .controller!;
    var lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final vp = tester.getRect(
      find.byKey(const ValueKey('pitch-grid-viewport')),
    );
    final rowH = lane.height / ladder.length;
    scroll.jumpTo(
      ((row + .5) * rowH - vp.height / 2)
          .clamp(0.0, scroll.position.maxScrollExtent)
          .toDouble(),
    );
    await tester.pump();
    lane = tester.getRect(find.byKey(const ValueKey('pitch-grid-lane')));
    final v = tester
        .widget<PitchGridSurface>(find.byType(PitchGridSurface))
        .view!
        .view;
    await tester.tapAt(
      Offset(
        lane.left + (step + .5 - v.start) / v.length * lane.width,
        lane.top + (row + .5) * rowH,
      ),
    );
    await tester.pumpAndSettle();
    expect(grid(tester).notes.any((n) => n.step == step), isTrue);
  }

  /// Ask the app to exit (the title-bar X path); not awaited, so a dialog
  /// can be answered.
  Future<AppExitResponse> requestExit(WidgetTester tester) =>
      tester.binding.handleRequestAppExit();

  final dialog = find.byKey(const ValueKey('exit-save-failed'));

  editorTest('unsaved edits are saved before the window closes', (
    tester,
  ) async {
    await open(tester);
    await draw(tester, 8);
    final response = requestExit(tester);
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.exit);
    expect(store.saves.last, containsAll([0, 8]));
  });

  editorTest('nothing unsaved: closes without another save', (tester) async {
    await open(tester);
    final response = requestExit(tester);
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.exit);
    expect(store.saves, isEmpty);
  });

  editorTest(
    'a failed save keeps the window and the edits; closing again retries, never discards',
    (tester) async {
      await open(tester);
      await draw(tester, 8);
      store.fail = true;
      for (var attempt = 0; attempt < 2; attempt++) {
        var answered = false;
        final response = requestExit(tester)..then((_) => answered = true);
        await tester.pumpAndSettle();
        expect(dialog, findsOneWidget, reason: 'attempt $attempt');
        expect(answered, isFalse, reason: 'no answer while asking');
        // Esc (the safe default) = keep editing
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(await response, AppExitResponse.cancel);
        expect(dialog, findsNothing);
        expect(find.byType(EditScreen), findsOneWidget);
        expect(grid(tester).notes.any((n) => n.step == 8), isTrue);
      }
      expect(store.saves, isEmpty);
      // storage back: the next close saves the same edits and closes
      store.fail = false;
      final response = requestExit(tester);
      await tester.pumpAndSettle();
      expect(await response, AppExitResponse.exit);
      expect(store.saves.single, containsAll([0, 8]));
    },
  );

  editorTest('"Save again" in the dialog retries and closes once saved', (
    tester,
  ) async {
    await open(tester);
    await draw(tester, 8);
    store.fail = true;
    final response = requestExit(tester);
    await tester.pumpAndSettle();
    expect(dialog, findsOneWidget);
    store.fail = false;
    await tester.tap(find.byKey(const ValueKey('exit-retry')));
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.exit);
    expect(store.saves.single, containsAll([0, 8]));
  });

  editorTest('quitting without saving is an explicit, separate choice', (
    tester,
  ) async {
    await open(tester);
    await draw(tester, 8);
    store.fail = true;
    final response = requestExit(tester);
    await tester.pumpAndSettle();
    final keep = tester.widget<FilledButton>(
      find.byKey(const ValueKey('exit-keep')),
    );
    expect(keep.autofocus, isTrue, reason: 'keep editing is the default');
    await tester.tap(find.byKey(const ValueKey('exit-discard')));
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.exit);
    expect(store.saves, isEmpty);
  });

  editorTest('repeated close requests share one save and one answer', (
    tester,
  ) async {
    await open(tester);
    await draw(tester, 8);
    store.gate = Completer<void>();
    final first = requestExit(tester);
    final second = requestExit(tester);
    await tester.pump();
    store.gate!.complete();
    store.gate = null;
    await tester.pumpAndSettle();
    expect(await first, AppExitResponse.exit);
    expect(await second, AppExitResponse.exit);
    expect(store.saves, hasLength(1));
  });

  editorTest('a back-save in flight is awaited before the window closes', (
    tester,
  ) async {
    await open(tester);
    await draw(tester, 8);
    store.gate = Completer<void>();
    await tester.binding.handlePopRoute(); // system back → save, then pop
    await tester.pump();
    var answered = false;
    final response = requestExit(tester)..then((_) => answered = true);
    await tester.pump();
    expect(answered, isFalse, reason: 'the back-save has not landed');
    store.gate!.complete();
    store.gate = null;
    await tester.pumpAndSettle();
    expect(await response, AppExitResponse.exit);
    expect(store.saves.single, containsAll([0, 8]));
  });

  editorTest(
    'an older save finishing after a newer edit leaves that edit unsaved',
    (tester) async {
      await open(tester);
      await draw(tester, 8);
      store.gate = Completer<void>();
      // the 12 s autosave snapshots the first edit and waits on the disk
      await tester.pump(const Duration(seconds: 13));
      await draw(tester, 16); // a newer edit while it is saving
      store.gate!.complete();
      store.gate = null;
      await tester.pumpAndSettle();
      expect(store.saves.single, isNot(contains(16)));
      // still dirty: the close saves the newer edit instead of quitting
      final response = requestExit(tester);
      await tester.pumpAndSettle();
      expect(await response, AppExitResponse.exit);
      expect(store.saves, hasLength(2));
      expect(store.saves.last, containsAll([0, 8, 16]));
    },
  );
}
