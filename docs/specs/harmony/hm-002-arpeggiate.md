# Arpeggiate (코드를 분산화음 노트로 바꾸기)

- **ID:** harmony-002
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Arpeggiate (MIDI Transformation tool); FL Studio — Piano roll Arpeggiate tool (카탈로그 PR-27). 실시간 Arpeggiator 장치(DV-03)는 이 스펙 범위가 아니다.

## Sources
- https://www.ableton.com/en/live-manual/12/midi-tools/ (Arpeggiate): 선택한 노트를 패턴 스타일에 따라 펼친 노트열로 **다시 써 넣는** 변환 도구다. Rate가 패턴 속도(그리고 노트 길이)를, Gate가 노트 길이 비율(100% 미만은 짧게, 초과는 겹치게)을 정한다. Distance/Steps로 패턴을 위아래로 옮겨 반복한다.
- https://www.ableton.com/en/live-manual/12/live-midi-effect-reference/ (Arpeggiator): 스타일에 Up, Down, 무작위 계열(무작위, 한 바퀴 안에서 겹치지 않는 무작위 등)이 있다. Gate는 Rate에 대한 백분율이다.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_arpeggiate.htm : 패턴 방향(정방향/뒤집기/번갈아), 시간 배수, Gate, 옥타브 범위(Range)와 그 위아래 진행 방식이 있다.
- 노트 생성 규칙(코드 묶기, 상속, 끝 처리)은 HumTrack 자체 설계다.

## User-visible behavior
1. 사용자가 코드(동시에 시작하는 여러 노트)를 선택하고 Arpeggiate를 실행하면, 각 코드가 차지하던 시간 안에 구성음이 정한 순서·속도로 하나씩 울리는 노트열로 바뀐다.
2. 설정(시트, 마지막 값 기억):
   - **Style:** Up(기본), Down, Up-Down, Down-Up, Random.
   - **Rate:** 1/4, 1/8, 1/16(기본), 1/32, 1/8T, 1/16T.
   - **Gate:** 10–200%(기본 90%).
   - **Octaves:** 1–4(기본 1). 2 이상이면 구성음을 한 옥타브씩 위로 복제해 패턴에 넣는다.
   - **원래 코드:** "바꾸기"(기본, 원래 노트 삭제) / "소리 끄고 남기기"(원래 노트를 PR-001 `muted`로 남김 — 나중에 다시 펼치거나 되돌리기 쉬움).
3. 결과 노트열이 선택된 상태가 된다. 실행 1회 = Undo 1회. 같은 설정으로 다시 실행하면(선택이 노트열이므로) 노트열의 같은 시작 묶음이 없어 변화 없음 안내.

## 생성 규칙
- **코드 묶기:** 선택 노트 중 잠기지 않고 꺼지지 않은 노트를 `startSteps` 기준으로 정렬하고, 시작 차이 0.05 step 이내를 한 묶음으로 본다. 묶음 시간 = [가장 이른 시작 s0, 가장 늦은 끝 e0]. 노트가 1개뿐인 묶음은 Octaves ≥ 2일 때만 펼치고, 아니면 그대로 둔다.
- **음 목록 P:** 묶음 음높이를 오름차순·중복 제거한 뒤 Octaves k에 대해 +12·j(j < k)를 더한 목록. 127 초과는 버린다.
- **순서 Q:** Up = P, Down = P 역순, Up-Down = P + (P 역순에서 양 끝 제외), Down-Up = 그 반대. |P| ≤ 2이면 Up-Down = Up. Random = 매 바퀴(|P|개)마다 P를 섞되 한 바퀴 안에서 같은 음 반복 없음, 바퀴 경계에서 같은 음이 연달아 나오지 않게 첫 음을 바꾼다. 무작위원은 PR-006의 `HumRng`(xorshift32)이고 seed는 실행마다 새로 만든다(Undo 스냅샷이 결과를 담으므로 seed 저장 안 함).
- **시간:** Rate 격자 g(step)는 PR-003 표와 같다(1/16 = 1, 1/8T = 4/3 …). i번째 노트 시작 tᵢ = s0 + i·g, tᵢ < e0인 동안. 길이 = min(g·Gate, e0 − tᵢ). 길이가 1/16 step 미만이면 그 노트는 만들지 않는다.
- **음 배정:** i번째 노트 음높이 = Q[i mod |Q|].
- **속성 상속:** 각 노트는 "그 음높이(옥타브 복제면 원래 음높이)의 원본 노트"의 `copyWith`로 만든다 — `velocity, sourceMidi, confidence, assisted, chance, velocityDeviation` 상속, 시작/길이만 `_withBounds` 규칙으로 새로. `locked=false`, `muted=false`.
- 결과 리스트: 원본 노트 자리 중 묶음의 첫 노트 자리에 노트열이 연속으로 들어가고, 묶음의 나머지 원본은 빠진다("소리 끄고 남기기"면 원본은 `muted=true`로 제자리에 남고 노트열은 그 뒤에 들어간다). 다른 노트는 순서·객체 그대로.

## Edge cases
- 겹쳐 있지만 시작이 다른 노트(예: 긴 베이스 위의 멜로디)는 다른 묶음이다. 묶음끼리 시간이 겹쳐도 각자 펼친다.
- 섹션 끝(`steps`)을 넘는 노트는 만들지 않는다(e0가 섹션보다 길면 `steps`로 자름).
- 스윙/그루브는 노트에 굽지 않는다. 노트열은 곧은 격자에 놓이고, 재생·내보내기에서 기존 스윙(및 GR-001 그루브)이 적용된다. 1/32·셋잇단 노트는 PR-003처럼 자신이 속한 정수 step의 스윙을 따른다.
- 기타 악기: 노트열은 시작이 서로 달라 strum 묶음이 생기지 않는다(기존 strum 규칙 변경 없음).
- 드럼 트랙: 명령 없음.

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/arpeggiate.dart`(신규): `enum ArpStyle`, `class ArpSettings {style, grid, gate, octaves, keepOriginalMuted}`, `({List<PitchNote> notes, Set<PitchNote> selection}) arpeggiatePitchNotes(notes, selected, ArpSettings s, {required int seed, required int steps})`. 바뀐 것이 없으면 `identical`. `_withBounds`가 private이면 `pitch_note_edit.dart`에 공개 래퍼(`pitchNoteWithBounds`)를 추가한다.
  - `widgets/surfaces/step_grid.dart`: 인스펙터 `note-arpeggiate`("펼치기"/"Arpeggiate", 길게 누르기 = 설정 시트), 노트 개수가 바뀌므로 `_commit(before, after, selection: ...)`.
  - `widgets/sheets/arp_sheet.dart`(신규): Style 칩, Rate 칩, Gate·Octaves 슬라이더, 원래 코드 스위치. 값은 `state/loop_prefs.dart`.
  - `edit_screen.dart`: 기존 `_gridEditNotes` → `_pushUndo()`.
- Model: 변경 없음.
- UI: 데스크톱 `A`(수정키 없음, 선택 편집 모드) = 현재 설정으로 펼치기, `Shift+A` = 설정. (`Ctrl/Cmd+A` 전체 선택과 구분.) 모바일 = 인스펙터 버튼.
- Export: 영향 없음(일반 노트).

## Decisions (2026-10-22, owner approved)
- **단축키 규칙:** 데스크톱 QWERTY 피아노·드럼 키(A S D F G H J K L ; ' \ 등)는 노트 편집기 위에서도 전역으로 잡히고, 노트 편집기는 Alt 조합을 받지 않는다. 그래서 단일 문자 단축키는 그 줄 밖의 키만 쓰고, 나머지는 Ctrl/Cmd 조합을 쓴다.
- 원래 코드의 기본 처리는 **바꾸기**(원 노트 삭제). '소리 끄고 남기기'는 옵션이다.
- 단축키: **`Ctrl/Cmd+Shift+A`**(적용). 설정은 버튼으로 연다(`A`는 피아노·드럼 키라 쓰지 않음).

## Acceptance tests
코드 C = (60, 64, 67) 모두 0–4, steps 32, Gate 100% 기준.
- [x] Up, 1/16 → 4개: (60,0–1), (64,1–2), (67,2–3), (60,3–4).
- [x] Down, 1/8 → (67,0–2), (64,2–4).
- [x] Up-Down, 1/16, 코드 0–8 → 60,64,67,64,60,64,67,64.
- [x] Octaves 2, Up, 1/16, 코드 0–8 → 60,64,67,72,76,79,60,64.
- [x] Gate 50%, 1/8 → 길이 1.0씩(0–1, 2–3).
- [x] Gate 200%, 1/16 → 각 길이 2, 마지막 (60, 3–4)는 e0에서 잘려 길이 1.
- [x] 1/16T: 시작 0, 2/3, 4/3 … (오차 1e-9), `offsetSteps` 소수 저장.
- [x] 상속: 64 노트 velocity 40·chance 0.5 → 64 자리 노트열 모두 velocity 40·chance 0.5, 옥타브 복제 76도 같은 값.
- [x] Random: 같은 seed → 같은 결과. 1000바퀴에서 한 바퀴 안 중복 0회, 바퀴 경계 연속 중복 0회.
- [x] "소리 끄고 남기기": 원본 3개가 `muted == true`로 남고 노트열 4개 추가(총 7).
- [x] 단일 노트 묶음, Octaves 1 → 입력과 `identical`. 잠긴 노트·꺼진 노트는 묶음에서 제외되고 그대로.
- [x] 결과 선택 집합 == 노트열, `onEdit` 1회.

## Out of scope
- 실시간 Arpeggiator 장치(누르는 동안 재생, Retrigger, Repeats, Latch) — DV-03.
- Distance(스케일 도수 이동), Converge/Diverge·연주 순서 스타일, 스텝별 세기 패턴, 묶음 사이 이어 연주.
- 드럼 트랙.
