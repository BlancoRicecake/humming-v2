import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/vocal_midi.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/sheets/vocal_midi_sheet.dart';
import 'package:humming/looptap/widgets/surfaces/step_grid.dart';
import 'package:humming/looptap/widgets/surfaces/vocal_surface.dart';
import 'package:humming/looptap/widgets/arrangement.dart';
import '../support/offline_fonts.dart';

class _Service extends VocalMidiService {
  final pending = Completer<VocalMidiAnalysis>();
  int calls = 0;
  @override
  Future<VocalMidiAnalysis> convert(
    VocalClip clip, {
    required int bpm,
    required int bars,
    required String keyRoot,
    required String scale,
    required double swing,
  }) {
    calls++;
    return pending.future;
  }
}

class _Analysis extends VocalMidiAnalysis {
  _Analysis()
    : super(
        [PitchNote(midi: 64, freq: 329, step: 3, dur: 2, sourceMidi: 63)],
        File('unused-test-preview.wav'),
        VocalMidiAudio(Uint8List(0), .5, .375),
      );
  bool cleaned = false;
  @override
  Future<void> dispose() async {
    cleaned = true;
  }
}

Widget app(Widget home, String lang) => MaterialApp(
  locale: Locale(lang),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Scaffold(body: home),
);

void main() {
  setUp(() {
    useOfflineTestFonts();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (_) async => null,
      );
    }
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async {
        if (call.method == 'create') {
          final id = (call.arguments as Map)['playerId'];
          messenger.setMockMethodCallHandler(
            MethodChannel('xyz.luan/audioplayers/events/$id'),
            (_) async => null,
          );
        }
        return null;
      },
    );
  });

  for (final lang in ['en', 'ko']) {
    testWidgets(
      '$lang conversion waits for confirmation and supports pitch/octave correction',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(640, 360));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final service = _Service();
        final result = _Analysis();
        VocalMidiResult? applied;
        await tester.pumpWidget(
          app(
            Builder(
              builder:
                  (context) => TextButton(
                    onPressed: () async {
                      applied = await showDialog<VocalMidiResult>(
                        context: context,
                        builder:
                            (_) => VocalMidiSheet(
                              clip: VocalClip(path: 'original.wav'),
                              bpm: 120,
                              bars: 2,
                              keyRoot: 'C',
                              scale: 'minor',
                              swing: 0,
                              service: service,
                            ),
                      );
                    },
                    child: const Text('open'),
                  ),
            ),
            lang,
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final l = L10n.of(tester.element(find.byType(VocalMidiSheet)));
        await tester.ensureVisible(find.text(l.ltMidiGuitar));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l.ltMidiGuitar));
        await tester.tap(find.text(l.ltMidiConvert));
        await tester.pump();
        expect(service.calls, 1);
        expect(applied, isNull);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        service.pending.complete(result);
        await tester.pumpAndSettle();
        expect(applied, isNull);
        await tester.ensureVisible(find.text(l.ltMidiRawPitch));
        await tester.tap(find.byType(SwitchListTile));
        await tester.pump();
        await tester.ensureVisible(find.byTooltip(l.ltMidiOctaveUp));
        await tester.tap(find.byTooltip(l.ltMidiOctaveUp));
        await tester.pump();
        await tester.tap(find.text(l.ltMidiAddTrack));
        await tester.pumpAndSettle();
        expect(applied!.program, 24);
        expect(applied!.notes.single.midi, 75);
        expect(applied!.notes.single.step, 3);
        expect(result.cleaned, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'cancelled analysis never applies a late result and cleans preview',
    (tester) async {
      final service = _Service();
      final result = _Analysis();
      await tester.pumpWidget(
        app(
          Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () => showDialog<VocalMidiResult>(
                        context: context,
                        builder:
                            (_) => VocalMidiSheet(
                              clip: VocalClip(path: 'original.wav'),
                              bpm: 120,
                              bars: 2,
                              keyRoot: 'C',
                              scale: 'minor',
                              swing: 0,
                              service: service,
                            ),
                      ),
                  child: const Text('open'),
                ),
          ),
          'en',
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Convert'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      service.pending.complete(result);
      await tester.pumpAndSettle();
      expect(result.cleaned, isTrue);
      expect(find.byType(VocalMidiSheet), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('idle grid settles; cancelled pointer does not commit a note', (
    tester,
  ) async {
    var placed = 0;
    await tester.pumpWidget(
      app(
        SizedBox(
          width: 600,
          height: 200,
          child: StepGrid(
            ladder: buildLadder('C', 'minor', 4, 8),
            notes: const [],
            onPlace: (_, _, _) => placed++,
            onErase: (_, _) {},
            playStep: 0,
            accent: Colors.green,
            steps: 32,
            bars: 2,
          ),
        ),
        'en',
      ),
    );
    await tester.pumpAndSettle();
    final grid = find.byType(StepGrid);
    final bounds = tester.getRect(grid);
    final gesture = await tester.startGesture(bounds.center);
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(placed, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'desktop drop selects a vocal clip and a pitched destination only',
    (tester) async {
      final head = ValueNotifier(0.0);
      addTearDown(head.dispose);
      final section = Section(id: 'a', name: 'A');
      section.tracks['vocal'] = TrackData(
        clips: [
          VocalClip(path: 'first.wav', startStep: 0, durSteps: 8),
          VocalClip(path: 'second.wav', startStep: 8, durSteps: 8),
        ],
      );
      VocalClipDrag? dropped;
      String? target;
      await tester.pumpWidget(
        app(
          SizedBox(
            width: 600,
            height: 350,
            child: Arrangement(
              section: section,
              tracks: [trackById('melody'), trackById('vocal')],
              activeId: 'vocal',
              mutes: const {},
              onSelect: (_) {},
              onToggleMute: (_) {},
              playStep: head,
              steps: 32,
              ranges: const {},
              onMoveClip: (_, _, _) {},
              onConvertClip: (clip, id) {
                dropped = clip;
                target = id;
              },
            ),
          ),
          'en',
        ),
      );
      await tester.pumpAndSettle();
      final handles = find.byType(Draggable<VocalClipDrag>);
      expect(handles, findsNWidgets(2));
      final start = tester.getCenter(handles.at(1));
      final dropArea = tester.getRect(find.byType(DragTarget<VocalClipDrag>));
      final destination = Offset(start.dx, dropArea.center.dy);
      final gesture = await tester.startGesture(start);
      await tester.pump();
      await gesture.moveBy(const Offset(0, -20));
      await tester.pump();
      await gesture.moveTo(destination);
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(dropped!.clipIndex, 1);
      expect(dropped!.clip.path, 'second.wav');
      expect(target, 'melody');
      expect(section.tracks['melody']!.pitchNotes, isEmpty);
      expect(section.tracks['vocal']!.effectiveClips.length, 2);
    },
  );

  testWidgets(
    'vocal conversion remains visible on a small landscape editor surface',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(640, 360));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        app(
          SizedBox(
            height: 180,
            child: VocalSurface(
              clip: List.filled(64, .5),
              onRecord: () {},
              onClear: () {},
              onAutotune: () {},
              onRevert: () {},
              onEdit: () {},
              onConvert: () {},
            ),
          ),
          'ko',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('MIDI로 변환'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
