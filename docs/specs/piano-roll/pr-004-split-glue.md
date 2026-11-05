# Split, chop and glue notes

- **ID:** piano-roll-004
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Split / Join Notes; FL Studio — Glue, Quick chop / Chop (카탈로그 PR-09, PR-10, PR-11)

## Sources
- https://www.ableton.com/en/live-manual/12/editing-midi/ (Note operations 절): 노트를 한 지점에서 둘로 나누는 동작과, 같은 음 줄의 선택 노트를 하나로 합치는 Join 명령이 있다.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm : 맞닿은 노트를 붙이는 Glue, 스냅 단위로 긴 노트를 잘게 나누는 Quick chop과 더 자세한 Chop 대화상자가 있다.
- https://www.ableton.com/en/live-manual/12/midi-tools/ : 노트를 정한 개수/단위로 나누는 도구(Chop).
- Hands-on observation 2026-10-21 (findings.json, `source_level_risks` P0 및 `recommended_order` 1): 노트를 자르거나 합칠 때 새 노트를 기본값으로 만들면 세기·미세 타이밍·잠금·분석 메타데이터가 사라진다. **편집 중 노트 정보 보존**이 최우선 규칙이다.

## User-visible behavior
1. **Split at position.** 선택 노트 중 위치 t를 시간상 안쪽에 포함하는(시작 < t < 끝) 노트를 t에서 둘로 나눈다. t는 데스크톱에서 재생 위치(playhead), 모바일 시트에서는 "재생 위치" 또는 각 노트의 "가운데(격자 맞춤)" 중 고른다. 격자 맞춤이 켜져 있으면 t를 가장 가까운 정수 step으로 반올림한다.
2. **Chop.** 선택 노트를 (a) N등분(N=2–16) 또는 (b) 격자 단위(1/4, 1/8, 1/16, 1/32)로 나눈다. 격자 단위는 0부터의 절대 격자선에서 자르며, 마지막 조각은 짧을 수 있다.
3. **Glue.** 선택 노트를 음높이별로 묶어 시간 순으로 이웃한 노트들을 하나로 합친다. 사이에 빈틈이 있어도 사용자가 둘 다 선택했으면 합친다(흥얼거림 변환은 같은 음 사이에 짧은 틈을 자주 남기므로). 단, 두 노트 사이에 **선택되지 않은** 같은 음 노트가 있으면 그 지점에서 끊는다.
4. 결과 조각/합친 노트는 선택된 상태로 남는다. 명령 1회 = Undo 1회.

## 속성 상속 규칙 (P0 보존)
- **Split/Chop 조각:** 모든 조각은 원본의 `copyWith`로 만든다. `midi, freq, velocity, sourceMidi, confidence, assisted, muted`(PR-001), `chance, velocityDeviation`(PR-007)을 그대로 상속한다. 첫 조각은 원본 `step/offsetSteps`를 유지하고, 나머지 조각만 새 시작을 가진다. 경계 계산은 `_withBounds` 규칙(정밀 필드가 있었거나 경계가 정수가 아니면 `durationSteps` 기록).
- **Glue 결과:** 가장 이른 노트(anchor)의 `copyWith`. 시작 = anchor 시작, 끝 = 묶음의 최대 끝. `velocity, sourceMidi, offsetSteps, chance, velocityDeviation`는 anchor 값. `confidence` = 묶음의 최솟값(덜 확실한 쪽을 남김). `assisted` = 하나라도 true면 true. `muted` = 묶음이 **모두** 꺼져 있을 때만 true(하나라도 소리 나면 합친 노트도 소리 남).
- 잠긴 노트는 나누지도, 합치지도 않는다. Glue 묶음에서 잠긴 노트는 경계 역할을 한다(그 앞뒤는 따로 묶임).

## Edge cases
- 조각 하나라도 1/16 step보다 짧아지면 그 노트는 나누지 않는다(`resizePitchNotes`의 최소 길이와 같은 기준).
- t가 노트 시작이나 끝과 정확히 같으면(±1e-6) 그 노트는 나누지 않는다.
- Split 대상 노트가 없으면 아무 기록도 남기지 않고 상태 표시줄에 "자를 노트 없음" 정도의 안내만.
- Glue 대상 음에서 노트가 1개뿐이면 그대로. 겹치는 같은 음 노트도 하나로 합친다(끝은 최댓값).
- 노트 순서: 결과 리스트에서 원본 노트 자리에 조각들이 연속으로 들어가고(Split/Chop), Glue는 anchor 자리에 결과가 들어가고 나머지 묶음 노트는 빠진다. 다른 노트는 순서·객체가 그대로.

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `splitPitchNotesAt(notes, selected, double at)`, `chopPitchNotes(notes, selected, {int? parts, double? grid})`, `gluePitchNotes(notes, selected)`. 모두 `_withBounds`/`copyWith`만으로 노트를 만들고, `PitchNote(...)` 생성자를 직접 부르지 않는다. 각 함수는 바뀐 것이 없으면 입력을 `identical`로 반환하고, 새 선택 집합도 함께 돌려준다(예: record `({List<PitchNote> notes, Set<PitchNote> selection})`).
  - `mobile/lib/looptap/music/melody_review.dart`의 `splitNoteAtMidpoint`/`mergeWithNext`는 멜로디 검토 시트 전용(±1반음 병합 등 규칙이 다름)으로 **그대로 둔다**.
  - `mobile/lib/looptap/widgets/surfaces/step_grid.dart`: 노트 개수가 바뀌므로 `_commit(before, after, selection: ...)`에 명시적 선택을 넘긴다(인덱스 대응 선택 계산은 길이가 바뀌면 틀림). `StepGrid`에 현재 `playStep`이 이미 있으므로 Split 위치로 사용.
  - `mobile/lib/looptap/screens/edit_screen.dart`: 기존 `_gridEditNotes` → `_pushUndo()`.
- Model: 변경 없음.
- UI: 데스크톱 `Ctrl/Cmd+E` = 재생 위치에서 Split, `Ctrl/Cmd+J` = Glue, `Ctrl/Cmd+Shift+E` = Chop 설정. 모바일·데스크톱 공통 인스펙터 버튼 `note-split`("자르기", 시트에서 위치/등분/격자 선택), `note-glue`("붙이기").
- Drum notes: 제외(드럼 히트는 길이 개념이 약하고 선택 UI가 없음).

## Decisions (2026-10-22, owner approved)
- 단축키(M, K, H, Ctrl/Cmd+U/E/J/L)는 사양대로 확정.
- 드럼 레인은 v1 제외 (드럼 선택 UI가 생기는 2번 묶음에서 다룸).
- Glue 결과 벨로시티는 **가장 앞 노트** 값 (사양대로).

## Acceptance tests
표기: 노트(midi, start, end, 기타).
- [x] Split at 2.0: A(60, 0.0–4.0, velocity 90, sourceMidi 61, confidence 0.7, assisted) → A1(60, 0–2), A2(60, 2–4). 둘 다 velocity 90, sourceMidi 61, confidence 0.7, assisted=true. A1.step == A.step, A1.offsetSteps == A.offsetSteps.
- [x] 정밀 노트 Split: (60, 1.25–3.75, durationSteps 2.5) at 2.0 → (1.25–2.0: step 1, offset 0.25, durationSteps 0.75), (2.0–3.75: step 2, offset 0, durationSteps 1.75).
- [x] Split 위치가 노트 밖이거나 경계와 같으면 결과가 입력과 `identical`.
- [x] 1/16 미만 조각: (60, 0–1.0) at 0.03 → 변화 없음.
- [x] Chop N=4: (60, 0–4) → 0–1, 1–2, 2–3, 3–4, 모두 원본 속성 상속.
- [x] Chop 1/8 격자: (60, 1–6) → 1–2, 2–4, 4–6.
- [x] Glue: [A(60, 0–1, v80, conf .9), B(60, 1.5–3, v40, conf .5)] 둘 다 선택 → 하나(60, 0–3, v80, conf .5).
- [x] Glue 경계: [A(60,0–1), C(60,1–2) 비선택, B(60,2–3)] 중 A·B만 선택 → 변화 없음.
- [x] Glue 잠금: A, L(locked), B 연속 선택 → A와 B는 합쳐지지 않음, L 그대로.
- [x] Glue muted: [A muted, B active] → 결과 `muted=false`. [A muted, B muted] → `muted=true`.
- [x] 서로 다른 음(60, 62)은 합쳐지지 않는다.

## Out of scope
- 칼 도구로 그어서 자르기(드래그 제스처), 비등분 Chop 패턴, 같은 음 아닌 노트 합치기.
- 드럼 노트 Split/Glue.
