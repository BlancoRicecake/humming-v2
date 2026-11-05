// Full channel-event reader for the single-track files `buildMidi` writes
// (every event carries its status byte): note on/off, control and program
// changes, in file order. gt-003 isolation tests use it as a per-channel
// event log.
import 'dart:typed_data';

typedef MidiEvent = ({int tick, int kind, int channel, int a, int b});

/// Kinds: 0x80 note off, 0x90 note on (velocity 0 = off), 0xB0 control,
/// 0xC0 program (b = 0).
({int tpq, List<MidiEvent> events}) readMidiEvents(Uint8List bytes) {
  final tpq = (bytes[12] << 8) | bytes[13];
  var i = 22;
  var tick = 0;
  int vlq() {
    var v = 0;
    while (true) {
      final c = bytes[i++];
      v = (v << 7) | (c & 0x7f);
      if (c & 0x80 == 0) return v;
    }
  }

  final out = <MidiEvent>[];
  while (i < bytes.length) {
    tick += vlq();
    final status = bytes[i++];
    if (status == 0xFF) {
      i++;
      final len = vlq();
      i += len;
      continue;
    }
    final kind = status & 0xF0, ch = status & 0x0F;
    if (kind == 0xC0 || kind == 0xD0) {
      out.add((tick: tick, kind: kind, channel: ch, a: bytes[i++], b: 0));
      continue;
    }
    final a = bytes[i++], b = bytes[i++];
    out.add((tick: tick, kind: kind, channel: ch, a: a, b: b));
  }
  return (tpq: tpq, events: out);
}

/// Notes (on → matching off) of [events]: channel, key, velocity and the
/// on/off ticks.
List<({int channel, int key, int velocity, int on, int off})> midiNotes(
  List<MidiEvent> events,
) {
  final open = <int, List<({int on, int velocity})>>{};
  final out = <({int channel, int key, int velocity, int on, int off})>[];
  for (final e in events) {
    final k = e.channel << 8 | e.a;
    if (e.kind == 0x90 && e.b > 0) {
      (open[k] ??= []).add((on: e.tick, velocity: e.b));
    } else if (e.kind == 0x80 || (e.kind == 0x90 && e.b == 0)) {
      final list = open[k];
      if (list == null || list.isEmpty) continue;
      final o = list.removeAt(0);
      out.add((
        channel: e.channel,
        key: e.a,
        velocity: o.velocity,
        on: o.on,
        off: e.tick,
      ));
    }
  }
  out.sort((x, y) => x.on != y.on ? x.on.compareTo(y.on) : x.key - y.key);
  return out;
}
