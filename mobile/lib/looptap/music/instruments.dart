// Instrument catalog — curated General MIDI programs for the melody & bass
// tracks (all present in the bundled assets/sounds/TimGM6mb.sf2). The chosen
// program is stored per-song (Song.instruments) and drives both live playback
// (LoopAudio.setPrograms) and MIDI export (midi_export buildMidi).
class InstrumentDef {
  const InstrumentDef(this.id, this.label, this.program);
  final String id;
  final String label;
  final int program; // GM program number (0–127)
}

/// Melody (pitched lead / keys) — 8 voices.
const List<InstrumentDef> kMelodyInstruments = [
  InstrumentDef('grand_piano', 'Grand Piano', 0),
  InstrumentDef('electric_piano', 'Electric Piano', 4),
  InstrumentDef('vibraphone', 'Vibraphone', 11),
  InstrumentDef('organ', 'Organ', 16),
  InstrumentDef('nylon_guitar', 'Nylon Guitar', 24),
  InstrumentDef('strings', 'Strings', 48),
  InstrumentDef('flute', 'Flute', 73),
  InstrumentDef('synth_lead', 'Synth Lead', 81),
];

/// Bass — 6 voices.
const List<InstrumentDef> kBassInstruments = [
  InstrumentDef('acoustic_bass', 'Acoustic Bass', 32),
  InstrumentDef('fingered_bass', 'Fingered Bass', 33),
  InstrumentDef('picked_bass', 'Picked Bass', 34),
  InstrumentDef('fretless_bass', 'Fretless Bass', 35),
  InstrumentDef('slap_bass', 'Slap Bass', 36),
  InstrumentDef('synth_bass', 'Synth Bass', 38),
];

/// Default GM program per track (matches the original hard-coded sound).
const int kDefaultMelodyProgram = 0; // Grand Piano
const int kDefaultBassProgram = 33; // Fingered Bass

/// The selectable instruments for a given track id ('melody' | 'bass').
List<InstrumentDef> instrumentsForTrack(String trackId) =>
    trackId == 'bass' ? kBassInstruments : kMelodyInstruments;

/// Display label for the currently-selected program on a track (fallback to the
/// track's first instrument if the stored program isn't in the catalog).
String instrumentLabel(String trackId, int program) {
  final list = instrumentsForTrack(trackId);
  for (final i in list) {
    if (i.program == program) return i.label;
  }
  return list.first.label;
}
