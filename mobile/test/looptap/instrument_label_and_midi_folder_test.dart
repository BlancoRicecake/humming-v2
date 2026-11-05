// Song e2e QA findings (artifacts/song-e2e-20261023/codex-review.md):
// 1) a stored GM program the picker doesn't offer (GM 24/25/27 guitars, or a
//    non-bass GM voice on the bass lane after a MIDI import) was labelled as
//    the list's first entry ("Piano 1"); it must show its real GM name while
//    the picker lists stay unchanged;
// 2) the MIDI file picker remembers the last opened file's folder (memory only).
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/widgets/sheets/midi_import_sheet.dart';

String _gmName(int program) =>
    kMelodyInstruments.firstWhere((i) => i.program == program).label;

void main() {
  group('instrumentLabel uses full metadata for stored programs', () {
    test('GM 24/25/27 guitars on melody lanes show their own names', () {
      for (final p in [24, 25, 27]) {
        expect(instrumentLabel('melody', p), _gmName(p), reason: 'GM $p');
        expect(instrumentLabel('melodyDec', p), _gmName(p), reason: 'GM $p');
        expect(instrumentLabel('melody', p), isNot(_gmName(0)));
      }
    });

    test('a non-bass GM voice on the bass lane shows its own name', () {
      expect(instrumentLabel('bass', 24), _gmName(24));
      expect(instrumentLabel('bass', 73), _gmName(73));
      // bass picker voices and the 808 keep their labels
      expect(instrumentLabel('bass', 33), _gmName(33));
      expect(instrumentLabel('bass', kProgram808), k808Bass.label);
    });

    test('drum kits unchanged; unknown values still fall back', () {
      for (final k in kDrumKits) {
        expect(instrumentLabel('drums', k.program), k.label);
        expect(instrumentLabel('beatDec', k.program), k.label);
      }
      // a non-kit value on a drum lane keeps the old fallback (first kit)
      expect(
        instrumentLabel('drums', 99),
        instrumentsForTrack('drums').first.label,
      );
    });

    test('picker lists are unchanged (GM 24/25/27 still not selectable)', () {
      final melody = instrumentsForTrack('melody').map((i) => i.program);
      expect(melody, isNot(contains(24)));
      expect(melody, isNot(contains(25)));
      expect(melody, isNot(contains(27)));
      final bass = instrumentsForTrack('bass').map((i) => i.program).toSet();
      expect(bass, {32, 33, 34, 35, 36, 37, 38, 39, 43, kProgram808});
    });
  });

  group('MIDI picker remembers the last folder (memory only)', () {
    tearDown(() => debugLastMidiDirectory = null);

    test('parent folder of Windows and POSIX paths', () {
      expect(
        midiParentDirectory(r'C:\src\humming-v2\artifacts\x\2-verse.mid'),
        r'C:\src\humming-v2\artifacts\x',
      );
      expect(midiParentDirectory('/home/u/songs/a.mid'), '/home/u/songs');
      expect(midiParentDirectory(''), isNull);
      expect(midiParentDirectory('a.mid'), isNull);
    });

    test('initial directory only when it still exists', () {
      expect(midiInitialDirectory(null, (_) => true), isNull);
      expect(midiInitialDirectory('', (_) => true), isNull);
      expect(midiInitialDirectory(r'C:\gone', (_) => false), isNull);
      expect(midiInitialDirectory(r'C:\ok', (_) => true), r'C:\ok');
    });

    test('no stored setting: starts empty each session', () {
      expect(debugLastMidiDirectory, isNull);
    });
  });
}
