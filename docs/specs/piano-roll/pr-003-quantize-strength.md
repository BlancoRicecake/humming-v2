# Quantize with grid and strength

- **ID:** piano-roll-003
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Quantize / Quantize Settings; FL Studio — Piano roll Quantizer (카탈로그 PR-12)

## Sources
- https://www.ableton.com/en/live-manual/12/editing-midi/ (Quantizing 절): 선택 노트에 현재 퀀타이즈 설정을 적용하는 명령과, 설정 창을 여는 명령이 따로 있다.
- https://www.ableton.com/en/live-manual/12/midi-tools/ (Quantize): 격자 값(셋잇단 포함)을 고르고, 시작/끝/둘 다를 맞출 수 있으며, Amount가 노트를 격자 쪽으로 일부만 옮긴다.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_qnt.htm : 시작은 항상 맞추고, 끝(길이)은 맞출지/유지할지 고르며, 원래 값과 맞춘 값을 섞는 비율 조절이 있다.
- Hands-on observation 2026-10-21 (findings.json): 데모 세트에 16분 격자 밖 시작점 27개, 격자 밖 길이 24개가 있다. 정수 칸으로 축소하면 리듬이 망가지므로 퀀타이즈는 사용자가 명시적으로 실행할 때만 해야 한다.

## User-visible behavior
1. 사용자가 노트를 선택하고(선택이 없으면 현재 트랙 전체) Quantize를 실행하면 각 노트의 **시작**이 가장 가까운 격자선 쪽으로 Strength 비율만큼 움직인다.
2. 설정: Grid = 1/4, 1/8, 1/16(기본), 1/32, 1/8T, 1/16T. Strength = 0–100%(기본 100%). "끝도 맞추기" 체크(기본 꺼짐).
3. "끝도 맞추기"가 꺼져 있으면 노트 길이는 그대로이고 노트 전체가 이동한다. 켜져 있으면 끝도 가장 가까운 격자선 쪽으로 같은 비율만큼 움직인다.
4. 음높이, 세기, 메타데이터는 바뀌지 않는다. 실행 1회 = Undo 1회.
5. 스윙은 퀀타이즈와 별개다. 퀀타이즈는 스윙이 없는 격자에 맞추고, 재생/내보내기에서 지금처럼 곡의 `swing`이 다시 적용된다. 그래서 스윙 값을 나중에 바꿔도 퀀타이즈를 다시 할 필요가 없다.

## 계산 규칙 (HumTrack 모델 기준)
- 단위는 16분음표 step. 격자 크기 g(step): 1/4=4, 1/8=2, 1/16=1, 1/32=0.5, 1/8T=4/3, 1/16T=2/3. 격자선 = 0부터 g의 배수.
- s = `startSteps`, e = `endSteps`, k = Strength/100.
- 시작 목표 S* = round(s/g)·g. 정확히 가운데이면 **늦은 쪽**(올림). S*가 섹션 길이 `steps` 이상이면 그보다 작은 마지막 격자선으로.
- 새 시작 s' = s + (S* − s)·k.
- 끝 맞추기 꺼짐: e' = s' + (e − s). 끝 맞추기 켜짐: E* = round(e/g)·g, 단 E* ≤ S*이면 E* = S* + g. e' = e + (E* − e)·k.
- e' > `steps`이면 e' = `steps`(길이를 줄임, 시작은 그대로). 결과 길이는 최소 1/16 step.
- 저장: s'와 e'를 정수 근처 오차(|x − round(x)| < 1e-6)에서 정수로 정리한 뒤, `pitch_note_edit.dart`의 `_withBounds` 규칙으로 `step`, `offsetSteps`, `dur`, `durationSteps`를 만든다. 원래 정밀 필드가 있던 노트는 정수 경계로 돌아와도 `durationSteps`가 남을 수 있다(값이 `dur`와 같아 소리는 동일).

## Edge cases
- 잠긴 노트는 건너뛴다. 꺼진 노트(PR-001)는 퀀타이즈된다.
- 같은 음 두 노트가 같은 시작으로 모이더라도 합치거나 지우지 않는다(퀀타이즈는 노트 수를 바꾸지 않는다).
- Strength 0% 또는 모든 노트가 이미 격자 위면 편집 기록을 남기지 않는다.
- 셋잇단 격자의 결과 시작은 정수가 아니므로 `offsetSteps`에 소수가 남는다(정상).
- 스윙은 정수 step의 홀짝으로 적용되므로(`midi_export.dart` `onTick(step)` + offset), 1/32·셋잇단 결과 노트는 자신이 속한 정수 step의 스윙을 따른다. 이는 기존 재생 규칙 그대로이며 이 스펙에서 바꾸지 않는다.

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `enum QuantizeGrid`와 `quantizePitchNotes(notes, selected, {required double grid, required double strength, required bool ends, required int steps})`. 바뀌지 않는 노트는 객체 유지, 아무것도 안 바뀌면 원본을 `identical`로 반환.
  - `mobile/lib/looptap/widgets/surfaces/step_grid.dart`: 인스펙터에 `note-quantize` 버튼(현재 설정으로 즉시 적용)과 `note-quantize-settings`(Grid 칩 + Strength 슬라이더 + "끝도 맞추기" 스위치의 작은 시트/팝오버). `_commit(before, after)`로 기록.
  - `mobile/lib/looptap/screens/edit_screen.dart`: 기존 `onEdit` → `_gridEditNotes` → `_pushUndo()` 경로. 별도 수정 없음.
  - `mobile/lib/looptap/state/loop_prefs.dart`: 마지막 Grid/Strength/끝 맞추기 값을 앱 설정으로 저장.
- Model: 변경 없음.
- UI: 데스크톱 `Ctrl/Cmd+U` = 현재 설정으로 적용, `Ctrl/Cmd+Shift+U` = 설정 열기(`_key`의 `command` 분기에 추가, 현재 command 미처리 키는 ignored로 빠지므로 그 앞에 둔다). 모바일 = 인스펙터 버튼과 길게 누르면 설정.
- Drum notes: v1 제외. 2단계 후보로 `quantizeDrumNotes(notes, grid, strength)`(시작만, 드럼 트랙 전체)를 같은 파일에 둘 수 있으나 드럼 표면에 진입점이 정해진 뒤 별도 승인.

## Decisions (2026-10-22, owner approved)
- 단축키(M, K, H, Ctrl/Cmd+U/E/J/L)는 사양대로 확정.
- 드럼 레인은 v1 제외 (드럼 선택 UI가 생기는 2번 묶음에서 다룸).
- 퀀타이즈 결과 같은 음높이·같은 시작점 노트가 겹치면 **합치지 않고** 결과 안내에 겹침 개수를 경고로 표시한다.

## Acceptance tests
steps=32, 노트는 (start, end)로 표기.
- [x] 1/16, 100%, 끝 끔: (2.3, 3.3) → (2.0, 3.0). `step=2, offsetSteps=0, dur=1, soundingSteps=1.0`.
- [x] 정밀 필드 없는 노트 `step=3, dur=2`(3.0, 5.0), 1/8, 100% → S*=4 → (4.0, 6.0), `offsetSteps=0, durationSteps=null`.
- [x] 1/16, 50%, 끝 끔: (2.4, 3.4) → (2.2, 3.2). `step=2, offsetSteps≈0.2, durationSteps=1.0`.
- [x] 1/16, 100%, 끝 켬: (2.3, 4.6) → (2.0, 5.0).
- [x] 1/16, 100%, 끝 켬, 짧은 노트 (2.1, 2.3): E* = round(2.3)=2 ≤ S*=2 → E* = 3 → (2.0, 3.0).
- [x] 동률: 1/8, 100%: (1.0, 2.0) → (2.0, 3.0)(가운데는 늦은 쪽).
- [x] 1/16T(2/3), 100%: (0.8, 1.3) → (2/3, 7/6)(오차 1e-9 이내).
- [x] 경계: steps=32, 1/4, (31.0, 32.0) → S* = 32 ≥ steps → 28 → (28.0, 29.0).
- [x] 끝 넘침: steps=32, 1/16, 끝 켬 아님, (30.6, 32.0) → s'=31, e'=32.4 → 32로 잘림 → (31.0, 32.0).
- [x] 잠긴 노트 `identical`, midi/velocity/sourceMidi/confidence/assisted/muted 불변.
- [x] Strength 0 → 입력과 `identical`.

## Out of scope
- 녹음 중 자동 퀀타이즈(RC-11), 그루브 템플릿, 감도(Sensitivity) 옵션, 스윙 격자로의 퀀타이즈.
- 드럼 노트 퀀타이즈 UI.
