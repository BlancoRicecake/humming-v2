// Instrumental cut of the full-song v2 reconstruction
// (artifacts/gotye-reference-20261023/full-song-v2-instrumental/): the v2 song
// from buildGotyeFullSongV2() with the two vocal-guide lanes removed
// everywhere (notes, section extras, instruments, vol). Everything else —
// guitar, mallet, bass, drums, counter, sustain, the muted pad candidates,
// velocities, micro timing, 130 bars, 129 BPM — is the v2 song unchanged.
import 'package:humming/looptap/models/loop_models.dart';
import 'package:humming/looptap/music/theory.dart';

import 'gotye_full_song.dart';
import 'gotye_full_song_v2.dart';

const String fullV2InstrumentalId = 'gotye_full_song_v2_instrumental_129';
const String fullV2InstrumentalTitle = 'Gotye full song reconstruction v2 (instrumental)';
const Set<String> vocalGuideIds = {voxMaleId, voxFemaleId};

Song buildGotyeFullSongV2Instrumental({Map<String, dynamic>? additions, Map<String, dynamic>? dynamics}) {
  final v2 = buildGotyeFullSongV2(additions: additions, dynamics: dynamics);
  for (final sec in v2.sections) {
    sec.extras.removeWhere((e) => vocalGuideIds.contains(e.id));
    sec.tracks.removeWhere((id, _) => vocalGuideIds.contains(id));
    sec.order.removeWhere(vocalGuideIds.contains);
  }
  final song = Song(
    id: fullV2InstrumentalId,
    title: fullV2InstrumentalTitle,
    key: v2.key,
    scale: v2.scale,
    bpm: v2.bpm,
    bars: v2.bars,
    sections: v2.sections,
    instruments: {...v2.instruments}..removeWhere((id, _) => vocalGuideIds.contains(id)),
  );
  song.swing = v2.swing;
  song.vol.addAll({...v2.vol}..removeWhere((id, _) => vocalGuideIds.contains(id)));
  return song;
}

/// The extra lanes left in the instrumental song, in order.
List<TrackRef> get instrumentalExtras => [
      for (final e in [...fullExtras, ...fullV2NewExtras])
        if (!vocalGuideIds.contains(e.id)) e,
    ];
