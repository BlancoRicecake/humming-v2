// 회귀 테스트 — "노트 머지 시 맨 첫 노트가 사라지는" 버그.
//
// 근본 원인: effectiveRenderNotes 가 리딩 트림 노트(짧은 픽업)를 드롭하면 표시 노트
// 인덱스가 원본 t.notes 인덱스와 한 칸 어긋난다. 과거엔 탭이 "표시 인덱스"를 그대로
// 넘겨, mergeNotes 가 원본 t.notes[표시인덱스] = 숨은 픽업을 집어 첫 가청 노트를 지웠다.
// 수정: 렌더 노트에 renderSrcIndex(원본 인덱스)를 박아 선택/편집이 그것을 사용한다.
import 'package:flutter_test/flutter_test.dart';
import 'package:humming/models/models.dart';
import 'package:humming/state/project_store.dart';

Note mk(double start, double end, int pitch) => Note.fromJson({
      'start': start, 'end': end, 'duration': end - start,
      'pitch': pitch, 'pitch_raw': pitch.toDouble(), 'pitch_hz': 0.0,
      'velocity': 90, 'confidence': 1.0, 'voiced_ratio': 1.0, 'kind': 'pitched',
      'pitch_original': pitch, 'assisted': false, 'candidates': [pitch],
      'source': 'raw', 'in_key': true, 'correction_cents': 0,
    });

void main() {
  // 픽업(짧은 리딩 노이즈) + 첫 가청 노트 A + 다음 노트 B.
  // lead(inPoint)=0.20 이라 effectiveRenderNotes 가 픽업(0.00~0.04)을 드롭한다.
  TrackData buildTrack() {
    final t = TrackData(1, TrackRole.keys);
    t.notes = [
      mk(0.00, 0.04, 50), // 픽업 — duration<0.06, lead 앞 → 드롭됨 (rawIdx 0)
      mk(0.20, 0.50, 60), // A — 첫 가청 노트                    (rawIdx 1)
      mk(0.50, 0.80, 62), // B                                   (rawIdx 2)
    ];
    for (final n in t.notes) {
      n.chunkId = 7;
    }
    t.chunks = [
      Chunk(id: 7, timelineStart: 0, inPoint: 0.20, outPoint: 0.80, originalLength: 0.80),
    ];
    return t;
  }

  test('effectiveRenderNotes drops the leading pickup and shifts display indices', () {
    final ern = buildTrack().effectiveRenderNotes;
    // 픽업이 드롭되어 표시 노트는 2개(A, B).
    expect(ern.length, 2);
    expect(ern[0].pitch, 60); // 첫 표시 노트 = A
    expect(ern[1].pitch, 62); // 둘째 표시 노트 = B
  });

  test('renderSrcIndex maps the first VISIBLE note to raw index 1, not display 0', () {
    final ern = buildTrack().effectiveRenderNotes;
    // 첫 표시 노트(A)를 탭하면 표시 인덱스는 0 이지만 원본 인덱스는 1 이어야 한다.
    // (과거 버그: 0 을 그대로 써서 t.notes[0]=픽업을 머지 → A 가 사라짐)
    expect(ern[0].renderSrcIndex, 1); // ← 핵심: 0 이 아니라 1
    expect(ern[1].renderSrcIndex, 2);
  });

  test('selected raw index points at the note the user actually sees/taps', () {
    final t = buildTrack();
    final ern = t.effectiveRenderNotes;
    // 위젯이 onNoteTap 에 넘기는 값 = 표시 노트의 renderSrcIndex.
    final tappedRaw = ern[0].renderSrcIndex; // 첫 가청 노트를 탭
    // 그 raw 인덱스가 가리키는 원본 노트가 사용자가 본 노트(A, pitch 60)와 일치해야 한다.
    expect(t.notes[tappedRaw].pitch, 60);
  });

  test('no leading drop: display index equals raw index', () {
    // inPoint 가 첫 노트 시작과 같으면 드롭 없음 → 인덱스 일치(회귀 가드).
    final t = TrackData(2, TrackRole.keys);
    t.notes = [mk(0.0, 0.3, 60), mk(0.3, 0.6, 62)];
    for (final n in t.notes) {
      n.chunkId = 9;
    }
    t.chunks = [Chunk(id: 9, timelineStart: 0, inPoint: 0.0, outPoint: 0.6, originalLength: 0.6)];
    final ern = t.effectiveRenderNotes;
    expect(ern.length, 2);
    expect(ern[0].renderSrcIndex, 0);
    expect(ern[1].renderSrcIndex, 1);
  });
}
