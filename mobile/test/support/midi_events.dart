// Raw note-on reader for the single-track files `buildMidi` writes (every
// event carries its status byte). Keeps every event, duplicates included.
import 'dart:typed_data';

typedef MidiOn = ({int tick, int channel, int pitch, int velocity});

({int tpq, List<MidiOn> ons}) readNoteOns(Uint8List b) {
  final tpq = (b[12] << 8) | b[13];
  var i = 22; // header (14) + "MTrk" + length (8)
  var tick = 0;
  int vlq() {
    var v = 0;
    while (true) {
      final c = b[i++];
      v = (v << 7) | (c & 0x7f);
      if (c & 0x80 == 0) return v;
    }
  }

  final ons = <MidiOn>[];
  while (i < b.length) {
    tick += vlq();
    final status = b[i++];
    if (status == 0xFF) {
      i++; // type
      final len = vlq();
      i += len;
      continue;
    }
    final kind = status & 0xF0;
    if (kind == 0xC0 || kind == 0xD0) {
      i += 1;
      continue;
    }
    final a = b[i++], v = b[i++];
    if (kind == 0x90 && v > 0) {
      ons.add((tick: tick, channel: status & 0x0F, pitch: a, velocity: v));
    }
  }
  return (tpq: tpq, ons: ons);
}
