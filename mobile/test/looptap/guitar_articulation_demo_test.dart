// Listening demo for gt-003 guitar articulations (짧게 / 팜뮤트 근사 /
// 하모닉스 근사). Spec: docs/specs/guitar/gt-003-palm-mute-harmonics.md
// (acceptance box "Demo"). Format follows guitar_demo_test.dart (G2).
//
// The music is our own: 8 bars of 4/4 at 80 BPM in E minor, one chord per
// bar (Em Am C G Em Am C G), voiced by HumTrack's own guitarVoicing, on
// catalog slot 1001 (FreePats nylon).
//
// ALWAYS: builds the songs with the real pure functions (applyStrokePattern,
// applyArticulation, ArticulationPlan) and checks them: pair notes identical
// except the articulation, apply counts, plan channels, the `.mid` r4
// routing (role channel, owner GM program, sounding pitch, gated length)
// and the WAV role-job MIDI (GM 28 key S, GM 31 key S - 24).
// ONLY with HUMTRACK_DEMO_OUT set: writes .mid (exportMidiSong), .wav (the
// real exportWavSong full mix), loudness-matched copies, levels.json,
// .song.json files, a GM-font render of the same-pitch case's exported .mid
// and a Korean README.md; also renders exportStems for every song.
//
// Regenerate (from mobile/):
//   HUMTRACK_DEMO_OUT=<dir> /c/src/flutter/bin/flutter test --no-pub \
//     test/looptap/guitar_articulation_demo_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/guitar_articulation.dart';
import 'package:humming/looptap/music/guitar_stroke.dart';
import 'package:humming/looptap/music/guitar_tuning.dart';
import 'package:humming/looptap/music/instruments.dart';
import 'package:humming/looptap/music/midi_export.dart';
import 'package:humming/looptap/music/song_util.dart';
import 'package:humming/looptap/music/soundfont_catalog.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/music/wav_export.dart';
import 'package:humming/looptap/state/loop_storage.dart';

import '../support/midi_all_events.dart';

const int _bpm = 80;
const int _bars = 8;
const int _nylonSlot = 1001;
const int _nylonGm = 24;
const String _key = 'E';
const String _scale = 'minor';
const List<String> _chordRoots = ['E', 'A', 'C', 'G', 'E', 'A', 'C', 'G'];

/// Same folk hits as the G2 demo A-pair: beats 1, 2, 2&, 3& (tied), 4, 4&.
const List<(int, int)> _folkHits = [
  (0, 4),
  (4, 2),
  (6, 4),
  (10, 2),
  (12, 2),
  (14, 2),
];

/// Gentle 8th-note arpeggio over the 6-note voicing. -1 = the top voice an
/// octave up, -2 = the fifth voice an octave up (the high line that reaches
/// into the harmonic-tone range 74..110).
const List<int> _arpOrder = [0, 2, 3, 4, -1, 5, -2, 4];

const String _a3n = 'A3-normal';
const String _a3s = 'A3-staccato';
const String _a3p = 'A3-palm';
const String _b3n = 'B3-normal';
const String _b3h = 'B3-harmonic';
const String _mix = 'MIX-samepitch';
const String _mixRender = 'MIX-samepitch.midrender';

/// One step at 80 BPM = 187.5 ms.
const double _stepSec = 60 / _bpm / kStepsPerBeat;

List<int> _voicing(int bar) =>
    guitarVoicing(rootMidi(_chordRoots[bar], 2), _key, _scale);

PitchNote _note(int midi, int step, int dur, {double offset = 0}) => PitchNote(
  midi: midi,
  freq: midiToFreq(midi),
  step: step,
  dur: dur,
  offsetSteps: offset,
);

List<PitchNote> _blockChords() => [
  for (var bar = 0; bar < _bars; bar++)
    for (final (s, d) in _folkHits)
      for (final m in _voicing(bar)) _note(m, bar * 16 + s, d),
];

int _arpPitch(int bar, int i) {
  final v = _voicing(bar);
  return switch (i) {
    -1 => v[5] + 12,
    -2 => v[4] + 12,
    _ => v[i],
  };
}

List<PitchNote> _arpeggio() => [
  for (var bar = 0; bar < _bars; bar++)
    for (var i = 0; i < _arpOrder.length; i++)
      _note(_arpPitch(bar, _arpOrder[i]), bar * 16 + i * 2, 2),
];

/// Normal 52 for ~2 s (11 steps = 2.06 s) plus palm-tone 52 hits at 0.25 s
/// and 1.0 s (step + 1/3 = exact quarter seconds at 80 BPM).
List<PitchNote> _samePitch({required bool withPalm}) => [
  _note(52, 0, 11),
  if (withPalm) _note(52, 1, 2, offset: 1 / 3),
  if (withPalm) _note(52, 5, 2, offset: 1 / 3),
];

Section _section(List<PitchNote> notes, int bars) {
  final sec = Section(id: 'A', name: 'A', bars: bars);
  sec.tracks['melody']!.pitchNotes.addAll(notes);
  return sec;
}

Song _song(String name, List<PitchNote> notes, {int bars = _bars}) {
  final song = Song(
    id: 'gt3_demo_${name.replaceAll('-', '_').replaceAll('.', '_')}',
    title: name,
    key: _key,
    scale: _scale,
    bpm: _bpm,
    bars: bars,
    sections: [_section(notes, bars)],
  );
  song.instruments['melody'] = _nylonSlot;
  // only the guitar lane has notes; the empty lanes are muted
  for (final id in ['bass', 'melodyDec', 'drums', 'beatDec']) {
    song.mutes[id] = true;
  }
  return song;
}

/// applyArticulation exactly as the panel calls it: the channel the song
/// would give the role with the tentative notes.
ArticulationEdit _apply(
  List<PitchNote> notes,
  Set<PitchNote> selected,
  ArticulationKind kind, {
  int bars = _bars,
}) => applyArticulation(
  notes,
  selected,
  newArticulation(kind),
  channelFor:
      (role, tentative) => ArticulationPlan.build(
        sections: [_section(tentative, bars)],
        instruments: const {'melody': _nylonSlot},
      ).channelFor('melody', role),
);

typedef _Demo = ({
  Map<String, Song> songs,
  Song mixReference,
  Map<String, ArticulationEdit> edits,
});

_Demo _buildDemo() {
  // A3 base: the G2 folk block chords converted with the gt-001 folk stroke
  // pattern, so every variant carries the same explicit stroke data (the
  // legacy auto strum only touches untouched chords, never articulated ones).
  List<PitchNote> strummed() =>
      applyStrokePattern(
        _blockChords(),
        const {},
        strokePatternById('folk'),
        bpm: _bpm,
      ).notes;
  final a3n = strummed();
  final stac = _apply(strummed(), const {}, ArticulationKind.staccato);
  final palm = _apply(strummed(), const {}, ArticulationKind.palmTone);
  final b3n = _arpeggio();
  final harm = _apply(_arpeggio(), const {}, ArticulationKind.harmonicTone);
  final mixNotes = _samePitch(withPalm: true);
  final mixEdit = _apply(
    mixNotes,
    {mixNotes[1], mixNotes[2]},
    ArticulationKind.palmTone,
    bars: 1,
  );
  return (
    songs: {
      _a3n: _song(_a3n, a3n),
      _a3s: _song(_a3s, stac.notes),
      _a3p: _song(_a3p, palm.notes),
      _b3n: _song(_b3n, b3n),
      _b3h: _song(_b3h, harm.notes),
      _mix: _song(_mix, mixEdit.notes, bars: 1),
    },
    mixReference: _song(
      'MIX-reference',
      _samePitch(withPalm: false),
      bars: 1,
    ),
    edits: {_a3s: stac, _a3p: palm, _b3h: harm, _mix: mixEdit},
  );
}

List<PitchNote> _guitar(Song s) =>
    s.sections.single.tracks['melody']!.pitchNotes;

Map<String, double> _exportVol(Song s) => {
  for (final e in s.vol.entries) e.key: s.mutes[e.key] == true ? 0.0 : e.value,
};

Map<String, dynamic> _withoutArt(PitchNote n) =>
    n.toJson()..remove('articulation');

// ── .mid expectations (r4 rule, computed from the note data) ────────────
typedef _N = ({int channel, int key, int velocity, int on, int off});

int _cmpN(_N x, _N y) {
  for (final c in [
    x.on.compareTo(y.on),
    x.key.compareTo(y.key),
    x.channel.compareTo(y.channel),
    x.off.compareTo(y.off),
    x.velocity.compareTo(y.velocity),
  ]) {
    if (c != 0) return c;
  }
  return 0;
}

List<_N> _sortedN(Iterable<_N> xs) => [...xs]..sort(_cmpN);

/// What a `.mid` must hold for [notes] under [plan]: every note at its
/// sounding pitch, start = step + offset, length = its own length capped by
/// the articulation gate, velocity × the snapshot's scale; palm/harmonic
/// notes with a plan channel on that channel (same key there: the earlier
/// note ends at the later onset), everything else on the track channel 0.
List<_N> _expectedMid(List<PitchNote> notes, ArticulationPlan plan, int tpq) {
  final tps = tpq / kStepsPerBeat;
  final out = <_N>[];
  final voice = <({int ch, int key, double on, double off, int vel})>[];
  for (final n in notes) {
    if (n.muted) continue;
    final on = n.step * tps + n.offsetSteps * tps;
    final a = n.articulation;
    var gate = n.soundingSteps;
    var vel = n.velocity ?? 100;
    if (a != null && a.gateMs != null) {
      gate = math.min(gate, a.gateMs! / 1000 * _bpm / 60 * kStepsPerBeat);
    }
    if (a != null && a.velScale != 1.0) {
      vel = (vel * a.velScale).round().clamp(1, 127);
    }
    final role = artRoleOf(a?.kind);
    final ch = role == null ? null : plan.channelFor('melody', role);
    if (ch == null) {
      out.add((
        channel: 0,
        key: n.midi,
        velocity: vel,
        on: on.round(),
        off: (on + gate * tps).round(),
      ));
    } else {
      voice.add((ch: ch, key: n.midi, on: on, off: on + gate * tps, vel: vel));
    }
  }
  for (final v in voice) {
    var off = v.off;
    for (final w in voice) {
      if (w.ch == v.ch && w.key == v.key && w.on > v.on && w.on < off) {
        off = w.on;
      }
    }
    out.add((
      channel: v.ch,
      key: v.key,
      velocity: v.vel,
      on: v.on.round(),
      off: off.round(),
    ));
  }
  return _sortedN(out);
}

/// Checks a `.mid` against the r4 rule for [s]; returns its notes.
List<_N> _checkMid(Uint8List bytes, Song s, String what) {
  final plan = ArticulationPlan.of(s);
  final read = readMidiEvents(bytes);
  final notes = _sortedN(midiNotes(read.events));
  expect(notes, _expectedMid(_guitar(s), plan, read.tpq), reason: what);
  expect(notes.length, _guitar(s).length, reason: '$what: nothing dropped');
  final programs = read.events.where((e) => e.kind == 0xC0).toList();
  // the track keeps the nylon's GM fallback; GM 28/31 never appear in .mid
  expect(
    programs.firstWhere((e) => e.channel == 0).a,
    _nylonGm,
    reason: what,
  );
  expect(programs.map((e) => e.a), everyElement(isNot(isIn([28, 31]))));
  // each role channel: the owner's GM program at t=0 before its first note
  for (final r in plan.routes) {
    final ev = read.events.where((e) => e.channel == r.channel).toList();
    if (ev.isEmpty) continue;
    expect(ev.first.kind, 0xC0, reason: '$what ch ${r.channel}');
    expect(ev.first.a, _nylonGm, reason: '$what ch ${r.channel}');
    expect(ev.first.tick, 0, reason: '$what ch ${r.channel}');
  }
  return notes;
}

/// The guitar lane's `.mid` bytes as exportMidiSong builds them (GM
/// fallback 24 for slot 1001, the song's plan), without the file write.
Uint8List _laneMid(Song s) => buildMidi(
  flattenSong(
    s.sections,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
  ),
  _bpm,
  melodyProgram: _nylonGm,
  pan: s.pan,
  articulations: ArticulationPlan.of(s),
);

/// The WAV exporter's job MIDI for the guitar lane and [role] (catalog
/// guitar = internal preset 0 with the forced strum, mixer CC7/CC10).
Uint8List _wavJob(Song s, ArtRole role) => buildMidi(
  flattenSong(
    s.sections,
    variationSeed: s.effectiveVariationSeed,
    groove: s.grooveContext,
  ),
  _bpm,
  melodyProgram: 0,
  swing: s.swing,
  vol: _exportVol(s),
  tracks: const {'melody'},
  extraInstruments: {...s.instruments, 'melody': 0},
  strumGuitar: true,
  pan: s.pan,
  articulations: ArticulationPlan.of(s),
  articulationRole: role,
);

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

/// RMS of both channels between [t0] and [t1] seconds.
double _rmsAt(_Pcm x, double t0, double t1) {
  final a = (t0 * x.sampleRate).round();
  final b = math.min((t1 * x.sampleRate).round(), x.left.length);
  var acc = 0.0;
  for (var i = a; i < b; i++) {
    acc += x.left[i] * x.left[i] + x.right[i] * x.right[i];
  }
  return math.sqrt(acc / (2 * (b - a)));
}

void _expectAudible(_Pcm x, String what) {
  for (final ch in [x.left, x.right]) {
    expect(ch.every((v) => v.isFinite), isTrue, reason: '$what: non-finite');
  }
  expect(_levels(x).peak, greaterThan(.01), reason: '$what is silent');
}

double _db(double v) => v <= 0 ? -999 : 20 * math.log(v) / math.ln10;
double _r2(double v) => (v * 100).round() / 100;
double _r3(double v) => (v * 1000).round() / 1000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // slot 1001 must resolve as a guitar for the plan: load the bundled
  // catalog metadata (read-only; no files written without the env var)
  setUpAll(() async {
    messenger.setMockMessageHandler('flutter/assets', (message) {
      final path = utf8.decode(
        message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        ),
      );
      final file = File(path);
      return SynchronousFuture(
        file.existsSync() ? ByteData.sublistView(file.readAsBytesSync()) : null,
      );
    });
    await SoundfontCatalog.instance.warm();
    expect(isGuitarProgram(_nylonSlot), isTrue);
  });
  tearDownAll(() => messenger.setMockMessageHandler('flutter/assets', null));

  group('gt-003 articulation demo songs', () {
    late _Demo demo;
    late Map<String, Song> songs;
    setUpAll(() {
      demo = _buildDemo();
      songs = demo.songs;
    });

    test('pairs keep identical notes; only the articulation differs', () {
      expect(_guitar(songs[_a3n]!).length, _bars * _folkHits.length * 6);
      expect(_guitar(songs[_b3n]!).length, _bars * _arpOrder.length);
      for (final (base, other) in [(_a3n, _a3s), (_a3n, _a3p), (_b3n, _b3h)]) {
        final x = _guitar(songs[base]!), y = _guitar(songs[other]!);
        expect(y.length, x.length, reason: other);
        for (var i = 0; i < x.length; i++) {
          expect(_withoutArt(y[i]), _withoutArt(x[i]), reason: '$other #$i');
        }
      }
      // the normal versions carry no articulation; A3 carries the folk
      // stroke on every note (same stroke data in all three A3 files)
      for (final n in [..._guitar(songs[_a3n]!), ..._guitar(songs[_b3n]!)]) {
        expect(n.articulation, isNull);
      }
      expect(_guitar(songs[_a3n]!).every((n) => n.stroke != null), isTrue);
      // voicings in the real guitar range, high line inside 74..86
      for (final n in _guitar(songs[_b3n]!)) {
        expect(n.midi, inInclusiveRange(kGuitarLowestMidi, kGuitarHighestMidi));
      }
    });

    test('apply counts and default snapshots', () {
      final e = demo.edits;
      const total = _bars * 6 * 6;
      final stacArt = newArticulation(ArticulationKind.staccato);
      final palmArt = newArticulation(ArticulationKind.palmTone);
      final harmArt = newArticulation(ArticulationKind.harmonicTone);
      expect(stacArt.gateMs, kStaccatoGateMs);
      expect((palmArt.gateMs, palmArt.velScale), (kPalmGateMs, kPalmVelScale));
      expect(
        (e[_a3s]!.applied, e[_a3s]!.outOfRange, e[_a3s]!.noChannel),
        (total, 0, 0),
      );
      expect(
        (e[_a3p]!.applied, e[_a3p]!.outOfRange, e[_a3p]!.noChannel),
        (total, 0, 0),
      );
      expect(_guitar(songs[_a3s]!).every((n) => n.articulation == stacArt),
          isTrue);
      expect(_guitar(songs[_a3p]!).every((n) => n.articulation == palmArt),
          isTrue);
      // harmonic: only the high-line notes inside 74..110 take it
      final b3n = _guitar(songs[_b3n]!), b3h = _guitar(songs[_b3h]!);
      final inRange = b3n
          .where((n) => n.midi >= kHarmonicToneLo && n.midi <= kHarmonicToneHi)
          .length;
      final h = e[_b3h]!;
      debugPrint(
        '[gt3-demo] B3 harmonic applied=${h.applied} '
        'outOfRange=${h.outOfRange} noChannel=${h.noChannel}',
      );
      expect((h.applied, h.outOfRange, h.noChannel), (14, 50, 0));
      expect(h.applied, inRange);
      for (var i = 0; i < b3n.length; i++) {
        expect(b3h[i].midi, b3n[i].midi, reason: 'pitch unchanged #$i');
        final fits = b3n[i].midi >= kHarmonicToneLo;
        expect(b3h[i].articulation, fits ? harmArt : isNull, reason: '#$i');
      }
      // same-pitch case: both palm hits applied, the normal 52 untouched
      final m = e[_mix]!;
      expect((m.applied, m.outOfRange, m.noChannel), (2, 0, 0));
      final mix = _guitar(songs[_mix]!);
      expect(
        [for (final n in mix) (n.midi, n.startSteps, n.articulation?.kind)],
        [
          (52, 0.0, null),
          (52, 1 + 1 / 3, ArticulationKind.palmTone),
          (52, 5 + 1 / 3, ArticulationKind.palmTone),
        ],
      );
      expect(mix[1].startSteps * _stepSec, closeTo(.25, 1e-9));
      expect(mix[2].startSteps * _stepSec, closeTo(1.0, 1e-9));
      expect(mix[0].soundingSteps * _stepSec, closeTo(2.0625, 1e-9));
    });

    test('the plan allocates articulation channels', () {
      for (final name in [_a3n, _a3s, _b3n]) {
        final plan = ArticulationPlan.of(songs[name]!);
        expect(plan.isGuitar('melody'), isTrue, reason: name);
        expect(plan.routes, isEmpty, reason: name);
      }
      for (final (name, role) in [
        (_a3p, ArtRole.muteVoice),
        (_b3h, ArtRole.harmonicVoice),
        (_mix, ArtRole.muteVoice),
      ]) {
        final plan = ArticulationPlan.of(songs[name]!);
        final ch = plan.channelFor('melody', role);
        expect(ch, isNotNull, reason: name);
        expect(kExtraPitchChannels, contains(ch), reason: name);
        expect(kArticulationReservedChannels, isNot(contains(ch)));
        expect(plan.shortRoles('melody'), isEmpty, reason: name);
        expect(plan.routes.length, 1, reason: name);
      }
    });

    test('.mid follows r4: role channel, owner GM program, sounding pitch, '
        'gated length', () {
      for (final e in songs.entries) {
        _checkMid(_laneMid(e.value), e.value, e.key);
      }
      final palmCh = ArticulationPlan.of(songs[_a3p]!)
          .channelFor('melody', ArtRole.muteVoice)!;
      final a3p = _checkMid(_laneMid(songs[_a3p]!), songs[_a3p]!, _a3p);
      expect(a3p.every((x) => x.channel == palmCh), isTrue);
      final a3s = _checkMid(_laneMid(songs[_a3s]!), songs[_a3s]!, _a3s);
      expect(a3s.every((x) => x.channel == 0), isTrue, reason: 'staccato');
      final harmCh = ArticulationPlan.of(songs[_b3h]!)
          .channelFor('melody', ArtRole.harmonicVoice)!;
      final b3h = _checkMid(_laneMid(songs[_b3h]!), songs[_b3h]!, _b3h);
      expect(b3h.where((x) => x.channel == harmCh).length, 14);
      expect(
        b3h.where((x) => x.channel == harmCh).every((x) => x.key >= 74),
        isTrue,
        reason: 'harmonic notes keep the sounding pitch S, never S-24',
      );
      // same pitch: the normal 52 keeps its whole 11 steps on ch 0 and the
      // palm hits sit on the role channel
      final read = readMidiEvents(_laneMid(songs[_mix]!));
      final tps = read.tpq / kStepsPerBeat;
      final notes = midiNotes(read.events);
      final normal = notes.where((x) => x.channel == 0).single;
      expect((normal.key, normal.on / tps, normal.off / tps), (52, 0.0, 11.0));
      final mixCh = ArticulationPlan.of(songs[_mix]!)
          .channelFor('melody', ArtRole.muteVoice)!;
      final pm = notes.where((x) => x.channel == mixCh).toList();
      expect(pm.length, 2);
      for (final x in pm) {
        expect(x.key, 52);
        expect((x.off - x.on) / tps * _stepSec, closeTo(.25, 1e-3));
      }
    });

    test('WAV role jobs: GM 28 key S, GM 31 key S-24, track job keeps the '
        'rest', () {
      final flatOf = {
        for (final e in songs.entries)
          e.key: flattenSong(
            e.value.sections,
            variationSeed: e.value.effectiveVariationSeed,
            groove: e.value.grooveContext,
          ),
      };
      for (final e in songs.entries) {
        final s = e.value;
        final plan = ArticulationPlan.of(s);
        final jobs = articulationJobs(
          flatOf[e.key]!,
          plan,
          'melody',
          0,
          (role) => _wavJob(s, role),
        );
        final notes = _guitar(s);
        final palm = notes
            .where((n) => n.articulation?.kind == ArticulationKind.palmTone)
            .toList();
        final harm = notes
            .where((n) => n.articulation?.kind == ArticulationKind.harmonicTone)
            .toList();
        expect(jobs.length, (palm.isEmpty ? 0 : 1) + (harm.isEmpty ? 0 : 1),
            reason: e.key);
        final track = midiNotes(readMidiEvents(_wavJob(s, ArtRole.track)).events);
        expect(track.length, notes.length - palm.length - harm.length,
            reason: e.key);
        expect(track.every((x) => x.channel == 0), isTrue, reason: e.key);
        for (final (role, list, program, offset) in [
          (ArtRole.muteVoice, palm, kPalmToneProgram, 0),
          (ArtRole.harmonicVoice, harm, kHarmonicToneProgram, 24),
        ]) {
          if (list.isEmpty) continue;
          final ch = plan.channelFor('melody', role)!;
          final read = readMidiEvents(_wavJob(s, role));
          final first = read.events.firstWhere((x) => x.kind != 0xFF);
          expect((first.kind, first.channel, first.a), (0xC0, ch, program));
          final got = midiNotes(read.events);
          expect(got.every((x) => x.channel == ch), isTrue);
          expect(
            [for (final x in got) x.key]..sort(),
            [for (final n in list) n.midi - offset]..sort(),
            reason: '${e.key} ${role.name}',
          );
        }
      }
    });

    test('songs survive a JSON round trip', () {
      for (final s in [...songs.values, demo.mixReference]) {
        final j = jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>;
        expect(Song.fromJson(j).toJson(), s.toJson());
      }
    });
  });

  final out = Platform.environment['HUMTRACK_DEMO_OUT'];
  test(
    'write the gt-003 demo (MIDI, WAV mix, stems, matched WAV, README)',
    () async {
      await _writeDemo(Directory(out!), _buildDemo());
    },
    skip:
        out == null || out.isEmpty
            ? 'set HUMTRACK_DEMO_OUT to write the demo'
            : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );
}

Future<void> _writeDemo(Directory outDir, _Demo demo) async {
  await outDir.create(recursive: true);
  final work = Directory('${outDir.path}/.work');
  if (await work.exists()) await work.delete(recursive: true);
  await work.create(recursive: true);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => work.path,
  );
  LoopStorage.rootOverride = work;
  addTearDown(() async {
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
  expect(catalog.midiFallback(_nylonSlot), _nylonGm);

  final sizes = <String, int>{};
  Future<void> put(String name, List<int> bytes) async {
    await File('${outDir.path}/$name').writeAsBytes(bytes, flush: true);
    sizes[name] = bytes.length;
  }

  Future<Uint8List> midOf(Song s, String name) async {
    final sec = s.sections.single;
    final f = await exportMidiSong(
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
      articulations: ArticulationPlan.of(s),
    );
    return f.readAsBytes();
  }

  Future<_Pcm> stemOf(Song s, String name) async {
    final sec = s.sections.single;
    final files = await exportStems(
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
      articulations: ArticulationPlan.of(s),
    );
    expect(files.length, 1, reason: '$name: one guitar stem');
    final pcm = _readStereo16(await files.single.readAsBytes());
    _expectAudible(pcm, '$name stem');
    return pcm;
  }

  final measured = <String, ({double peak, double rms})>{};
  final pcms = <String, _Pcm>{};
  final stems = <String, _Pcm>{};
  final midBytes = <String, Uint8List>{};
  for (final e in demo.songs.entries) {
    final name = e.key, s = e.value;
    final sec = s.sections.single;
    final mid = await midOf(s, name);
    _checkMid(mid, s, '$name (exportMidiSong)');
    midBytes[name] = mid;
    await put('$name.mid', mid);

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
      articulations: ArticulationPlan.of(s),
    );
    expect(wav.skippedVocals, 0);
    final wavBytes = await wav.file.readAsBytes();
    await put('$name.wav', wavBytes);
    final pcm = _readStereo16(wavBytes);
    expect(pcm.sampleRate, 44100);
    _expectAudible(pcm, name);
    pcms[name] = pcm;
    measured[name] = _levels(pcm);
    stems[name] = await stemOf(s, name);

    await put(
      '$name.song.json',
      utf8.encode(const JsonEncoder.withIndent('  ').convert(s.toJson())),
    );
  }

  // ── same-pitch overlap: WAV (stems are not normalized) and an actual
  // render of the exported .mid through the GM font ──
  final ref = demo.mixReference;
  final refStem = await stemOf(ref, 'MIX-reference');
  const w0 = 1.5, w1 = 1.95; // after both palm hits, before the 52 ends
  final wavRef = _rmsAt(refStem, w0, w1);
  final wavMix = _rmsAt(stems[_mix]!, w0, w1);
  final wavPalmDiff = _rmsAt(stems[_mix]!, .25, .5) - _rmsAt(refStem, .25, .5);
  expect(wavRef, greaterThan(1e-3));
  expect(wavMix, greaterThan(wavRef * .9), reason: 'WAV: normal 52 not cut');
  expect(wavPalmDiff.abs(), greaterThan(1e-4), reason: 'palm hit audible');

  final gmPath = File('assets/sounds/GeneralUser-GS.sf2').absolute.path;
  Uint8List renderMid(Uint8List mid) =>
      renderWavForExport({
        'sf2s': [gmPath],
        'jobs': [
          {'sf2': 0, 'midi': mid},
        ],
        'mix': false,
        'sampleRate': 44100,
        'tail': 1.2,
      }).single;
  final refMid = await midOf(ref, 'MIX-reference');
  final midRenderBytes = renderMid(midBytes[_mix]!);
  final midRender = _readStereo16(midRenderBytes);
  final midRefRender = _readStereo16(renderMid(refMid));
  _expectAudible(midRender, _mixRender);
  final midRef = _rmsAt(midRefRender, w0, w1);
  final midMix = _rmsAt(midRender, w0, w1);
  expect(midRef, greaterThan(1e-3));
  expect(midMix, greaterThan(midRef * .9), reason: '.mid: normal 52 not cut');
  await put('$_mixRender.wav', midRenderBytes);
  pcms[_mixRender] = midRender;
  measured[_mixRender] = _levels(midRender);
  final overlap = {
    'window_s': [w0, w1],
    'wav_stem_rms_reference': _r3(_db(wavRef)),
    'wav_stem_rms_with_palm': _r3(_db(wavMix)),
    'wav_ratio': _r3(wavMix / wavRef),
    'mid_render_rms_reference': _r3(_db(midRef)),
    'mid_render_rms_with_palm': _r3(_db(midMix)),
    'mid_ratio': _r3(midMix / midRef),
  };
  debugPrint('[gt3-demo] overlap ${jsonEncode(overlap)}');

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
  for (final name in measured.keys) {
    final m = measured[name]!, pcm = pcms[name]!;
    final gain = target / m.rms;
    final l = Float32List(pcm.left.length), r = Float32List(pcm.right.length);
    for (var i = 0; i < l.length; i++) {
      l[i] = pcm.left[i] * gain;
      r[i] = pcm.right[i] * gain;
    }
    final bytes = _encodeWavStereo16Raw(l, r, pcm.sampleRate);
    await put('$name.matched.wav', bytes);
    final after = _levels(_readStereo16(bytes));
    expect(after.peak, lessThanOrEqualTo(ceiling + 1e-4), reason: name);
    expect(_db(after.rms), closeTo(targetDb, .05), reason: name);
    levels[name] = {
      'seconds': _r2(pcm.left.length / pcm.sampleRate),
      'before': {'peak_dbfs': _r2(_db(m.peak)), 'rms_dbfs': _r2(_db(m.rms))},
      'gain_db': _r2(_db(gain)),
      'after': {
        'peak_dbfs': _r2(_db(after.peak)),
        'rms_dbfs': _r2(_db(after.rms)),
      },
    };
  }
  final edits = demo.edits;
  final counts = {
    for (final k in edits.keys)
      k: {
        'applied': edits[k]!.applied,
        'out_of_range': edits[k]!.outOfRange,
        'no_channel': edits[k]!.noChannel,
      },
  };
  final levelsJson = {
    'method':
        'RMS over every sample of both channels of the whole file (render tail '
        'included), dBFS relative to digital full scale (a full-scale square '
        'wave = 0 dBFS). One common RMS target; lowered for all files if any '
        'gain would put a peak above the ceiling. 16-bit PCM, no limiter.',
    'target_rms_dbfs': _r2(targetDb),
    'requested_target_rms_dbfs': -20.0,
    'peak_ceiling_dbfs': ceilingDb,
    'files': levels,
    'apply_counts': counts,
    'same_pitch_overlap': overlap,
  };
  await put(
    'levels.json',
    utf8.encode(const JsonEncoder.withIndent('  ').convert(levelsJson)),
  );

  final readme = _readme(demo, levelsJson, sizes);
  await File('${outDir.path}/README.md').writeAsString(readme, flush: true);
  debugPrint('[gt3-demo] wrote ${sizes.length + 1} files to ${outDir.path}');
  for (final s in sizes.entries) {
    debugPrint('[gt3-demo]   ${s.key}: ${s.value} B');
  }
  for (final l in levels.entries) {
    debugPrint('[gt3-demo]   ${l.key}: ${jsonEncode(l.value)}');
  }
  debugPrint('[gt3-demo] counts ${jsonEncode(counts)}');
}

/// 16-bit stereo WAV with no gain applied (samples clamped only).
Uint8List _encodeWavStereo16Raw(Float32List l, Float32List r, int sr) {
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

String _kb(int b) => '${(b / 1024).toStringAsFixed(1)} KB';

String _readme(
  _Demo demo,
  Map<String, Object> levelsJson,
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
  final edits = demo.edits;
  String c(String k) =>
      '적용 ${edits[k]!.applied}, 지원 범위 밖 ${edits[k]!.outOfRange}, '
      '채널 부족 ${edits[k]!.noChannel}';
  final o = levelsJson['same_pitch_overlap'] as Map;
  final palmCh = ArticulationPlan.of(demo.songs[_a3p]!)
      .channelFor('melody', ArtRole.muteVoice);
  final harmCh = ArticulationPlan.of(demo.songs[_b3h]!)
      .channelFor('melody', ArtRole.harmonicVoice);
  final voicings = [
    for (final (i, name) in [(0, 'Em'), (1, 'Am'), (2, 'C'), (3, 'G')])
      '$name ${_voicing(i).join(' ')}',
  ].join(' · ');
  final high = [
    for (final (i, name) in [(0, 'Em'), (1, 'Am'), (2, 'C'), (3, 'G')])
      '$name ${_arpPitch(i, -1)}/${_arpPitch(i, -2)}',
  ].join(' · ');
  return '''
# HumTrack 기타 연주법(gt-003) 청취 데모 (2026-10-22)

`docs/specs/guitar/gt-003-palm-mute-harmonics.md`의 마지막 수락 항목(데모).
자체 제작 8마디 진행에서 일반 / 짧게 / 팜뮤트 근사, 일반 / 하모닉스 근사를 같은 음량으로 비교한다.
**청취 검증은 하지 않았다.** 아래 내용은 이벤트·파형 측정 사실뿐이다.

## 무엇이 진짜이고 무엇이 근사인가
| 연주법 | 실제로 하는 일 | 근사 여부 |
|---|---|---|
| 일반 | FreePats nylon(슬롯 1001) 샘플 그대로 | 실제 나일론 음색 |
| 짧게 | **같은 나일론 샘플**을 같은 채널에서 짧게 끊음 (게이트 = min(음 길이, 120 ms), 세기 그대로) | 스타카토다. **팜뮤트가 아니다** (나일론 샘플은 세기를 낮춰도 어두워지지 않음) |
| 팜뮤트 근사 | 전용 채널에서 **GM 28 "Muted Guitar"(일렉 뮤트 기타) 음색**, 같은 키, 세기 × 0.85, 게이트 = min(음 길이, 250 ms) | 근사. 어둡고 짧은 성격은 있지만 **일렉 음색**이며 **나일론 팜뮤트 녹음이 아니다** |
| 하모닉스 근사 | 전용 채널에서 **GM 31 "Guitar Harmonics" 음색**, 엔진 키 S − 24로 연주 | 근사. 음높이 S는 **부분음 구조 대리 지표**(partial-structure proxy)로만 확인했고 **지각 음높이는 확인되지 않았다**. 지원 범위 S = **74..110**, 범위 밖 음은 적용 거부(일반 그대로, 음높이 변경 없음). 실제 자연 하모닉스라고 부르지 않는다 |

`.mid` 파일: 모든 음이 **실제로 울리는 음높이(S)**와 같은 시작·같은 게이트 길이로 기록된다.
팜뮤트/하모닉스 음은 계획(ArticulationPlan)의 **전용 역할 채널**에 쓰이고, 그 채널의 프로그램은
트랙의 GM 대체 음색(GM 24 나일론)이다. 즉 `.mid`에는 GM 28/31 음색도 S − 24 키도 들어가지 않는다
(**음색 손실**, gt-003 r4). 짧게는 트랙 채널(0)에 그대로 쓰인다.

## 음악 내용 (자체 제작, 저작권 없음)
- 8마디, 4/4, **80 BPM**, 키 E 단조, 한 마디에 한 코드: **Em – Am – C – G – Em – Am – C – G**
  (`guitarVoicing`, 다이어토닉 3화음).
- 보이싱 (MIDI): $voicings
- 악기: 카탈로그 슬롯 1001 **FreePats nylon** (번들 에셋에서 오프라인 설치). `.mid`는 GM 24.
- 기타는 melody 트랙 하나. 빈 트랙(bass, melodyDec, drums, beatDec)은 음소거로 저장·렌더.

## 변형
| 이름 | 내용 | 적용 결과 |
|---|---|---|
| `$_a3n` | G2 데모 A쌍과 같은 포크 타격(박 1, 2, 2&, 3&, 4, 4&)의 블록 코드에 gt-001 포크 스트로크 패턴(`↓ ↓↑ ↑↓↑`) 적용. 연주법 없음 | – |
| `$_a3s` | 같은 음에 `applyArticulation` **짧게** (기본 스냅샷 120 ms) | ${c(_a3s)} |
| `$_a3p` | 같은 음에 **팜뮤트 근사** (기본 스냅샷 250 ms, × 0.85), 채널 $palmCh | ${c(_a3p)} |
| `$_b3n` | 8분음표 아르페지오 (보이싱 순서 0 2 3 4 H 5 H' 4; H = 맨 윗음 + 12, H' = 다섯째 음 + 12). 연주법 없음 | – |
| `$_b3h` | 같은 음, 트랙 전체에 **하모닉스 근사** 적용 → 74..110 안의 음만 적용, 채널 $harmCh | ${c(_b3h)} |
| `$_mix` | 1마디: 일반 52를 2.06 s 유지 + 0.25 s와 1.0 s에 팜뮤트 근사 52 (같은 음높이 겹침) | ${c(_mix)} |
| `$_mixRender` | `$_mix.mid`(내보낸 파일 그대로)를 GM 폰트(GeneralUser-GS)로 렌더한 것 | – |

고음 라인 H/H' (마디별): $high. 74 미만은 하모닉스 범위 밖이라 일반으로 남는다.

A3 기준을 스트로크 변환된 코드로 둔 이유: 손대지 않은 블록 코드는 기존 자동 스트럼(28 ms 다운, -18%)을 받지만
연주법이 붙은 음은 자동 스트럼을 받지 않는다(스펙 구현 노트). 블록 코드 그대로 두면 일반/짧게/팜뮤트의
타이밍이 달라져 비교가 섞이므로, 세 파일 모두 **같은 명시적 스트로크 데이터**를 갖게 했다.

## 같은 음높이 겹침 (`$_mix`)
- `.mid`: 일반 52는 채널 0에서 0–11스텝(2.06 s) 전체 유지, 팜뮤트 52 두 개는 역할 채널에서 각 0.25 s.
- 측정 창 ${(o['window_s'] as List).join('–')} s (두 팜뮤트 음이 끝난 뒤, 일반 52가 끝나기 전) RMS, 팜뮤트 없는 기준 대비:
  - WAV(exportStems 기타 스템, 정규화 없음): 기준 ${o['wav_stem_rms_reference']} dBFS, 팜뮤트 포함 ${o['wav_stem_rms_with_palm']} dBFS, 비율 ${o['wav_ratio']}
  - 내보낸 `.mid`의 실제 렌더(GM 폰트): 기준 ${o['mid_render_rms_reference']} dBFS, 팜뮤트 포함 ${o['mid_render_rms_with_palm']} dBFS, 비율 ${o['mid_ratio']}
  - 테스트 기준: 비율 > 0.9 (팜뮤트 음이 일반 음을 끊지 않음).

## 파일
| 파일 | 크기 |
|---|---|
$fileRows| `README.md` | (이 파일) |
| `test-output.log` | 아래 명령의 실행 로그 |

- `<이름>.mid`: 실제 `exportMidiSong` 결과 (GM 24, r4 라우팅).
- `<이름>.wav`: 실제 `exportWavSong` 전체 믹스 (나일론 SF2 + 역할 잡은 GM 폰트의 GM 28/31, MeltySynth, 44.1 kHz 16비트 스테레오).
  내보내기 규칙대로 피크 정규화된 상태.
- `<이름>.matched.wav`: 아래 표대로 RMS를 맞춘 비교용 파일 (청취는 이 파일로).
- `<이름>.song.json`: `Song.toJson()`. `levels.json`: 맞추기 전·후 레벨, 적용 개수, 겹침 측정.
- 스템(`exportStems`)은 검사용으로만 렌더했고 저장하지 않았다.

## 음량 맞추기
방법: 파일 전체(렌더 꼬리 포함), 양 채널 모든 샘플의 RMS. dBFS는 디지털 풀스케일 기준.
요청 목표 -20 dBFS RMS, 피크 상한 ${levelsJson['peak_ceiling_dbfs']} dBFS. 한 파일이라도 넘으면 모든 파일의 목표를 같이 낮춘다.
**적용 목표: ${levelsJson['target_rms_dbfs']} dBFS RMS.** 리미터 없음, 클리핑 없음.

| 파일 | 길이(s) | 원본 피크 | 원본 RMS | 게인 dB | 맞춘 후 피크 | 맞춘 후 RMS |
|---|---|---|---|---|---|---|
$rows
주의: RMS는 단순 음량 지표다(청감 가중 LUFS 아님). 짧게/팜뮤트처럼 음이 짧은 파일은 무음 구간이 많아
같은 RMS로 맞추면 어택이 원래보다 크게 들릴 수 있다.

## 다시 만들기
```
cd C:/src/humming-v2/mobile && TMP=C:/src/humming-v2/artifacts/g3-impl-20261022/temp TEMP=C:/src/humming-v2/artifacts/g3-impl-20261022/temp HUMTRACK_DEMO_OUT=C:/src/humming-v2/artifacts/guitar-articulation-demo-20261022 /c/src/flutter/bin/flutter test --no-pub test/looptap/guitar_articulation_demo_test.dart
```
`HUMTRACK_DEMO_OUT`이 없으면 같은 테스트가 곡을 만들고 검사만 한다(파일 쓰기 없음).
검사 내용: 쌍 안에서 연주법 외 음 데이터 동일, 적용 개수, 계획의 채널 배정, `.mid` r4 라우팅
(역할 채널·소유 트랙 GM 프로그램·울리는 음높이·게이트 길이), WAV 역할 잡 MIDI(GM 28 키 S, GM 31 키 S − 24).
환경 변수가 있으면 추가로: 실제 내보내기 `.mid` 재검사, 믹스·스템 유한·비무음, 같은 음높이 겹침(WAV와 `.mid` 렌더).

## 한계 (정직하게)
- **청취 검증 안 됨.** 하모닉스의 음높이는 부분음 구조 대리 지표일 뿐 지각 음높이가 아니다.
- 팜뮤트 근사는 일렉 뮤트 기타 음색이라 나일론과 음색이 다르다. 나일론 자체의 어두운 팜뮤트는 v1 범위 밖.
- `.mid`는 연주법 음색을 담지 못한다(GM 24로 재생됨). 음높이·시작·길이만 보존된다.
- WAV는 MeltySynth 오프라인 렌더(앱 내보내기와 같은 경로)다. 실시간 재생 엔진과 미세한 차이가 있을 수 있다.
''';
}
