/// Stable pad names plus a lossless escape for all other MIDI percussion keys.
const Map<String, int> kPercussionMidi = {
  'kick': 36,
  'snare': 38,
  'hihat': 42,
  'shaker': 82,
  'tambourine': 54,
  'clap': 39,
  'cowbell': 56,
  'maracas': 70,
  'claves': 75,
  'rimshot': 37,
  'woodhi': 76,
  'woodlo': 77,
  'ride': 51,
  'crash': 57,
  'triangle': 81,
};

int? percussionMidi(String kind) {
  final known = kPercussionMidi[kind];
  if (known != null) return known;
  if (!kind.startsWith('midi_')) return null;
  final midi = int.tryParse(kind.substring(5));
  return midi != null && midi >= 0 && midi <= 127 ? midi : null;
}

String percussionKind(int midi) {
  for (final e in kPercussionMidi.entries) {
    if (e.value == midi) return e.key;
  }
  return 'midi_$midi';
}

/// Null means the existing pad gain curve, preserving old songs verbatim.
int noteVelocity(int? velocity, double volume) =>
    velocity == null
        ? (volume.clamp(0.0, 1.0) * 110 + 12).round().clamp(1, 127)
        : (velocity * volume.clamp(0.0, 1.0)).round().clamp(0, 127);
