// gt-002 standard guitar tuning, kept free of imports so the note model can
// validate a stored string on every pitch change.
//
// Strings are numbered by guitar convention: 1 = high E (E4, MIDI 64) ...
// 6 = low E (E2, MIDI 40).

/// Open-string MIDI pitch for strings 1..6 (index 0 = string 1, high E).
const List<int> kGuitarOpenMidi = [64, 59, 55, 50, 45, 40];

/// Number of strings on the standard-tuned guitar.
const int kGuitarStrings = 6;

/// Highest fret used for assignment (v1; frets 0..22).
const int kGuitarMaxFret = 22;

/// Lowest and highest playable MIDI pitch in standard tuning.
const int kGuitarLowestMidi = 40;
const int kGuitarHighestMidi = 64 + kGuitarMaxFret;

/// The fret [midi] needs on [string] (1..6), or null when it is not playable
/// there (wrong string number or outside frets 0..[kGuitarMaxFret]).
int? guitarFret(int string, int midi) {
  if (string < 1 || string > kGuitarStrings) return null;
  final fret = midi - kGuitarOpenMidi[string - 1];
  return fret < 0 || fret > kGuitarMaxFret ? null : fret;
}

/// Whether [midi] can sound on [string].
bool guitarPlayable(int string, int midi) => guitarFret(string, midi) != null;
