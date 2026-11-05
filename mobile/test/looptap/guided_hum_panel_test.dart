// The guided start (2026-11-02 layout):
// - first: two described choices (a melody from a hum / the voice as it is,
//   with "import a recording");
// - after a hum: compare my hum with the converted melody, change the
//   instrument or the key, "make a song with this melody" → editor; no
//   listen / save / undo / saved bar and no "record more";
// - after a voice take: listen, "make a song with this recording".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/l10n/generated/app_localizations.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/widgets/guided_hum_panel.dart';

import '../support/offline_fonts.dart';

void main() {
  Future<void> show(
    WidgetTester tester, {
    required bool hasNotes,
    bool? hasMelody,
    String lang = 'ko',
    Size size = const Size(850, 400),
    List<String>? log,
    bool withTake = true,
    bool keyChanged = false,
  }) async {
    useOfflineTestFonts();
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = log ?? <String>[];
    await tester.pumpWidget(
      MaterialApp(
        locale: Locale(lang),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: GuidedHumPanel(
            hasNotes: hasNotes,
            hasMelody: hasMelody,
            playing: false,
            onBack: () => actions.add('back'),
            onRecord: () => actions.add('hum'),
            onRecordVocal: () => actions.add('voice'),
            onSample: () => actions.add('import'),
            onListen: () => actions.add('listen'),
            onInstrument: () => actions.add('instrument'),
            onKey: () => actions.add('key'),
            onPlayTake: withTake ? () => actions.add('take') : null,
            onEdit: () => actions.add('edit'),
            notes: [PitchNote(midi: 60, freq: 261.63, step: 0, dur: 4), PitchNote(midi: 64, freq: 329.63, step: 4, dur: 4)],
            keyLabel: 'C 메이저',
            instrumentName: 'Piano',
            keyChanged: keyChanged,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('first: two described choices, no backing step', (tester) async {
    final log = <String>[];
    await show(tester, hasNotes: false, log: log);
    expect(find.text('녹음 → 비교 → 곡 만들기'), findsOneWidget);
    expect(find.text('허밍으로 멜로디 만들기'), findsOneWidget);
    expect(find.text('목소리 그대로 녹음하기'), findsOneWidget);
    expect(find.textContaining('최대 20초'), findsOneWidget);
    expect(find.text('신나게'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('guided-choice-hum')));
    await tester.tap(find.byKey(const ValueKey('guided-choice-voice')));
    await tester.ensureVisible(find.byKey(const ValueKey('guided-voice-import')));
    await tester.tap(find.byKey(const ValueKey('guided-voice-import')));
    expect(log, ['hum', 'voice', 'import']);
    expect(find.byKey(const ValueKey('guided-make-song')), findsNothing);
  });

  testWidgets('after a hum: compare, instrument, key, retake and make a song', (tester) async {
    final log = <String>[];
    await show(tester, hasNotes: true, hasMelody: true, log: log);
    expect(find.text('멜로디가 만들어졌어요'), findsOneWidget);
    for (final gone in ['내 곡 듣기', '내 곡 저장', '실행취소', '저장됨', '멜로디 추가 녹음', '목소리 그대로 녹음하기']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    // a short landscape window scrolls: bring each one into view first
    for (final k in ['guided-play-take', 'guided-play-melody', 'guided-instrument', 'guided-key', 'guided-retake']) {
      await tester.ensureVisible(find.byKey(ValueKey(k)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(k)));
    }
    await tester.tap(find.byKey(const ValueKey('guided-make-song')));
    expect(log, ['take', 'listen', 'instrument', 'key', 'hum', 'edit']);
    expect(find.text('이 멜로디로 곡 만들기'), findsOneWidget);
  });

  testWidgets('no kept take: the melody can still be heard alone', (tester) async {
    await show(tester, hasNotes: true, hasMelody: true, withTake: false);
    expect(find.byKey(const ValueKey('guided-play-take')), findsNothing);
    expect(find.byKey(const ValueKey('guided-play-melody')), findsOneWidget);
  });

  testWidgets('after a voice take: listen, make a song with it', (tester) async {
    final log = <String>[];
    await show(tester, hasNotes: true, hasMelody: false, log: log);
    expect(find.text('녹음했어요'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guided-play-melody')));
    await tester.tap(find.byKey(const ValueKey('guided-make-song')));
    expect(log, ['listen', 'edit']);
    expect(find.text('이 녹음으로 곡 만들기'), findsOneWidget);
  });

  for (final (lang, size) in [('ko', const Size(850, 400)), ('en', const Size(850, 400)), ('ko', const Size(320, 640)), ('en', const Size(360, 640))]) {
    testWidgets('$lang ${size.width.toInt()}x${size.height.toInt()}: fits, make-song reachable', (tester) async {
      await show(tester, hasNotes: true, hasMelody: true, lang: lang, size: size);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('guided-make-song')).hitTestable(), findsOneWidget);
      await show(tester, hasNotes: false, lang: lang, size: size);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the melody is drawn like a clip; a key change is heard', (tester) async {
    await show(tester, hasNotes: true, hasMelody: true);
    expect(find.byKey(const ValueKey('guided-melody-roll')), findsOneWidget);
    expect(find.text('변환된 멜로디'), findsOneWidget);
    expect(find.text('C 메이저'), findsOneWidget);
    expect(find.text('Piano'), findsOneWidget);
    await show(tester, hasNotes: true, hasMelody: true, keyChanged: true);
    expect(find.text('바뀐 키로 듣기'), findsOneWidget);
    expect(find.text('변환된 멜로디'), findsNothing);
  });
}
