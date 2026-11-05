# Drum hit selection, velocity editing and batch-1 tools on drum lanes

- **ID:** drums-001
- **Status:** implemented (uncommitted)
- **Inspired by:** FL Studio — Channel rack step grid + Graph editor (Velocity); Ableton Live 12 — MIDI note selection / Velocity editor / Quantize / Humanize / Chance (카탈로그 ST-01, ST-02, PR-02, PR-06, PR-07, PR-12, PR-13)

## Sources
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm : 악기 줄의 칸을 눌러 켜고 끄며, 칸별 세기는 그래프 편집기에서 막대를 위아래로 끌어 바꾼다. 여러 칸을 함께 비율로 바꾸거나 두 값 사이를 이어 그을 수 있다.
- https://www.ableton.com/en/live-manual/12/editing-midi/ : 노트 선택(클릭, 추가 선택, 영역 선택) 후 세기 편집기에서 선택 노트의 세기를 함께 바꾼다. Quantize, Humanize, 노트별 확률(Chance)·세기 편차는 드럼 노트에도 똑같이 쓰인다.
- Hands-on observation 2026-10-21 (findings.json runtime_observations "Velocity 편집"): 선택 노트의 세기 핸들을 위로 끌어 34 → 83으로 바꿨고 음높이·시간은 유지됐다.
- 승인된 piano-roll 스펙 PR-001/003/006/007의 "드럼 레인은 2번 묶음에서 다룸" 결정을 이어받는다. 계산 규칙은 그 스펙들을 그대로 따른다.
- HumTrack 기존 동작(코드 읽음): `DrumGrid`는 칸 탭 = 켜기/끄기만 있고 선택이 없다. `DrumNote`는 `velocity`, `offsetSteps`, `durationSteps`를 저장하지만 편집 UI가 없다. `_openFillPadPicker`의 소리 바꾸기는 `DrumNote(kind, step)`을 새로 만들어 세기·미세 타이밍을 잃는다(P0 보존 위반).

## User-visible behavior
1. 드럼 Grid 화면 머리에 **"그리기 / 선택"** 전환이 생긴다. 그리기(기본) = 지금처럼 칸 탭으로 켜기/끄기.
2. 선택 모드: 히트를 탭 = 그 히트만 선택, Shift/Ctrl(Cmd)+탭 = 추가/제외, 빈 곳에서 끌기 = 사각형 영역 선택(여러 줄·여러 칸), 빈 칸 탭 = 선택 해제. 선택된 히트는 테두리로 표시된다.
3. 그리드 아래 **세기 레인**: 현재 초점 줄(줄 이름 탭으로 바꿈, 기본 = 첫 선택 히트의 줄 또는 맨 위 줄)의 히트마다 막대가 보인다. 막대를 끌면 그 히트의 세기가 바뀌고, 선택된 히트가 여럿이면 모두 같은 양만큼 바뀐다(상대 편집, 1–127 clamp). 드래그 1회 = Undo 1회. 세기 레인은 PR-007처럼 "강약 | 확률" 전환이 있다.
4. 선택한 히트(선택이 없으면 현재 트랙 전체)에 쓸 수 있는 도구: **삭제, 좌우 이동, Quantize, Humanize, Mute, Chance, Velocity variation, 세기 지정**. 동작은 피아노롤과 같은 이름·같은 단축키다.
5. 세기가 다른 히트는 칸 색 진하기로, 미세 타이밍이 있는 히트는 칸 안의 위치로, Chance < 100%는 흐리게 + %표시로, 꺼진 히트는 속이 빈 칸으로 그린다.

## 도구별 규칙 (드럼에 맞춘 차이만)
- **Quantize (PR-003):** 시작만 맞춘다(끝 옵션 없음). 같은 Grid·Strength·동률 규칙. 같은 줄·같은 위치로 모여도 합치지 않고 경고 개수만 안내(PR-003 결정과 같음).
- **Humanize (PR-006):** Timing + Velocity, 길이 없음. 정렬 키 = (startSteps, `kDrumNote[kind]`, 원래 인덱스). 노트마다 u₁, u₂ 두 번 뽑기 규칙 동일.
- **Chance / Velocity variation (PR-007):** 같은 필드·같은 판정. 판정 키의 `midi` 자리에 `kind`를 쓴다: `"$seed|$sectionId|$trackId|$kind|${(startSteps*1000).round()}|$pass"`.
- **Mute (PR-001):** 선택이 모두 꺼져 있으면 켜고, 아니면 끈다. 꺼진 히트는 재생·내보내기·파형에서 빠진다.
- **좌우 이동:** ←/→ = 격자 1칸, Shift+←/→ = 1/4칸(미세). 섹션 밖으로 나가는 이동은 그룹 전체가 경계에서 멈춤(`movePitchNotes`와 같은 규칙).
- **세기 키:** ↑/↓ = 선택 세기 +5/−5, Shift+↑/↓ = ±20(드럼에는 음높이 이동이 없으므로 ↑/↓를 세기에 씀). 줄(소리 종류) 바꾸기는 v1에 없음.
- 모든 도구는 바뀐 히트만 새 객체(`copyWith`)이고 나머지는 같은 객체, 바뀐 게 없으면 입력 `identical`(Undo 기록 없음).

## Edge cases
- 그리기 모드의 칸 탭은 지금처럼 "그 줄에서 정수 step == 칸인 히트"를 지운다. 미세 타이밍으로 옆 칸 경계를 넘은 히트는 원래 정수 step 칸에 속한다.
- Pads 모드(두 손 패드, Beat-Fill 런치패드)에는 선택 UI가 없다. 선택 모드는 Grid 모드에서만.
- Beat-Fill 패드 소리 바꾸기(`_openFillPadPicker`)는 `copyWith(kind: …)`로 바꿔 세기·미세 타이밍·Chance·muted를 보존한다(이 스펙에 포함되는 버그 수정).
- 곡 미리보기 중에는 편집 불가(기존 규칙). 녹음 중 탭 입력은 기존 경로 그대로.
- 겹친 히트(같은 줄, 같은 시작)는 둘 다 남고 영역 선택에 둘 다 잡힌다.

## HumTrack design
- Model (`models/loop_models.dart`): `DrumNote`에 `final bool muted`(기본 false), `final double chance`(기본 1.0, 0–1 clamp), `final int velocityDeviation`(기본 0, −127…127 clamp). JSON은 기본값이 아닐 때만 쓴다. `copyWith`에 `kind`, `muted`, `chance`, `velocityDeviation` 추가. 옛 곡은 그대로 열린다. PR-007의 스키마 v3에 함께 포함(구버전이 다시 저장하면 이 필드만 사라짐).
- Code:
  - `music/drum_note_edit.dart`(신규, `pitch_note_edit.dart`와 같은 형태의 순수 함수): `moveDrumNotes`, `deleteDrumNotes`, `setDrumVelocity`, `shiftDrumVelocities`, `quantizeDrumNotes(notes, selected, {grid, strength, steps})`, `humanizeDrumNotes(..., {timingSteps, velocityRange, seed, steps})`, `setDrumNotesMuted`, `setDrumChance`, `setDrumVelocityDeviation`.
  - `music/note_random.dart`: `realizeDrumNote(note, {seed, sectionId, trackId, pass})`.
  - `widgets/surfaces/drum_surface.dart`: `DrumGrid`에 `onEdit(before, after)`, `selectMode`, 선택 상태, 정밀 위치·세기·Chance·muted 그리기, 영역 선택. `widgets/surfaces/drum_velocity_lane.dart`(신규, `VelocityLane`과 같은 제스처 모델).
  - 인스펙터: StepGrid의 버튼 묶음(`note-quantize`, `note-humanize`, `note-mute`, `note-chance`, `note-velocity-deviation`, `note-velocity`, 삭제)을 드럼용으로 같은 키 이름 + `drum-` 접두사로(`drum-quantize` …). 설정 시트와 `loop_prefs.dart` 저장값은 피아노롤과 공유.
  - `screens/edit_screen.dart`: `_drumEditNotes(before, after)` → `_pushUndo()`(`_gridEditNotes`와 같은 검사). `_trigger` 드럼 분기에서 `muted` 건너뛰기, `realizeDrumNote`로 울림/세기 판정 후 `velocity:` 전달. `_toggleDrumCell`은 그리기 모드 전용으로 유지.
  - `music/song_util.dart` `flattenSong`의 `perc()`: muted 제외, `variationSeed`가 있으면 판정·세기 반영(PR-007 Export rule과 동일). WAV/stem/MIDI가 같은 FlatSong을 쓴다.
- UI: 데스크톱(드럼 그리드에 포커스, 선택 모드): `Ctrl/Cmd+A` 전체, `Delete/Backspace`, ←/→(Shift 미세), ↑/↓ 세기(Shift ±20), `Ctrl/Cmd+U`/`Ctrl/Cmd+Shift+U` Quantize, `H`/`Shift+H` Humanize, `M` Mute, 세기 레인 확률 모드에서 `Ctrl/Cmd+↑/↓` Chance ±10%, `Esc` 선택 해제, `D`(수정키 없음) 그리기/선택 전환(`Tab`은 포커스 이동이라 쓰지 않음). 모바일: 그리드 머리의 전환 버튼(`drum-select-mode`)과 그리드 아래 인스펙터 줄.
- Export: 꺼진 히트 제외, Chance/편차는 PR-007 규칙으로 한 변주를 굽는다. 그 외 변화 없음.

## Decisions (2026-10-22, owner approved)
- **단축키 규칙:** 데스크톱 QWERTY 피아노·드럼 키(A S D F G H J K L ; ' \ 등)는 노트 편집기 위에서도 전역으로 잡히고, 노트 편집기는 Alt 조합을 받지 않는다. 그래서 단일 문자 단축키는 그 줄 밖의 키만 쓰고, 나머지는 Ctrl/Cmd 조합을 쓴다.
- 드럼 선택 모드에서 ↑/↓는 세기 ±5(Shift는 ±20)로 쓰고, 줄(소리 종류) 이동은 없앤다.
- 드럼에도 Mute(`muted`)를 포함한다.
- Fill 패드 소리 바꾸기의 보존 버그 수정(`DrumNote.copyWith(kind:)`)을 이 스펙에 묶는다.
- 그리기/선택 전환은 **`Ctrl/Cmd+B`**(`D`는 드럼 키라 쓰지 않음).

## Acceptance tests
- [x] `DrumNote` JSON: 기본값이면 새 키 없음, `{muted:true, chance:0.25, velocityDeviation:-10}` 왕복 보존. `copyWith(kind: 'clap')`이 velocity·offsetSteps·chance 유지.
- [x] Fill 패드 소리 바꾸기: (shaker, step 3, velocity 50, offsetSteps 0.2) → (clap, 3, 50, 0.2).
- [x] `quantizeDrumNotes` 1/16 100%: start 2.3 → 2.0(`step 2, offsetSteps 0`); 50%: 2.4 → 2.2. 바뀐 게 없으면 `identical`.
- [x] `humanizeDrumNotes` 같은 seed → 같은 결과, timing 0·velocity 0 → `identical`. velocity null 히트에 dv ≠ 0 → 명시 세기.
- [x] `shiftDrumVelocities` +30(피아노롤 `shiftPitchVelocities`와 같은 규칙, 각각 clamp): [40, 60] → [70, 90]; [100, 120] → [127, 127]; velocity null → 100 기준으로 130 → 127.
- [x] `setDrumNotesMuted`: [muted, active] 선택 → 둘 다 muted. 둘 다 muted → 둘 다 active.
- [x] `realizeDrumNote`: chance 0 → 항상 null, chance 1·deviation 0 → velocity 그대로, 같은 키 → 같은 결과, kind만 다르면 결과 독립.
- [x] `flattenSong`: muted 드럼 제외, `variationSeed` 고정 시 두 번 실행 결과 동일, `buildMidi` 바이트 동일.
- [x] 위젯: 선택 모드에서 히트 탭 → 선택 1개, 빈 곳 끌기 → 영역 내 히트 전부 선택, `Delete` → `onEdit` 1회로 삭제. 그리기 모드 탭은 기존 `onToggle` 호출.
- [x] 세기 레인 드래그 1회 → `onEdit` 1회, Undo 1회로 복원.
- [x] 재생: muted 히트와 chance 0 히트는 `playDrum`이 호출되지 않는다(가짜 오디오로 기록).

## Out of scope
- 드럼 노트 Split/Glue/Legato/Scale snap/Chord/Arpeggiate(의미 없음), 줄(소리 종류) 간 이동.
- Pads 모드에서의 선택, 드럼 세기를 패드 누르는 세기로 녹음(압력 감지).
- 스텝별 Pan/Pitch/Repeat 그래프(ST-02의 나머지 항목), 줄별 반복 길이(ST-06).
