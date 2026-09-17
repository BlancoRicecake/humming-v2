import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/beginner_backing.dart';
import 'package:humming/looptap/music/theory.dart';

void main() {
  for (final style in BackingStyle.values) {
    test(
      '$style preserves melody and samples, bounds notes and survives saving',
      () {
        final original = Section(id: 'A', name: 'A', bars: 4);
        original.tracks['melody']!.pitchNotes.add(
          PitchNote(midi: 64, freq: midiToFreq(64), step: 0, dur: 4),
        );
        original.tracks['vocal']!.clips = [VocalClip(path: 'test.wav')];
        final snapshot = original.toJson();
        final backed = withBeginnerBacking(original, 'C', 'major', style);
        expect(original.toJson(), snapshot);
        expect(
          backed.tracks['melody']!.toJson(),
          original.tracks['melody']!.toJson(),
        );
        expect(
          backed.tracks['vocal']!.toJson(),
          original.tracks['vocal']!.toJson(),
        );
        expect(backed.tracks['drums']!.drumNotes, isNotEmpty);
        for (final n in backed.tracks['bass']!.pitchNotes) {
          expect(kScales['major']!.steps, contains(n.midi % 12));
          expect(n.step, greaterThanOrEqualTo(0));
          expect(n.step + n.dur, lessThanOrEqualTo(64));
        }
        for (final n in backed.tracks['drums']!.drumNotes) {
          expect(n.step, inInclusiveRange(0, 63));
        }
        expect(Section.fromJson(backed.toJson()).toJson(), backed.toJson());
        backed.tracks['melody']!.pitchNotes.clear();
        expect(original.tracks['melody']!.pitchNotes, hasLength(1));
      },
    );
  }
}
