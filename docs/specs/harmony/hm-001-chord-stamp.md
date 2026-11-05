# Chord stamp (선택 노트 아래 / 클릭 위치에 코드 깔기)

- **ID:** harmony-001
- **Status:** implemented (uncommitted)
- **Inspired by:** FL Studio — Chord Stamp; Ableton Live 12 — Stacks (chord generator), Chord MIDI effect (카탈로그 PR-24, PR-26, DV-04)

## Sources
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/pianoroll.htm (Stamp 절): 코드 종류를 메뉴에서 고른 뒤 피아노롤을 클릭하면 그 음높이·시간에 코드 구성음이 한꺼번에 놓인다. 스냅과 스케일 설정을 따른다. 자동 모드에는 클릭한 음을 **맨 위 음**으로 두고 아래로 코드를 쌓는 방식(멜로디가 이끔)과, 클릭한 음 근처에서 스케일에 맞는 코드를 고르는 방식이 있다. "한 번만" 옵션을 끄면 여러 번 연속으로 찍을 수 있다.
- https://www.ableton.com/en/live-manual/12/midi-tools/ (Stacks): 클립 스케일이 있으면 코드 근음이 스케일 음으로만 맞춰지고, 전위(inversion) 값을 올리면 전위가 차례로 바뀐다(음수는 한 옥타브 아래).
- https://www.ableton.com/en/live-manual/12/live-midi-effect-reference/ (Chord): 한 음에 정해 둔 음정(반음)들을 더해 화음을 만든다(예: +4, +7 = 장3화음).
- HumTrack 기존 동작(코드 읽음): `theory.dart`의 `diatonicTriad`/`guitarVoicing`/`powerChord`/`guitarPowerVoicing`과 `edit_screen.dart`의 `_chordMidis`가 **패드 연주**에서만 코드를 만든다. 격자(StepGrid)에 그리는 노트(`_gridPlace`)는 코드 토글과 무관하게 한 음만 놓는다.

## User-visible behavior
1. **코드 깔기 (선택 아래, top-down).** 노트를 선택하고 "코드 깔기"를 실행하면 선택한 각 멜로디 노트를 맨 위 음으로 두고, 그 아래 한 옥타브 안에 코드 구성음이 같은 시작·길이로 추가된다. 같은 시작(±1e-6 step)에 선택 노트가 여러 개면 그 묶음의 **가장 높은 음** 하나만 기준으로 쓴다.
2. **코드 찍기 모드 (클릭 위치, bottom-up).** 격자 툴바의 "코드 찍기"를 켜면 빈 칸을 누르거나 끌어 그릴 때 한 음 대신 그 음을 근음으로 한 코드가 놓인다. 끌어 그린 길이가 코드 길이다. 모드는 끄기 전까지 유지된다(연속 찍기). 노트 위를 누르면 기존처럼 선택/지우기 동작.
3. **코드 종류 목록.** 기본값 = **Diatonic (곡 키)**. 목록: Diatonic 3화음, Diatonic 7화음, Power(5th), Major, Minor, Dim, Aug, Sus2, Sus4, Maj7, m7, 7, add9. Diatonic 계열만 곡의 `key/scale`을 따르고, 나머지는 고정 음정(반음)이다. 전위 0/1/2(bottom-up에만 적용).
4. 결과 노트는 선택된 상태가 된다(top-down이면 새로 추가된 음만). 명령 1회 = Undo 1회. 찍는 순간 코드를 미리 듣기로 한 번 들려준다(기존 `_previewGridNote`와 같은 경로).

## 코드 계산 규칙
- **Diatonic 3화음 / 7화음 (bottom-up):** 근음 r에서 `diatonicTriad(r, key, scale)` 규칙(스케일 사다리에서 i, i+2, i+4, 7화음은 +i+6). r이 스케일 밖이면 사다리 규칙대로 **바로 위 스케일 음**이 근음이 된다(기존 함수 동작 그대로). `pentatonic`은 화음 계산에서 같은 근음의 natural minor로, `chromatic`은 Diatonic을 비활성화하고 기본값을 Major로 바꾼다.
- **Diatonic (top-down):** 멜로디 음 m의 음이름(pitch class)을 포함하는 스케일 3화음(또는 7화음) 중 우선순위 I, IV, V, vi, ii, iii, vii 순으로 첫 번째를 고른다(마이너 계열은 i, iv, v, VI, III, VII, ii). 고른 코드의 나머지 구성음을 각각 "m보다 낮은 가장 가까운 같은 음이름"에 놓는다(밀집 배치). m은 새로 만들지 않는다.
- **고정 음정 (top-down):** m을 근음이 아니라 맨 위 음으로 두고, 근음 = m과 같은 음이름 기준 코드의 구성음을 m 아래로 밀집 배치한다(Major top-down = m 아래에 5음·3음).
- **Guitar:** 활성 트랙 악기가 기타이고 종류가 Diatonic 3화음/Power이면 bottom-up에서 패드와 같은 `guitarVoicing`/`guitarPowerVoicing` 음을 쓴다(패드로 친 코드와 격자로 찍은 코드가 같은 소리).
- **전위:** 1이면 가장 낮은 음을 +12, 2면 두 번 반복. 127을 넘는 음은 버린다.
- 0 미만·127 초과 음, 이미 같은 음높이·같은 시작에 있는(겹치는) 노트와 중복되는 음은 추가하지 않는다.

## 속성 상속 (P0 보존)
- 새 구성음 = 기준 노트의 `copyWith`로 만들고 `midi`, `freq`만 바꾼다. `step, offsetSteps, dur, durationSteps, velocity, muted, chance, velocityDeviation`은 상속, `sourceMidi=null, confidence=1.0, assisted=false, locked=false`로 초기화(분석 산출물이 아니므로).
- bottom-up은 기존 `paintPitchSpan`으로 음마다 그린다(겹침 규칙 동일). 기준 노트(top-down의 멜로디)는 바뀌지 않으므로 잠긴 노트도 기준이 될 수 있다.

## Edge cases
- 선택이 비었으면 명령 비활성. 꺼진(muted) 노트를 기준으로 하면 구성음도 꺼진 채 생긴다(같은 묶음으로 보이도록).
- top-down 결과가 모두 중복이라 추가할 음이 없으면 기록하지 않고 "추가할 음 없음" 안내.
- 드럼 트랙에서는 명령과 모드가 보이지 않는다.
- 곡 미리보기(Play Song) 중에는 편집 불가(기존 `_songSection != null` 규칙).

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/theory.dart`: `enum ChordType`와 `List<int> chordMidis(ChordType t, int root, {required String key, required String scale, int inversion = 0, bool guitar = false})`(bottom-up), `List<int> chordBelow(ChordType t, int top, {key, scale})`(top-down, m 제외 구성음). 기존 `diatonicTriad` 등은 그대로 두고 이 함수가 호출한다.
  - `edit_screen.dart` `_chordMidis`: 내부를 `chordMidis(_chordOn ? diatonic3 : power, ...)` 호출로 바꾸되 **동작은 바이트 단위로 동일**(회귀 테스트로 고정).
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `stampChordsBelow(notes, selected, ChordType, {key, scale})` → `({List<PitchNote> notes, Set<PitchNote> selection})`, `stampChordAt(notes, PitchNote seed, List<int> midis)`. 바뀐 게 없으면 입력 `identical`.
  - `widgets/surfaces/step_grid.dart`: 인스펙터 `note-chord-stamp`("코드 깔기", 길게 누르기 = 종류 선택), 툴바 토글 `grid-chord-stamp`("코드 찍기"). 찍기는 `onPlace`가 아니라 `_commit(before, after, selection:)`로 보내 코드 1개 = Undo 1회(현재 `_gridPlace`의 coalesce 경로를 쓰지 않음).
  - `widgets/sheets/chord_type_sheet.dart`(신규): 종류 칩 + 전위 세그먼트. 마지막 값은 `state/loop_prefs.dart`에 저장.
  - `edit_screen.dart`: 기존 `_gridEditNotes` → `_pushUndo()`.
- Model: 변경 없음(결과는 일반 노트).
- UI: 데스크톱 `C`(수정키 없음, 선택 편집 모드) = 현재 종류로 코드 깔기, `Shift+C` = 종류 선택 시트, `Alt+C` = 코드 찍기 모드 토글. 모바일 = 인스펙터 버튼 + 격자 툴바 토글.
- Export: 영향 없음(일반 노트로 저장되어 WAV/stem/MIDI에 그대로 나감).

## Decisions (2026-10-22, owner approved)
- **단축키 규칙:** 데스크톱 QWERTY 피아노·드럼 키(A S D F G H J K L ; ' \ 등)는 노트 편집기 위에서도 전역으로 잡히고, 노트 편집기는 Alt 조합을 받지 않는다. 그래서 단일 문자 단축키는 그 줄 밖의 키만 쓰고, 나머지는 Ctrl/Cmd 조합을 쓴다.
- 코드 음은 **같은 트랙**에 넣는다(melodyDec 옵션은 다음 버전).
- 단축키: `C` 깔기, `Shift+C` 종류 선택, **찍기 모드는 `Ctrl/Cmd+Shift+C`**(Alt+C 대신).
- pentatonic은 같은 근음의 natural minor 화음으로 계산하고, chromatic이면 Diatonic을 끄고 Major를 기본값으로 한다.

## Acceptance tests
키 C major 기준, 노트 = (midi, start, end).
- [x] `chordMidis(diatonic3, 60, key C, major)` == [60, 64, 67]; 근음 62 → [62, 65, 69](ii); 근음 61(스케일 밖) → [62, 65, 69].
- [x] A minor, `chordMidis(diatonic3, 57)` == [57, 60, 64]; 전위 1 → [60, 64, 69]; 전위 2 → [64, 69, 72].
- [x] `chordMidis(major, 60, key C, scale minor)` == [60, 64, 67](고정 음정은 스케일 무시).
- [x] `_chordMidis` 회귀: chord 토글/power 토글/기타 조합 12가지에서 리팩터 전후 결과 동일.
- [x] top-down C major: 멜로디 (67 G4, 0–4) → I 코드 선택 → 추가 (64, 0–4), (60, 0–4). 멜로디 (65 F4) → IV → (60), (57).
- [x] top-down 상속: 기준 노트 velocity 90, offsetSteps 0.25, durationSteps 3.5, chance 0.5 → 구성음 모두 같은 값, `sourceMidi == null`, `assisted == false`.
- [x] 같은 시작 묶음 [(60,0–2),(67,0–2)] 둘 다 선택 → 67 기준 하나만 계산, 60은 이미 있으므로 64만 추가.
- [x] 결과가 모두 중복이면 반환 리스트가 입력과 `identical`.
- [x] `stampChordAt` 1회 → `onEdit` 호출 1회(Undo 1개), 결과 선택 집합 == 새 코드 음들.
- [x] chromatic 스케일에서 Diatonic 종류는 비활성, 기본 Major.

## Out of scope
- 코드 진행 생성/추천(PR-25), 곡 전체 코드 트랙(AR-17), 멜로디 전체 자동 화성 분석.
- 앞뒤 코드 사이의 성부 진행(voice leading) 최적화, Strum(PR-28), 실시간 Chord 장치(DV-04).
- 타악 스탬프, 사용자 정의 코드 종류 저장.
