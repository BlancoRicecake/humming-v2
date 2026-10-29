// arrangement-001: linked sections + Make unique.
// docs/specs/arrangement/ar-001-linked-sections.md
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/section_links.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/screens/edit_screen.dart';
import 'package:humming/looptap/state/loop_storage.dart';
import 'package:humming/looptap/state/loop_prefs.dart';
import 'package:humming/looptap/state/loop_store.dart';
import 'package:humming/looptap/widgets/desktop_section_band.dart';
import 'package:humming/looptap/widgets/desktop_top_bar.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import 'package:humming/looptap/widgets/desktop_instrument.dart';
import 'package:humming/looptap/widgets/desktop_workspace.dart';
import 'package:provider/provider.dart';

import '../support/offline_fonts.dart';
import '../support/step_grid_harness.dart';

PitchNote pn(int midi, int step) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step);

Section sectionA() {
  final a = Section(id: 'A', name: 'A', repeats: 2);
  a.tracks['melody']!.pitchNotes.addAll([pn(60, 0), pn(64, 4), pn(67, 8)]);
  a.tracks['drums']!.drumNotes.add(DrumNote(kind: 'kick', step: 0));
  return a;
}

String content(Section s) => jsonEncode(s.tracks.map((k, v) => MapEntry(k, v.toJson())));

List<Section> roundTrip(List<Section> l) => [
  for (final s in l) Section.fromJson(jsonDecode(jsonEncode(s.toJson()))),
];

class _Store extends LoopStore {
  Song? lastSaved;
  @override
  Future<void> upsert(Song song) async => lastSaved = song;
  @override
  bool get loaded => true;
}

void main() {
  group('model', () {
    test('duplicateLinked shares tracks under one new link id', () {
      final a = sectionA();
      final b = duplicateLinked(a, 'B');
      expect(a.linkId, isNotNull);
      expect(b.linkId, a.linkId);
      expect(identical(b.tracks, a.tracks), isTrue);
      expect(identical(b.fillKinds, a.fillKinds), isTrue);
      expect(b.id, isNot(a.id));
      expect(b.repeats, a.repeats);
      // an edit in A shows in B (same list)
      a.tracks['melody']!.pitchNotes.add(pn(72, 12));
      expect(b.tracks['melody']!.pitchNotes.last.midi, 72);
    });

    test('relinkSections restores sharing from the first section', () {
      final a = sectionA();
      final b = duplicateLinked(a, 'B')..repeats = 3;
      final loaded = roundTrip([a, b]);
      expect(identical(loaded[0].tracks, loaded[1].tracks), isFalse);
      // a hand-edited file where B drifted: A (first) wins
      loaded[1].tracks['melody']!.pitchNotes.clear();
      loaded[1].bars = 4;
      final linked = relinkSections(loaded);
      expect(identical(linked[0].tracks, linked[1].tracks), isTrue);
      expect(linked[1].tracks['melody']!.pitchNotes, hasLength(3));
      expect(linked[1].bars, linked[0].bars);
      expect(linked[1].repeats, 3);
      expect(linked[1].id, 'B');
    });

    test('a lone link id is cleared', () {
      final a = sectionA()..linkId = 'x';
      expect(relinkSections([a]).single.linkId, isNull);
    });

    test('makeUnique copies the content and leaves the group', () {
      final a = sectionA();
      final b = makeUnique(duplicateLinked(a, 'B'));
      expect(b.linkId, isNull);
      expect(identical(b.tracks, a.tracks), isFalse);
      expect(content(b), content(a));
      a.tracks['melody']!.pitchNotes.clear();
      expect(b.tracks['melody']!.pitchNotes, hasLength(3));
    });

    test('deleting from a group of three', () {
      final a = sectionA();
      final b = duplicateLinked(a, 'B'), c = duplicateLinked(a, 'C');
      var list = relinkSections([a, b, c]..removeAt(1));
      expect(list.map((s) => s.linkId).toSet(), {a.linkId});
      expect(identical(list[0].tracks, list[1].tracks), isTrue);
      list = relinkSections(list..removeAt(0));
      expect(list.single.linkId, isNull);
    });

    test('flattenSong repeats linked content', () {
      final a = sectionA(); // repeats 2
      final b = duplicateLinked(a, 'B')..repeats = 1;
      final flat = flattenSong([a, b]);
      expect(flat.melody.length, 3 * 3);
    });

    test('vocal clips are shared; Make unique keeps the same file', () {
      final a = sectionA();
      final b = duplicateLinked(a, 'B');
      a.tracks['vocal']!.clips = [VocalClip(path: 'take1.m4a')];
      expect(b.tracks['vocal']!.effectiveClips.single.path, 'take1.m4a');
      final u = makeUnique(b);
      u.tracks['vocal']!.clips!.single.trimStart = 500;
      expect(a.tracks['vocal']!.clips!.single.trimStart, 0);
      expect(u.tracks['vocal']!.clips!.single.path, 'take1.m4a');
    });

    test('older files: no linkId → independent, complete sections', () {
      final a = sectionA();
      final b = duplicateLinked(a, 'B');
      final json = [
        for (final s in [a, b]) s.toJson()..remove('linkId'),
      ];
      final old = relinkSections([
        for (final j in json) Section.fromJson(jsonDecode(jsonEncode(j))),
      ]);
      expect(old.every((s) => s.linkId == null), isTrue);
      expect(identical(old[0].tracks, old[1].tracks), isFalse);
      expect(content(old[1]), content(a));
      // and linkId is stored only when set
      expect(sectionA().toJson().containsKey('linkId'), isFalse);
      expect(a.toJson()['linkId'], a.linkId);
    });
  });

  testWidgets('Ctrl+G and Ctrl+Shift+D pass a focused grid and the '
      'desktop piano to the editor commands', (tester) async {
    useOfflineTestFonts();
    LoopPrefs.instance.keyboardBindings.value = {};
    var groove = 0, linked = 0;
    final played = <int>[];
    final key = GlobalKey<GridHarnessState>();
    final note = pn(60, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DesktopCommands(
            enabled: true,
            play: () {},
            record: () {},
            save: () {},
            undo: () {},
            redo: () {},
            groove: () => groove++,
            duplicateLinked: () => linked++,
            child: SizedBox(
              width: 720,
              height: 420,
              child: DesktopInstrument(
                group: 'piano',
                identity: 'melody',
                capturePointerFocus: false,
                labels: const ['C', 'D', 'E'],
                onDown: (i) {
                  played.add(i);
                  return () {};
                },
                child: GridHarness(key: key, notes: [note], high: 67),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(gridPoint(tester, 1.5, 60, high: 67)); // select note
    await tester.pump();
    Future<void> chord(LogicalKeyboardKey k, {bool shift = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(k);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await chord(LogicalKeyboardKey.keyG);
    await chord(LogicalKeyboardKey.keyD, shift: true);
    expect((groove, linked), (1, 1));
    // the grid did not duplicate its selected note on Ctrl+Shift+D
    expect(key.currentState!.commits, 0);
    expect(played, isEmpty);
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
      root = await Directory.systemTemp.createTemp('humtrack_links_');
      LoopStorage.rootOverride = root;
      await LoopStorage.ensureDirs();
    });
    tearDown(() async {
      LoopStorage.rootOverride = null;
      await root.delete(recursive: true);
    });

    testWidgets('linked duplicate, undo, bars/repeats/name, add track', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1100, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // The transport's BPM readout overflows by a few pixels with the Ahem
      // test font; unrelated to this feature.
      final onError = FlutterError.onError;
      FlutterError.onError = (d) {
        if (!d.exceptionAsString().contains('overflowed')) onError?.call(d);
      };
      final song = Song(id: 'l', title: 'Links', sections: [sectionA()]);
      await tester.pumpWidget(
        ChangeNotifierProvider<LoopStore>.value(
          value: _Store(),
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: EditScreen(song: song),
          ),
        ),
      );
      await tester.pumpAndSettle();
      DesktopCommands commands() =>
          tester.widget<DesktopCommands>(find.byType(DesktopCommands));
      // ui-001 stage 2: desktop sections live in the track header band
      DesktopSectionBand bar() =>
          tester.widget<DesktopSectionBand>(find.byType(DesktopSectionBand));
      Section active() =>
          tester.widget<Arrangement>(find.byType(Arrangement)).section;

      commands().duplicateLinked!(); // Ctrl/Cmd+Shift+D
      await tester.pumpAndSettle();
      expect(bar().sections, hasLength(2));
      final a0 = bar().sections[0], b0 = bar().sections[1];
      expect(identical(a0.tracks, b0.tracks), isTrue);
      expect(find.byKey(ValueKey('section-link-${a0.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('section-link-${b0.id}')), findsOneWidget);
      expect(find.byKey(const ValueKey('section-link-notice')), findsOneWidget);
      expect(identical(active(), b0), isTrue);

      // edit B (clear its drums) → A changes too; Undo restores both, shared
      // ui-001 stage 1: desktop transport lives in the top bar
      tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).onClear();
      await tester.pumpAndSettle();
      expect(bar().sections[0].tracks['drums']!.drumNotes, isEmpty);
      commands().undo();
      await tester.pumpAndSettle();
      final a1 = bar().sections[0], b1 = bar().sections[1];
      expect(a1.tracks['drums']!.drumNotes, hasLength(1));
      expect(identical(a1.tracks, b1.tracks), isTrue);
      expect(b1.linkId, a1.linkId);

      // bars from A apply to B; repeats and names stay per section
      bar().onSwitch(0);
      await tester.pumpAndSettle();
      tester.widget<DesktopTopBar>(find.byType(DesktopTopBar)).onBars(4);
      await tester.pumpAndSettle();
      expect(bar().sections[1].bars, 4);
      bar().onRepeats(1, 5);
      bar().onRename(1, 'Chorus 2');
      await tester.pumpAndSettle();
      expect(bar().sections[0].repeats, 2);
      expect(bar().sections[0].name, 'A');
      expect(bar().sections[1].name, 'Chorus 2');

      // add a track: one shared TrackData, existing content kept
      tester.widget<Arrangement>(find.byType(Arrangement)).onAddTrack!();
      await tester.pumpAndSettle();
      await tester.tap(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(GestureDetector),
            )
            .first,
      );
      await tester.pumpAndSettle();
      final a2 = bar().sections[0], b2 = bar().sections[1];
      final added = a2.extras.last.id;
      expect(b2.extras.last.id, added);
      expect(identical(a2.tracks[added], b2.tracks[added]), isTrue);
      expect(a2.tracks['melody']!.pitchNotes, hasLength(3));

      // plain Duplicate of a linked section stays independent
      bar().onMenu(0);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Duplicate').last);
      await tester.pumpAndSettle();
      expect(bar().sections, hasLength(3));
      expect(bar().sections[1].linkId, isNull);
      expect(identical(bar().sections[1].tracks, a2.tracks), isFalse);
      // desktop delete = the section menu row (the band has no ×)
      bar().onMenu(1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section-menu-delete')));
      await tester.pumpAndSettle();
      expect(bar().sections, hasLength(2));
      expect(identical(bar().sections[0].tracks, bar().sections[1].tracks), isTrue);

      // Make unique from the menu: B leaves the group with a copy
      bar().onMenu(1);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('section-make-unique')));
      await tester.pumpAndSettle();
      final a3 = bar().sections[0], b3 = bar().sections[1];
      expect(b3.linkId, isNull);
      expect(a3.linkId, isNull); // group of one
      expect(identical(a3.tracks, b3.tracks), isFalse);
      expect(content(b3), content(a3));
      expect(b3.name, 'Chorus 2');
      expect(find.byKey(const ValueKey('section-link-notice')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      FlutterError.onError = onError;
    });
  });
}
