// gt-004 UI: "줄별 울림 유지" lives only in the guitar panel, reports
// "연장 N · 그대로 M" with reasons (or a hint), is one undo including the
// automatic strings, and in the editor keeps redo, save/load, 울림 되돌리기
// and live gates == export lengths for the extended notes.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/audio/loop_audio.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/guitar_sustain.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

const _em = [40, 47, 52, 55, 59, 64];

PitchNote _raw(int midi, int step, int dur) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

List<PitchNote> _plain() => [
  for (final s in [0, 4])
    for (final m in _em) _raw(m, s, 4),
];

/// Em struck down twice (0 and 4, 4 steps each).
List<PitchNote> _stroked() =>
    applyGuitarStroke(_plain(), const {}, const StrokeSpec.down(), bpm: 120)
        .notes;

List<Map<String, dynamic>> _js(Iterable<PitchNote> notes) => [
  for (final n in notes) n.toJson(),
];

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

/// Opens the "기타 연주" panel (the note toolbar's guitar button, which the
/// editor also shows) and taps [key].
Future<void> _panelTap(WidgetTester tester, String key) async {
  await tapGridButton(tester, 'note-guitar-tools');
  final f = find.byKey(ValueKey(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    LoopPrefs.instance.strokePattern.value = 'down';
    LoopPrefs.instance.keyboardBindings.value = {};
  });

  testWidgets('the button lives only in the guitar panel, with its '
      'description', (tester) async {
    await mountGrid(tester, _stroked(), low: 40, high: 64, steps: 16);
    expect(find.byKey(const ValueKey('stroke-more')), findsNothing);
    expect(find.byKey(const ValueKey('note-guitar-tools')), findsNothing);
    expect(find.byKey(const ValueKey('guitar-sustain')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await mountGrid(tester, _stroked(), low: 40, high: 64, steps: 16, guitar: true);
    await tapGridButton(tester, 'note-guitar-tools');
    final button = find.byKey(const ValueKey('guitar-sustain'));
    await tester.ensureVisible(button);
    expect(button, findsOneWidget);
    expect(find.text('Keep strings ringing'), findsOneWidget);
    expect(find.byKey(const ValueKey('guitar-sustain-info')), findsOneWidget);
    // next to the string actions
    expect(find.byKey(const ValueKey('guitar-ring')), findsOneWidget);
    expect(find.byKey(const ValueKey('guitar-sustain-result')), findsNothing);
  });

  testWidgets('one press = one edit with counts and reasons; nothing to do '
      'shows a hint and makes no edit', (tester) async {
    final src = _stroked();
    final key = await mountGrid(
      tester,
      src,
      low: 40,
      high: 64,
      steps: 16,
      guitar: true,
    );
    final state = key.currentState!;
    await _panelTap(tester, 'guitar-sustain');
    expect(state.commits, 1);
    final expected = applyStrokeSustain(src, const {}, sectionSteps: 16);
    expect(_js(state.notes), _js(expected.notes));
    expect(
      find.text('Extended 5 · kept 7 (section end 6, already connected 1)'),
      findsWidgets,
    );
    await tapGridButton(tester, 'note-guitar-tools');
    final result = find.byKey(const ValueKey('guitar-sustain-result'));
    await tester.ensureVisible(result);
    expect(
      tester.widget<Text>(result).data,
      'Extended 5 · kept 7 (section end 6, already connected 1)',
    );
    await tester.tapAt(const Offset(5, 5)); // close the sheet
    await tester.pumpAndSettle();
    // again: everything is connected already -> hint, no edit
    await _panelTap(tester, 'guitar-sustain');
    expect(state.commits, 1);
    await tapGridButton(tester, 'note-guitar-tools');
    await tester.ensureVisible(result);
    final hint = tester.widget<Text>(result).data!;
    expect(hint, startsWith('Nothing to extend.'));
    expect(hint, endsWith('Extended 0 · kept 12 (already connected 6, section end 6)'));
  });

  testWidgets('untagged chords: hint with the reason, no edit', (tester) async {
    final key = await mountGrid(
      tester,
      _plain(),
      low: 40,
      high: 64,
      steps: 16,
      guitar: true,
    );
    await _panelTap(tester, 'guitar-sustain');
    expect(key.currentState!.commits, 0);
    expect(_js(key.currentState!.notes), _js(_plain()));
    expect(find.textContaining('Nothing to extend'), findsWidgets);
    expect(find.textContaining('no stroke 12'), findsWidgets);
  });

  group('editor', () {
    late Directory root;
    setUp(() async {
      useOfflineTestFonts();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events',
        'xyz.luan/audioplayers',
      ]) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
      }
      root = await Directory.systemTemp.createTemp('humtrack_sustain_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopAudio.instance.debugOnPitchGate = null;
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    Future<_Store> mountEditor(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      addTearDown(() => FlutterError.onError = onError);
      final store = _Store();
      final sec = Section(id: 'A', name: 'A', bars: 1)
        ..tracks['melody'] = TrackData(notes: _stroked());
      final song = Song(
        id: 'g4',
        title: 'Sustain',
        bpm: 120,
        bars: 1,
        sections: [sec],
        instruments: {'melody': 25},
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: store,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: song),
          ),
        ),
      );
      await tester.pumpAndSettle();
      tester.widget<Arrangement>(find.byType(Arrangement)).onSelect('melody');
      await tester.pumpAndSettle();
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
      expect(find.byType(StepGrid), findsOneWidget);
      return store;
    }

    DesktopCommands commands(WidgetTester tester) =>
        tester.widget<DesktopCommands>(find.byType(DesktopCommands));
    StepGrid grid(WidgetTester tester) =>
        tester.widget<StepGrid>(find.byType(StepGrid));

    testWidgets('one undo restores the exact JSON (auto strings included); '
        'redo, save/load and 울림 되돌리기', (tester) async {
      final store = await mountEditor(tester);
      final original = _js(grid(tester).notes);
      expect(original, _js(_stroked()));
      await _panelTap(tester, 'guitar-sustain');
      final applied = _js(grid(tester).notes);
      expect(applied, _js(applyStrokeSustain(_stroked(), const {}, sectionSteps: 16).notes));
      expect(grid(tester).notes.where((n) => n.guitarString != null), hasLength(5));
      expect(grid(tester).notes.where((n) => n.ringBaseDur != null), hasLength(5));
      commands(tester).undo();
      await tester.pump();
      expect(_js(grid(tester).notes), original, reason: 'one undo, strings too');
      commands(tester).redo();
      await tester.pump();
      expect(_js(grid(tester).notes), applied);
      await tester.runAsync(() async => commands(tester).save());
      await tester.pump();
      final loaded = Song.fromJson(
        jsonDecode(jsonEncode(store.lastSaved!.toJson()))
            as Map<String, dynamic>,
      );
      expect(_js(loaded.sections.single.tracks['melody']!.pitchNotes), applied);
      // 울림 되돌리기: lengths back exactly; strokes kept; strings stay
      await _panelTap(tester, 'guitar-ring-revert');
      final back = grid(tester).notes;
      final src = _stroked();
      for (var i = 0; i < src.length; i++) {
        expect(
          back[i].toJson()..remove('guitarString'),
          src[i].toJson(),
          reason: '#$i',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('live gates == export lengths for the extended notes', (
      tester,
    ) async {
      await mountEditor(tester);
      await _panelTap(tester, 'guitar-sustain');
      final notes = grid(tester).notes;
      expect(notes.where((n) => n.ringBaseDur != null), hasLength(5));
      final gates = <(int, double)>[];
      LoopAudio.instance.debugOnPitchGate =
          (ch, midi, durSec) => gates.add((midi, durSec));
      commands(tester).play();
      for (var i = 0; i < 115; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      commands(tester).play(); // stop
      await tester.pump();
      const sps = 60 / 120 / kStepsPerBeat;
      final sec = Section(id: 'A', name: 'A', bars: 1)
        ..tracks['melody'] = TrackData(notes: notes);
      final flat = [...flattenSong([sec]).melody]
        ..sort((a, b) => a.startSteps.compareTo(b.startSteps));
      expect(flat, hasLength(12));
      // gates arrive in onset order
      expect(gates, hasLength(12));
      for (var k = 0; k < 12; k++) {
        final x = flat[k];
        expect(gates[k].$1, x.midi, reason: '#$k');
        expect(
          gates[k].$2,
          closeTo((x.endSteps - x.startSteps) * sps, .002),
          reason: '#$k ${x.midi}',
        );
      }
      // the extended first-hit strings sound up to the re-strike
      for (var k = 1; k < 6; k++) {
        expect(gates[k].$2, greaterThan((4 - flat[k].startSteps) * sps + .01));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
