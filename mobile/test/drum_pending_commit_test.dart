import 'package:flutter_test/flutter_test.dart';
import 'package:humming/models/models.dart';
import 'package:humming/state/project_store.dart';

Note drum(double start, int pitch) => Note.fromJson({
      'start': start,
      'end': start + 0.08,
      'duration': 0.08,
      'pitch': pitch,
      'pitch_raw': pitch.toDouble(),
      'pitch_hz': 0.0,
      'velocity': 84,
      'confidence': 1.0,
      'voiced_ratio': 0.0,
      'kind': 'percussive',
      'pitch_original': pitch,
      'drum': pitch,
      'drum_name': drumNames[pitch],
      'onset_strength': 1.0,
    });

AnalyzeResponse response(List<Note> notes) => AnalyzeResponse(
      notes: notes,
      detectedKey: null,
      keyCandidates: const [],
      assistAppliedCount: 0,
      durationSec: 1.2,
      peaks: const [],
    );

List<String> sig(List<Note> notes) => notes
    .map((n) => [
          n.start.toStringAsFixed(4),
          n.end.toStringAsFixed(4),
          n.pitch,
          n.drum,
          n.velocity,
          n.kind,
        ].join(':'))
    .toList();

void main() {
  test('drum pending preview matches committed render timing and classes', () {
    final store = ProjectStore();
    final track = store.firstByRole(TrackRole.drum)!;
    final notes = [drum(0.12, 36), drum(0.42, 38), drum(0.68, 42)];
    final res = response(notes);
    final pending = PendingRecording(
      trackId: track.id,
      role: TrackRole.drum,
      wavPath: 'pending.wav',
      notes: notes,
      analysis: res,
    );
    store.pendingRecording = pending;

    final preview = sig(store.pendingRenderNotes(pending));
    store.commitPendingRecording();
    final committed = sig(store.renderNotesForTrack(track, includeLoops: false));

    expect(committed, preview);
  });

  test('drum quantize remains identical between pending preview and commit', () {
    final store = ProjectStore();
    store.bpm = 90;
    final track = store.firstByRole(TrackRole.drum)!
      ..quantizeEnabled = true
      ..quantizeGrid = 16
      ..quantizeStrength = 0.45;
    final notes = [drum(0.12, 36), drum(0.42, 38), drum(0.68, 42)];
    final res = response(notes);
    final pending = PendingRecording(
      trackId: track.id,
      role: TrackRole.drum,
      wavPath: 'pending.wav',
      notes: notes,
      analysis: res,
    );
    store.pendingRecording = pending;

    final preview = sig(store.pendingRenderNotes(pending));
    store.commitPendingRecording();
    final committed = sig(store.renderNotesForTrack(track, includeLoops: false));

    expect(committed, preview);
  });
}
