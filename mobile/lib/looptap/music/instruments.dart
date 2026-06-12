// Instrument catalog — curated General MIDI programs for the melody & bass
// tracks (all present in the bundled assets/sounds/TimGM6mb.sf2). The chosen
// program is stored per-song (Song.instruments) and drives both live playback
// (LoopAudio.setPrograms) and MIDI export (midi_export buildMidi).
//
// Beyond the bundled GM set + 808 / hip-hop sentinels, a track's program can be
// a runtime-catalog slot (>= 1000, see soundfont_catalog.dart) downloaded on
// demand. Labels for those resolve via the catalog in [instrumentLabel].
import 'soundfont_catalog.dart';
class InstrumentDef {
  const InstrumentDef(this.id, this.label, this.program);
  final String id;
  final String label;
  final int program; // GM program (0–127) or kProgram808 sentinel
}

class InstrumentCategory {
  const InstrumentCategory(this.label, this.instruments);
  final String label;
  final List<InstrumentDef> instruments;
}

/// Sentinel "program" for the synthetic 808 sub-bass — it has no GM slot, so it
/// routes to a second soundfont (assets/sounds/808.sf2) in live playback and is
/// rendered separately for WAV export. Out of GM range (0–127) so it never
/// collides. Mirrors SynthEngine.program808. The plain .mid export falls back to
/// [kProgram808MidiFallback] since a Standard MIDI File can't carry a custom patch.
const int kProgram808 = 128;
const int kProgram808MidiFallback = 38; // GM Synth Bass 1 — nearest GM voice

/// Melody (pitched lead / keys) — the FULL General MIDI set (128 programs) that
/// ships in assets/sounds/TimGM6mb.sf2. Labels mirror the bundled font's own
/// preset names so what you read matches what you hear. The picker scrolls.
const List<InstrumentDef> kMelodyInstruments = [
  InstrumentDef('gm_0', 'Piano 1', 0),
  InstrumentDef('gm_1', 'Piano 2', 1),
  InstrumentDef('gm_2', 'Piano 3', 2),
  InstrumentDef('gm_3', 'Honky Tonk', 3),
  InstrumentDef('gm_4', 'E.Piano 1', 4),
  InstrumentDef('gm_5', 'E.Piano 2', 5),
  InstrumentDef('gm_6', 'Harpsichord', 6),
  InstrumentDef('gm_7', 'Clavinet', 7),
  InstrumentDef('gm_8', 'Celesta', 8),
  InstrumentDef('gm_9', 'Glockenspiel', 9),
  InstrumentDef('gm_10', 'MusicBox', 10),
  InstrumentDef('gm_11', 'Vibraphone', 11),
  InstrumentDef('gm_12', 'Marimba', 12),
  InstrumentDef('gm_13', 'Xylophone', 13),
  InstrumentDef('gm_14', 'Tubular Bells', 14),
  InstrumentDef('gm_15', 'Dulcimer', 15),
  InstrumentDef('gm_16', 'Organ 1', 16),
  InstrumentDef('gm_17', 'Organ 2', 17),
  InstrumentDef('gm_18', 'Organ 3', 18),
  InstrumentDef('gm_19', 'Church Organ', 19),
  InstrumentDef('gm_20', 'Reed Organ', 20),
  InstrumentDef('gm_21', 'Accordion', 21),
  InstrumentDef('gm_22', 'Harmonica', 22),
  InstrumentDef('gm_23', 'Bandoneon', 23),
  InstrumentDef('gm_24', 'Nylon Guitar', 24),
  InstrumentDef('gm_25', 'Steel Guitar', 25),
  InstrumentDef('gm_26', 'Jazz Guitar', 26),
  InstrumentDef('gm_27', 'Clean Guitar', 27),
  InstrumentDef('gm_28', 'Guitar Mutes', 28),
  InstrumentDef('gm_29', 'Overdrive Guitar', 29),
  InstrumentDef('gm_30', 'Distortion Guitar', 30),
  InstrumentDef('gm_31', 'Guitar Harmonics', 31),
  InstrumentDef('gm_32', 'Acoustic Bass', 32),
  InstrumentDef('gm_33', 'Fingered Bass', 33),
  InstrumentDef('gm_34', 'Picked Bass', 34),
  InstrumentDef('gm_35', 'Fretless Bass', 35),
  InstrumentDef('gm_36', 'Slap Bass 1', 36),
  InstrumentDef('gm_37', 'Slap Bass 2', 37),
  InstrumentDef('gm_38', 'Synth Bass 1', 38),
  InstrumentDef('gm_39', 'Synth Bass 2', 39),
  InstrumentDef('gm_40', 'Violin', 40),
  InstrumentDef('gm_41', 'Viola', 41),
  InstrumentDef('gm_42', 'Cello', 42),
  InstrumentDef('gm_43', 'Contrabass', 43),
  InstrumentDef('gm_44', 'Strings (Tremolo)', 44),
  InstrumentDef('gm_45', 'Pizzicato', 45),
  InstrumentDef('gm_46', 'Harp', 46),
  InstrumentDef('gm_47', 'Timpani', 47),
  InstrumentDef('gm_48', 'Strings', 48),
  InstrumentDef('gm_49', 'Slow Strings', 49),
  InstrumentDef('gm_50', 'Synth Strings 1', 50),
  InstrumentDef('gm_51', 'Synth Strings 2', 51),
  InstrumentDef('gm_52', 'Choir Aahs', 52),
  InstrumentDef('gm_53', 'Voice Oohs', 53),
  InstrumentDef('gm_54', 'Synth Vox', 54),
  InstrumentDef('gm_55', 'Orchestra Hit', 55),
  InstrumentDef('gm_56', 'Trumpet', 56),
  InstrumentDef('gm_57', 'Trombone', 57),
  InstrumentDef('gm_58', 'Tuba', 58),
  InstrumentDef('gm_59', 'Mute Trumpet', 59),
  InstrumentDef('gm_60', 'French Horns', 60),
  InstrumentDef('gm_61', 'Brass', 61),
  InstrumentDef('gm_62', 'Synth Brass 1', 62),
  InstrumentDef('gm_63', 'Synth Brass 2', 63),
  InstrumentDef('gm_64', 'Soprano Sax', 64),
  InstrumentDef('gm_65', 'Alto Sax', 65),
  InstrumentDef('gm_66', 'Tenor Sax', 66),
  InstrumentDef('gm_67', 'Bari Sax', 67),
  InstrumentDef('gm_68', 'Oboe', 68),
  InstrumentDef('gm_69', 'English Horn', 69),
  InstrumentDef('gm_70', 'Bassoon', 70),
  InstrumentDef('gm_71', 'Clarinet', 71),
  InstrumentDef('gm_72', 'Piccolo', 72),
  InstrumentDef('gm_73', 'Flute', 73),
  InstrumentDef('gm_74', 'Recorder', 74),
  InstrumentDef('gm_75', 'Pan Flute', 75),
  InstrumentDef('gm_76', 'Bottle Chiff', 76),
  InstrumentDef('gm_77', 'Shakuhachi', 77),
  InstrumentDef('gm_78', 'Whistle', 78),
  InstrumentDef('gm_79', 'Ocarina', 79),
  InstrumentDef('gm_80', 'Square Lead', 80),
  InstrumentDef('gm_81', 'Saw Lead', 81),
  InstrumentDef('gm_82', 'Synth Calliope', 82),
  InstrumentDef('gm_83', 'Chiffer Lead', 83),
  InstrumentDef('gm_84', 'Charang', 84),
  InstrumentDef('gm_85', 'Solo Vox', 85),
  InstrumentDef('gm_86', '5th Saw Wave', 86),
  InstrumentDef('gm_87', 'Bass & Lead', 87),
  InstrumentDef('gm_88', 'Fantasia', 88),
  InstrumentDef('gm_89', 'Warm Pad', 89),
  InstrumentDef('gm_90', 'Poly Synth', 90),
  InstrumentDef('gm_91', 'Space Voice', 91),
  InstrumentDef('gm_92', 'Bowed Glass', 92),
  InstrumentDef('gm_93', 'Metal Pad', 93),
  InstrumentDef('gm_94', 'Halo Pad', 94),
  InstrumentDef('gm_95', 'Sweep Pad', 95),
  InstrumentDef('gm_96', 'Ice Rain', 96),
  InstrumentDef('gm_97', 'Soundtrack', 97),
  InstrumentDef('gm_98', 'Crystal', 98),
  InstrumentDef('gm_99', 'Atmosphere', 99),
  InstrumentDef('gm_100', 'Brightness', 100),
  InstrumentDef('gm_101', 'Goblin', 101),
  InstrumentDef('gm_102', 'Echo Drops', 102),
  InstrumentDef('gm_103', 'Star Theme', 103),
  InstrumentDef('gm_104', 'Sitar', 104),
  InstrumentDef('gm_105', 'Banjo', 105),
  InstrumentDef('gm_106', 'Shamisen', 106),
  InstrumentDef('gm_107', 'Koto', 107),
  InstrumentDef('gm_108', 'Kalimba', 108),
  InstrumentDef('gm_109', 'Bagpipe', 109),
  InstrumentDef('gm_110', 'Fiddle', 110),
  InstrumentDef('gm_111', 'Shenai', 111),
  InstrumentDef('gm_112', 'Tinker Bell', 112),
  InstrumentDef('gm_113', 'Agogo', 113),
  InstrumentDef('gm_114', 'Steel Drum', 114),
  InstrumentDef('gm_115', 'Wood Block', 115),
  InstrumentDef('gm_116', 'Taiko Drum', 116),
  InstrumentDef('gm_117', 'Melodic Tom', 117),
  InstrumentDef('gm_118', 'Synth Drum', 118),
  InstrumentDef('gm_119', 'Reverse Cymbal', 119),
  InstrumentDef('gm_120', 'Fret Noise', 120),
  InstrumentDef('gm_121', 'Breath Noise', 121),
  InstrumentDef('gm_122', 'Seashore', 122),
  InstrumentDef('gm_123', 'Bird', 123),
  InstrumentDef('gm_124', 'Telephone', 124),
  InstrumentDef('gm_125', 'Helicopter', 125),
  InstrumentDef('gm_126', 'Applause', 126),
  InstrumentDef('gm_127', 'Gun Shot', 127),
];

/// Bass — 8 voices.
const List<InstrumentDef> kBassInstruments = [
  InstrumentDef('acoustic_bass', 'Acoustic Bass', 32),
  InstrumentDef('fingered_bass', 'Fingered Bass', 33),
  InstrumentDef('picked_bass', 'Picked Bass', 34),
  InstrumentDef('fretless_bass', 'Fretless Bass', 35),
  InstrumentDef('slap_bass', 'Slap Bass', 36),
  InstrumentDef('synth_bass', 'Synth Bass', 38),
  InstrumentDef('sub_bass', 'Sub Bass', 39), // round GM sub (Synth Bass 2)
  // Real 808 sub-bass (CC0 sample, in C). Routes to assets/sounds/808.sf2.
  InstrumentDef('eight08', '808', kProgram808),
];

/// Sentinel "drum kit" that routes the drum channel to a bundled CC0 soundfont
/// (assets/sounds/hiphop_kit.sf2) instead of a GM bank-128 kit in TimGM6mb.
/// Out of GM range (0–127) so it never collides; mirrors SynthEngine.kitHipHop.
const int kProgramHipHopKit = 200;
const int kProgramHipHopKitMidiFallback =
    25; // GM "TR-808" kit — nearest .mid voice

/// Drum kits: the 8 GM kits present in TimGM6mb (bank 128) + the CC0 hip-hop kit.
/// Reuses InstrumentDef (program = GM kit number, or the hip-hop sentinel).
const List<InstrumentDef> kDrumKits = [
  InstrumentDef('kit_standard', 'Standard', 0),
  InstrumentDef('kit_room', 'Room', 8),
  InstrumentDef('kit_power', 'Power', 16),
  InstrumentDef('kit_electronic', 'Electronic', 24),
  InstrumentDef('kit_tr808', 'TR-808', 25),
  InstrumentDef('kit_jazz', 'Jazz', 32),
  InstrumentDef('kit_brush', 'Brush', 40),
  InstrumentDef('kit_orchestra', 'Orchestra', 48),
  InstrumentDef('kit_hiphop', 'Hip-Hop', kProgramHipHopKit),
];

/// Default GM program per track (matches the original hard-coded sound).
const int kDefaultMelodyProgram = 0; // Grand Piano
const int kDefaultBassProgram = 33; // Fingered Bass
const int kDefaultDrumKit = 0; // Standard

List<InstrumentDef> _gmRange(int start, int end) => kMelodyInstruments
    .where((i) => i.program >= start && i.program <= end)
    .toList(growable: false);

InstrumentDef _gm(int program) =>
    kMelodyInstruments.firstWhere((i) => i.program == program);

final List<InstrumentCategory> kMelodyInstrumentCategories = [
  InstrumentCategory('Recommended', [
    _gm(0),
    _gm(4),
    _gm(24),
    _gm(27),
    _gm(33),
    _gm(40),
    _gm(48),
    _gm(56),
    _gm(65),
    _gm(73),
    _gm(80),
    _gm(81),
    _gm(88),
    _gm(90),
  ]),
  InstrumentCategory('Piano & Keys', _gmRange(0, 7)),
  InstrumentCategory('Bells & Mallets', _gmRange(8, 15)),
  InstrumentCategory('Organs & Reeds', _gmRange(16, 23)),
  InstrumentCategory('Guitars', _gmRange(24, 31)),
  InstrumentCategory('Bass', _gmRange(32, 39)),
  InstrumentCategory('Strings & Orchestra', _gmRange(40, 55)),
  InstrumentCategory('Brass', _gmRange(56, 63)),
  InstrumentCategory('Woodwinds', _gmRange(64, 79)),
  InstrumentCategory('Leads', _gmRange(80, 87)),
  InstrumentCategory('Pads & Textures', _gmRange(88, 103)),
  InstrumentCategory('World', _gmRange(104, 111)),
  InstrumentCategory('Percussion & SFX', _gmRange(112, 127)),
];

final List<InstrumentCategory> kBassInstrumentCategories = [
  InstrumentCategory('Bass Essentials', kBassInstruments),
  InstrumentCategory('Deep Alternatives', [
    _gm(32),
    _gm(33),
    _gm(34),
    _gm(35),
    _gm(36),
    _gm(37),
    _gm(38),
    _gm(39),
    _gm(43),
    _gm(58),
    _gm(70),
    _gm(87),
  ]),
  InstrumentCategory('All GM Sounds', kMelodyInstruments),
];

final List<InstrumentCategory> kDrumKitCategories = [
  InstrumentCategory('Studio Kits', [
    kDrumKits[0],
    kDrumKits[1],
    kDrumKits[2],
    kDrumKits[5],
  ]),
  InstrumentCategory('Electronic', [kDrumKits[3], kDrumKits[4], kDrumKits[8]]),
  InstrumentCategory('Specialty', [kDrumKits[6], kDrumKits[7]]),
];

/// The selectable sounds for a track id: bass voices for 'bass', drum kits for
/// the percussion tracks, the full GM list otherwise (melody / melody-fill).
List<InstrumentDef> instrumentsForTrack(String trackId) {
  final seen = <int>{};
  return [
    for (final group in instrumentCategoriesForTrack(trackId))
      for (final inst in group.instruments)
        if (seen.add(inst.program)) inst,
  ];
}

List<InstrumentCategory> instrumentCategoriesForTrack(String trackId) {
  if (trackId == 'bass') return kBassInstrumentCategories;
  if (trackId == 'drums' || trackId == 'beatDec') return kDrumKitCategories;
  return kMelodyInstrumentCategories;
}

String instrumentFavoriteKeyForTrack(String trackId) {
  if (trackId == 'bass') return 'bass';
  if (trackId == 'drums' || trackId == 'beatDec') return 'drums';
  return 'melody';
}

/// Display label for the currently-selected program on a track (fallback to the
/// track's first instrument if the stored program isn't in the catalog).
String instrumentLabel(String trackId, int program) {
  if (isDynamicSlot(program)) {
    final e = SoundfontCatalog.instance.bySlot(program);
    if (e != null) return e.label;
    // slot no longer in the catalog (removed / not yet refreshed) → show the
    // track default rather than a misleading GM name.
    return instrumentsForTrack(trackId).first.label;
  }
  final list = instrumentsForTrack(trackId);
  for (final i in list) {
    if (i.program == program) return i.label;
  }
  return list.first.label;
}
