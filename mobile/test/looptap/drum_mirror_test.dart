// Guards the 3-map percussion mirror from drifting: a kind that's playable
// (kDrumNote) but missing a display (kDrumSpecs) or an export note (_drumNote)
// would silently misbehave. Also checks the Fill launchpad palette/defaults are
// fully backed.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/audio/loop_audio.dart' show kDrumNote;
import 'package:humming/looptap/music/midi_export.dart' show midiDrumKinds;
import 'package:humming/looptap/music/theory.dart'
    show kFillPalette, kFillKindsDefault;
import 'package:humming/looptap/widgets/surfaces/drum_surface.dart'
    show kDrumSpecs;

void main() {
  test('kDrumNote and midi _drumNote cover the same kinds', () {
    expect(kDrumNote.keys.toSet(), equals(midiDrumKinds));
  });

  test('every playable kind has a display spec', () {
    for (final k in kDrumNote.keys) {
      expect(kDrumSpecs.containsKey(k), isTrue, reason: 'no DrumSpec for "$k"');
      expect(kDrumSpecs[k]!.kind, k); // spec self-consistency
    }
  });

  test('every Fill palette sound is fully backed (note + spec)', () {
    for (final k in kFillPalette) {
      expect(kDrumNote.containsKey(k), isTrue, reason: 'no note for "$k"');
      expect(kDrumSpecs.containsKey(k), isTrue, reason: 'no spec for "$k"');
    }
  });

  test('default Fill kinds: exactly 6 and a subset of the palette', () {
    expect(kFillKindsDefault.length, 6);
    for (final k in kFillKindsDefault) {
      expect(kFillPalette.contains(k), isTrue, reason: '"$k" not in palette');
    }
  });
}
