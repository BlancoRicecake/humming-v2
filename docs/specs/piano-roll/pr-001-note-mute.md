# Note mute (deactivate notes)

- **ID:** piano-roll-001
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Deactivate Note(s); FL Studio — Piano roll mute/unmute (카탈로그 PR-08)

## Sources
- https://www.ableton.com/en/live-manual/12/editing-midi/ (Deactivating notes 절): 선택 노트를 끄면 회색으로 남고 소리가 나지 않으며, 같은 명령을 다시 쓰면 켜진다.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll_menu.htm : 선택 노트를 mute/unmute하는 메뉴 명령과 "muted 노트만 선택" 명령이 있다.
- Hands-on observation 2026-10-21 (`artifacts/ableton-analysis-20261021/findings.json`, file_structure_findings): 데모 세트의 저장된 노트 192개 중 40개가 꺼진 상태로 저장되어 있었다. 즉 "꺼짐"은 삭제가 아니라 노트에 붙은 저장 속성이다.

## User-visible behavior
1. 사용자가 노트를 하나 이상 선택하고 Mute 명령을 실행하면, 선택된 노트가 화면에 그대로 남되 흐리게(속이 빈 모양) 그려지고 재생 시 소리가 나지 않는다.
2. 선택 노트가 **모두** 꺼져 있으면 같은 명령이 "Unmute"가 되어 모두 다시 켠다. 하나라도 켜진 노트가 섞여 있으면 명령은 "Mute"이며 선택 전체를 끈다(토글 기준은 "전부 꺼짐인가").
3. 꺼진 노트도 선택·이동·길이 조절·복사·복제·삭제가 된다. 복사/복제된 노트는 꺼짐 상태를 그대로 가진다.
4. 꺼진 노트는 WAV/stem/MIDI 내보내기, 곡 미리보기 파형, 반주 생성 입력에 포함되지 않는다.
5. Undo 한 번이 Mute/Unmute 한 번을 되돌린다.

## Edge cases
- 잠긴(`locked`) 노트는 Mute 대상에서 빠진다(일반 편집이 잠긴 노트를 건너뛰는 HumTrack 규칙과 같음). 선택이 전부 잠긴 노트면 명령은 비활성.
- 꺼진 노트 위에 같은 음을 그리면(`paintPitchSpan`) 꺼진 노트와 합쳐지지 않는다. 꺼진 노트는 "막는 노트"로도 치지 않아, 새로 그린 소리 나는 노트가 꺼진 노트와 시간상 겹쳐 존재할 수 있다.
- 지우개(`erasePitchCell`)는 꺼진 노트도 지운다(지우기는 삭제이므로).
- 재생 중 Mute하면 이미 예약된 다음 박의 소리도 나지 않아야 한다(예약 콜백이 실행 직전에 상태를 다시 확인).
- 길게 울리는 노트를 재생 중 Mute하면, 다음 루프부터 확실히 조용해야 하고 이미 울리는 소리는 남은 게이트까지 울려도 된다.

## HumTrack design
- Code:
  - `mobile/lib/looptap/models/loop_models.dart`: `PitchNote`에 `final bool muted` (기본 `false`) 추가. `copyWith`, `toJson`(`if (muted) 'muted': true`), `fromJson`(`?? false`) 반영. `deepCopy`는 `copyWith()`를 쓰므로 자동 보존.
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `setPitchNotesMuted(notes, selected, bool muted)` 추가. `setPitchNotesLocked`와 같은 형태로, 바뀌는 노트가 없으면 원본 리스트를 그대로(identical) 반환, 바뀌지 않은 노트는 같은 객체 유지, 잠긴 노트는 건너뜀. `_plainNote`는 `muted == true`면 false. `paintPitchSpan`의 겹침 탐색에서 `muted` 노트는 무시.
  - `mobile/lib/looptap/screens/edit_screen.dart`: 박 예약 루프(`due` 계산)와 `_playAfter` 콜백, `_chasePitched`에서 `n.muted` 노트를 건너뜀. 기록은 기존 `_gridEditNotes` → `_pushUndo()` 경로(1회 편집 = 1 undo).
  - `mobile/lib/looptap/music/song_util.dart`: `flattenSong`의 `pitched()`에서 `muted` 노트를 건너뜀. 이 한 곳으로 `midi_export.dart`, `wav_export.dart`(믹스·stem), `buildWave`가 모두 꺼진 노트를 제외하게 된다.
  - `mobile/lib/looptap/music/song_spec.dart`, `beginner_backing.dart`: 생성 입력에서 꺼진 노트 제외.
  - `mobile/lib/looptap/widgets/surfaces/pitch_grid_surface.dart`: 꺼진 노트는 glow 없이 테두리만(stroke) + 낮은 alpha로 그림. 선택 표시·잠금 점은 그대로.
  - `mobile/lib/looptap/widgets/surfaces/velocity_lane.dart`, `widgets/arrangement.dart`: 꺼진 노트 막대/미리보기를 흐리게.
- Model: 필드 1개 추가, 기본값일 때 JSON에 쓰지 않으므로 옛 곡은 그대로 열린다(전부 `muted=false`). 주의: 이 필드를 모르는 **구버전 앱**이 새 곡을 다시 저장하면 꺼짐 정보가 사라져 노트가 다시 소리 난다. 스키마 버전(`Song.kSchemaVersion`)은 올리지 않는다(필드 추가만).
- UI:
  - 데스크톱: `step_grid.dart` `_key`에 `M` 키(수정키 없음, 선택 편집 모드) = Mute/Unmute 토글.
  - 모바일·데스크톱 공통: `_inspectorItems()`에 `note-mute` 버튼(라벨 "소리 끄기"/"소리 켜기"), 잠금 버튼 옆.
- Drum notes: v1에서는 제외. `DrumSurface`에 노트 선택 UI가 없어 진입점이 없다. `DrumNote` 모델은 바꾸지 않는다.

## Decisions (2026-10-22, owner approved)
- 단축키(M, K, H, Ctrl/Cmd+U/E/J/L)는 사양대로 확정.
- 드럼 레인은 v1 제외 (드럼 선택 UI가 생기는 2번 묶음에서 다룸).
- 잠긴(locked) 노트는 음소거 대상에서 제외 (다른 편집과 동일).
- **스키마 v3:** 새 필드(`muted`, `chance`, `velocityDeviation`, `Song.variationSeed`)를 추가하면서 `kSchemaVersion`을 3으로 올린다. 저장 시 디스크의 `songs.json` 스키마가 앱이 아는 버전보다 높으면 덮어쓰지 않고 저장 실패로 처리한다(이후 버전 다운그레이드 데이터 손실 방지). v2 파일은 그대로 읽힌다.
- 본문 Model 절의 '스키마 버전을 올리지 않는다'는 위 v3 결정으로 대체된다.

## Acceptance tests
- [x] `setPitchNotesMuted([A(60,step0), B(62,step4)], {A}, true)` → A'는 `muted=true`, 나머지 필드(midi, step, dur, velocity, offsetSteps, durationSteps, sourceMidi, confidence, assisted) 동일. B는 `identical(B)`.
- [x] 이미 모두 `muted=true`인 선택에 `true`를 다시 주면 반환값이 입력 리스트와 `identical`.
- [x] 잠긴 노트 L(`locked=true`)을 선택에 포함해 mute → L은 그대로(`identical`), `muted=false`.
- [x] `PitchNote(midi:60,..., muted:true).toJson()`에 `'muted': true`가 있고, `muted:false`일 때는 키가 없다. `fromJson`에 키가 없으면 `muted=false`.
- [x] `flattenSong`: 한 섹션 melody에 [소리 나는 C, 꺼진 D] → 결과 melody에 C만 있다. `buildMidi` 결과에 D(62)의 note-on이 없다.
- [x] `paintPitchSpan([M(60, step0..4, muted)], incoming 60 step2..3)` → M은 그대로, incoming이 별도 노트로 추가된다(합쳐지지 않음).
- [x] `erasePitchCell([M(60, step0..4, muted)], 60, 1)` → [0,1), [2,4) 두 조각, 둘 다 `muted=true`.
- [x] 위젯 테스트: 선택 편집 모드에서 노트 선택 후 `M` 키 → `onEdit`가 1회 호출되고 after의 해당 노트가 `muted=true`.

## Out of scope
- 드럼 노트 mute, "꺼진 노트만 선택" 명령.
- 클립/섹션 단위 비활성화(카탈로그 AR-13).
- 꺼진 노트를 포함해 MIDI로 내보내는 옵션.
