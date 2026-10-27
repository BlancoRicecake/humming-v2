// HumTrack song v2 (artifacts/song-arrangement-v2-20261023/design.md):
// checks and renders for the arrangement in song_v2_arrangement.dart.
//
// ALWAYS: builds the plain and the processed song with the real models and
// guitar tools and checks form (64 bars, section lengths, repeats ×1),
// ranges, monophony / no same-pitch overlaps, drum kinds (percussionMidi +
// the GM kit preset of the bundled GeneralUser-GS.sf2), the hook identity,
// rests before the chorus and at the final chorus end, no two 8-bar blocks
// identical per track, save → reload through LoopStorage (into a temporary
// directory), and that every section .mid parses with midi_import.dart.
// ONLY with HUMTRACK_V2_OUT set: writes song.json, the real exportWavSong
// mix, exportStems, exportMidiSong, the section .mid files, previews, the
// E.Piano vs flute comparison, measurements.json, arrangement.md, README.md.
//
// Regenerate (from mobile/):
//   TMP=<out>/temp TEMP=<out>/temp HUMTRACK_V2_OUT=<out> \
//     /c/src/flutter/bin/flutter test --no-pub test/looptap/song_v2_arrangement_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_melty_soundfont/soundfont.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/midi_import.dart';
import 'package:humming/looptap/music/percussion.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import 'song_v2_arrangement.dart';

const double _headroom = 0.94;
const double _lsb = 1 / 32767;
const String _gmSf2 = 'assets/sounds/GeneralUser-GS.sf2';

// Ranges (MIDI): lead E.Piano D4–B5, guitar = playable open-position range,
// bass E1–E3, counter strings D4–B4.
const (int, int) _leadRange = (60, 83);
const (int, int) _bassRange = (28, 52);
const (int, int) _counterRange = (60, 72);

void _expectMonophonic(List<PitchNote> ns, String what) {
  final l = [...ns]..sort((a, b) => a.startSteps.compareTo(b.startSteps));
  for (var i = 0; i + 1 < l.length; i++) {
    expect(l[i].endSteps, lessThanOrEqualTo(l[i + 1].startSteps + 1e-9), reason: what);
  }
}

/// No two notes of the same pitch sound at once.
void _expectNoSamePitchOverlap(List<PitchNote> ns, String what) {
  final byPitch = <int, List<PitchNote>>{};
  for (final n in ns) {
    (byPitch[n.midi] ??= []).add(n);
  }
  for (final e in byPitch.entries) {
    _expectMonophonic(e.value, '$what ${noteName(e.key)}');
  }
}

/// Per-bar signatures of every track over the flattened song.
Map<String, List<String>> _barSignatures(Song s) {
  final flat = flattenSong(s.sections);
  final bars = flat.steps ~/ 16;
  List<String> pitched(List<PitchNote> ns) {
    final out = List.generate(bars, (_) => <String>[]);
    for (final n in ns) {
      out[n.step ~/ 16].add('${n.midi}@${n.step % 16}+${n.offsetSteps.toStringAsFixed(3)}:${n.soundingSteps.toStringAsFixed(3)}:${n.velocity}');
    }
    return [for (final b in out) (b..sort()).join(',')];
  }

  final drums = List.generate(bars, (_) => <String>[]);
  for (final d in flat.drums) {
    drums[d.step ~/ 16].add('${d.kind}@${d.step % 16}+${d.offsetSteps.toStringAsFixed(3)}:${d.velocity}');
  }
  return {
    'guitar': pitched(flat.melody),
    'lead': pitched(flat.melodyDec),
    'bass': pitched(flat.bass),
    'counter': pitched(flat.extraPitched[v2CounterId] ?? const []),
    'drums': [for (final b in drums) (b..sort()).join(',')],
  };
}

/// Pairs of non-overlapping bar-aligned 8-bar windows with identical,
/// non-empty content, per track.
Map<String, List<(int, int)>> _identicalBlocks(Song s) {
  final out = <String, List<(int, int)>>{};
  for (final e in _barSignatures(s).entries) {
    final b = e.value;
    String w(int i) => b.sublist(i, i + 8).join('|');
    bool empty(int i) => b.sublist(i, i + 8).every((x) => x.isEmpty);
    final same = <(int, int)>[];
    for (var i = 0; i + 8 <= b.length; i++) {
      for (var j = i + 8; j + 8 <= b.length; j++) {
        if (!empty(i) && w(i) == w(j)) same.add((i + 1, j + 1));
      }
    }
    out[e.key] = same;
  }
  return out;
}

/// Distinct contents among the 16 bar-aligned 4-bar instances (the v1
/// baseline counted 5 distinct lead phrases; its drums used 3 instruments —
/// kick/snare/hihat — which is a kind count, not a pattern count).
Map<String, int> _distinct4BarInstances(Song s) => {
      for (final e in _barSignatures(s).entries)
        e.key: {for (var i = 0; i < 64; i += 4) e.value.sublist(i, i + 4).join('|')}.length,
    };

/// The GM standard kit (bank 128, preset 0) of the bundled GeneralUser-GS:
/// key → sample name of the first region that sounds it at velocity 100.
Map<int, String> _gmKitKeys(Iterable<int> keys) {
  final sf = SoundFont.fromByteData(ByteData.sublistView(File(_gmSf2).readAsBytesSync()));
  final kit = sf.presets.firstWhere((p) => p.bankNumber == 128 && p.patchNumber == 0);
  final out = <int, String>{};
  for (final k in keys) {
    for (final pr in kit.regions.where((r) => r.contains(k, 100))) {
      final ir = pr.instrument.regions.where((r) => r.contains(k, 100)).firstOrNull;
      if (ir != null) {
        out[k] = '${kit.name} / ${pr.instrument.name} / ${ir.sample.name}';
        break;
      }
    }
  }
  return out;
}

Map<String, dynamic> _semantic(Song s) {
  final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
  j.remove('updatedAt');
  return j;
}

/// Parse a section .mid with the app importer and compare every lane.
Song _checkImport(V2Part p, Uint8List bytes) {
  final ref = MidiReference.parse(bytes);
  expect(ref.constantTempo && ref.fourFour, isTrue, reason: p.name);
  expect((ref.bpm - v2Bpm).abs(), lessThan(.001));
  expect(ref.bars, p.bars, reason: p.name);
  expect(ref.warnings, isEmpty, reason: p.name);
  final song = ref.passage(title: p.name, startBar: 1, lengthBars: p.bars);
  expect(song.bpm, v2Bpm);
  final sec = song.sections.single;
  expect(sec.bars, p.bars);
  final lanes = sectionLanes(p);
  // importer rule: pitched lanes take melody, melodyDec, bass, then extras, in
  // order of their first note (ties: file order)
  final pitched = [
    for (final (i, l) in lanes.indexed)
      if (l.ch != 9) (i, l, l.notes.map((n) => n.$2).reduce(math.min)),
  ]..sort((a, b) => a.$3 != b.$3 ? a.$3.compareTo(b.$3) : a.$1.compareTo(b.$1));
  final expectIds = <String, String>{'Drums': 'drums'};
  for (final (k, (_, l, _)) in pitched.indexed) {
    expectIds[l.name] = k < 3 ? ['melody', 'melodyDec', 'bass'][k] : 'midi_lane_${k - 3}';
  }
  expect(sec.extras.length, math.max(0, pitched.length - 3), reason: p.name);
  for (final l in lanes) {
    final id = expectIds[l.name]!;
    final t = sec.tracks[id]!;
    expect(t.label, '${l.name} · ${l.ch + 1}', reason: '${p.name} ${l.name}');
    if (l.ch == 9) {
      final got = [
        for (final d in t.drumNotes) (d.kind, d.step, d.velocity, (d.offsetSteps * 24).round()),
      ]..sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
      final want = [for (final d in p.drums) (percussionKind(percussionMidi(d.kind)!), d.step, d.vel, d.tick)]
        ..sort((a, b) => a.$2 != b.$2 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1));
      expect(got, want, reason: '${p.name} drums');
      for (final d in t.drumNotes) {
        expect((d.offsetSteps * 24 - (d.offsetSteps * 24).round()).abs(), lessThan(1e-9));
      }
      continue;
    }
    final got = [for (final n in t.pitchNotes) (n.step * v2Tps, n.midi, n.dur * v2Tps, n.velocity)]
      ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    final want = [for (final (m, on, off, v) in l.notes) (on, m, off - on, v)]
      ..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    expect(got, want, reason: '${p.name} ${l.name}');
    for (final n in t.pitchNotes) {
      expect(n.offsetSteps, 0);
    }
    expect(song.instruments[id], l.program, reason: '${p.name} ${l.name} program');
  }
  return song;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HumTrack song v2', () {
    final built = buildV2Song(processed: true);
    final song = built.song;
    final plain = buildV2Song(processed: false).song;

    test('form: 64 bars, ten sections, every section ×1', () {
      expect([for (final s in song.sections) s.name],
          ['Intro', 'Verse 1', 'Lift', 'Chorus 1', 'Post', 'Verse 2', 'Bridge', 'Final Chorus A', 'Final Chorus B', 'Outro']);
      expect([for (final s in song.sections) s.bars], [4, 8, 4, 8, 4, 8, 8, 8, 8, 4]);
      expect(song.sections.every((s) => s.repeats == 1 && s.linkId == null), isTrue);
      expect(song.sections.fold(0, (n, s) => n + s.bars * s.repeats), 64);
      final flat = flattenSong(song.sections);
      expect(flat.steps, 1024);
      expect(flat.steps / 4 * 60 / v2Bpm, closeTo(149.126, .001));
      // one added track, present (empty or not) in every section
      for (final s in song.sections) {
        expect([for (final e in s.extras) '${e.id}:${e.type}'], ['$v2CounterId:melody']);
        expect(s.tracks.containsKey(v2CounterId), isTrue);
      }
    });

    test('shapes, ranges, bounds, monophony', () {
      const open = [40, 45, 50, 55, 59, 64];
      for (final e in v2Shapes.entries) {
        final (ms, frets) = e.value;
        expect([for (var i = 0; i < 6; i++) if (frets[i] != 'x') open[i] + int.parse(frets[i])], ms, reason: e.key);
      }
      for (final p in v2Parts) {
        for (final b in p.guitar) {
          for (final h in b.hits) {
            expect(v2Shapes.containsKey(h.$3), isTrue, reason: h.$3);
          }
        }
        expect(p.chords.length, p.bars, reason: p.name);
        bool inR(int m, (int, int) r) => m >= r.$1 && m <= r.$2;
        for (final n in p.lead) {
          expect(inR(n.midi, _leadRange), isTrue, reason: '${p.name} lead ${noteName(n.midi)}');
        }
        for (final n in p.bass) {
          expect(inR(n.midi, _bassRange), isTrue, reason: '${p.name} bass ${noteName(n.midi)}');
        }
        for (final n in p.counter) {
          expect(inR(n.midi, _counterRange), isTrue, reason: '${p.name} counter ${noteName(n.midi)}');
        }
        for (final n in [...p.lead, ...p.bass, ...p.counter, for (final g in guitarPlain(p)) fromPn(g)]) {
          expect(n.step, inInclusiveRange(0, p.steps - 1));
          expect(n.step + n.dur, lessThanOrEqualTo(p.steps));
          expect(n.vel, inInclusiveRange(1, 127));
        }
        _expectMonophonic([for (final n in p.lead) pn(n)], '${p.name} lead');
        _expectMonophonic([for (final n in p.bass) pn(n)], '${p.name} bass');
        _expectMonophonic([for (final n in p.counter) pn(n)], '${p.name} counter');
        // drums: inside the section, one hit per kind and cell, small late offsets only
        final seen = <String>{};
        for (final d in p.drums) {
          expect(d.step, inInclusiveRange(0, p.steps - 1));
          expect(seen.add('${d.kind}@${d.step}'), isTrue, reason: '${p.name} ${d.kind}@${d.step}');
          expect(d.tick, inInclusiveRange(0, 3));
        }
      }
      // the counter only plays in the two final choruses
      expect([for (final p in v2Parts) if (p.counter.isNotEmpty) p.id], ['finalA', 'finalB']);
    });

    test('drum kinds map via percussionMidi and exist in the GM standard kit', () {
      final kinds = {for (final p in v2Parts) for (final d in p.drums) d.kind};
      final midi = {for (final k in kinds) k: percussionMidi(k)};
      expect(midi.values.every((m) => m != null), isTrue, reason: '$midi');
      expect(percussionMidi('midi_46'), 46);
      expect(percussionMidi('crash'), 57);
      final kit = _gmKitKeys(midi.values.whereType<int>());
      for (final e in midi.entries) {
        expect(kit[e.value], isNotNull, reason: '${e.key} (${e.value}) missing from the GM kit');
      }
      debugPrint('[song-v2] kit: ${jsonEncode({for (final e in midi.entries) e.key: '${e.value} ${kit[e.value]}'})}');
      // 12 of the 13 notes are GM1 standard-kit notes (35..81); shaker (82) is a GS extension present in this kit
      expect(midi.values.where((m) => m! < 35 || m > 81).toList(), [82]);
    });

    test('guitar tools applied, every string playable, no same-pitch overlaps', () {
      for (final p in v2Parts) {
        final notes = song.sections.firstWhere((s) => s.id == p.id).tracks['melody']!.pitchNotes;
        final r = built.reports[p.id]!;
        debugPrint('[song-v2] ${p.name}: ${r.tools.join(' / ')} → 연장 ${r.extended} · 그대로 ${r.kept} ${r.reasons} '
            'unassignable=${r.unassignable} assignLengthChanges=${r.assignLengthChanges}');
        expect(notes.length, guitarPlain(p).length);
        expect(r.unassignable, 0, reason: p.name);
        expect(r.extended, greaterThan(0), reason: p.name);
        for (final n in notes) {
          expect(n.guitarString, isNotNull, reason: p.name);
          expect(guitarPlayable(n.guitarString!, n.midi), isTrue);
          expect(n.midi, inInclusiveRange(kGuitarLowestMidi, 76));
          expect(n.endSteps, lessThanOrEqualTo(p.steps + 1e-9));
          expect(n.articulation, isNull);
        }
        for (var s = 1; s <= kGuitarStrings; s++) {
          _expectMonophonic(notes.where((n) => n.guitarString == s).toList(), '${p.name} string $s');
        }
        _expectNoSamePitchOverlap(notes, '${p.name} guitar');
        for (final b in p.guitar) {
          final inBlock = notes.where((n) => n.step >= b.start && n.step < b.end);
          expect(inBlock.every((n) => (n.stroke != null) == (b.stroke != null)), isTrue, reason: '${p.name} ${b.label}');
        }
      }
      // whole-song lanes: no same-pitch overlaps on any pitched track
      final flat = flattenSong(song.sections);
      for (final (name, ns) in [
        ('guitar', flat.melody),
        ('lead', flat.melodyDec),
        ('bass', flat.bass),
        ('counter', flat.extraPitched[v2CounterId]!),
      ]) {
        _expectNoSamePitchOverlap(ns, name);
      }
    });

    test('hook identity, high points, cadences and rests', () {
      List<int> bar(V2Part p, int b, [bool pitches = false]) => [
            for (final n in p.lead.where((n) => n.step ~/ 16 == b)) pitches ? n.midi : n.dur,
          ];
      const hookRhythm = [6, 2, 2, 2, 4];
      const hook = [76, 79, 78, 76, 71]; // E5 G5 F#5 E5 B4
      for (final (id, b) in [('intro', 0), ('chorus1', 0), ('chorus1', 4), ('finalA', 0), ('finalA', 4), ('finalB', 0), ('outro', 0)]) {
        expect(bar(v2Part(id), b, true), hook, reason: '$id bar ${b + 1}');
      }
      // verses carry the same rhythm (and contour) lower
      for (final (id, b) in [('verse1', 0), ('verse1', 2), ('verse1', 4), ('verse2', 0), ('verse2', 2)]) {
        expect(bar(v2Part(id), b).take(4), hookRhythm.take(4), reason: '$id bar ${b + 1}');
      }
      int top(String id) => v2Part(id).lead.map((n) => n.midi).reduce(math.max);
      expect(top('chorus1'), 81); // A5
      expect(v2Part('chorus1').lead.firstWhere((n) => n.midi == 81).step ~/ 16, 2); // in bar 3
      expect(top('finalB'), 83); // B5, the song's peak (never above B5)
      expect(v2Parts.every((p) => p.lead.isEmpty || top(p.id) <= 83), isTrue);
      // long resolving notes
      final c1 = v2Part('chorus1').lead.last;
      expect((c1.midi, c1.dur), (76, 14));
      final end = v2Part('outro').lead.last;
      expect((end.midi, end.step + end.dur, end.dur), (64, 64, 16));
      expect(v2Part('outro').bass.last.midi, 28); // E1
      // explicit rest before the chorus: the Lift's last beat
      final lift = v2Part('lift');
      expect(lift.drums.where((d) => d.step >= 59), isEmpty);
      expect(lift.bass.every((n) => n.step + n.dur <= 60), isTrue);
      expect(lift.lead.every((n) => n.step + n.dur <= 60), isTrue);
      final liftGuitar = song.sections.firstWhere((s) => s.id == 'lift').tracks['melody']!.pitchNotes;
      expect(liftGuitar.every((n) => n.endSteps <= 60 + 1e-9), isTrue, reason: 'guitar note-off before the last beat of the Lift');
      // the final chorus ends with a short stop (drums, bass, guitar)
      final fb = v2Part('finalB');
      expect(fb.drums.where((d) => d.step >= 123), isEmpty);
      expect(fb.bass.every((n) => n.step + n.dur <= 123), isTrue);
      // the bridge drops the drums for bars 1–4 (shaker only)
      expect({for (final d in v2Part('bridge').drums.where((d) => d.step < 64)) d.kind}, {'shaker'});
      // fills are composed, not every bar: a fill bar has ≥ 2 snare/tom hits
      // off the backbeat that are not ghost notes (velocity > 42)
      bool fillHit(V2Hit d) =>
          (d.kind == 'snare' || const ['midi_45', 'midi_47', 'midi_50'].contains(d.kind)) && d.step % 16 != 4 && d.step % 16 != 12 && d.vel > 42;
      for (final p in v2Parts) {
        final fills = [
          for (var b = 0; b < p.bars; b++)
            if (p.drums.where((d) => d.step ~/ 16 == b && fillHit(d)).length >= 2) b + 1,
        ];
        debugPrint('[song-v2] ${p.name} fill bars $fills');
        expect(fills.every((b) => b % 4 == 0), isTrue, reason: '${p.name} fills only at 4/8-bar ends: $fills');
        expect(fills.length, lessThanOrEqualTo(2), reason: '${p.name} fills $fills');
      }
    });

    test('no two 8-bar blocks are identical on any track', () {
      final same = _identicalBlocks(song);
      debugPrint('[song-v2] distinct 4-bar instances: ${_distinct4BarInstances(song)}');
      for (final e in same.entries) {
        expect(e.value, isEmpty, reason: '${e.key}: identical 8-bar windows starting at bars ${e.value}');
      }
    });

    test('save → reload through LoopStorage keeps the song (semantic JSON)', () async {
      final dir = await Directory.systemTemp.createTemp('humtrack_v2_');
      LoopStorage.rootOverride = dir;
      try {
        for (final s in [song, plain]) {
          await LoopStorage.save([s]);
          final back = await LoopStorage.load();
          expect(back.length, 1);
          expect(jsonEncode(_semantic(back.single)), jsonEncode(_semantic(s)));
        }
      } finally {
        LoopStorage.rootOverride = null;
        await dir.delete(recursive: true);
      }
    });

    test('every section .mid parses with the app importer and gives its bars', () {
      for (final p in v2Parts) {
        final s = _checkImport(p, sectionMid(p));
        debugPrint('[song-v2] ${p.name}.mid → ${s.sections.single.tracks.entries.where((e) => e.value.pitchNotes.isNotEmpty || e.value.drumNotes.isNotEmpty).map((e) => '${e.value.label}=>${e.key}').join(', ')}');
      }
    });
  });

  final out = Platform.environment['HUMTRACK_V2_OUT'];
  test(
    'write song.json, renders, section MIDI, previews, measurements and docs',
    () async {
      await _writeAll(Directory(out!));
    },
    skip: out == null || out.isEmpty ? 'set HUMTRACK_V2_OUT to write the files' : false,
    timeout: const Timeout(Duration(minutes: 40)),
  );
}

// ── WAV helpers ─────────────────────────────────────────────────────────
typedef _Wav = ({ByteData data, int dataOffset, int frames, int sampleRate});

_Wav _wav(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  expect(bd.getUint16(22, Endian.little), 2);
  expect(bd.getUint16(34, Endian.little), 16);
  var p = 12;
  while (String.fromCharCodes(bytes.sublist(p, p + 4)) != 'data') {
    p += 8 + bd.getUint32(p + 4, Endian.little);
  }
  return (data: bd, dataOffset: p + 8, frames: bd.getUint32(p + 4, Endian.little) ~/ 4, sampleRate: bd.getUint32(24, Endian.little));
}

double _sample(_Wav w, int frame, int ch) {
  final v = w.data.getInt16(w.dataOffset + frame * 4 + ch * 2, Endian.little);
  return v < 0 ? v / 0x8000 : v / 0x7fff;
}

typedef _Lv = ({double peak, double rms, int clipped, bool finite});

_Lv _levels(_Wav w, [int from = 0, int? to]) {
  final end = math.min(to ?? w.frames, w.frames);
  var peak = 0.0, sum = 0.0, clipped = 0;
  for (var i = from; i < end; i++) {
    for (var c = 0; c < 2; c++) {
      final raw = w.data.getInt16(w.dataOffset + i * 4 + c * 2, Endian.little);
      if (raw == 32767 || raw == -32768) clipped++;
      final v = raw < 0 ? raw / 0x8000 : raw / 0x7fff;
      final a = v.abs();
      if (a > peak) peak = a;
      sum += v * v;
    }
  }
  final n = math.max(1, end - from);
  return (peak: peak, rms: math.sqrt(sum / (2 * n)), clipped: clipped, finite: sum.isFinite);
}

/// Frames [f0, f1) of [w] with linear fades, as a 16-bit stereo WAV.
Uint8List _cut(_Wav w, int f0, int f1, {int fadeIn = 441, int fadeOut = 2646}) {
  final n = f1 - f0;
  final out = ByteData(44 + n * 4);
  void s4(int o, String t) {
    for (var i = 0; i < 4; i++) {
      out.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  s4(0, 'RIFF');
  out.setUint32(4, 36 + n * 4, Endian.little);
  s4(8, 'WAVE');
  s4(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, 2, Endian.little);
  out.setUint32(24, w.sampleRate, Endian.little);
  out.setUint32(28, w.sampleRate * 4, Endian.little);
  out.setUint16(32, 4, Endian.little);
  out.setUint16(34, 16, Endian.little);
  s4(36, 'data');
  out.setUint32(40, n * 4, Endian.little);
  for (var i = 0; i < n; i++) {
    final g = math.min(1.0, math.min(i / fadeIn, (n - 1 - i) / fadeOut));
    for (var c = 0; c < 2; c++) {
      final v = w.data.getInt16(w.dataOffset + (f0 + i) * 4 + c * 2, Endian.little);
      out.setInt16(44 + i * 4 + c * 2, (v * g).round().clamp(-32768, 32767), Endian.little);
    }
  }
  return out.buffer.asUint8List();
}

double _db(double v) => v <= 0 ? -999 : 20 * math.log(v) / math.ln10;
double _r(double v, [int d = 4]) => double.parse(v.toStringAsFixed(d));

// ── renders, files, measurements ────────────────────────────────────────
Future<void> _writeAll(Directory outDir) async {
  await outDir.create(recursive: true);
  final temp = Directory('${outDir.path}/temp/render-work');
  if (await temp.exists()) await temp.delete(recursive: true);
  await temp.create(recursive: true);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMessageHandler('flutter/assets', (message) {
    final path = utf8.decode(message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes));
    final file = File(path);
    return SynchronousFuture(file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null);
  });
  messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async => temp.path);
  LoopStorage.rootOverride = temp;
  addTearDown(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    messenger.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    LoopStorage.rootOverride = null;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  // slot 1001 offline: install the bundled FreePats nylon (as the demo tests)
  final catalog = SoundfontCatalog.instance;
  catalog.debugSetDirectory(await Directory('${temp.path}/soundfonts').create(recursive: true));
  await catalog.warm();
  expect(catalog.bySlot(v2NylonSlot)!.id, 'freepats_nylon');
  expect(await catalog.ensureDownloaded(v2NylonSlot), isNotNull);
  expect(isGuitarProgram(v2NylonSlot), isTrue);

  final built = buildV2Song(processed: true);
  final s = built.song;
  final plan = ArticulationPlan.of(s); // as the editor passes it
  // the editor's export: vol with mutes folded to 0, extras = union over sections
  final vol = Map.of(s.vol);
  for (final e in s.mutes.entries) {
    if (e.value) vol[e.key] = 0.0;
  }
  final extras = <TrackRef>[];
  final seenExtra = <String>{};
  for (final sec in s.sections) {
    for (final e in sec.extras) {
      if (seenExtra.add(e.id)) extras.add(e);
    }
  }
  expect(extras.map((e) => e.id), [v2CounterId]);

  await File('${outDir.path}/song.json').writeAsString(const JsonEncoder.withIndent('  ').convert(s.toJson()), flush: true);

  Future<({File file, int skippedVocals})> mixOf(List<Section> secs, {int? leadProgram}) {
    final inst = {...s.instruments, if (leadProgram != null) 'melodyDec': leadProgram};
    return exportWavSong(
      secs,
      s.bpm,
      s.swing,
      vol,
      s.title,
      melodyProgram: inst['melody'] ?? 0,
      bassProgram: inst['bass'] ?? 33,
      melodyDecProgram: inst['melodyDec'] ?? 48,
      drumProgram: inst['drums'] ?? kDefaultDrumKit,
      extras: extras,
      instruments: inst,
      fallbackName: s.id,
      variationSeed: s.effectiveVariationSeed,
      groove: s.grooveContext,
      pan: s.pan,
      articulations: leadProgram == null ? plan : ArticulationPlan.build(sections: secs, instruments: inst),
    );
  }

  // ── full mix ──
  final sw = Stopwatch()..start();
  final wav = await mixOf(s.sections);
  final mixSec = sw.elapsedMilliseconds / 1000;
  expect(wav.skippedVocals, 0);
  final mixBytes = await wav.file.readAsBytes();
  await File('${outDir.path}/HumTrack-Song-v2.mix.wav').writeAsBytes(mixBytes, flush: true);
  final mix = _wav(mixBytes);
  final mixLv = _levels(mix);
  final frames = mix.frames;
  final musicSec = 64 * v2BarSec;
  final mpq = (60000000 / v2Bpm).round();
  final barSmf = 4 * mpq / 1e6; // what the SMF tempo actually encodes
  final midiSec = 64 * barSmf;
  final expectedFrames = ((midiSec + 1.2) * 44100).ceil();
  expect(mix.sampleRate, 44100);
  expect((frames / 44100 - (musicSec + 1.2)).abs(), lessThan(.005));
  expect(mixLv.peak, lessThanOrEqualTo(_headroom + _lsb + 1e-9));
  expect(mixLv.clipped, 0);
  int frameAtBar(int bar) => (bar * barSmf * 44100).round();

  // ── stems ──
  sw.reset();
  final stems = await exportStems(
    s.sections,
    s.bpm,
    s.swing,
    vol,
    s.title,
    melodyProgram: s.instruments['melody'] ?? 0,
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: extras,
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: plan,
  );
  final stemSec = sw.elapsedMilliseconds / 1000;
  const stemNames = {'melody': 'guitar', 'melodyDec': 'lead', 'bass': 'bass', 'drums': 'drums', 'Melody 2': 'counter'};
  final sumL = Float64List(frames), sumR = Float64List(frames);
  final stemInfo = <String, Object>{};
  final stemWavs = <String, _Wav>{};
  for (final f in stems) {
    final label = f.path.split(RegExp(r'[\\/]')).last.replaceFirst('${s.title} - ', '').replaceFirst('.wav', '');
    final name = stemNames[label] ?? label;
    final bytes = await f.readAsBytes();
    await File('${outDir.path}/stem-$name.wav').writeAsBytes(bytes, flush: true);
    final w = _wav(bytes);
    stemWavs[name] = w;
    final lv = _levels(w);
    for (var i = 0; i < math.min(frames, w.frames); i++) {
      sumL[i] += _sample(w, i, 0);
      sumR[i] += _sample(w, i, 1);
    }
    stemInfo[name] = {
      'lane': label,
      'frames': w.frames,
      'peak': _r(lv.peak),
      'peak_dbfs': _r(_db(lv.peak), 2),
      'rms': _r(lv.rms),
      'rms_dbfs': _r(_db(lv.rms), 2),
      'clipped_samples': lv.clipped,
      'attenuated_by_stem_limiter': lv.peak >= _headroom - _lsb,
    };
    expect(lv.finite, isTrue, reason: name);
    expect(lv.rms, greaterThan(1e-4), reason: '$name is silent');
    expect(lv.peak, lessThanOrEqualTo(_headroom + _lsb + 1e-9));
  }
  expect(stemWavs.keys.toSet(), {'guitar', 'lead', 'bass', 'drums', 'counter'});
  var dot = 0.0, den = 0.0, sumPeak = 0.0;
  for (var i = 0; i < frames; i++) {
    final ml = _sample(mix, i, 0), mr = _sample(mix, i, 1);
    dot += ml * sumL[i] + mr * sumR[i];
    den += sumL[i] * sumL[i] + sumR[i] * sumR[i];
    sumPeak = math.max(sumPeak, math.max(sumL[i].abs(), sumR[i].abs()));
  }
  final g = den == 0 ? 0.0 : dot / den;
  var res = 0.0;
  for (var i = 0; i < frames; i++) {
    final a = _sample(mix, i, 0) - g * sumL[i], b = _sample(mix, i, 1) - g * sumR[i];
    res += a * a + b * b;
  }
  final resRms = math.sqrt(res / (2 * frames));

  // ── per-section levels (mix and stems, dBFS RMS) ──
  final sectionLevels = <Map<String, Object?>>[];
  var bar = 0;
  for (final p in v2Parts) {
    final f0 = frameAtBar(bar), f1 = frameAtBar(bar + p.bars);
    final row = <String, Object?>{'section': p.name, 'bars': '${bar + 1}–${bar + p.bars}', 'mix_rms_dbfs': _r(_db(_levels(mix, f0, f1).rms), 2)};
    for (final e in stemWavs.entries) {
      final lv = _levels(e.value, f0, f1);
      row['${e.key}_rms_dbfs'] = lv.rms < 1e-5 ? null : _r(_db(lv.rms), 2);
    }
    // the loudest of drums/bass vs the louder of lead/guitar (positive = covers)
    final lead = row['lead_rms_dbfs'] as double?, gtr = row['guitar_rms_dbfs'] as double?;
    final front = [lead, gtr].whereType<double>().fold<double>(-999, math.max);
    final back = [row['drums_rms_dbfs'] as double?, row['bass_rms_dbfs'] as double?].whereType<double>().fold<double>(-999, math.max);
    if (front > -999 && back > -999) row['back_minus_front_db'] = _r(back - front, 2);
    if (lead != null && row['drums_rms_dbfs'] != null) row['lead_minus_drums_db'] = _r(lead - (row['drums_rms_dbfs'] as double), 2);
    sectionLevels.add(row);
    bar += p.bars;
  }
  debugPrint('[song-v2] section levels ${jsonEncode(sectionLevels)}');

  // ── MIDI export ──
  final mid = await exportMidiSong(
    s.sections,
    s.bpm,
    s.title,
    melodyProgram: s.instruments['melody'] ?? 0,
    bassProgram: s.instruments['bass'] ?? 33,
    melodyDecProgram: s.instruments['melodyDec'] ?? 48,
    drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
    extras: extras,
    instruments: Map.of(s.instruments),
    fallbackName: s.id,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
    pan: s.pan,
    articulations: plan,
  );
  final midBytes = await mid.readAsBytes();
  await File('${outDir.path}/HumTrack-Song-v2.export.mid').writeAsBytes(midBytes, flush: true);
  final midRef = MidiReference.parse(midBytes);
  final flat = flattenSong(s.sections, variationSeed: s.effectiveVariationSeed, groove: s.grooveContext);
  final flatNotes = flat.melody.length + flat.melodyDec.length + flat.bass.length + flat.drums.length + flat.extraPitched[v2CounterId]!.length;
  expect(midRef.noteCount, flatNotes);
  expect(midRef.bpm.round(), v2Bpm);
  expect(midRef.bars, 64);

  // ── section .mid files ──
  final secDir = await Directory('${outDir.path}/sections').create(recursive: true);
  final sectionFiles = <Map<String, Object>>[];
  for (final (i, p) in v2Parts.indexed) {
    final bytes = sectionMid(p);
    final imported = _checkImport(p, bytes);
    final name = '${(i + 1).toString().padLeft(2, '0')}-${p.id}.mid';
    await File('${secDir.path}/$name').writeAsBytes(bytes, flush: true);
    sectionFiles.add({
      'file': 'sections/$name',
      'bars': p.bars,
      'tracks': [for (final l in sectionLanes(p)) '${l.name} (${l.program == null ? 'ch10' : 'GM ${l.program}'}, ${l.notes.length})'],
      'import_lanes': {
        for (final e in imported.sections.single.tracks.entries)
          if (e.value.pitchNotes.isNotEmpty || e.value.drumNotes.isNotEmpty) e.value.label!: e.key,
      },
    });
  }

  // ── previews (cut from the full mix at bar boundaries) ──
  final previews = <String, Object>{};
  for (final (file, from, to, what) in [
    ('preview-lift-chorus1.wav', 12, 24, 'Lift + Chorus 1 (마디 13–24)'),
    ('preview-final-chorus.wav', 48, 60, 'Final Chorus A 5–8마디 + Final Chorus B (마디 49–60)'),
  ]) {
    final f0 = frameAtBar(from), f1 = frameAtBar(to);
    final bytes = _cut(mix, f0, f1);
    await File('${outDir.path}/$file').writeAsBytes(bytes, flush: true);
    final lv = _levels(_wav(bytes));
    final sec = (f1 - f0) / 44100;
    expect(sec, inInclusiveRange(25, 35));
    previews[file] = {
      'what': what,
      'start_frame': f0,
      'end_frame': f1,
      'start_seconds': _r(f0 / 44100, 4),
      'seconds': _r(sec, 4),
      'fades_ms': {'in': 10, 'out': 60},
      'peak': _r(lv.peak),
      'rms_dbfs': _r(_db(lv.rms), 2),
    };
  }

  // ── lead comparison: E.Piano (GM 4) vs flute (GM 73), Lift → Chorus 1 ──
  final comparison = <String, Object>{};
  final excerpt = [s.sections[2], s.sections[3]];
  for (final (file, program) in [('compare-lift-chorus1-epiano.wav', v2LeadProgram), ('compare-lift-chorus1-flute.wav', v2FluteProgram)]) {
    final r = await mixOf(excerpt, leadProgram: program);
    final bytes = await r.file.readAsBytes();
    await File('${outDir.path}/$file').writeAsBytes(bytes, flush: true);
    final w = _wav(bytes);
    final lv = _levels(w);
    expect(lv.peak, lessThanOrEqualTo(_headroom + _lsb + 1e-9));
    comparison[file] = {
      'lead_program': program,
      'lead_instrument': kMelodyInstruments[program].label,
      'frames': w.frames,
      'seconds': _r(w.frames / 44100, 4),
      'peak': _r(lv.peak),
      'rms_dbfs': _r(_db(lv.rms), 2),
      'note': 'exportWavSong of the two sections only (normalized on its own, like a single-section export)',
    };
  }

  // ── counts ──
  final counts = <String, Object>{};
  for (final sec in s.sections) {
    final t = sec.tracks;
    counts[sec.name] = {
      'guitar': t['melody']!.pitchNotes.length,
      'lead': t['melodyDec']!.pitchNotes.length,
      'bass': t['bass']!.pitchNotes.length,
      'counter': t[v2CounterId]!.pitchNotes.length,
      'drums': t['drums']!.drumNotes.length,
    };
  }
  final kinds = {for (final p in v2Parts) for (final d in p.drums) d.kind};
  final kit = _gmKitKeys([for (final k in kinds) percussionMidi(k)!]);

  final bounds = <Map<String, Object>>[];
  var b0 = 0;
  for (var k = 0; k <= s.sections.length; k++) {
    final steps = k == 0 ? 0 : flattenSong(s.sections.sublist(0, k)).steps;
    expect(steps, b0 * 16);
    bounds.add({
      'boundary': k == 0 ? 'start' : 'end of ${s.sections[k - 1].name}',
      'bar': b0,
      'seconds_exact_tempo': _r(b0 * v2BarSec, 4),
      'frame_smf_tempo': frameAtBar(b0),
    });
    if (k < s.sections.length) b0 += s.sections[k].bars;
  }

  final measurements = <String, Object>{
    'song': {'id': s.id, 'title': s.title, 'bpm': s.bpm, 'bars': 64, 'key': '${s.key} ${s.scale}', 'instruments': s.instruments, 'vol': s.vol, 'pan': s.pan},
    'render_paths': {
      'mix': 'exportWavSong (vol = song.vol with mutes folded to 0, extras = union over sections, pan, ArticulationPlan.of(song), variationSeed = effectiveVariationSeed)',
      'stems': 'exportStems (same arguments)',
      'midi': 'exportMidiSong (same arguments)',
      'guitar_sf2': 'catalog slot 1001 freepats_nylon, installed offline from the bundled asset',
      'render_seconds': {'mix': mixSec, 'stems': stemSec},
    },
    'duration': {
      'frames': frames,
      'seconds': _r(frames / 44100, 6),
      'expected_seconds_exact_tempo': _r(musicSec + 1.2, 6),
      'expected_frames_from_smf_tempo': expectedFrames,
      'frames_minus_expected': frames - expectedFrames,
      'diff_ms_vs_exact': _r((frames / 44100 - musicSec - 1.2) * 1000, 3),
      'explanation': '64 bars at 103 BPM = ${_r(musicSec, 6)} s; SMF tempo $mpq µs/quarter gives ${_r(midiSec, 6)} s; + 1.2 s export tail, rounded up to whole frames.',
    },
    'mix': {
      'peak': _r(mixLv.peak, 6),
      'peak_dbfs': _r(_db(mixLv.peak), 3),
      'rms': _r(mixLv.rms, 6),
      'rms_dbfs': _r(_db(mixLv.rms), 2),
      'clipped_samples': mixLv.clipped,
      'ceiling': _headroom,
      'peak_within_ceiling_plus_1_lsb': mixLv.peak <= _headroom + _lsb + 1e-9,
    },
    'stems': stemInfo,
    'stems_vs_mix': {
      'sum_of_stems_peak': _r(sumPeak, 6),
      'fitted_mix_gain_over_stem_sum': _r(g, 6),
      'fitted_gain_db': _r(_db(g), 3),
      'residual_rms_dbfs': _r(_db(resRms), 2),
    },
    'section_levels': sectionLevels,
    'section_levels_note': 'RMS per section from the stems (raw lane level, before the mix normalisation gain). back_minus_front_db = max(drums, bass) − max(lead, guitar); lead_minus_drums_db = lead − drums. Numbers only, not a listening evaluation.',
    'section_boundaries': bounds,
    'note_counts': counts,
    'distinct_4bar_instances': _distinct4BarInstances(s),
    'identical_8bar_blocks': _identicalBlocks(s).map((k, v) => MapEntry(k, v.length)),
    'drum_kinds': {
      for (final k in (kinds.toList()..sort())) k: {'gm_note': percussionMidi(k), 'kit_region': kit[percussionMidi(k)]},
    },
    'guitar_tools': {
      for (final e in built.reports.entries)
        e.key: {
          'tools': e.value.tools,
          'notes': e.value.notes,
          'unassignable': e.value.unassignable,
          'length_changes_from_assign_strings': e.value.assignLengthChanges,
          'extended': e.value.extended,
          'kept': e.value.kept,
          'kept_reasons': e.value.reasons,
        },
    },
    'export_midi': {
      'file': 'HumTrack-Song-v2.export.mid',
      'bytes': midBytes.length,
      'notes': midRef.noteCount,
      'bars': midRef.bars,
      'lanes': [for (final l in midRef.lanes) '${l.name} (${l.notes.length})'],
      'warnings': midRef.warnings,
    },
    'section_midi': sectionFiles,
    'previews': previews,
    'lead_comparison': comparison,
  };
  await File('${outDir.path}/measurements.json').writeAsString(const JsonEncoder.withIndent('  ').convert(measurements), flush: true);
  await File('${outDir.path}/arrangement.md').writeAsString(_arrangement(built), flush: true);
  await File('${outDir.path}/README.md').writeAsString(_readme(built, measurements), flush: true);
  debugPrint('[song-v2] duration ${jsonEncode(measurements['duration'])}');
  debugPrint('[song-v2] mix ${jsonEncode(measurements['mix'])}');
  debugPrint('[song-v2] stems ${jsonEncode(stemInfo)}');
  debugPrint('[song-v2] comparison ${jsonEncode(comparison)}');
}

// ── documents (Korean) ──────────────────────────────────────────────────
String _lineText(List<V2Note> ns, int bars) {
  final parts = <String>[];
  for (var b = 0; b < bars; b++) {
    final inBar = ns.where((n) => n.step ~/ 16 == b).toList();
    parts.add(inBar.isEmpty ? '쉼' : inBar.map((n) => '${noteName(n.midi)}(${n.dur})').join(' '));
  }
  return [for (final (i, t) in parts.indexed) '${i + 1}: $t'].join(' / ');
}

String _arrangement(V2Built built) {
  final b = StringBuffer();
  b.writeln('# HumTrack Song v2 — 편곡표');
  b.writeln();
  b.writeln('E단조, 103 BPM, 4/4, 64마디, 모든 섹션 반복 ×1. 생성기 `mobile/test/looptap/song_v2_arrangement.dart` (테스트 `song_v2_arrangement_test.dart`).');
  b.writeln('음 이름은 앱 표기(C4 = MIDI 60), 괄호 안은 16분음표 칸 수. 섹션 MIDI는 `sections/`.');
  b.writeln();
  b.writeln('| 섹션 | 마디 | 코드 | 리드 (E.Piano) | 기타 (나일론) | 베이스 | 드럼 | 이전 섹션 대비 변화 |');
  b.writeln('|---|---|---|---|---|---|---|---|');
  var bar = 1;
  for (final p in v2Parts) {
    b.writeln('| ${p.name} | $bar–${bar + p.bars - 1} (${p.bars}) | ${p.chords.join(' · ')} | ${p.desc['lead']} | ${p.desc['guitar']} | ${p.desc['bass']} | ${p.desc['drums']} | ${p.desc['change']} |');
    bar += p.bars;
  }
  b.writeln();
  b.writeln('## 동기');
  b.writeln('- 2마디 동기: `E5(점4분) G5 F#5 E5(8분) B4(4분)` / `D5(4분) B4 A4(8분) G4(4분) 쉼(4분)`. 1마디 리듬 6·2·2·2·4칸.');
  b.writeln('- Intro 1–2마디 = 동기 그대로(작게). Verse = 같은 리듬·같은 윤곽을 B4에서(B4–D5–C5–B4–G4). Chorus = E5에서 동기, 2마디째는 D5–B4–A4 다음 D5로 다시 올라가 E5 픽업 → 3마디 A5.');
  b.writeln('- 4마디 = 질문(Verse: F#4/D/F#, Chorus: B4/Em의 5음에서 쉼), 8마디 = 응답(Verse: B4/B7 롱톤, Chorus: D#5 이끎음 → E5 14칸).');
  b.writeln('- Final Chorus A: 1–3마디 훅 그대로 + 4마디부터 새 응답. Final Chorus B: 3마디 정점을 A5 → B5, 5마디 마지막 응답이 다시 B5. 리드는 B5를 넘지 않는다.');
  b.writeln();
  b.writeln('## 섹션별 리드 / 카운터 음');
  for (final p in v2Parts) {
    b.writeln('- **${p.name}** 리드 — ${_lineText(p.lead, p.bars)}');
    if (p.counter.isNotEmpty) b.writeln('  - 카운터(현악 GM 48) — ${_lineText(p.counter, p.bars)}');
  }
  b.writeln();
  b.writeln('## 섹션별 베이스');
  for (final p in v2Parts) {
    b.writeln('- **${p.name}** — ${_lineText(p.bass, p.bars)}');
  }
  b.writeln();
  b.writeln('## 기타 도구 (앱 함수 그대로)');
  b.writeln('| 섹션 | 도구 | 결과 |');
  b.writeln('|---|---|---|');
  for (final p in v2Parts) {
    final r = built.reports[p.id]!;
    final why = r.reasons.isEmpty ? '' : ' (${r.reasons.entries.map((e) => '${e.key} ${e.value}').join(', ')})';
    b.writeln('| ${p.name} | ${r.tools.join('<br>')} | 음 ${r.notes} · 연장 ${r.extended} · 그대로 ${r.kept}$why · 줄 배정 불가 ${r.unassignable} |');
  }
  b.writeln();
  b.writeln('## 드럼 격자 (마디별, 칸 1–16, 세기 g30 q42 l54 m68 h82 x96 X110, `·`=없음)');
  for (final p in v2Parts) {
    b.writeln();
    b.writeln('### ${p.name}');
    final late = {for (final d in p.drums) if (d.tick > 0) '${d.kind} +${d.tick}/24칸'};
    if (late.isNotEmpty) b.writeln('늦게 친 백비트: ${late.join(', ')}');
    b.writeln();
    b.writeln('| 마디 | 소리 (GM) | 격자 |');
    b.writeln('|---|---|---|');
    const velChar = {30: 'g', 42: 'q', 54: 'l', 68: 'm', 82: 'h', 96: 'x', 110: 'X'};
    for (var m = 0; m < p.bars; m++) {
      final hits = p.drums.where((d) => d.step ~/ 16 == m).toList();
      if (hits.isEmpty) {
        b.writeln('| ${m + 1} | (쉼) | |');
        continue;
      }
      for (final k in drumKindsOf(p)) {
        final cells = {for (final d in hits.where((d) => d.kind == k)) d.step % 16: velChar[d.vel]!};
        if (cells.isEmpty) continue;
        final grid = [for (var c = 0; c < 16; c++) cells[c] ?? '·'].join();
        b.writeln('| ${m + 1} | $k (${percussionMidi(k)}) | `${grid.substring(0, 4)} ${grid.substring(4, 8)} ${grid.substring(8, 12)} ${grid.substring(12)}` |');
      }
    }
  }
  return b.toString();
}

String _readme(V2Built built, Map<String, Object> m) {
  final d = m['duration'] as Map;
  final mix = m['mix'] as Map;
  final stems = m['stems'] as Map;
  final svm = m['stems_vs_mix'] as Map;
  final levels = m['section_levels'] as List;
  final distinct = m['distinct_4bar_instances'] as Map;
  final prev = m['previews'] as Map;
  final cmp = m['lead_comparison'] as Map;
  final kinds = m['drum_kinds'] as Map;
  final b = StringBuffer();
  b.writeln('# HumTrack Song v2 — 자작 연주곡 편곡 (2026-10-23)');
  b.writeln();
  b.writeln('설계: `design.md`. 생성기: `mobile/test/looptap/song_v2_arrangement.dart` + `song_v2_arrangement_test.dart` (앱 코드 변경 없음). 편곡 상세: `arrangement.md`.');
  b.writeln();
  b.writeln('E단조, **103 BPM**, 4/4, 어쿠스틱 팝 + 멜로딕 힙합. 64마디 = 149.126초(+ 내보내기 꼬리 1.2초). 모든 섹션 반복 ×1:');
  b.writeln('Intro 4 · Verse 1 8 · Lift 4 · Chorus 1 8 · Post 4 · Verse 2 8 · Bridge 8 · Final Chorus A 8 · Final Chorus B 8 · Outro 4.');
  b.writeln();
  b.writeln('트랙: 기타 = 나일론 FreePats(슬롯 1001), 리드 = **GM 4 E.Piano 1**, 베이스 = GM 33, 드럼 = Standard 킷, 추가 트랙 1개 = 카운터멜로디(GM 48 현악, 마지막 두 후렴에만 음이 있음).');
  b.writeln();
  b.writeln('## 파일');
  b.writeln('| 파일 | 내용 |');
  b.writeln('|---|---|');
  b.writeln('| `HumTrack-Song-v2.mix.wav` | 전체 믹스 (`exportWavSong`, `ArticulationPlan.of(song)`, 편집기와 같은 내보내기 vol 맵) |');
  b.writeln('| `stem-lead.wav` `stem-guitar.wav` `stem-bass.wav` `stem-drums.wav` `stem-counter.wav` | `exportStems` 스템 (리드=melodyDec, 기타=melody, 카운터=추가 트랙 "Melody 2") |');
  b.writeln('| `song.json` | Song JSON (id `$v2SongId`). 사용자 저장소에는 쓰지 않았다. 기타 도구 적용 후 데이터 |');
  b.writeln('| `HumTrack-Song-v2.export.mid` | `exportMidiSong` 전체 64마디 (슬롯 1001 → GM 24) |');
  b.writeln('| `sections/01-intro.mid` … `10-outro.mid` | 섹션별 MIDI(4 또는 8마디, format 1, 트랙 이름 Guitar/Lead/Bass/(Counter)/Drums). 기타는 도구 적용 **전** 데이터(코드 타격 / 펼치기 결과). 모두 `midi_import.dart`로 파싱·구간 변환을 테스트에서 확인 |');
  b.writeln('| `preview-lift-chorus1.wav` | ${(prev['preview-lift-chorus1.wav'] as Map)['what']}, ${(prev['preview-lift-chorus1.wav'] as Map)['seconds']} s, 전체 믹스에서 마디 경계로 자름(페이드 10/60 ms) |');
  b.writeln('| `preview-final-chorus.wav` | ${(prev['preview-final-chorus.wav'] as Map)['what']}, ${(prev['preview-final-chorus.wav'] as Map)['seconds']} s |');
  b.writeln('| `compare-lift-chorus1-epiano.wav` / `compare-lift-chorus1-flute.wav` | 같은 Lift→Chorus 1 두 섹션을 리드 GM 4 / GM 73(v1 플루트)로 각각 렌더 |');
  b.writeln('| `arrangement.md` | 섹션 × 코드/리드/기타/베이스/드럼/변화 표, 섹션별 음, 기타 도구 결과, 드럼 격자 |');
  b.writeln('| `measurements.json` | 길이·피크·RMS·스템·섹션별 레벨·킷 매핑·도구 결과·MIDI 확인 |');
  b.writeln();
  b.writeln('## v1 대비 달라진 것');
  b.writeln('- **구성**: v1은 4마디 섹션 5종을 반복(Verse ×4, Chorus ×4 두 번, Break ×2)해 64마디를 채웠다(4마디 단위 16개 중 리드 구절 5종 — `codex-v1-baseline.json`, 드럼 kind는 kick/snare/hihat 3종). '
      'v2는 4·8마디 섹션 10개를 한 번씩만 쓴다. 4마디 단위 16개 기준 서로 다른 패턴 수: 리드 ${distinct['lead']}, 기타 ${distinct['guitar']}, 베이스 ${distinct['bass']}, 드럼 ${distinct['drums']}. '
      '어느 트랙에서도 겹치지 않는 8마디 두 블록이 같은 경우는 0 (테스트로 확인). 단, 숫자보다 훅 반복·쉼·종지를 우선했다 — 훅 1마디는 Intro/Chorus/Final A/Final B/Outro에 그대로 7번 나온다.');
  b.writeln('- **동기 전개**: v1은 Verse "B4–G4 A4–B4"를 Chorus에서 그대로 위로 옮긴 것이 전부였다. v2는 2마디 동기(6·2·2·2·4칸 리듬)를 Intro에서 예고 → Verse에서 같은 리듬·윤곽을 낮게 → Chorus에서 E5 훅 + 3마디 정점 A5 → Post에서 응답 조각만 2박 밀어 메아리 → Verse 2에서 음정 변주와 새 응답 → Final A에서 새 응답 → Final B에서 정점 B5와 마지막 응답 → Outro에서 조각 → E4로 해결. 4마디 질문/8마디 응답, 쉼표, 이끎음 D#5 → E5, 긴 해결음.');
  b.writeln('- **화성**: v1은 Em–C–G–D / C–G/B–D–Em 계열과 Am7–Em–Cmaj7–B7 정도였다. v2는 섹션마다 화성 역할을 나눴다: Intro Cmaj7–G/B(후렴 훅의 색을 미리), Lift Am7–Bm7–Cmaj7–Dsus4→D(상행 + 4–3 해결), Chorus C–D–Bm7–Em / C–D–B7–Em(베이스 D/F#·B7/D# 전위), Bridge Am–C–G/B–F#m7♭5–Cmaj7–D–B7sus4–B7(새 화성), Outro Cmaj7–Am7–B7–Em(add9). 기타 코드 모양 15종 모두 실제 오픈 포지션(테스트로 프렛 확인).');
  b.writeln('- **비트**: v1은 kick/snare/hihat 3종, 섹션 내 마디 거의 동일. v2는 ${kinds.length}종(${kinds.keys.join(', ')}), 모두 `percussionMidi`로 GM 노트가 되고 번들 GeneralUser-GS 킷에 실제 영역이 있음을 테스트에서 확인(셰이커 82는 GM1 범위 35–81 밖의 GS 확장음, 이 킷에는 있음). '
      'Verse 1 앞 4마디 림 → 뒤 4마디 스네어, 고스트 노트, 세기 7단계, 스네어/클랩/림 백비트를 1–2/24칸(약 6–12 ms) 늦게, Lift 마지막 박 완전 정지, Post 하프타임, Bridge 1–4마디 드럼 드롭(셰이커만) → 탐 필, Final B 5–7마디 햇 → 라이드, 끝 짧은 쉼. 필은 4/8마디 끝에만(섹션당 최대 2마디, 테스트로 확인), 16분 햇을 계속 깔지 않는다.');
  b.writeln('- **베이스**: 킥 패턴과 같은 칸에 치고(Chorus 1·2e·2&·3&), 반음 접근(C#→D, D#→E, A#→B), 전위(D/F#, B7/D#), Verse 2 옥타브 도약, Final B 8분 추진, Outro B→E1 해결.');
  b.writeln('- **기타**: 앱 도구만 사용. Verse 1 folk 패턴, Lift ↓↑ 8분, Chorus/Final 정박 ↓·엇박 ↑(선택 두 번에 `applyGuitarStroke`), Post 다운 3–3–2, Verse 2 16분 당김, Bridge 펼치기 → 스트로크, Outro 펼치기 → 느린 Em(add9) 한 번. 모두 줄 배정 불가 0.');
  b.writeln('- **리드 음색**: 플루트(73) → E.Piano 1(4). 비교 렌더 `compare-lift-chorus1-*.wav`: E.Piano RMS ${(cmp['compare-lift-chorus1-epiano.wav'] as Map)['rms_dbfs']} dBFS, 플루트 RMS ${(cmp['compare-lift-chorus1-flute.wav'] as Map)['rms_dbfs']} dBFS(각자 정규화된 믹스 기준).');
  b.writeln();
  b.writeln('## 설계(design.md) 대비 바꾼 점');
  b.writeln('- 동기 2마디째 리듬을 `D5(4분) B4 A4(8분) G4(4분) 쉼(4분)`으로 고정했다(설계: "D5 B4 A4 G4 이어서 쉼/픽업"). 후렴 2마디(D 위)에서는 G4 대신 D5로 다시 올라가고 E5 픽업으로 3마디 A5에 닿게 했다 — D 화음 위 4분음표 G4(4음)를 피하고 정점으로 가는 길을 만들기 위해.');
  b.writeln('- Intro 훅 예고는 1–2마디(Cmaj7 · G/B)에 두었다. 4마디(B7) 위에 동기 2마디째 D5를 두면 B7의 D#과 부딪혀서다. 3마디는 C5–B4–A4 응답, 4마디는 쉼.');
  b.writeln('- Final Chorus B: 설계의 "옥타브를 올린 클라이맥스"는 리드 전체를 +12로 옮기지 않았다(A6 금지, 검토 의견 반영). 대신 3마디 정점을 A5 → **B5**로 올리고, 5마디에 새 응답(G5–E5–G5–B5)과 카운터의 응답을 넣었다. 리드 최고음 B5(83) — 테스트로 확인.');
  b.writeln('- 카운터멜로디(추가 트랙 1개)는 Final A·B에만. 앱 규칙상 추가 트랙은 모든 섹션에 들어가므로 나머지 섹션에는 빈 레인으로 존재한다.');
  b.writeln('- Verse 1 드럼: 설계의 킥 "1·2&"에 3&(또는 4&)을 더해 2마디 단위로 교대했다. Chorus 킥은 1·2&·3& / 1·1a·2&·3&·4& 두 가지 교대.');
  b.writeln('- Chorus 1의 오픈햇은 Final A부터만(설계대로), 라이드는 설계에 없지만 Final B 5–7마디의 질감 변화로 추가. 탐(midi_50/47/45)은 Bridge 끝 필과 Final B 4마디 끝에만.');
  b.writeln('- Post 기타는 다운 스트로크를 3–3–2 리듬으로, 베이스는 걷는 선(4분 대신 6·6·4칸)으로 해서 하프타임 킥과 맞췄다.');
  b.writeln('- Outro 마지막 코드는 Em 대신 Em(add9)(022002) — 리드 E4 해결음과 부딪히지 않는 열린 울림.');
  b.writeln('- Lift→Chorus 정지(검토 의견 반영): Lift 4마디 4박 전체를 실제 이벤트로 비웠다 — 리드 F#5는 3박 끝(60칸)에서 끝, 기타 마지막 D 타격도 60칸에서 끝(줄별 울림 유지 뒤에도, 테스트로 확인), 베이스 4박 쉼, 드럼은 3& 스네어(58칸) 뒤 없음. 자연 감쇠 꼬리만 남는다.');
  b.writeln('- 경과음 길이(검토 의견 반영): Lift 베이스 A#·C#, Post 베이스 C#·D#는 마디 끝 8분(2칸)만 반음 접근음이고 그 앞은 화음 구성음(E2, G1, D2, A1)이다.');
  b.writeln();
  b.writeln('## 측정 (숫자 검증일 뿐, 청취 평가가 아님)');
  b.writeln('- 길이: **${d['seconds']} s** (${d['frames']} 프레임, SMF 템포 기준 기대 ${d['expected_frames_from_smf_tempo']} 프레임과 차이 ${d['frames_minus_expected']}). 정확한 템포 기대값 ${d['expected_seconds_exact_tempo']} s, 차이 ${d['diff_ms_vs_exact']} ms.');
  b.writeln('- 믹스 피크 **${mix['peak']}** (${mix['peak_dbfs']} dBFS, 0.94 + 1 LSB 이내: ${mix['peak_within_ceiling_plus_1_lsb']}), 클리핑 샘플 ${mix['clipped_samples']}, RMS ${mix['rms_dbfs']} dBFS.');
  b.writeln('- 믹스 설정(song.vol / pan): ${jsonEncode(v2Vol)} / ${jsonEncode(v2Pan)}.');
  b.writeln('- 믹스 반복(숫자 기준): 첫 설정 vol 기타 0.80 / 리드 0.90 / 베이스 0.80 / 드럼 0.78 / 카운터 0.50에서 Chorus 1 RMS가 기타 −24.24, 리드 −38.95, 베이스 −32.12, 드럼 −33.27 dBFS — '
      '나일론 기타가 리드를 약 14.7 dB 덮고, 드럼·베이스도 리드보다 5–7 dB 컸다. CC7 볼륨은 대략 40·log10(vol) dB로 움직이므로 기타 0.40(−12 dB), 드럼 0.53, 베이스 0.54로 내리고 리드 1.0, 카운터 0.58로 맞췄다. '
      '이 상태에서 Final Chorus B 기타 −34.24 / 리드 −36.35 dBFS(기타가 2.1 dB 앞)여서 기타를 0.35로 한 번 더 내렸다(최종 값은 위 설정, 결과는 아래 표). v1 Chorus 기준(`codex-v1-baseline.json`)은 리드(플루트) −24.90, 드럼 −33.60 dBFS로 드럼이 리드보다 8.7 dB 아래였고, v2는 약 3 dB 아래 — 비트가 묻히지 않으면서 리드·기타보다 크지 않게.');
  b.writeln('- 스템 (원 레벨, 정규화 전):');
  for (final e in stems.entries) {
    final v = e.value as Map;
    b.writeln('  - `${e.key}`: 피크 ${v['peak']} (${v['peak_dbfs']} dBFS), RMS ${v['rms_dbfs']} dBFS, 프레임 ${v['frames']}');
  }
  b.writeln('- 스템 합 × ${svm['fitted_mix_gain_over_stem_sum']} ≈ 믹스 (잔차 ${svm['residual_rms_dbfs']} dBFS).');
  b.writeln('- 섹션별 RMS(dBFS, 스템 원 레벨). "뒤−앞" = max(드럼, 베이스) − max(리드, 기타):');
  b.writeln();
  b.writeln('| 섹션 | 마디 | 믹스 | 리드 | 기타 | 베이스 | 드럼 | 카운터 | 뒤−앞 | 리드−드럼 |');
  b.writeln('|---|---|---|---|---|---|---|---|---|---|');
  String f(Object? v) => v == null ? '–' : '$v';
  for (final r in levels.cast<Map>()) {
    b.writeln('| ${r['section']} | ${r['bars']} | ${f(r['mix_rms_dbfs'])} | ${f(r['lead_rms_dbfs'])} | ${f(r['guitar_rms_dbfs'])} | ${f(r['bass_rms_dbfs'])} | ${f(r['drums_rms_dbfs'])} | ${f(r['counter_rms_dbfs'])} | ${f(r['back_minus_front_db'])} | ${f(r['lead_minus_drums_db'])} |');
  }
  b.writeln();
  b.writeln('## 한계');
  b.writeln('- **청취 검증 안 함.** 위 숫자는 길이·레벨·이벤트 검증뿐이다. 소리가 좋은지, 훅이 기억에 남는지는 사람이 들어 봐야 한다.');
  b.writeln('- 코드 렌더 ≠ 네이티브 UI: 테스트 안에서 앱의 모델·도구·내보내기 함수를 직접 불렀다. 앱 화면에서 같은 곡을 만들고 재생·저장한 것이 아니다(앱에는 곡 JSON 가져오기가 없다). 실시간 재생 경로(라이브 신스, 오디오 세션)는 오프라인 MeltySynth 렌더와 다르다.');
  b.writeln('- GM 음원 근사: E.Piano·현악·드럼은 GeneralUser-GS의 GM 음색, 기타는 FreePats 나일론. 실제 악기·믹싱(EQ, 컴프레서, 리버브 버스)이 없고 레벨 조정은 트랙 볼륨(CC7)과 팬뿐이다. 믹스 전체는 내보내기에서 0.94 피크로 정규화된다.');
  b.writeln('- 마이크로 타이밍은 드럼 백비트에만 1–2/24칸(약 6–12 ms) 늦춤을 넣었다. 리드·베이스는 격자 위(기타는 스트로크 도구의 줄 간 시차만).');
  b.writeln('- 섹션 `.mid` 가져오기: 홈의 `MIDI +`는 **새 곡**을 만든다(첫 음 순서대로 melody → melodyDec → bass 레인, 네 번째 음높이 레인은 추가 트랙 — 예: Post는 리드가 2박에 시작해 Bass 파트가 Melody Fill 레인에, Final A/B의 Counter는 midi_lane_0에 놓임; 이 규칙은 테스트에서 확인). '
      '이미 있는 곡에서는 섹션 메뉴 → "MIDI 구간을 새 섹션으로"로 구간을 파트→트랙 매핑 후 새 섹션으로 끼워 넣을 수 있다(현재 소스: `lib/looptap/music/midi_section_import.dart`, `midi_import_sheet.dart`). 이 경로는 이번에 코드로 실행하지 않았다 — 위 렌더는 테스트 안의 코드 렌더이고 네이티브 UI 조작이 아니다.');
  b.writeln();
  b.writeln('## 다시 만들기');
  b.writeln('```');
  b.writeln('cd C:/src/humming-v2/mobile && TMP=C:/src/humming-v2/artifacts/song-arrangement-v2-20261023/temp TEMP=C:/src/humming-v2/artifacts/song-arrangement-v2-20261023/temp HUMTRACK_V2_OUT=C:/src/humming-v2/artifacts/song-arrangement-v2-20261023 /c/src/flutter/bin/flutter test --no-pub test/looptap/song_v2_arrangement_test.dart');
  b.writeln('```');
  b.writeln('`HUMTRACK_V2_OUT`이 없으면 같은 테스트가 곡을 만들고 검사만 한다(파일 쓰기 없음).');
  return b.toString();
}
