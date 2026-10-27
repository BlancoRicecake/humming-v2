// A/B listening demo for the guitar features (gt-001 stroke conversion,
// gt-002 string assignment + ringing arpeggio). Product criterion:
// docs/product/song-completion-plan.md §1 — compare plain / stroke / ringing
// arpeggio on a small self-made 8-bar progression at the same loudness.
//
// The music is our own: 8 bars of 4/4 at 80 BPM in E minor, one chord per
// bar (Em Am C G Em Am C G), voiced by HumTrack's own guitarVoicing.
//
// ALWAYS: builds the four songs with the real pure functions and checks them
// (conversion applied, strings assigned, MIDI events == note data, no note
// dropped or moved in pitch).
// ONLY with HUMTRACK_DEMO_OUT set: writes .mid (exportMidiSong), .wav (the
// real exportWavSong mix render through catalog slot 1001, FreePats nylon,
// installed offline from the bundled asset), loudness-matched copies,
// levels.json, sf2_facts.json, .song.json files and a Korean README.md.
//
// Regenerate (from mobile/):
//   HUMTRACK_DEMO_OUT=<dir> /c/src/flutter/bin/flutter test --no-pub \
//     test/looptap/guitar_demo_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dart_melty_soundfont/soundfont.dart' show SoundFont;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_strings.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

const int _bpm = 80;
const int _bars = 8;
const int _steps = _bars * 16;
const int _nylonSlot = 1001;
const String _key = 'E';
const String _scale = 'minor';
const List<String> _chordRoots = ['E', 'A', 'C', 'G', 'E', 'A', 'C', 'G'];
const List<String> _chordNames = ['Em', 'Am', 'C', 'G', 'Em', 'Am', 'C', 'G'];

/// Folk strum "↓ ↓↑ ↑↓↑" positions inside one bar: (step, length in steps).
/// Beats 1, 2, 2&, 3& (tied over beat 3), 4, 4&.
const List<(int, int)> _folkHits = [
  (0, 4),
  (4, 2),
  (6, 4),
  (10, 2),
  (12, 2),
  (14, 2),
];

/// Fingerpicked 8th-note order over the 6-note voicing: bass, then the
/// upper strings up and back down.
const List<int> _arpOrder = [0, 2, 3, 4, 5, 4, 3, 2];

const String _a1 = 'A1-chords-normal';
const String _a2 = 'A2-chords-stroke';
const String _b1 = 'B1-arpeggio-normal';
const String _b2 = 'B2-arpeggio-ring';

List<int> _voicing(int bar) =>
    guitarVoicing(rootMidi(_chordRoots[bar], 2), _key, _scale);

PitchNote _note(int midi, int step, int dur) =>
    PitchNote(midi: midi, freq: midiToFreq(midi), step: step, dur: dur);

List<PitchNote> _blockChords() => [
  for (var bar = 0; bar < _bars; bar++)
    for (final (s, d) in _folkHits)
      for (final m in _voicing(bar)) _note(m, bar * 16 + s, d),
];

List<PitchNote> _arpeggio() => [
  for (var bar = 0; bar < _bars; bar++)
    for (var i = 0; i < _arpOrder.length; i++)
      _note(_voicing(bar)[_arpOrder[i]], bar * 16 + i * 2, 2),
];

Song _song(String name, List<PitchNote> notes) {
  final sec = Section(id: 'A', name: 'A', bars: _bars);
  sec.tracks['melody']!.pitchNotes.addAll(notes);
  final song = Song(
    id: 'guitar_demo_${name.split('-').first}',
    title: name,
    key: _key,
    scale: _scale,
    bpm: _bpm,
    bars: _bars,
    sections: [sec],
  );
  song.instruments['melody'] = _nylonSlot;
  // only the guitar lane has notes; the empty lanes are muted
  for (final id in ['bass', 'melodyDec', 'drums', 'beatDec']) {
    song.mutes[id] = true;
  }
  return song;
}

typedef _Demo = ({
  Map<String, Song> songs,
  int unassignable,
  Map<int, int> stringHistogram,
  int ringExtended,
});

_Demo _buildDemo() {
  final a1 = _blockChords();
  final a2 =
      applyStrokePattern(
        _blockChords(),
        const {},
        strokePatternById('folk'),
        bpm: _bpm,
      ).notes;
  final b1 = _arpeggio();
  final assigned = assignStrings(_arpeggio(), const {});
  final ring =
      applyRing(
        assigned.notes,
        const {},
        rangeEnd: ringRangeEnd(assigned.notes, const {}, _steps),
      ).notes;
  final hist = <int, int>{};
  for (final n in ring) {
    if (n.guitarString != null) {
      hist[n.guitarString!] = (hist[n.guitarString!] ?? 0) + 1;
    }
  }
  var extended = 0;
  for (var i = 0; i < ring.length; i++) {
    if (ring[i].endSteps > b1[i].endSteps + 1e-9) extended++;
  }
  return (
    songs: {
      _a1: _song(_a1, a1),
      _a2: _song(_a2, a2),
      _b1: _song(_b1, b1),
      _b2: _song(_b2, ring),
    },
    unassignable: assigned.unassignable.length,
    stringHistogram: hist,
    ringExtended: extended,
  );
}

List<PitchNote> _guitar(Song s) => s.sections.single.tracks['melody']!.pitchNotes;

Map<String, double> _exportVol(Song s) => {
  for (final e in s.vol.entries) e.key: s.mutes[e.key] == true ? 0.0 : e.value,
};

// ── MIDI parsing (single-track SMF as written by buildMidi) ─────────────
typedef _Ev = ({int midi, int on, int off, int vel});

({int tpq, List<int> programs, List<_Ev> notes}) _parseMidi(Uint8List b) {
  final bd = ByteData.sublistView(b);
  expect(String.fromCharCodes(b.sublist(0, 4)), 'MThd');
  final tpq = bd.getUint16(12);
  var p = 14;
  expect(String.fromCharCodes(b.sublist(p, p + 4)), 'MTrk');
  final len = bd.getUint32(p + 4);
  p += 8;
  final end = p + len;
  int vlq() {
    var v = 0;
    while (true) {
      final c = b[p++];
      v = (v << 7) | (c & 0x7f);
      if (c & 0x80 == 0) return v;
    }
  }

  var t = 0, status = 0;
  final programs = <int>[];
  final open = <int, List<(int, int)>>{};
  final notes = <_Ev>[];
  while (p < end) {
    t += vlq();
    var s = b[p];
    if (s & 0x80 != 0) {
      p++;
      status = s;
    } else {
      s = status;
    }
    if (s == 0xFF) {
      p++; // meta type
      final l = vlq();
      p += l;
      continue;
    }
    if (s == 0xF0 || s == 0xF7) {
      p += vlq();
      continue;
    }
    final kind = s & 0xF0;
    if (kind == 0xC0 || kind == 0xD0) {
      if (kind == 0xC0 && (s & 0x0F) == 0) programs.add(b[p]);
      p += 1;
      continue;
    }
    final d1 = b[p], d2 = b[p + 1];
    p += 2;
    if (kind == 0x90 && d2 > 0) {
      (open[d1] ??= []).add((t, d2));
    } else if (kind == 0x80 || (kind == 0x90 && d2 == 0)) {
      final q = open[d1];
      expect(q, isNotNull, reason: 'note-off without note-on ($d1 @ $t)');
      final (on, vel) = q!.removeAt(0);
      notes.add((midi: d1, on: on, off: t, vel: vel));
    }
  }
  expect(open.values.every((q) => q.isEmpty), isTrue, reason: 'hanging notes');
  return (tpq: tpq, programs: programs, notes: _sorted(notes));
}

List<_Ev> _sorted(List<_Ev> evs) => [...evs]..sort((x, y) {
  var c = x.on.compareTo(y.on);
  if (c == 0) c = x.midi.compareTo(y.midi);
  if (c == 0) c = x.off.compareTo(y.off);
  return c != 0 ? c : x.vel.compareTo(y.vel);
});

/// The events the note data asks for (same tick math as buildMidi's emit).
List<_Ev> _fromNoteData(List<PitchNote> notes, int tpq) {
  final tps = tpq / kStepsPerBeat;
  return _sorted([
    for (final n in notes)
      if (!n.muted)
        (() {
          final on = n.step * tps + n.offsetSteps * tps;
          return (
            midi: n.midi,
            on: on.round(),
            off: (on + n.soundingSteps * tps).round(),
            vel: n.velocity ?? 100,
          );
        })(),
  ]);
}

/// The legacy automatic strum (theory.dart strumPlan) for untouched chords.
List<_Ev> _legacyStrum(List<PitchNote> notes, int tpq) {
  final tps = tpq / kStepsPerBeat;
  final byStep = <int, List<PitchNote>>{};
  for (final n in notes) {
    (byStep[n.step] ??= []).add(n);
  }
  return _sorted([
    for (final group in byStep.values)
      for (final s in strumPlan([for (final n in group) n.midi]))
        (() {
          final n = group.firstWhere((g) => g.midi == s.midi);
          final on = n.step * tps + s.delayMs * tpq * _bpm / 60000.0;
          return (
            midi: s.midi,
            on: on.round(),
            off: (on + n.dur * tps).round(),
            vel: (100 * s.velScale).round().clamp(1, 127),
          );
        })(),
  ]);
}

/// The guitar lane's MIDI as the .mid export builds it (GM 24) and as the
/// WAV mix builds it for a catalog guitar (internal preset 0, forced strum,
/// mixer CC7/CC10).
({Uint8List mid, Uint8List wavJob}) _laneMidi(Song s) {
  final flat = flattenSong(
    s.sections,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
  );
  return (
    mid: buildMidi(flat, _bpm, melodyProgram: 24, tracks: const {'melody'}),
    wavJob: buildMidi(
      flat,
      _bpm,
      melodyProgram: 0,
      swing: s.swing,
      vol: _exportVol(s),
      tracks: const {'melody'},
      extraInstruments: {...s.instruments, 'melody': 0},
      strumGuitar: true,
      pan: s.pan,
    ),
  );
}

List<(int, int)> _stepMidi(List<PitchNote> notes) =>
    [for (final n in notes) (n.step, n.midi)]..sort((x, y) {
      final c = x.$1.compareTo(y.$1);
      return c != 0 ? c : x.$2.compareTo(y.$2);
    });

void _expectNoOverlap(Iterable<PitchNote> notes, String what) {
  final list = [...notes]..sort((x, y) => x.startSteps.compareTo(y.startSteps));
  for (var i = 0; i + 1 < list.length; i++) {
    expect(
      list[i].endSteps,
      lessThanOrEqualTo(list[i + 1].startSteps + 1e-9),
      reason: '$what: ${list[i].midi}@${list[i].startSteps} overlaps the next',
    );
  }
}

// ── WAV levels ──────────────────────────────────────────────────────────
typedef _Pcm = ({Float32List left, Float32List right, int sampleRate});

_Pcm _readStereo16(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  expect(String.fromCharCodes(bytes.sublist(0, 4)), 'RIFF');
  final channels = bd.getUint16(22, Endian.little);
  final sr = bd.getUint32(24, Endian.little);
  final bits = bd.getUint16(34, Endian.little);
  expect(channels, 2);
  expect(bits, 16);
  var p = 12;
  while (String.fromCharCodes(bytes.sublist(p, p + 4)) != 'data') {
    p += 8 + bd.getUint32(p + 4, Endian.little);
  }
  final len = bd.getUint32(p + 4, Endian.little);
  p += 8;
  final frames = len ~/ 4;
  final l = Float32List(frames), r = Float32List(frames);
  double f(int v) => v < 0 ? v / 0x8000 : v / 0x7fff;
  for (var i = 0; i < frames; i++) {
    l[i] = f(bd.getInt16(p + i * 4, Endian.little));
    r[i] = f(bd.getInt16(p + i * 4 + 2, Endian.little));
  }
  return (left: l, right: r, sampleRate: sr);
}

({double peak, double rms}) _levels(_Pcm x) {
  var peak = 0.0, sum = 0.0;
  for (final ch in [x.left, x.right]) {
    for (final v in ch) {
      final a = v.abs();
      if (a > peak) peak = a;
      sum += v * v;
    }
  }
  return (peak: peak, rms: math.sqrt(sum / (2 * x.left.length)));
}

double _db(double v) => v <= 0 ? -999 : 20 * math.log(v) / math.ln10;
double _r2(double v) => (v * 100).round() / 100;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('guitar A/B demo songs', () {
    final demo = _buildDemo();
    final songs = demo.songs;

    test('the four variants keep identical notes within each pair', () {
      expect(_guitar(songs[_a1]!).length, _bars * _folkHits.length * 6);
      expect(_guitar(songs[_b1]!).length, _bars * _arpOrder.length);
      // nothing dropped, moved to another step or octave-shifted
      expect(_stepMidi(_guitar(songs[_a2]!)), _stepMidi(_guitar(songs[_a1]!)));
      expect(_stepMidi(_guitar(songs[_b2]!)), _stepMidi(_guitar(songs[_b1]!)));
      // the voicings sit in the real guitar range and the progression is
      // Em Am C G (diatonic triads of E minor)
      for (var bar = 0; bar < _bars; bar++) {
        final v = _voicing(bar);
        expect(v.every((m) => m >= kGuitarLowestMidi && m <= kGuitarHighestMidi),
            isTrue);
        final pcs = v.map((m) => m % 12).toSet();
        final root = rootMidi(_chordRoots[bar], 0) % 12;
        final third = _chordNames[bar].endsWith('m') ? 3 : 4;
        expect(pcs, {root, (root + third) % 12, (root + 7) % 12});
      }
      // A1/B1 are untouched plain data
      for (final n in [..._guitar(songs[_a1]!), ..._guitar(songs[_b1]!)]) {
        expect(n.stroke, isNull);
        expect(n.velocity, isNull);
        expect(n.offsetSteps, 0);
        expect(n.durationSteps, isNull);
        expect(n.guitarString, isNull);
      }
    });

    test('A2 is the gt-001 folk pattern ↓ ↓↑ ↑↓↑ on every hit', () {
      final a1 = _guitar(songs[_a1]!);
      final a2 = _guitar(songs[_a2]!);
      final pattern = strokePatternById('folk');
      final hits = strokeChordHits(a2, a2.toSet());
      expect(hits.length, _bars * _folkHits.length);
      for (var k = 0; k < hits.length; k++) {
        final dir = pattern.dirs[k % pattern.dirs.length];
        final hit = [for (final i in hits[k]) a2[i]];
        final spec =
            dir == StrokeDir.down ? const StrokeSpec.down() : const StrokeSpec.up();
        final originalEnd = a1[hits[k].first].endSteps;
        for (final n in hit) {
          expect(n.stroke, isNotNull);
          expect(n.stroke!.dir, dir);
          expect(n.stroke!.spreadMs, spec.spreadMs);
          expect(n.velocity, isNotNull);
          expect(n.durationSteps, isNotNull);
          // every string ends where the chord ended
          expect(n.endSteps, closeTo(originalEnd, 1e-9));
        }
        // strike order: down = low → high, up = high → low
        final byOrder = [...hit]
          ..sort((x, y) => x.stroke!.order.compareTo(y.stroke!.order));
        final pitches = [for (final n in byOrder) n.midi];
        final sorted = [...pitches]..sort();
        expect(pitches, dir == StrokeDir.down ? sorted : sorted.reversed);
        final stepsPerMs = _bpm * kStepsPerBeat / 60000.0;
        for (var p = 0; p < byOrder.length; p++) {
          expect(
            byOrder[p].startSteps - byOrder.first.startSteps,
            closeTo(p * spec.spreadMs * stepsPerMs, 1e-9),
          );
          expect(
            byOrder[p].velocity,
            (100 * spec.accent * (1 - spec.falloff * p / (byOrder.length - 1)))
                .round(),
          );
        }
      }
    });

    test('B2 is assigned to real strings and rings (gt-002)', () {
      final b1 = _guitar(songs[_b1]!);
      final b2 = _guitar(songs[_b2]!);
      debugPrint(
        '[guitar-demo] B2 unassignable=${demo.unassignable} '
        'strings=${demo.stringHistogram} ringExtended=${demo.ringExtended}/'
        '${b2.length}',
      );
      // every note is playable in standard tuning: nothing is unassignable
      expect(demo.unassignable, 0);
      for (final n in b2) {
        expect(n.guitarString, isNotNull);
        expect(guitarPlayable(n.guitarString!, n.midi), isTrue);
      }
      expect(demo.ringExtended, greaterThan(0));
      for (var i = 0; i < b2.length; i++) {
        // ring only extends (originals never overlap here), never past the end
        expect(b2[i].endSteps, greaterThanOrEqualTo(b1[i].endSteps - 1e-9));
        expect(b2[i].endSteps, lessThanOrEqualTo(_steps + 1e-9));
      }
      // one string sounds one note at a time; one pitch too (single channel)
      for (var s = 1; s <= kGuitarStrings; s++) {
        _expectNoOverlap(b2.where((n) => n.guitarString == s), 'string $s');
      }
      for (final m in b2.map((n) => n.midi).toSet()) {
        _expectNoOverlap(b2.where((n) => n.midi == m), 'pitch $m');
      }
      // "울림 되돌리기" restores B1 exactly (apart from the strings)
      final reverted = revertRing(b2, const {}).notes;
      for (var i = 0; i < b1.length; i++) {
        final j = reverted[i].toJson()
          ..remove('guitarString')
          ..remove('stringLocked');
        expect(j, b1[i].toJson());
      }
    });

    test('MIDI events equal the note data (A2, B1, B2); A1 keeps the legacy strum', () {
      for (final name in [_a1, _a2, _b1, _b2]) {
        final s = songs[name]!;
        final notes = _guitar(s);
        final midi = _laneMidi(s);
        for (final bytes in [midi.mid, midi.wavJob]) {
          final parsed = _parseMidi(bytes);
          final want =
              name == _a1
                  ? _legacyStrum(notes, parsed.tpq)
                  : _fromNoteData(notes, parsed.tpq);
          expect(parsed.notes, want, reason: name);
          expect(parsed.notes.length, notes.length, reason: name);
        }
        expect(_parseMidi(midi.mid).programs.first, 24, reason: name);
        expect(_parseMidi(midi.wavJob).programs.first, 0, reason: name);
      }
      // the legacy strum really differs from the plain note data
      final a1 = _guitar(songs[_a1]!);
      final parsed = _parseMidi(_laneMidi(songs[_a1]!).mid);
      expect(parsed.notes, isNot(_fromNoteData(a1, parsed.tpq)));
    });

    test('songs survive a JSON round trip', () {
      for (final s in songs.values) {
        final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
        expect(Song.fromJson(j).toJson(), s.toJson());
      }
    });
  });

  final out = Platform.environment['HUMTRACK_DEMO_OUT'];
  test(
    'write the A/B demo (MIDI, WAV via exportWavSong, matched WAV, README)',
    () async {
      await _writeDemo(Directory(out!), _buildDemo());
    },
    skip: out == null || out.isEmpty ? 'set HUMTRACK_DEMO_OUT to write the demo' : false,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<void> _writeDemo(Directory outDir, _Demo demo) async {
  await outDir.create(recursive: true);
  final work = Directory('${outDir.path}/.work');
  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // bundled assets come straight from the repo (like the reference test)
  messenger.setMockMessageHandler('flutter/assets', (message) {
    final path = utf8.decode(
      message!.buffer.asUint8List(message.offsetInBytes, message.lengthInBytes),
    );
    final file = File(path);
    return SynchronousFuture(
      file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null,
    );
  });
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => work.path,
  );
  LoopStorage.rootOverride = work;
  addTearDown(() async {
    messenger.setMockMessageHandler('flutter/assets', null);
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    LoopStorage.rootOverride = null;
    if (await work.exists()) await work.delete(recursive: true);
  });

  // slot 1001 resolved offline: install the bundled FreePats nylon
  final catalog = SoundfontCatalog.instance;
  catalog.debugSetDirectory(
    await Directory('${work.path}/soundfonts').create(recursive: true),
  );
  await catalog.warm();
  final entry = catalog.bySlot(_nylonSlot)!;
  expect(entry.id, 'freepats_nylon');
  final sfPath = await catalog.ensureDownloaded(_nylonSlot);
  expect(sfPath, isNotNull);
  expect(catalog.localPath(_nylonSlot), sfPath);
  expect(isGuitarProgram(_nylonSlot), isTrue);
  expect(catalog.midiFallback(_nylonSlot), 24);

  final sizes = <String, int>{};
  Future<void> put(String name, List<int> bytes) async {
    await File('${outDir.path}/$name').writeAsBytes(bytes, flush: true);
    sizes[name] = bytes.length;
  }

  final measured = <String, ({double peak, double rms})>{};
  final pcms = <String, _Pcm>{};
  for (final e in demo.songs.entries) {
    final name = e.key, s = e.value;
    final sec = s.sections.single;
    final notes = _guitar(s);
    final mid = await exportMidiSong(
      s.sections,
      s.bpm,
      name,
      melodyProgram: s.instruments['melody'] ?? 0,
      bassProgram: s.instruments['bass'] ?? 33,
      melodyDecProgram: s.instruments['melodyDec'] ?? 48,
      drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
      extras: sec.extras,
      instruments: s.instruments,
      fallbackName: s.id,
      variationSeed: s.effectiveVariationSeed,
      groove: s.grooveContext,
      pan: s.pan,
    );
    final midBytes = await mid.readAsBytes();
    final parsed = _parseMidi(midBytes);
    expect(parsed.programs.first, 24, reason: '$name: GM nylon');
    expect(
      parsed.notes,
      name == _a1 ? _legacyStrum(notes, parsed.tpq) : _fromNoteData(notes, parsed.tpq),
      reason: name,
    );
    await put('$name.mid', midBytes);

    final wav = await exportWavSong(
      s.sections,
      s.bpm,
      s.swing,
      _exportVol(s),
      name,
      melodyProgram: s.instruments['melody'] ?? 0,
      bassProgram: s.instruments['bass'] ?? 33,
      melodyDecProgram: s.instruments['melodyDec'] ?? 48,
      drumProgram: s.instruments['drums'] ?? kDefaultDrumKit,
      extras: sec.extras,
      instruments: s.instruments,
      fallbackName: s.id,
      variationSeed: s.effectiveVariationSeed,
      groove: s.grooveContext,
      pan: s.pan,
    );
    expect(wav.skippedVocals, 0);
    final wavBytes = await wav.file.readAsBytes();
    await put('$name.wav', wavBytes);
    final pcm = _readStereo16(wavBytes);
    expect(pcm.sampleRate, 44100);
    pcms[name] = pcm;
    measured[name] = _levels(pcm);
    expect(measured[name]!.peak, greaterThan(.01), reason: '$name is silent');

    await put(
      '$name.song.json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(s.toJson())),
    );
  }

  // ── loudness match: one common RMS target, lowered for all if any gain
  // would push a peak over the ceiling ──
  const ceilingDb = -1.0;
  final ceiling = math.pow(10, ceilingDb / 20).toDouble();
  var targetDb = -20.0;
  for (final m in measured.values) {
    final peakAfter = m.peak * math.pow(10, targetDb / 20) / m.rms;
    if (peakAfter > ceiling) {
      targetDb = math.min(targetDb, _db(m.rms * ceiling / m.peak));
    }
  }
  final target = math.pow(10, targetDb / 20).toDouble();
  final levels = <String, Object>{};
  for (final name in demo.songs.keys) {
    final m = measured[name]!, pcm = pcms[name]!;
    final gain = target / m.rms;
    final l = Float32List(pcm.left.length), r = Float32List(pcm.right.length);
    for (var i = 0; i < l.length; i++) {
      l[i] = pcm.left[i] * gain;
      r[i] = pcm.right[i] * gain;
    }
    final bytes = encodeWavStereo16Raw(l, r, pcm.sampleRate);
    await put('$name.matched.wav', bytes);
    final after = _levels(_readStereo16(bytes));
    expect(after.peak, lessThanOrEqualTo(ceiling + 1e-4), reason: name);
    expect(_db(after.rms), closeTo(targetDb, .05), reason: name);
    levels[name] = {
      'seconds': _r2(pcm.left.length / pcm.sampleRate),
      'before': {
        'peak_dbfs': _r2(_db(m.peak)),
        'rms_dbfs': _r2(_db(m.rms)),
      },
      'gain_db': _r2(_db(gain)),
      'after': {
        'peak_dbfs': _r2(_db(after.peak)),
        'rms_dbfs': _r2(_db(after.rms)),
      },
    };
  }
  final levelsJson = {
    'method':
        'RMS over every sample of both channels of the whole file (render tail '
        'included), dBFS relative to digital full scale (a full-scale square '
        'wave = 0 dBFS). One common RMS target; lowered for all four if any '
        'gain would put a peak above the ceiling. 16-bit PCM, no limiter.',
    'target_rms_dbfs': _r2(targetDb),
    'requested_target_rms_dbfs': -20.0,
    'peak_ceiling_dbfs': ceilingDb,
    'files': levels,
  };
  await put(
    'levels.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(levelsJson)),
  );

  final facts = _sf2Facts(sfPath!, entry.sfBank, entry.sfProgram);
  await put(
    'sf2_facts.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(facts)),
  );

  final readme = _readme(demo, levelsJson, facts, sizes);
  await File('${outDir.path}/README.md').writeAsString(readme, flush: true);
  debugPrint('[guitar-demo] wrote ${sizes.length + 1} files to ${outDir.path}');
  for (final e in sizes.entries) {
    debugPrint('[guitar-demo]   ${e.key}: ${e.value} B');
  }
  for (final e in levels.entries) {
    debugPrint('[guitar-demo]   ${e.key}: ${jsonEncode(e.value)}');
  }
  debugPrint('[guitar-demo] sf2: ${jsonEncode(facts)}');
}

/// 16-bit stereo WAV with no gain applied (samples clamped only).
Uint8List encodeWavStereo16Raw(Float32List l, Float32List r, int sr) {
  final n = l.length;
  final data = ByteData(44 + n * 4);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  data.setUint32(4, 36 + n * 4, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, sr, Endian.little);
  data.setUint32(28, sr * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  str(36, 'data');
  data.setUint32(40, n * 4, Endian.little);
  int pcm(double x) {
    final s = x.clamp(-1.0, 1.0);
    return (s < 0 ? s * 0x8000 : s * 0x7fff).round();
  }

  for (var i = 0; i < n; i++) {
    data.setInt16(44 + i * 4, pcm(l[i]), Endian.little);
    data.setInt16(46 + i * 4, pcm(r[i]), Endian.little);
  }
  return data.buffer.asUint8List();
}

/// What the SF2 itself says (parsed with MeltySynth, the render engine).
Map<String, Object> _sf2Facts(String path, int bank, int program) {
  final sf = SoundFont.fromFile(path);
  final preset = sf.presets.firstWhere(
    (p) => p.bankNumber == bank && p.patchNumber == program,
  );
  final instRegions = [
    for (final pr in preset.regions)
      for (final ir in pr.instrument.regions) (pr: pr, ir: ir),
  ];
  final velRanges = <String>{
    for (final x in instRegions)
      '${x.ir.velocityRangeStart()}-${x.ir.velocityRangeEnd()}',
  };
  final presetVelRanges = <String>{
    for (final pr in preset.regions)
      '${pr.velocityRangeStart()}-${pr.velocityRangeEnd()}',
  };
  // per key in the guitar range: how many distinct velocity layers (distinct
  // sets of sounding regions over velocity 1..127) and how many regions
  // sound at once for one note-on
  var maxLayers = 0, minLayers = 1 << 30, maxStack = 0;
  final layersPerKey = <String, int>{};
  for (var key = kGuitarLowestMidi; key <= kGuitarHighestMidi; key++) {
    final sets = <String>{};
    for (var v = 1; v <= 127; v++) {
      final hit = <int>[
        for (var i = 0; i < instRegions.length; i++)
          if (instRegions[i].pr.contains(key, v) && instRegions[i].ir.contains(key, v)) i,
      ];
      if (hit.isEmpty) continue;
      sets.add(hit.join(','));
      maxStack = math.max(maxStack, hit.length);
    }
    layersPerKey['$key'] = sets.length;
    maxLayers = math.max(maxLayers, sets.length);
    minLayers = math.min(minLayers, sets.length);
  }
  return {
    'file': path.split(RegExp(r'[\\/]')).last,
    'presets_in_file': sf.presets.length,
    'preset_names': [
      for (final p in sf.presets) '${p.bankNumber}:${p.patchNumber} ${p.name}',
    ],
    'used_preset': '${preset.bankNumber}:${preset.patchNumber} ${preset.name}',
    'preset_zones': preset.regions.length,
    'preset_zone_velocity_ranges': presetVelRanges.toList()..sort(),
    'instruments_in_file': sf.instruments.length,
    'instrument_zones_reached': instRegions.length,
    'distinct_samples_reached': {for (final x in instRegions) x.ir.sample.name}.length,
    'sample_headers_in_file': sf.sampleHeaders.length,
    'instrument_zone_velocity_ranges': velRanges.toList()..sort(),
    'velocity_layers_per_key_min': minLayers,
    'velocity_layers_per_key_max': maxLayers,
    'max_regions_sounding_per_note_on': maxStack,
    'velocity_layers_per_key': layersPerKey,
  };
}

String _kb(int b) => '${(b / 1024).toStringAsFixed(1)} KB';

String _readme(
  _Demo demo,
  Map<String, Object> levelsJson,
  Map<String, Object> facts,
  Map<String, int> sizes,
) {
  final files = levelsJson['files'] as Map<String, Object>;
  final rows = StringBuffer();
  for (final e in files.entries) {
    final v = e.value as Map;
    final b = v['before'] as Map, a = v['after'] as Map;
    rows.writeln(
      '| ${e.key} | ${v['seconds']} | ${b['peak_dbfs']} | ${b['rms_dbfs']} | '
      '${v['gain_db']} | ${a['peak_dbfs']} | ${a['rms_dbfs']} |',
    );
  }
  final fileRows = StringBuffer();
  for (final e in sizes.entries) {
    fileRows.writeln('| `${e.key}` | ${_kb(e.value)} |');
  }
  final velRanges = (facts['instrument_zone_velocity_ranges'] as List).join(', ');
  final presetVel = (facts['preset_zone_velocity_ranges'] as List).join(', ');
  return '''
# HumTrack 기타 A/B 청취 데모 (2026-10-22)

`docs/product/song-completion-plan.md` §1 기준: 작은 자체 제작 8마디 진행으로
일반 / 스트로크 / 울림 아르페지오를 같은 음량에서 비교한다.
관련 스펙: `docs/specs/guitar/gt-001-stroke-conversion.md`,
`docs/specs/guitar/gt-002-string-assignment-ring.md`.

## 음악 내용 (자체 제작, 저작권 없음)
- 8마디, 4/4, **80 BPM**, 키 **E 단조**, 한 마디에 한 코드:
  **Em – Am – C – G – Em – Am – C – G**
  (`theory.dart`의 `guitarVoicing`은 키의 다이어토닉 3화음을 쓰므로 E 마디는 **Em**이다.)
- 보이싱 (MIDI, 모두 표준 튜닝 실제 기타 음역 안):
  Em 40 47 52 55 59 64 · Am 45 52 57 60 64 69 · C 48 55 60 64 67 72 · G 43 50 55 59 62 67
- 악기: 카탈로그 슬롯 1001 **FreePats nylon** (`assets/sounds/reference/freepats_nylon.sf2`, CC0),
  번들 에셋에서 오프라인 설치. `.mid` 파일은 GM 프로그램 24(Nylon Guitar)로 내보내진다.
- 한 곡 = 8마디 섹션 1개, 기타는 melody 트랙. 비어 있는 다른 트랙(bass, melodyDec, drums, beatDec)은
  음소거 상태로 저장·렌더했다 (소리 차이 없음, 렌더 시간만 줄임).
  참고: 앱의 마디 토글은 1/2/4마디만 제공하며, 8마디 섹션은 MIDI 가져오기 등에서 만들어지는 형태다.

## 변형 (각 쌍은 같은 음·같은 리듬, 기능만 다름)
| 이름 | 내용 |
|---|---|
| `A1-chords-normal` | 블록 코드, 포크 8분 리듬(박 1, 2, 2&, 3&, 4, 4& = ↓ ↓↑ ↑↓↑ 자리). 손대지 않은 음 → 기존 자동 스트럼(항상 다운, 28 ms, -18%) |
| `A2-chords-stroke` | A1과 같은 타격을 gt-001 패턴 프리셋 `↓ ↓↑ ↑↓↑`(`applyStrokePattern`, 기본값: 다운 28 ms/100%, 업 18 ms/80%, 감쇠 18%)으로 변환. 각 줄이 원래 코드 끝에서 함께 끝남 |
| `B1-arpeggio-normal` | 같은 코드의 핑거피킹 아르페지오, 8분음표(보이싱 순서 0 2 3 4 5 4 3 2: 베이스 후 윗줄), 각 음 8분 길이(일반 데이터) |
| `B2-arpeggio-ring` | B1과 같은 음에 gt-002 `assignStrings` + `applyRing`(트랙 전체, 범위 끝 = 섹션 끝) 적용 |

B2 줄 배정 결과: 배정 불가 ${demo.unassignable}개, 줄별 음 수 ${demo.stringHistogram}
(1 = 높은 E), 울림으로 길어진 음 ${demo.ringExtended}/${_bars * _arpOrder.length}개.

## 파일
| 파일 | 크기 |
|---|---|
$fileRows| `README.md` | (이 파일) |
| `test-output.log` | 아래 명령의 실행 로그 |

- `<이름>.mid`: 실제 MIDI 내보내기(`exportMidiSong`) 결과, GM 24. HumTrack으로 다시 가져올 수 있다.
- `<이름>.wav`: 실제 WAV 내보내기 경로(`exportWavSong` 전체 믹스, 슬롯 1001 → FreePats nylon SF2,
  MeltySynth, 44.1 kHz 16비트 스테레오). 내보내기 규칙대로 피크 정규화된 상태.
- `<이름>.matched.wav`: 아래 표대로 RMS를 맞춘 비교용 파일 (청취는 이 파일로).
- `<이름>.song.json`: `Song.toJson()` (곡 데이터 그대로).
- `levels.json`: 맞추기 전·후 피크/RMS와 게인. `sf2_facts.json`: SF2에서 직접 읽은 사실.

## 음량 맞추기
방법: 파일 전체(렌더 꼬리 포함), 양 채널 모든 샘플의 RMS. dBFS는 디지털 풀스케일 기준.
요청 목표 -20 dBFS RMS, 피크 상한 ${levelsJson['peak_ceiling_dbfs']} dBFS. 한 파일이라도 넘으면 네 파일 모두 목표를 같이 낮춘다.
**적용 목표: ${levelsJson['target_rms_dbfs']} dBFS RMS.** 리미터 없음, 클리핑 없음.
원본 `.wav`는 앱 내보내기 규칙대로 피크 정규화되어 있어 피크는 같고 RMS가 다르다.
A1이 조금 긴 이유: 기존 자동 스트럼은 각 줄을 늦게 시작한 뒤 원래 길이만큼 울리므로 마지막 코드가 섹션 끝을 약간 넘는다.

| 파일 | 길이(s) | 원본 피크 | 원본 RMS | 게인 dB | 맞춘 후 피크 | 맞춘 후 RMS |
|---|---|---|---|---|---|---|
$rows
주의: RMS는 단순 음량 지표다(청감 가중 LUFS 아님). 다운스트로크 위주인 A1과 업스트로크가 가벼운 A2는
어택 모양이 달라 같은 RMS에서도 체감 음량이 조금 다를 수 있다.

## 다시 만들기
```
cd C:/src/humming-v2/mobile && TMP=C:/src/humming-v2/artifacts/guitar-review-20261022/temp TEMP=C:/src/humming-v2/artifacts/guitar-review-20261022/temp HUMTRACK_DEMO_OUT=C:/src/humming-v2/artifacts/guitar-demo-20261022 /c/src/flutter/bin/flutter test --no-pub test/looptap/guitar_demo_test.dart
```
`HUMTRACK_DEMO_OUT`이 없으면 같은 테스트가 네 곡을 만들고 검사만 한다(파일 쓰기 없음).
검사 내용: 쌍 안에서 음 수·스텝·음높이 동일(누락·옥타브 이동 없음), A2 모든 타격이 패턴 방향/간격/세기/끝점대로,
B2 모든 음 줄 배정·같은 줄과 같은 음높이 겹침 없음·울림 되돌리기 시 B1과 동일,
A2/B1/B2의 MIDI 이벤트(.mid용과 WAV 렌더용 모두) = 음 데이터, A1은 기존 자동 스트럼과 일치.

## SF2에서 확인한 사실 (`sf2_facts.json`, MeltySynth로 파싱)
- 파일 안 프리셋 ${facts['presets_in_file']}개: ${(facts['preset_names'] as List).join(', ')}. 사용 프리셋 `${facts['used_preset']}`.
- 프리셋 존 ${facts['preset_zones']}개 (벨로시티 범위: $presetVel), 도달하는 인스트루먼트 존 ${facts['instrument_zones_reached']}개,
  서로 다른 샘플 ${facts['distinct_samples_reached']}개 (파일 전체 샘플 헤더 ${facts['sample_headers_in_file']}개).
- 인스트루먼트 존 벨로시티 범위: $velRanges.
- 기타 음역(MIDI $kGuitarLowestMidi–$kGuitarHighestMidi) 한 키당 벨로시티 레이어 수: 최소 ${facts['velocity_layers_per_key_min']}, 최대 ${facts['velocity_layers_per_key_max']}.
  한 번의 note-on에 동시에 울리는 존 최대 ${facts['max_regions_sounding_per_note_on']}개.
  즉 벨로시티 레이어가 키마다 하나뿐이면, 세게/약하게 친 음은 **같은 샘플**의 음량(과 엔진의 벨로시티 처리)만 다르고
  다른 샘플로 바뀌지 않는다. 스트로크의 세기 감쇠·업스트로크 액센트도 이 범위 안에서만 들린다.
- 라운드로빈: SF2 형식에는 라운드로빈 선택 기능이 없다. MeltySynth `noteOn`은 키·벨로시티가 맞는 존을
  **모두** 결정적으로 재생한다(무작위·순환 선택 없음). 따라서 같은 음을 같은 세기로 다시 치면 같은 샘플이 나온다.

## 한계 (정직하게)
- 음색은 단일 SF2 프리셋(FreePats 클래식 기타) 하나뿐이다. 줄마다 다른 샘플, 업/다운 스트로크 전용 샘플,
  피크 소리, 줄 잡음, 팜뮤트, 하모닉스는 없다 (gt-001/gt-002 범위 밖, G3 이후).
- gt-001/gt-002가 바꾸는 것은 **음의 시간·세기·길이(스케줄링)** 뿐이다. 샘플 품질이 좋아지는 것이 아니다.
  A1↔A2, B1↔B2 차이는 오직 이벤트 타이밍/세기/길이 차이다.
- 한 MIDI 채널에서는 같은 음높이 두 개가 독립적으로 겹쳐 울릴 수 없다. B2는 같은 음높이를 다음 같은 음 시작에서 끊는다.
- 울림은 섹션 끝을 넘지 않는다(v1). 마지막 마디의 음은 섹션 끝에서 멈추고 렌더 꼬리(1.2 s)는 릴리스/리버브만 담는다.
- WAV는 MeltySynth 오프라인 렌더(앱 내보내기와 같은 경로)다. 실시간 재생 엔진과 미세한 차이가 있을 수 있다.
- RMS 맞추기는 청감 가중이 아니다.
''';
}
