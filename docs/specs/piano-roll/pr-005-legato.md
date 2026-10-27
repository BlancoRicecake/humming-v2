# Legato

- **ID:** piano-roll-005
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Legato (Pitch and Time Utilities), Span tool legato mode; FL Studio — Quick legato / Articulate (카탈로그 PR-14)

## Sources
- https://www.ableton.com/en/live-manual/12/editing-midi/ (Pitch and Time Utilities 절): 선택 노트 각각을 다음 노트의 시작까지 늘이거나 줄인다. 마지막 노트는 루프 끝까지 늘어난다.
- https://www.ableton.com/en/live-manual/12/midi-tools/ (Span, Legato 모드): 같은 동작을 도구로 제공하며, 마지막 노트는 시간 선택 끝 또는 루프 끝까지.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm : 빠른 레가토 명령과 길이 주법(Articulate) 도구가 있다.

## User-visible behavior
1. 사용자가 노트를 선택하고(선택이 없으면 현재 트랙 전체) Legato를 실행하면, 각 노트의 끝이 "자기보다 늦게 시작하는 다음 노트의 시작"으로 맞춰진다. 늘어날 수도, 줄어들 수도 있다.
2. 기준이 되는 "다음 노트"는 **같은 선택 안의 노트**에서만 찾는다(선택하지 않은 노트는 무시). 음높이는 상관없다.
3. 선택 중 가장 늦게 시작하는 노트(들)는 섹션 루프 끝(`steps`)까지 늘어난다.
4. **화음 처리:** 시작이 같은(±1e-6) 노트들은 한 덩어리로 보고, 모두 다음 "다른 시작 시각"까지 같은 길이로 맞춘다. 그래서 단선율과 화음 진행이 같은 규칙으로 동작한다(화음 → 다음 화음 시작까지 모든 구성음 연장).
5. 시작, 음높이, 세기, 메타데이터는 바뀌지 않는다. 1회 = Undo 1회.

## Edge cases
- 잠긴 노트는 길이가 바뀌지 않지만, 선택에 포함되어 있으면 그 **시작은 기준점으로 쓰인다**(잠긴 노트 앞의 노트가 잠긴 노트 시작까지 이어짐).
- 꺼진(muted, PR-001) 노트는 자신은 길이가 맞춰지지만 **기준점으로는 쓰이지 않는다**(소리 없는 노트 때문에 앞 노트가 끊기면 안 되므로).
- 겹친 성부(시작이 다른 긴 노트 위에 짧은 노트가 시작): 긴 노트는 짧은 노트 시작에서 잘린다. 이는 "각 노트를 다음 시작까지"라는 규칙의 결과이며, 성부를 지키고 싶으면 성부별로 선택해 실행한다.
- 결과 길이가 1/16 step 미만이 되는 경우는 시작이 서로 1e-6 이상 다르면 생기지 않지만, 생긴다면 1/16 step으로 올린다.
- 선택된 노트가 1개면 루프 끝까지 늘어난다.
- 모든 노트 길이가 이미 맞으면 편집 기록을 남기지 않는다.
- 같은 음 노트가 정확히 맞닿게 되면 재생 시 끝/시작이 같은 tick에 나온다. 합치지는 않는다(합치기는 Glue, PR-004).

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `legatoPitchNotes(notes, selected, {required int steps})`.
    1. 기준 시작 목록 R = 선택 중 `muted == false`인 노트의 `startSteps`를 정렬·중복 제거(±1e-6).
    2. 선택 중 잠기지 않은 노트 n마다 next = R에서 `n.startSteps + 1e-6`보다 큰 첫 값, 없으면 `steps`.
    3. `_withBounds(n, n.startSteps, next)`로 끝만 바꾼다(시작은 `sameStart` 경로로 `step/offsetSteps` 그대로).
    4. 바뀐 것이 없으면 입력을 `identical`로 반환.
  - `mobile/lib/looptap/widgets/surfaces/step_grid.dart`: 인스펙터 버튼 `note-legato`("이어 붙이기"/"Legato"), `_key`에 단축키. `_commit(before, after)`(노트 개수 불변이라 인덱스 기반 선택 유지가 맞음).
  - `mobile/lib/looptap/screens/edit_screen.dart`: 기존 `_gridEditNotes` → `_pushUndo()`.
- Model: 변경 없음.
- UI: 데스크톱 `Ctrl/Cmd+L`. 모바일은 인스펙터 버튼.
- 기타(guitar) 프로그램의 화음 strum: 길이가 정밀 값이 되면(`durationSteps` 기록) 기존 규칙대로 그 화음은 strum 없이 동시에 울린다(`edit_screen.dart`/`midi_export.dart`의 "정밀 노트는 strum 제외" 조건). 레가토 결과가 정수 길이면 strum은 유지된다. 이 스펙은 strum 규칙을 바꾸지 않는다.
- Drum notes: 제외(드럼은 길이로 소리가 달라지지 않음).

## Decisions (2026-10-22, owner approved)
- 단축키(M, K, H, Ctrl/Cmd+U/E/J/L)는 사양대로 확정.
- 드럼 레인은 v1 제외 (드럼 선택 UI가 생기는 2번 묶음에서 다룸).

## Acceptance tests
steps=16, 노트는 (midi, start–end).
- [x] 단선율: [A(60, 0–1), B(62, 4–5), C(64, 6–6.5)] 모두 선택 → A(0–4), B(4–6), C(6–16).
- [x] 줄이기: [A(60, 0–8), B(62, 2–3)] → A(0–2), B(2–16).
- [x] 화음: [C(60,0–1), E(64,0–1), G(67,0–1), F(65,8–9), A(69,8–9)] → C,E,G 모두 0–8, F,A 모두 8–16.
- [x] 비선택 무시: [A(60,0–1) 선택, B(62,4–5) 비선택] → A(0–16), B `identical`.
- [x] 잠긴 기준: [A(60,0–1), L(62,4–5, locked)] 모두 선택 → A(0–4), L `identical`.
- [x] 꺼진 노트 무시: [A(60,0–1), M(62,4–5, muted), B(64,8–9)] 모두 선택 → A(0–8), M(4–8), B(8–16).
- [x] 정밀 시작 유지: A(step 0, offset 0.25, 0.25–1.0), B(2.5–3) → A는 step 0, offsetSteps 0.25, soundingSteps 2.25.
- [x] 이미 레가토 상태([A(0–4), B(4–16)]) → 입력과 `identical`.
- [x] midi, velocity, sourceMidi, confidence, assisted, muted, chance 불변.

## Out of scope
- 스타카토/테누토 등 길이 비율 주법(PR-32), 레가토 간격(겹침/틈) 조절 값.
- 선택하지 않은 노트까지 기준으로 쓰는 모드.
- 드럼 노트.
