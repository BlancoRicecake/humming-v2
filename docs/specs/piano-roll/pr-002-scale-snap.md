# Fit to scale / Snap to scale

- **ID:** piano-roll-002
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Fit to Scale; FL Studio — Snap piano roll notes to scale (카탈로그 PR-17, PR-21)

## Sources
- https://www.ableton.com/en/live-manual/12/editing-midi/ (Pitch and Time Utilities 절): 선택(또는 클립 전체) 노트의 음높이를 클립 스케일의 가장 가까운 음으로 옮긴다. 거리가 같으면 아래로 옮긴다. 스케일이 없으면 명령이 비활성.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm : 스케일 스냅을 켜면 새로 그리거나 옮기는 노트가 선택한 스케일의 가장 가까운 음에 붙는다. 이미 있는 노트는 옮기기 전까지 바뀌지 않는다.

## User-visible behavior
1. **Fit to scale (일회성 명령).** 선택 노트(선택이 없으면 현재 트랙의 모든 노트) 중 곡의 키+스케일(`Song.key`, `Song.scale`)에 속하지 않는 음을 가장 가까운 스케일 음으로 옮긴다. 이미 스케일 안에 있는 노트는 바뀌지 않는다.
2. 위·아래 후보와의 거리가 같으면 **아래 음**을 고른다.
3. 시간, 길이, 세기, 꺼짐 상태는 그대로다. Undo 한 번으로 모두 원래 음으로 돌아온다.
4. **Scale snap (토글).** 툴바 토글을 켜면:
   - 그리기 모드에서 스케일 밖 줄을 눌러 그린 노트는 같은 규칙으로 스케일 음 줄에 놓인다.
   - 선택 편집에서 ↑/↓(반음 이동)은 각 노트를 "바로 위/아래의 스케일 음"으로 옮긴다(노트마다 이동 폭이 1~3반음으로 다를 수 있음). Shift+↑/↓(옥타브)는 그대로 12반음.
   - 이미 있는 노트는 토글을 켜는 것만으로는 바뀌지 않는다.
5. 곡 스케일이 `chromatic`이면 Fit to scale 버튼은 비활성이고 Scale snap은 아무 효과가 없다.

### Tie-break 결정과 근거
- HumTrack은 **아래(down)** 를 고른다. 근거: (a) 기존 흥얼거림 매핑 `snapToLadder`(hum_map.dart)가 같은 거리에서 낮은 rung을 고르므로, 흥얼거림 변환 결과와 수동 Fit 결과가 같은 규칙을 따른다. (b) 공식 매뉴얼의 Fit to Scale도 아래를 택한다. (c) 규칙이 노트 방향·위치와 무관해 예측과 테스트가 쉽다.
- 동률은 7음 스케일에서 스케일 음 사이 반음(예: A minor의 G# → G), pentatonic에서 3반음 간격의 중간이 없는 경우 등에서 생긴다. 사용자가 위가 맞다고 느끼면 ↑ 한 번(Scale snap 켬)으로 바로 고칠 수 있다.

## Edge cases
- 잠긴 노트는 Fit 대상에서 빠지고, Scale snap 이동에서도 기존 규칙대로 움직이지 않는다.
- 아래 후보가 0 미만이면 위 후보, 위 후보가 127 초과면 아래 후보를 쓴다.
- 꺼진(muted, PR-001) 노트도 Fit 대상이다(나중에 켰을 때 맞는 음이어야 하므로).
- 옥타브 접기는 하지 않는다. Fit은 같은 옥타브 근처의 가장 가까운 음만 고른다(흥얼거림 매핑의 `phraseOctaveShift`/ladder 접기와 다름).
- 바꿀 노트가 하나도 없으면 편집 기록(undo)을 남기지 않는다.
- 여러 노트가 같은 음·같은 시작으로 겹치게 되어도 합치지 않는다.
- Scale snap 이동에서 그룹 이동 경계: 선택 중 한 노트라도 0~127을 벗어나면 그 키 입력 전체를 무시한다(기존 `movePitchNotes`의 그룹 clamp와 같은 원칙).

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/theory.dart`: 순수 함수 `bool inScale(int midi, String root, String scale)`, `int nearestInScale(int midi, String root, String scale)`(동률 아래), `int stepInScale(int midi, String root, String scale, int dir)`(바로 위/아래 스케일 음) 추가. `kScales`, `kNoteNames`를 사용.
  - `mobile/lib/looptap/music/hum_map.dart`: **수정하지 않는다.** `snapToLadder`는 백엔드 파이썬 미러와 parity 테스트로 묶여 있다. 새 함수는 동률 규칙만 맞춘다.
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `fitPitchNotesToScale(notes, selected, root, scale)` 추가. 바뀐 노트는 `copyWith(midi, freq: midiToFreq(new), sourceMidi: n.sourceMidi ?? n.midi, assisted: true)`. 원래 음을 `sourceMidi`에 남겨 기존 raw/교정 비교 청취(`_previewRawMelody`)가 계속 동작한다. 이미 `sourceMidi`가 있으면 덮어쓰지 않는다(가장 처음 음 유지). `movePitchNotesInScale(...)`도 추가.
  - `mobile/lib/looptap/widgets/surfaces/step_grid.dart`: `StepGrid`에 `scaleRoot`, `scaleName` 파라미터 추가. 툴바에 `note-scale-snap` 토글, 인스펙터에 `note-fit-scale` 버튼. `_key`의 ↑/↓ 분기에서 토글이 켜져 있으면 `movePitchNotesInScale` 사용. 그리기(`onPlace`) 전 rung을 스냅.
  - `mobile/lib/looptap/screens/edit_screen.dart`: `_keyRoot`, `_scale`을 StepGrid에 전달. 기록은 `_gridEditNotes` → `_pushUndo()`.
  - `mobile/lib/looptap/state/loop_prefs.dart`: Scale snap 토글 상태를 앱 설정으로 저장(곡 데이터 아님).
- Model: 변경 없음. 옛 곡 그대로.
- UI: 데스크톱 단축키 `K`(Fit to scale), 토글은 버튼만. 모바일은 인스펙터 버튼과 툴바 토글(StepGrid가 공용).
- Drum notes: 제외(음높이가 없음).

## Decisions (2026-10-22, owner approved)
- 단축키(M, K, H, Ctrl/Cmd+U/E/J/L)는 사양대로 확정.
- 드럼 레인은 v1 제외 (드럼 선택 UI가 생기는 2번 묶음에서 다룸).
- 동거리 타이브레이크는 **아래로** (기존 `snapToLadder`와 동일).
- **단축키 변경(2026-10-22, 구현 후):** `K` → `Ctrl/Cmd+K`. 데스크톱 QWERTY 피아노가 노트 편집기 위에서도 전역으로 `K`를 받아서 원래 키는 동작하지 않았다.

## Acceptance tests
Key A minor(A, [0,2,3,5,7,8,10]) 기준.
- [x] G#4(68) → G4(67) (동률 1:1 → 아래). `sourceMidi=68`, `assisted=true`, `freq=midiToFreq(67)`.
- [x] A#4(70) → A4(69) (동률 → 아래). C#5(73) → C5(72).
- [x] A4(69)는 그대로이며 결과 리스트에서 `identical`.
- [x] Key C pentatonic(minor penta, [0,3,5,7,10]): C#(61)→C(60), D(62)→D#(63), B(71)→A#(70)(10과 12 사이 동률 → 아래).
- [x] 이미 `sourceMidi=66`인 G#(68) → G(67), `sourceMidi`는 66 유지.
- [x] 잠긴 G# 노트는 그대로(`identical`).
- [x] scale `chromatic` → 반환값이 입력과 `identical`.
- [x] midi 0, key D major(pc 0이 스케일 밖, B와 C#이 동률이지만 아래 후보 −1이 범위 밖) → 1(C#)로 이동.
- [x] `movePitchNotesInScale`, A minor, 선택 [A4(69), C5(72)], dir +1 → [B4(71), D5(74)].
- [x] step, offsetSteps, durationSteps, velocity, muted 불변.

## Out of scope
- 스케일 줄 강조/접기(PR-18, PR-19), 노트별/클립별 스케일, 음계 밖 노트 자동 탐지 경고.
- 흥얼거림 ladder 매핑 규칙 변경.
