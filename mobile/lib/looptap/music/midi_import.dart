import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../models/loop_models.dart';
import 'instruments.dart';
import 'percussion.dart';
import 'theory.dart';

/// SMF inspection is separate from conversion: no unsupported part is silently
/// dropped, and a user can choose a short passage before creating a new song.
class ReferenceNote {
  ReferenceNote(
    this.track,
    this.channel,
    this.program,
    this.pitch,
    this.velocity,
    this.tick,
    this.endTick,
  );
  final int track, channel, program, pitch, velocity, tick;
  int endTick;
}

class ReferenceLane {
  ReferenceLane(this.id, this.name, this.channel, this.program, this.notes);
  final String id, name;
  final int channel, program;
  final List<ReferenceNote> notes;
  bool get drums => channel == 9;
}

class MidiReference {
  MidiReference._(
    this.ppq,
    this.bpm,
    this.lanes,
    this.warnings,
    this.lastTick,
    this.constantTempo,
    this.fourFour,
  );
  final int ppq;
  final double bpm;
  final List<ReferenceLane> lanes;
  final List<String> warnings;
  final int lastTick;
  final bool constantTempo, fourFour;
  int get noteCount => lanes.fold(0, (n, l) => n + l.notes.length);
  int get bars => math.max(1, (lastTick / ppq / 4).ceil());
  int get firstNoteBar =>
      lanes.isEmpty
          ? 1
          : lanes.expand((l) => l.notes).map((n) => n.tick).reduce(math.min) ~/
                  (ppq * 4) +
              1;

  /// 4/4, constant-tempo passages only. Explicit limits prevent channel aliasing.
  /// Notes cut by the selected window are trimmed at its edges, never stretched.
  Song passage({
    required String title,
    required int startBar,
    required int lengthBars,
    Set<String>? selectedLanes,
  }) {
    if (!constantTempo || !fourFour) {
      throw const FormatException(
        'This MIDI needs tempo/time-signature map support.',
      );
    }
    if (bpm < 40 || bpm > 240 || (bpm - bpm.round()).abs() > 0.001) {
      throw const FormatException(
        'This MIDI needs fractional or extended tempo support.',
      );
    }
    if (startBar < 1 || startBar > bars || lengthBars < 1 || lengthBars > 8) {
      throw const FormatException('Choose a valid passage of 1–8 bars.');
    }
    final start = (startBar - 1) * ppq * 4;
    final end = start + lengthBars * ppq * 4;
    final active =
        lanes
            .where(
              (l) =>
                  (selectedLanes == null || selectedLanes.contains(l.id)) &&
                  l.notes.any((n) => n.tick < end && n.endTick > start),
            )
            .toList();
    if (active.isEmpty) {
      throw const FormatException('No notes in this passage.');
    }
    final pitched = active.where((l) => !l.drums).length;
    final drums = active.length - pitched;
    final extrasNeeded = math.max(0, pitched - 3) + math.max(0, drums - 2);
    if (extrasNeeded > kExtraPitchChannels.length) {
      throw FormatException(
        '$pitched pitched + $drums drum lanes exceed the independent '
        'instrument limit. Choose fewer lanes or a shorter passage.',
      );
    }
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final section = Section(
      id: 'midi_$stamp',
      name: '$startBar–${startBar + lengthBars - 1}',
      autoName: false,
      bars: lengthBars,
    );
    final programs = <String, int>{};
    final volumes = <String, double>{};
    var pi = 0, di = 0;
    for (final lane in active) {
      String id;
      if (lane.drums && di < 2) {
        id = ['drums', 'beatDec'][di++];
      } else if (!lane.drums && pi < 3) {
        // Import roles do not restrict pitch: all three voices use chromatic
        // mode. Original instrument labels remain visible on each lane.
        id = ['melody', 'melodyDec', 'bass'][pi++];
      } else {
        id = 'midi_lane_${section.extras.length}';
        section.extras.add(TrackRef(id, lane.drums ? 'drums' : 'melody'));
      }
      final data = TrackData(label: lane.name);
      for (final n in lane.notes.where(
        (n) => n.tick < end && n.endTick > start,
      )) {
        final position = (math.max(n.tick, start) - start) * 4 / ppq;
        final duration =
            (math.min(n.endTick, end) - math.max(n.tick, start)) * 4 / ppq;
        final step = position.floor();
        if (lane.drums) {
          data.drumNotes.add(
            DrumNote(
              kind: percussionKind(n.pitch),
              step: step,
              velocity: n.velocity,
              offsetSteps: position - step,
              durationSteps: duration,
            ),
          );
        } else {
          data.pitchNotes.add(
            PitchNote(
              midi: n.pitch,
              freq: midiToFreq(n.pitch),
              step: step,
              dur: math.max(1, duration.ceil()),
              velocity: n.velocity,
              offsetSteps: position - step,
              durationSteps: duration,
            ),
          );
        }
      }
      if (lane.drums) {
        data.drumKinds = data.drumNotes.map((n) => n.kind).toSet().toList();
      }
      section.tracks[id] = data;
      programs[id] = lane.program;
      volumes[id] = 1;
    }
    return Song(
      id: 'lt_midi_$stamp',
      title: title,
      key: 'C',
      scale: 'chromatic',
      bpm: bpm.round(),
      bars: lengthBars,
      sections: [section],
      instruments: programs,
      vol: volumes,
      generationLocks: {},
      updatedAt: DateTime.now(),
    );
  }

  static MidiReference parse(Uint8List bytes) {
    if (bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('MIDI exceeds 8 MB.');
    }
    final r = _Reader(bytes);
    if (r.text(4) != 'MThd') {
      throw const FormatException('Choose a Standard MIDI (.mid) file.');
    }
    final headerSize = r.u32();
    if (headerSize < 6 || headerSize > bytes.length - 8) {
      throw const FormatException('Invalid MIDI header.');
    }
    final format = r.u16(), trackCount = r.u16(), ppq = r.u16();
    if (format > 1 ||
        trackCount < 1 ||
        trackCount > 256 ||
        ppq == 0 ||
        (ppq & 0x8000) != 0) {
      throw const FormatException(
        'Only MIDI format 0/1 with PPQ timing is supported.',
      );
    }
    r.skip(headerSize - 6);
    final events = <_MidiEvent>[];
    final names = <int, String>{};
    for (var track = 0; track < trackCount; track++) {
      if (r.text(4) != 'MTrk') {
        throw const FormatException('Missing MIDI track.');
      }
      final size = r.u32();
      final end = r.pos + size;
      if (end > bytes.length) {
        throw const FormatException('Truncated MIDI track.');
      }
      final tr = _Reader(Uint8List.sublistView(bytes, r.pos, end));
      r.pos = end;
      var tick = 0, running = 0;
      while (tr.pos < tr.bytes.length) {
        tick += tr.vlq();
        var status = tr.u8();
        if (status < 0x80) {
          if (running == 0) {
            throw const FormatException('Invalid running status.');
          }
          tr.pos--;
          status = running;
        }
        if (status == 0xff) {
          running = 0;
          final type = tr.u8(), count = tr.vlq();
          final data = tr.take(count);
          if (type == 3) {
            names[track] = utf8.decode(data, allowMalformed: true).trim();
          }
          if (type == 0x51 && count == 3) {
            events.add(
              _MidiEvent(
                tick,
                track,
                0xff,
                type,
                (data[0] << 16) | (data[1] << 8) | data[2],
              ),
            );
          }
          if (type == 0x58 && count >= 2) {
            events.add(
              _MidiEvent(tick, track, 0xff, type, (data[0] << 8) | data[1]),
            );
          }
          if (type == 0x2f) break;
        } else if (status == 0xf0 || status == 0xf7) {
          running = 0;
          tr.skip(tr.vlq());
          events.add(_MidiEvent(tick, track, 0xf0, 0, 0));
        } else {
          if (status < 0x80 || status >= 0xf0) {
            throw const FormatException('Unsupported MIDI status.');
          }
          running = status;
          final a = tr.u8();
          final b = status & 0xe0 == 0xc0 ? 0 : tr.u8();
          if (a > 127 || b > 127) {
            throw const FormatException('Invalid MIDI data byte.');
          }
          events.add(_MidiEvent(tick, track, status, a, b));
        }
        if (events.length > 250000) {
          throw const FormatException('MIDI contains too many events.');
        }
      }
    }
    final indexed =
        events.asMap().entries.toList()..sort(
          (a, b) =>
              a.value.tick.compareTo(b.value.tick) != 0
                  ? a.value.tick.compareTo(b.value.tick)
                  : a.key.compareTo(b.key),
        );
    final programs = List<int>.filled(16, 0);
    final held = <int, Queue<ReferenceNote>>{};
    final notes = <ReferenceNote>[];
    final controllers = <int>{};
    final tempos = <int>{};
    var fourFour = true,
        lastTick = 0,
        dangling = 0,
        pitchBend = false,
        sysex = false;
    for (final item in indexed) {
      final e = item.value;
      lastTick = math.max(lastTick, e.tick);
      if (e.status == 0xff) {
        if (e.a == 0x51 && e.b > 0) tempos.add(e.b);
        if (e.a == 0x58 && e.b != 0x0402) fourFour = false;
        continue;
      }
      if (e.status == 0xf0) {
        sysex = true;
        continue;
      }
      final ch = e.status & 15, type = e.status & 0xf0;
      if (type == 0xc0) programs[ch] = e.a;
      if (type == 0xb0) controllers.add(e.a);
      if (type == 0xe0 && (e.a != 0 || e.b != 64)) pitchBend = true;
      final key = ch * 128 + e.a;
      if (type == 0x90 && e.b > 0) {
        final n = ReferenceNote(
          e.track,
          ch,
          programs[ch],
          e.a,
          e.b,
          e.tick,
          e.tick + 1,
        );
        notes.add(n);
        (held[key] ??= Queue()).add(n);
      } else if (type == 0x80 || (type == 0x90 && e.b == 0)) {
        final q = held[key];
        if (q != null && q.isNotEmpty) {
          final n = q.removeFirst();
          n.endTick = math.max(n.tick + 1, e.tick);
        }
      }
    }
    for (final q in held.values) {
      for (final n in q) {
        n.endTick = math.max(n.tick + 1, lastTick);
        dangling++;
      }
    }
    if (notes.isEmpty) {
      throw const FormatException('This MIDI contains no notes.');
    }
    final grouped = <String, List<ReferenceNote>>{};
    for (final n in notes) {
      (grouped['${n.track}:${n.channel}:${n.program}'] ??= []).add(n);
    }
    final lanes = <ReferenceLane>[];
    for (final g in grouped.entries) {
      final n = g.value.first;
      final instrument =
          n.channel == 9 ? 'Drums' : kMelodyInstruments[n.program].label;
      final name = names[n.track];
      lanes.add(
        ReferenceLane(
          g.key,
          '${name == null || name.isEmpty || name == "untitled" ? instrument : name} · ${n.channel + 1}',
          n.channel,
          n.program,
          g.value,
        ),
      );
    }
    final warnings = <String>[
      if (controllers.isNotEmpty)
        'Controller automation is not applied (${(controllers.toList()..sort()).join(", ")}).',
      if (pitchBend) 'Pitch bend is not applied.',
      if (sysex)
        'Vendor-specific SysEx and bank changes are not applied; instruments use GM substitutes.',
      if (dangling > 0)
        '$dangling notes without note-off were closed at the file end.',
      if (tempos.length > 1) 'Variable tempo is inspection-only.',
      if (!fourFour) 'Non-4/4 time signatures are inspection-only.',
    ];
    return MidiReference._(
      ppq,
      60000000 / (tempos.isEmpty ? 500000 : tempos.first),
      lanes,
      warnings,
      lastTick,
      tempos.length <= 1,
      fourFour,
    );
  }
}

class _MidiEvent {
  _MidiEvent(this.tick, this.track, this.status, this.a, this.b);
  final int tick, track, status, a, b;
}

class _Reader {
  _Reader(this.bytes);
  final Uint8List bytes;
  int pos = 0;
  int u8() {
    if (pos >= bytes.length) throw const FormatException('Truncated MIDI.');
    return bytes[pos++];
  }

  int u16() => (u8() << 8) | u8();
  int u32() => (u16() << 16) | u16();
  int vlq() {
    var result = 0;
    for (var i = 0; i < 4; i++) {
      final b = u8();
      result = (result << 7) | (b & 127);
      if (b < 128) return result;
    }
    throw const FormatException('Invalid MIDI variable-length quantity.');
  }

  void skip(int n) {
    take(n);
  }

  Uint8List take(int n) {
    if (n < 0 || pos + n > bytes.length) {
      throw const FormatException('Truncated MIDI chunk.');
    }
    final data = Uint8List.sublistView(bytes, pos, pos + n);
    pos += n;
    return data;
  }

  String text(int n) => latin1.decode(take(n));
}
