// 코드 모드 — 단선율을 detected key 기준 다이아토닉 트라이어드로 확장.
// backend/app/scales.py / frontend chords.ts 와 동일 로직(루트+3음+5음).
import 'dart:math' as math;
import '../models/models.dart';

const Map<String, int> _noteToPc = {
  'C': 0, 'C#': 1, 'DB': 1, 'D': 2, 'D#': 3, 'EB': 3, 'E': 4, 'F': 5,
  'F#': 6, 'GB': 6, 'G': 7, 'G#': 8, 'AB': 8, 'A': 9, 'A#': 10, 'BB': 10, 'B': 11,
};

const Map<String, List<int>> _scaleIntervals = {
  'major': [0, 2, 4, 5, 7, 9, 11],
  'minor': [0, 2, 3, 5, 7, 8, 10],
  'harmonic_minor': [0, 2, 3, 5, 7, 8, 11],
  'melodic_minor': [0, 2, 3, 5, 7, 9, 11],
  'dorian': [0, 2, 3, 5, 7, 9, 10],
  'phrygian': [0, 1, 3, 5, 7, 8, 10],
  'lydian': [0, 2, 4, 6, 7, 9, 11],
  'mixolydian': [0, 2, 4, 5, 7, 9, 10],
  'locrian': [0, 1, 3, 5, 6, 8, 10],
  'major_pentatonic': [0, 2, 4, 7, 9],
  'minor_pentatonic': [0, 3, 5, 7, 10],
  'blues': [0, 3, 5, 6, 7, 10],
  'chromatic': [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
};

int? _tonicToPc(String tonic) {
  final k = tonic.trim().toUpperCase().replaceAll('♯', '#').replaceAll('♭', 'B');
  return _noteToPc[k];
}

/// 루트 + 3음 + 5음 (다이아토닉). 키 없음/스케일 모르면 메이저 트라이어드 폴백.
List<int> buildDiatonicTriad(int rootMidi, String? tonic, String? scale) {
  final rootPc = tonic == null ? null : _tonicToPc(tonic);
  final intervals = scale == null ? null : _scaleIntervals[scale];
  if (rootPc == null || intervals == null) {
    return [rootMidi, rootMidi + 4, rootMidi + 7];
  }
  final pcSet = intervals.map((iv) => (rootPc + iv) % 12).toSet();
  final ladder = <int>[];
  for (int m = rootMidi - 12; m <= rootMidi + 24; m++) {
    if (pcSet.contains(((m % 12) + 12) % 12)) ladder.add(m);
  }
  final i = ladder.indexWhere((m) => m >= rootMidi);
  if (i < 0) return [rootMidi, rootMidi + 4, rootMidi + 7];
  final root = ladder[i];
  final third = (i + 2 < ladder.length) ? ladder[i + 2] : root + 4;
  final fifth = (i + 4 < ladder.length) ? ladder[i + 4] : root + 7;
  return [root, third, fifth];
}

double _midiToHz(int m) => 440.0 * math.pow(2, (m - 69) / 12.0);

/// 코드 모드일 때 각 pitched 노트를 트라이어드로 확장. percussive 는 그대로.
List<Note> expandChords(List<Note> notes, DetectedKey? key, bool chordMode) {
  if (!chordMode) return notes;
  final tonic = key?.tonic, scale = key?.scale;
  final out = <Note>[];
  for (final n in notes) {
    if (n.kind != 'pitched' || tonic == null || scale == null) {
      out.add(n);
      continue;
    }
    final chord = buildDiatonicTriad(n.pitch, tonic, scale);
    for (var idx = 0; idx < chord.length; idx++) {
      final p = chord[idx];
      final cn = Note.fromJson(n.toJson())
        ..pitch = p
        ..pitchHz = _midiToHz(p)
        ..velocity = idx == 0 ? n.velocity : math.max(1, (n.velocity * 0.82).round());
      out.add(cn);
    }
  }
  return out;
}
