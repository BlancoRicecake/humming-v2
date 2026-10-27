import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/widgets/sheets/midi_import_sheet.dart';

void main() {
  testWidgets(
    'review a MIDI passage and create a new song without touching the library',
    (tester) async {
      final track = [
        0,
        0xc0,
        28,
        61,
        0x90,
        60,
        47,
        121,
        0x80,
        60,
        0,
        0,
        0xff,
        0x2f,
        0,
      ];
      final ref = MidiReference.parse(
        Uint8List.fromList([
          ...'MThd'.codeUnits,
          0,
          0,
          0,
          6,
          0,
          0,
          0,
          1,
          1,
          224,
          ...'MTrk'.codeUnits,
          0,
          0,
          0,
          track.length,
          ...track,
        ]),
      );
      Song? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () async {
                      result = await showMidiPassageDialog(
                        context,
                        midi: ref,
                        title: 'Reference',
                      );
                    },
                    child: const Text('Open MIDI'),
                  ),
                ),
          ),
        ),
      );
      await tester.tap(find.text('Open MIDI'));
      await tester.pumpAndSettle();
      expect(find.text('Import MIDI passage'), findsOneWidget);
      expect(find.byType(CheckboxListTile), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Import as new song'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(
        result!.sections.single.tracks['melody']!.pitchNotes.single.velocity,
        47,
      );
      expect(result!.scale, 'chromatic');
      expect(find.text('Import MIDI passage'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
