// 단일 노트 → 코드(트라이어드/7th/sus) 확장 헬퍼.
//
// 트랙 전체를 일괄 확장하는 `expandChords`(chords.dart)와 달리, 사용자가
// 명시적으로 "이 노트를 코드로" 지정한 단음만 여러 노트로 분리한다.
// 확장된 노트들은 같은 chunkId(새로 발급)로 묶여 이동/삭제/볼륨 변경이
// 한 단위로 동작한다. 루트 = 가장 낮은 pitch (Unchord 시 루트만 남김).
import 'dart:math' as math;
import '../models/models.dart';
import 'chords.dart';

/// 사용자가 선택할 수 있는 코드 타입.
enum ChordType {
  diatonic('Diatonic', '키 기준 트라이어드'),
  major('Major', '0·4·7'),
  minor('Minor', '0·3·7'),
  sus2('Sus2', '0·2·7'),
  sus4('Sus4', '0·5·7'),
  dom7('7th', '0·4·7·10'),
  maj7('Maj7', '0·4·7·11'),
  min7('m7', '0·3·7·10');

  const ChordType(this.label, this.intervalsLabel);
  final String label;
  final String intervalsLabel;
}

const Map<ChordType, List<int>> _absIntervals = {
  ChordType.major: [0, 4, 7],
  ChordType.minor: [0, 3, 7],
  ChordType.sus2: [0, 2, 7],
  ChordType.sus4: [0, 5, 7],
  ChordType.dom7: [0, 4, 7, 10],
  ChordType.maj7: [0, 4, 7, 11],
  ChordType.min7: [0, 3, 7, 10],
};

double _midiToHz(int m) => 440.0 * math.pow(2, (m - 69) / 12.0);

/// `root` 노트를 기준으로 `type` 코드의 구성 pitch 목록을 반환.
/// diatonic 모드 + 키 정보가 있으면 키 안에서 루트+3+5음 사용,
/// 키가 없으면 메이저 트라이어드로 폴백.
List<int> chordPitches(int rootMidi, ChordType type, {String? tonic, String? scale}) {
  if (type == ChordType.diatonic) {
    return buildDiatonicTriad(rootMidi, tonic, scale);
  }
  final ivs = _absIntervals[type] ?? const [0, 4, 7];
  return [for (final iv in ivs) rootMidi + iv];
}

/// 단음 `root`를 코드로 확장 — start/end 동일, pitch 다른 여러 Note 생성.
/// 모든 결과 노트는 `chunkId = newChunkId`. 루트는 원본 velocity, 나머지는 약하게.
List<Note> expandToChord(Note root, ChordType type, int newChunkId,
    {String? tonic, String? scale}) {
  final pitches = chordPitches(root.pitch, type, tonic: tonic, scale: scale);
  final out = <Note>[];
  for (var i = 0; i < pitches.length; i++) {
    final p = pitches[i];
    final n = Note.fromJson(root.toJson())
      ..pitch = p
      ..pitchHz = _midiToHz(p)
      ..velocity = i == 0 ? root.velocity : math.max(1, (root.velocity * 0.82).round())
      ..source = i == 0 ? root.source : 'assistant'
      ..chunkId = newChunkId;
    out.add(n);
  }
  return out;
}

/// 같은 chunkId 의 노트들이 "사용자가 만든 코드 묶음"인지 판정.
/// 휴리스틱: 노트가 2개 이상이고 모두 시작/끝 시각이 거의 동일.
bool isChordChunk(List<Note> chunkNotes) {
  if (chunkNotes.length < 2) return false;
  final s0 = chunkNotes.first.start, e0 = chunkNotes.first.end;
  for (final n in chunkNotes) {
    if ((n.start - s0).abs() > 0.001) return false;
    if ((n.end - e0).abs() > 0.001) return false;
  }
  return true;
}
