import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/pitch_clipboard.dart';

void main() {
  test(
    'clipboard snapshots expression, spacing and rejects partial pastes',
    () {
      final clipboard = PitchClipboard();
      final a = PitchNote(
        midi: 60,
        freq: 261.63,
        step: 2,
        dur: 2,
        offsetSteps: .3,
        durationSteps: 1.6,
        velocity: 47,
        sourceMidi: 61,
        confidence: .8,
        assisted: true,
      );
      final b = PitchNote(
        midi: 64,
        freq: 329.63,
        step: 4,
        dur: 1,
        locked: true,
      );
      clipboard.copy([a, b]);
      a.step = 12;
      final pasted = clipboard.paste(atStep: 6, steps: 16);
      expect(pasted.map((n) => n.startSteps), [6.3, 8]);
      expect(pasted.first.durationSteps, 1.6);
      expect(pasted.first.velocity, 47);
      expect(pasted.first.sourceMidi, 61);
      expect(pasted.first.confidence, .8);
      expect(pasted.first.assisted, true);
      expect(pasted.last.locked, true);
      pasted.first.step = 0;
      expect(clipboard.paste(atStep: 6, steps: 16).first.step, 6);
      expect(clipboard.paste(atStep: 14, steps: 16), isEmpty);
      expect(clipboard.paste(atStep: -1, steps: 16), isEmpty);
      clipboard.dispose();
    },
  );
}
