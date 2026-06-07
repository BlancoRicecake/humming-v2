// LoopTap app state — the song list + persistence. The editor keeps its own
// working copy (like the prototype's EditScreen) and calls [upsert] on save.
import 'package:flutter/foundation.dart';

import '../models/loop_models.dart';
import '../music/theory.dart';
import 'loop_storage.dart';

class LoopStore extends ChangeNotifier {
  final List<Song> _songs = [];
  bool _loaded = false;

  /// Simple local user (name + provider), like the prototype's looptap_user.
  Map<String, String>? _user;

  List<Song> get songs => List.unmodifiable(_songs);
  bool get loaded => _loaded;
  Map<String, String>? get user => _user;
  bool get isSignedIn => _user != null;

  Future<void> bootstrap() async {
    final loaded = await LoopStorage.load();
    _user = await LoopStorage.loadUser();
    _songs
      ..clear()
      ..addAll(loaded.isEmpty ? _seed() : loaded);
    _songs.sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    _loaded = true;
    if (loaded.isEmpty) await _persist();
    notifyListeners();
  }

  Future<void> signIn(String providerLabel) async {
    _user = {'name': '$providerLabel user', 'provider': providerLabel};
    await LoopStorage.saveUser(_user);
    notifyListeners();
  }

  Future<void> signOut() async {
    _user = null;
    await LoopStorage.saveUser(null);
    notifyListeners();
  }

  Future<void> _persist() => LoopStorage.save(_songs);

  /// Create a fresh empty song and return it (not yet persisted until saved).
  Song createNew() {
    final s = Song(
      id: 'lt${DateTime.now().millisecondsSinceEpoch}',
      title: 'Untitled loop',
      updatedAt: DateTime.now(),
    );
    return s;
  }

  /// Insert or replace a song by id, then persist.
  Future<void> upsert(Song song) async {
    song.updatedAt = DateTime.now();
    final i = _songs.indexWhere((s) => s.id == song.id);
    if (i >= 0) {
      _songs[i] = song;
    } else {
      _songs.insert(0, song);
    }
    _songs.sort((a, b) => (b.updatedAt ?? DateTime(0)).compareTo(a.updatedAt ?? DateTime(0)));
    await _persist();
    notifyListeners();
  }

  Future<void> delete(String id) async {
    _songs.removeWhere((s) => s.id == id);
    await _persist();
    notifyListeners();
  }

  // ── 3 demo songs (parallels index.html seeds) ─────────────────────
  List<Song> _seed() {
    Section drumSection(String id, String name, {int bars = 2}) {
      final steps = stepsForBars(bars);
      final drums = <DrumNote>[];
      for (var s = 0; s < steps; s++) {
        if (s % 8 == 0) drums.add(DrumNote(kind: 'kick', step: s));
        if (s % 8 == 4) drums.add(DrumNote(kind: 'snare', step: s));
        if (s % 2 == 0) drums.add(DrumNote(kind: 'hihat', step: s));
      }
      final sec = Section(id: id, name: name, bars: bars);
      sec.tracks['drums'] = TrackData(drums: drums);
      return sec;
    }

    Song demo(String id, String title, String key, String scale, int bpm, int bars) {
      final song = Song(
        id: id,
        title: title,
        key: key,
        scale: scale,
        bpm: bpm,
        bars: bars,
        sections: [drumSection('A', 'A', bars: bars)],
        updatedAt: DateTime.now(),
      );
      // give the melody a couple of in-key notes so the thumbnail looks alive
      final ladder = buildLadder(key, scale, 4, 8);
      final mel = <PitchNote>[];
      for (var i = 0; i < 4; i++) {
        final r = ladder[(i * 2) % ladder.length];
        mel.add(PitchNote(midi: r.midi, freq: r.freq, step: i * 4, dur: 2));
      }
      song.sections.first.tracks['melody'] = TrackData(notes: mel);
      return song;
    }

    return [
      demo('seed1', 'Midnight Tap', 'A', 'minor', 92, 2),
      demo('seed2', 'Sunrise Penta', 'C', 'pentatonic', 104, 2),
      demo('seed3', 'Dorian Drift', 'D', 'dorian', 88, 4),
    ];
  }
}
