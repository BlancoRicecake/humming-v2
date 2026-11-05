// Deterministic randomness for note tools: Humanize (piano-roll-006) and
// per-note chance / velocity variation (piano-roll-007). A HumTrack-owned
// xorshift32 keeps sequences identical across platforms and Dart versions.
import 'dart:convert';

import '../models/loop_models.dart';

/// Marsaglia xorshift32 (13, 17, 5) on a 32-bit state. Seed 0 (a fixed
/// point of xorshift) is replaced by 0x9E3779B9.
class HumRng {
  HumRng(int seed) : _x = _mask(seed) == 0 ? 0x9E3779B9 : _mask(seed);

  static int _mask(int v) => v & 0xFFFFFFFF;
  int _x;

  /// Next raw 32-bit output.
  int nextUint32() {
    var x = _x;
    x = _mask(x ^ (x << 13));
    x ^= x >> 17;
    x = _mask(x ^ (x << 5));
    return _x = x;
  }

  /// Uniform in [0, 1): raw / 2^32.
  double nextDouble() => nextUint32() / 4294967296.0;
}

/// 32-bit FNV-1a over the UTF-8 bytes of [s].
int fnv1a32(String s) {
  var h = 0x811C9DC5;
  for (final b in utf8.encode(s)) {
    h ^= b;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// What [note] plays on loop pass [pass]: null when it stays silent (muted,
/// or the chance roll failed), else the note with its realized velocity.
/// The roll is keyed by song seed, section, track, pitch, start and pass —
/// never the list index — so adding or removing other notes can't change it.
/// A note without chance/variation is returned as is.
PitchNote? realizePitchNote(
  PitchNote note, {
  required int seed,
  required String sectionId,
  required String trackId,
  required int pass,
}) {
  if (note.muted) return null;
  if (note.chance >= 1 && note.velocityDeviation == 0) return note;
  final key =
      '$seed|$sectionId|$trackId|${note.midi}|'
      '${(note.startSteps * 1000).round()}|$pass';
  final rng = HumRng(fnv1a32(key));
  final sound = rng.nextDouble(), level = rng.nextDouble();
  if (!(sound < note.chance)) return null;
  if (note.velocityDeviation == 0) return note;
  final v = ((note.velocity ?? 100) + (level * note.velocityDeviation).round())
      .clamp(1, 127);
  return note.copyWith(velocity: v);
}

/// The drum-hit form of [realizePitchNote] (drums-001): the same roll, with
/// the hit's [DrumNote.kind] in the key where a note has its pitch.
DrumNote? realizeDrumNote(
  DrumNote note, {
  required int seed,
  required String sectionId,
  required String trackId,
  required int pass,
}) {
  if (note.muted) return null;
  if (note.chance >= 1 && note.velocityDeviation == 0) return note;
  final key =
      '$seed|$sectionId|$trackId|${note.kind}|'
      '${(note.startSteps * 1000).round()}|$pass';
  final rng = HumRng(fnv1a32(key));
  final sound = rng.nextDouble(), level = rng.nextDouble();
  if (!(sound < note.chance)) return null;
  if (note.velocityDeviation == 0) return note;
  final v = ((note.velocity ?? 100) + (level * note.velocityDeviation).round())
      .clamp(1, 127);
  return note.copyWith(velocity: v);
}

/// The live-playback pick for one clock step (drums-001): hits of [notes] in
/// cell [step] that sound on loop [pass], each with what it plays. Muted hits
/// and failed chance rolls are left out, so they never reach the synth.
List<({DrumNote note, DrumNote played})> soundingDrumHits(
  List<DrumNote> notes,
  int step, {
  required int seed,
  required String sectionId,
  required String trackId,
  required int pass,
}) => [
  for (final n in notes)
    if (n.step == step)
      if (realizeDrumNote(
            n,
            seed: seed,
            sectionId: sectionId,
            trackId: trackId,
            pass: pass,
          )
          case final played?)
        (note: n, played: played),
];
