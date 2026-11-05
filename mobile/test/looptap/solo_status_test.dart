import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/audition.dart';
import 'package:humming/looptap/music/solo_status.dart';
import 'package:humming/looptap/music/theory.dart';
import 'package:humming/looptap/widgets/solo_status_notice.dart';

void main() {
  final tracks = <String, TrackData>{};
  List<SoloStatus> inspect({
    Set<String> solos = const {'melody'},
    Map<String, bool> mutes = const {},
    Map<String, double> volumes = const {},
    bool bypass = false,
  }) => soloIssues(
    tracks: tracks,
    metas: kTracks,
    solos: solos,
    mutes: mutes,
    volumes: volumes,
    range: const PlaybackRange(16, 32),
    steps: 32,
    bypass: bypass,
  );
  setUp(tracks.clear);
  PitchNote n(int step, {int? velocity = 3, int dur = 2, double offset = 0}) =>
      PitchNote(
        midi: 60,
        freq: 261.63,
        step: step,
        dur: dur,
        velocity: velocity,
        offsetSteps: offset,
      );

  test(
    'mute, zero gain, absent passage and genuinely low source velocities are distinct',
    () {
      tracks['melody'] = TrackData(
        notes: [n(18, velocity: 1), n(20, velocity: 3)],
      );
      final before = tracks['melody']!.toJson();
      expect(inspect().single.issue, SoloIssue.veryQuiet);
      expect(inspect().single.minVelocity, 1);
      expect(inspect().single.maxVelocity, 3);
      expect(inspect(mutes: {'melody': true}).single.issue, SoloIssue.muted);
      expect(
        inspect(volumes: {'melody': 0}).single.issue,
        SoloIssue.zeroVolume,
      );
      tracks['melody']!.pitchNotes.clear();
      expect(inspect().single.issue, SoloIssue.noNotes);
      tracks['melody'] = TrackData.fromJson(before);
      expect(tracks['melody']!.toJson(), before);
    },
  );
  test(
    'sustained notes count, range end is exclusive and defaults do not falsely warn',
    () {
      tracks['melody'] = TrackData(notes: [n(14, dur: 4)]);
      expect(inspect().single.issue, SoloIssue.veryQuiet);
      tracks['melody'] = TrackData(notes: [n(14), n(32)]);
      expect(inspect().single.issue, SoloIssue.noNotes);
      tracks['melody'] = TrackData(notes: [n(18, velocity: null), n(20)]);
      expect(inspect(), isEmpty);
      expect(inspect(bypass: true), isEmpty);
      expect(inspect(solos: {}), isEmpty);
    },
  );
  test('percussion attacks and audio clips use their actual placement', () {
    tracks['drums'] = TrackData(
      drums: [DrumNote(kind: 'kick', step: 15, offsetSteps: .9, velocity: 3)],
    );
    expect(inspect(solos: {'drums'}).single.issue, SoloIssue.noNotes);
    tracks['vocal'] = TrackData(
      clips: [VocalClip(path: 'take.wav', startStep: 8, durSteps: 12)],
    );
    expect(inspect(solos: {'vocal'}), isEmpty);
    tracks['vocal'] = TrackData(
      clips: [VocalClip(path: 'take.wav', startStep: 0, durSteps: 16)],
    );
    expect(inspect(solos: {'vocal'}).single.issue, SoloIssue.noNotes);
  });
  testWidgets('small Solo hint opens the quiet part without changing notes', (
    tester,
  ) async {
    String? opened;
    await tester.binding.setSurfaceSize(const Size(360, 220));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SoloStatusNotice(
            issues: const [
              SoloStatus(
                'melodyDec',
                'Piano 1',
                SoloIssue.veryQuiet,
                minVelocity: 1,
                maxVelocity: 3,
              ),
            ],
            onOpenVelocity: (id) => opened = id,
          ),
        ),
      ),
    );
    expect(find.textContaining('Velocity 1–3/127'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('solo-open-velocity')));
    expect(opened, 'melodyDec');
    expect(tester.takeException(), isNull);
  });
}
