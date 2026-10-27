# Humanize (timing and velocity)

- **ID:** piano-roll-006
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Humanize (Pitch and Time Utilities) (카탈로그 PR-13)

## Sources
- https://www.ableton.com/en/live-manual/12/editing-midi/ (Pitch and Time Utilities 절): 노트 시작 시각을 무작위로 조금씩 흩뜨려 기계적인 느낌을 줄인다. 양(Amount) 슬라이더가 최대 이동 폭을 정하며, 그 상한은 격자 한 칸의 4분의 1(앞뒤)이다. 버튼을 누를 때 한 번 적용된다.
- 세기 무작위화는 위 매뉴얼의 Humanize에는 없고, HumTrack이 같은 명령에 덧붙이는 **자체 설계**다(세기 쪽 근거: 같은 페이지의 velocity 편집 절은 세기 범위를 다루지만 그것은 재생 시점 무작위이므로 PR-007에서 다룬다).

## User-visible behavior
1. 사용자가 노트를 선택하고(선택이 없으면 현재 트랙 전체) Humanize를 실행하면, 각 노트의 시작이 ±Timing 범위 안에서, 세기가 ±Velocity 범위 안에서 무작위로 바뀐다. 길이는 유지되어 노트 전체가 이동한다.
2. 설정: Timing = 16분음표 한 칸의 0–50%(기본 10%), Velocity = 0–40(기본 10). 둘 중 하나를 0으로 두면 그 속성은 바뀌지 않는다.
3. 결과는 **한 번 적용되고 저장된다**(파괴적 편집). 재생할 때마다 달라지지 않는다(그것은 PR-007).
4. 다시 누르면 새 무작위 값으로 한 번 더 흩뜨린다(이전 결과 위에 누적). Undo 한 번이 한 번의 Humanize를 되돌리고, Redo는 **같은 결과**를 다시 돌려준다(다시 굴리지 않음).

## 결정성 (undo/테스트)
- 함수는 `seed`(정수)를 입력으로 받고, 같은 입력 노트 + 같은 설정 + 같은 seed → 항상 같은 결과.
- 무작위원은 Dart `math.Random`이 아니라 HumTrack 자체 32-bit xorshift(Marsaglia, `x ^= x<<13; x ^= x>>>17; x ^= x<<5`, 32비트 마스크, seed 0은 `0x9E3779B9`로 대체)를 쓴다. 플랫폼·Dart 버전과 무관하게 같은 수열을 보장하기 위해서다. u = x / 2^32 ∈ [0, 1).
- 대상 노트를 (startSteps, midi, 원래 리스트 인덱스) 순으로 정렬한 뒤 노트마다 **항상 두 번** 뽑는다: 첫째 timing u₁, 둘째 velocity u₂. 범위가 0이어도 뽑아서, 한쪽 설정을 바꿔도 다른 쪽 결과가 섞이지 않게 한다.
- dt = (2u₁ − 1) · Timing, dv = round((2u₂ − 1) · Velocity).
- UI는 실행할 때마다 새 seed를 만들어(예: 시계 기반) 함수에 넘긴다. Undo 스냅샷이 결과를 담으므로 seed를 곡에 저장할 필요는 없다.

## Edge cases
- 새 시작 = clamp(s + dt, 0, steps − 길이). 길이가 섹션보다 길면 시작 0.
- 새 세기 = clamp((velocity ?? 100) + dv, 1, 127). 원래 `velocity == null`(기본 세기)이었고 dv ≠ 0이면 명시적 값이 된다. dv == 0이면 null 유지.
- 잠긴 노트는 건너뛴다(RNG도 소비하지 않음 — 잠금 여부를 바꿔도 다른 노트 결과가 바뀌지 않게 하려면 정렬 대상에서 잠긴 노트를 아예 뺀다).
- 꺼진 노트(PR-001)도 대상이다.
- 화음 구성음도 각각 따로 흩어진다(v1). 기타 strum 화음은 정밀 오프셋이 생기면 기존 규칙대로 strum 대신 개별 재생된다.
- 결과 시작은 `_withBounds` 규칙으로 `step/offsetSteps`에 저장한다. 시작이 이동하므로 정밀 필드가 생긴다.

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/note_random.dart`(신규): `class HumRng`(xorshift32, `nextDouble()`), PR-007과 공용.
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `humanizePitchNotes(notes, selected, {required double timingSteps, required int velocityRange, required int seed, required int steps})`. 바뀐 게 없으면 입력 `identical` 반환.
  - `mobile/lib/looptap/widgets/surfaces/step_grid.dart`: 인스펙터 `note-humanize` 버튼(현재 설정으로 즉시), 길게 누르기/설정 아이콘 → Timing·Velocity 슬라이더 시트. `_commit(before, after)`.
  - `mobile/lib/looptap/state/loop_prefs.dart`: 마지막 Timing/Velocity 설정 저장.
  - `mobile/lib/looptap/screens/edit_screen.dart`: 기존 `_gridEditNotes` → `_pushUndo()`. Redo는 스냅샷 복원이므로 자동으로 같은 결과.
- Model: 변경 없음.
- UI: 데스크톱 `H`(수정키 없음, 선택 편집 모드) = 현재 설정으로 적용, `Shift+H` = 설정. macOS에서 `Cmd+H`는 앱 숨기기라 쓰지 않는다. 모바일 = 인스펙터 버튼.
- Drum notes: v1 UI 제외. 같은 규칙의 `humanizeDrumNotes(notes, ..., seed)`(시작 + 세기, 길이 없음)는 순수 함수로만 추가 가능하며, 드럼 표면 진입점은 별도 승인.

## Decisions (2026-10-22, owner approved)
- 단축키(M, K, H, Ctrl/Cmd+U/E/J/L)는 사양대로 확정.
- 드럼 레인은 v1 제외 (드럼 선택 UI가 생기는 2번 묶음에서 다룸).
- v1은 노트별 개별 이동. 화음을 함께 움직이는 옵션은 다음 버전.
- **단축키 변경(2026-10-22, 구현 후):** `H` → `Ctrl/Cmd+Shift+H`(적용). 설정은 버튼/길게 누르기로만 연다. 사유는 PR-002와 같고, macOS의 `Cmd+H`는 앱 숨기기라 피했다.

## Acceptance tests
- [x] `HumRng(1)`의 첫 원시 출력(32-bit 정수) = 270369. seed 0과 seed `0x9E3779B9`의 수열이 같다.
- [x] 같은 notes/설정/seed로 두 번 호출 → 결과의 (step, offsetSteps, velocity)가 모두 같다.
- [x] seed만 다르게 → 적어도 한 노트가 다르다(노트 8개, Timing 10%, Velocity 10 기준).
- [x] 범위: 모든 결과 노트에서 |새 시작 − 원래 시작| ≤ Timing(clamp 경우 제외), |새 세기 − 원래 세기| ≤ Velocity.
- [x] Timing 0, Velocity 10 → 모든 시작 불변, 세기만 변화. 같은 seed에서 Timing 10%로 바꿔도 **세기 결과는 동일**.
- [x] Velocity 0 → `velocity == null`인 노트는 null 유지.
- [x] 경계: steps=16, 노트(15.0–16.0), Timing 50%, dt > 0이 나오는 seed → 시작 15.0으로 clamp.
- [x] 잠긴 노트 `identical`이고, 잠긴 노트를 목록에서 빼도 나머지 결과가 같다.
- [x] midi, 길이(soundingSteps), sourceMidi, confidence, assisted, muted 불변.
- [x] Timing 0, Velocity 0 → 입력과 `identical`.

## Out of scope
- 재생 시점 무작위(PR-007), 화음 단위로 함께 이동하는 옵션, 그루브 템플릿, 길이 무작위화.
- 드럼 노트 Humanize UI.
