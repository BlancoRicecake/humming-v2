// Per-track drum independence rests on channel allocation: every added track
// instance (pitched OR drums) must get its own MIDI channel so its kit/voice
// is independent. Base drums + beat-fill stay on ch9 (one shared beat kit).
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/music/theory.dart';

void main() {
  test('base drums and beat-fill have independent channels', () {
    final metas = sectionTrackMetas(const []);
    final drums = metas.firstWhere((m) => m.id == 'drums');
    final beatDec = metas.firstWhere((m) => m.id == 'beatDec');
    expect(drums.channel, 9);
    expect(beatDec.channel, isNot(9)); // its own channel → its own kit
    expect(beatDec.channel, isNot(drums.channel));
  });

  test('each added drum track gets its own non-9 channel', () {
    final extras = [
      const TrackRef('drums_a', 'drums'),
      const TrackRef('drums_b', 'drums'),
    ];
    final metas = sectionTrackMetas(extras);
    final a = metas.firstWhere((m) => m.id == 'drums_a').channel;
    final b = metas.firstWhere((m) => m.id == 'drums_b').channel;
    expect(a, isNot(9)); // not the base drum channel
    expect(b, isNot(9));
    expect(a, isNot(b)); // independent of each other
    expect(a, isNot(15)); // not the metronome click channel
    expect(b, isNot(15));
  });

  test('pitched + drum instances never collide on a channel', () {
    final extras = [
      const TrackRef('mel2', 'melody'),
      const TrackRef('drums_a', 'drums'),
      const TrackRef('bass2', 'bass'),
      const TrackRef('drums_b', 'drums'),
    ];
    final metas = sectionTrackMetas(extras);
    final extraChans = [
      for (final e in extras) metas.firstWhere((m) => m.id == e.id).channel,
    ];
    expect(extraChans.toSet().length, extraChans.length); // all distinct
    expect(extraChans, isNot(contains(9))); // never the base drum channel
    expect(extraChans, everyElement(isNot(15))); // never the click channel
  });
}
