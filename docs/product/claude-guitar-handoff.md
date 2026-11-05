# Claude → Codex 인계: 기타 G0~G2

2026-10-22 · 구현: Claude · 리뷰·실행 검증: Codex · **커밋하지 않음**

이번 단계의 범위는 G0~G2와 데모·빌드·인계까지다. G3(팜뮤트·하모닉스 등 아티큘레이션), 효과, 자동 프로듀싱은 다음 단계로 남긴다.

## 1. 단계별 결과

| 단계 | 사양 | 상태 | 핵심 |
|---|---|---|---|
| G0+G1 스트로크 변환 | [gt-001](../specs/guitar/gt-001-stroke-conversion.md) | 구현, 독립 확인 통과 | 명시적으로 적용하면 노트 데이터(offset·velocity·durationSteps)를 다시 쓰는 opt-in 방식. 기존 자동 스트럼은 골든 8종으로 바이트 동일 |
| G1 후속 태그 규칙 | gt-001 "Decision after implementation" | 구현 | 음높이만 바꾸는 편집은 태그를 유지하고, 시간·길이·벨로시티 편집은 태그를 버린다. 노트 값은 구체값으로 남는다 |
| P1 이전 칸 저장 줄 | gt-001 "P1 fix" | 구현, 독립 확인 통과 | `offsetSteps ≥ 1`인 줄은 실제 타현 시점 기준으로 패스당 정확히 1회 울린다 |
| G2 줄 배정·울림·같은 줄 끊기 | [gt-002](../specs/guitar/gt-002-string-assignment-ring.md) | 구현, 독립 확인 통과 | 표준 튜닝 실제 배정 또는 배정 불가 표시. 옥타브 이동·삭제는 하지 않는다. 울림·끊기는 노트 길이에 기록하고 정확히 원복된다 |
| 리뷰 반영 | [체크리스트](guitar-review-checklist.md) | 반영 | 묶음 오차 0.05 step, 실제 onset 정렬, 울림 상한, 줄 순서 스트로크, 문서 정합성 |
| 오프라인 나일론 | Codex 준비 + Claude 인수 | 반영 | 슬롯 1001, 8개 오프라인 테스트, 재현 도구 병합 수정, CREDITS 갱신 |

## 2. 새 기능까지 가는 클릭 경로 (Windows 데스크톱)

1. 곡 목록 화면 상단의 **`MIDI +`** → 데모 MIDI 선택(§4). 또는 새 곡을 만들어 화음을 직접 입력한다.
2. 편집 화면에서 기타로 쓸 트랙(예: Melody)을 선택한다 → 악기 버튼 → **Guitar** 분류 → **Nylon Acoustic Guitar (FreePats)** (오프라인 슬롯 1001).
3. 입력 방식을 **`그리드`**로 바꾼다(`패드 / 그리드` 토글). 기타 트랙이면 그리드 도구줄 맨 앞에 **"기타 연주"** 버튼이 입력·선택 편집 모드 모두에서 보인다 → 상세 패널을 바로 연다(패널 상단에 "선택 없음 = 트랙 전체에 적용" / "선택한 노트 N개에 적용" 안내).
4. 노트를 선택하거나, 아무것도 선택하지 않으면 트랙 전체가 대상이다. 인스펙터의 **"기타 스트로크"** 줄에서 `↓` / `↑` / 패턴 칩(`↓↑`, `↓ ↓↑ ↑↓↑`)을 누른다.
   - 단축키: `Ctrl/Cmd+Shift+↓` / `Ctrl/Cmd+Shift+↑`
5. **`▸`**로 상세 패널을 연다. 다음 항목이 있다:
   - 간격(ms), 감쇠, 강세
   - 일반으로 되돌리기
   - **줄 배정** (`Ctrl/Cmd+Shift+G`)
   - **울림 아르페지오** (`Ctrl/Cmd+Shift+I`)
   - **울림 되돌리기**
   - **줄 번호 보기/숨기기**
   - 개별 노트의 줄 지정(1–6 / 자동)
6. 줄 번호 보기를 켜면 배정되지 않은 노트에 주황 테두리가 생기고, 인스펙터에 **"줄 없음 N"** 칩이 나타난다. 칩을 누르면 해당 노트가 선택된다.
7. 기타 컨트롤은 기타 트랙(GM 24–31, 카탈로그 Guitar)에서만 보인다. 데스크톱 QWERTY 피아노 키와 충돌하지 않는다(위젯 테스트로 확인).

## 3. 파일

**새 파일 (`mobile/lib/looptap/…`)**
- `music/guitar_stroke.dart`: 스트로크 변환·패턴·되돌리기, 묶음 규칙, legacy 짝짓기(`strumPairs`), P1 `laterCellOnsets`
- `music/guitar_tuning.dart`, `music/guitar_strings.dart`: 표준 튜닝, 줄 배정, 울림, 끊기, 되돌리기
- `widgets/sheets/guitar_stroke_panel.dart`: 상세 패널

**수정한 파일**
- `models/loop_models.dart`: `StrokeTag`, `PitchNote.stroke`, `guitarString`, `stringLocked`, `ringBaseDur`, `ringBaseDurationSteps`
- `music/pitch_note_edit.dart`: 태그 상속·삭제 규칙
- `music/midi_export.dart`: legacy 인덱스 안정화, 같은 tick에서 note-off를 note-on보다 먼저
- `music/song_util.dart`: 섹션 끝 처리
- `screens/edit_screen.dart`: legacy 스트럼 함수화, P1 예약, `bpm`·`grooved` 전달
- `widgets/surfaces/step_grid.dart`: 인스펙터, 단축키
- `widgets/surfaces/pitch_grid_surface.dart`: ↓/↑ 표시, 줄 번호, 주황 테두리
- `state/loop_prefs.dart`
- `audio/loop_audio.dart`: 테스트 훅만

**테스트 (`mobile/test/looptap/`)**
- `guitar_stroke_golden_test.dart`, `guitar_stroke_test.dart`, `guitar_stroke_ui_test.dart`, `guitar_stroke_edit_test.dart`, `guitar_stroke_p1_test.dart`
- `guitar_strings_test.dart`, `guitar_strings_ui_test.dart`
- `reference_soundfonts_test.dart`(8개)
- 지원 파일: `test/support/midi_events.dart`, `step_grid_harness.dart`

**사운드폰트·도구**
- `mobile/assets/sounds/reference/freepats_nylon.*`, `catalog.json`
- `tools/prepare_guitar_soundfont.py`
- `tools/prepare_reference_soundfonts.py`: 병합하도록 수정
- `CREDITS-soundfonts.md`

## 4. 데모 · 빌드 · 로그

(데모·빌드 결과는 아래 §6에 기록)

| 항목 | 경로 |
|---|---|
| 비교 데모 | `artifacts/guitar-demo-20261022/` (README.md 참조) |
| 새 Windows 릴리스 | `C:/src/humming-v2/artifacts/releases/current/HumTrack.exe` (= `mobile/build/windows/x64/runner/Release`, 17:14 빌드, 86개 파일 해시 동일) |
| 검증 로그 | `artifacts/guitar-review-20261022/` |

로그 파일:
- `reference-soundfonts-test.log`, `reference-sf2-sha256.txt`
- `g2-analyze.log`, `g2-guitar-tests.log`, `g2-full-tests.log`
- `build-release.log`

Codex 독립 로그: `offline-guitar-test.log`, `legacy-before.log`, `strings-independent.log`, `strings-ui-independent.log`

## 5. 알려진 한계 (과장하지 않음)

- **음원:**
  - FreePats nylon은 SF2 프리셋 하나다. 줄별 샘플·다운/업 스트로크 샘플·팜뮤트·하모닉스·릴리스 노이즈는 없다.
  - 이번 개선은 연주 스케줄링(타이밍·세기·울림 길이)에 대한 것이고, 음원 품질 개선이 아니다.
- **같은 음 두 줄:** 한 MIDI 채널에서는 겹친 같은 음이 독립적으로 울리지 않는다. 데이터는 보존하고, 출력에서는 앞 음을 뒤 음 시작에서 끊는다(되돌리기 가능).
- **그루브 트랙:** 울림·끊기는 노트 데이터 기준이라, 그루브가 onset을 옮기면 끊기 경계가 그루브 이동량만큼 어긋날 수 있다. UI에 안내가 있다.
- **재생 시작 위치:** 1 step 미만 offset 노트에서, 칸은 탐색 위치 이전이고 실제 onset은 이후인 경우 재생되지 않는다. 기존 동작이며 legacy 보존을 위해 그대로 두었다. 스트로크 줄(`offset ≥ 1`)은 P1로 해결했다.
- **BPM 변경:** 변환 후 BPM을 바꾸면 스트로크 간격이 템포에 비례해 변한다. 다시 적용하면 원래 ms로 재계산된다.
- **잠긴 노트:** 줄 배정 시 바뀌지 않는다. 줄이 없으면 "배정 불가(잠김)"로 표시된다.
- **청취 미검증:** 귀로 듣는 확인은 하지 않았다. 동일 음량 비교와 실제 울림은 사용자 청취가 필요하며, 도구만으로 통과 처리하지 않는다.

## 6. 데모·빌드 결과

### Windows 릴리스 빌드 (2026-10-22 17:07)
- 명령: `cd C:/src/humming-v2/mobile && flutter build windows --release --no-pub --target lib/main.dart` (TMP/TEMP = `C:/src/humming-v2/artifacts/guitar-review-20261022/temp`), 기존 `mobile/build` 재사용, 46.7초, exit 0. 로그: `artifacts/guitar-review-20261022/build-release.log`
- 실행 파일: `C:/src/humming-v2/mobile/build/windows/x64/runner/Release/HumTrack.exe` (Release 폴더 전체를 유지한 채 실행)
- `data/app.so` sha256 `33b8d4c0bf897f12083b397cfb300ee86338632331fd5db0ab346f9b00efa0a5` (17:07 생성). `HumTrack.exe`는 네이티브 변경이 없어 이전과 동일(sha256 `62935987…6c91`).
- 바이너리에 새 UI 문자열(Guitar stroke / Assign strings / Ringing arpeggio / Undo ringing) 포함 확인.
- 빌드 후 관련 검사: `flutter analyze` 문제 없음, 기타 UI 테스트 16개 통과(`label-rename-tests.log`, "울림 되돌리기" 문구 변경 반영).
- `artifacts/releases/current`는 교체하지 않음. 기동 확인은 Codex 화면 리뷰에서 진행.

### UI 보완 재빌드 (2026-10-22 17:14) → current 교체
- 변경: 기타 트랙의 그리드 도구줄 맨 앞 **"기타 연주"** 버튼(입력/선택 편집 모두, 기존 패널 재사용), 패널 상단 적용 범위 안내. 파일: `step_grid.dart`, `guitar_stroke_panel.dart`. 테스트: `guitar_stroke_ui_test.dart` "the 기타 연주 toolbar button…"(입력 모드 노출·전체 트랙 적용·선택 수 안내) — 기타 UI 테스트 17개 통과, analyze 문제 없음.
- 빌드: 같은 명령, exit 0, 로그 `artifacts/guitar-review-20261022/build-release-2.log`. `data/app.so` sha256 `4200e09e5a6ca168688abb530f76208b47d04517df4e4282379b2776b00faef5`, `HumTrack.exe` `62935987be788d1d116c4cfd25b456d85e2e1e364926cbad9aa7e031699e6c91`.
- **current 교체:** `C:/src/humming-v2/artifacts/releases/current/` = 새 Release 폴더 전체. 빌드 결과와 86개 파일 sha256 동일(`artifacts/guitar-review-20261022/release-build-files.sha256`, `release-current-files.sha256`). `사용법.txt`는 이번 릴리스 안내로 갱신(두 폴더 동일). 출처 기록 `artifacts/releases/current-source.json`.
- 이전 실행본은 `artifacts/build-history/` 한 곳에만 보존: `release-20261022-1459-pan`, `release-20261021-vocalfx`.

### 비교 데모 (`C:/src/humming-v2/artifacts/guitar-demo-20261022/`)
- 자체 작곡 8마디 80 BPM, **Em–Am–C–G ×2** (`guitarVoicing`이 E 단조 다이어토닉 3화음을 만들어 첫 화음은 Em), 나일론 슬롯 1001 오프라인.
- A1 화음 일반(기존 자동 스트럼) / A2 같은 화음 `↓ ↓↑ ↑↓↑` 스트로크 변환 / B1 아르페지오 일반 / B2 같은 아르페지오 줄 배정 + 울림(배정 불가 0, 64음 중 47음 연장).
- 파일: `*.mid`(GM 24, 앱 `MIDI +`로 가져오기 가능), `*.wav`(실제 `exportWavSong` 경로), `*.matched.wav`(RMS −20 dBFS 맞춤, 피크 ≤ −4.4 dBFS), `*.song.json`, `levels.json`, `sf2_facts.json`, `README.md`, `test-output.log`.
- 재생성: `cd C:/src/humming-v2/mobile && TMP=… TEMP=… HUMTRACK_DEMO_OUT=C:/src/humming-v2/artifacts/guitar-demo-20261022 flutter test --no-pub test/looptap/guitar_demo_test.dart` (환경변수 없으면 검사 5개만 실행, 파일 쓰기 테스트는 건너뜀).
- 8마디 섹션은 앱 마디 토글(1/2/4)에는 없고 MIDI 가져오기로만 만들어진다 — 데이터는 정상 로드.
- 테스트 곡 경로(앱 리뷰): `MIDI +` → `artifacts/guitar-demo-20261022/A1-chords-normal.mid` 또는 `B1-arpeggio-normal.mid` → 악기를 Nylon(FreePats)으로 → `그리드` → "기타 연주"에서 스트로크/줄 배정/울림 적용 후 A2/B2 WAV와 비교.


---

# G3 인계: 연주법 (짧게 · 팜뮤트 근사 · 하모닉스 근사)

2026-10-22 · 사양 [gt-003](../specs/guitar/gt-003-palm-mute-harmonics.md) (r3 + 빌드 중 리뷰 + r4) · 커밋하지 않음

## 결과
- **데이터:** `PitchNote.articulation`은 적용 시점의 불변 스냅샷 `{kind, gateMs, velScale}`이다. 렌더할 때만 변환하므로 줄·음높이·길이, G1·G2 데이터, 수동 수정은 그대로 남는다. "일반으로"를 하면 JSON이 정확히 원래대로 돌아간다.
- **짧게:** 같은 나일론 샘플, 같은 채널에서 재생 길이만 줄인다. 스타카토이며 팜뮤트가 아니다.
- **팜뮤트 근사:** GM28 Muted(일렉) 음색을 전용 연주법 채널에서 낸다. 음역 40..86(렌더로 경계 확인).
- **하모닉스 근사:** GM31 음색을 전용 연주법 채널에서 낸다.
  - MIDI 음 = 실제로 들리는 음 S이고, 엔진에는 키 S−24를 보낸다. 지원 범위는 74..110이며, 범위 밖은 거절하고 개수를 안내한다.
  - 피치 판단은 배음 구조 **대리 측정**이고 지각 피치를 확인한 것이 아니다.
- **라우팅:** `ArticulationPlan.of(song)` 하나를 실시간·미리듣기·믹스·스템이 공유한다. 채널이 부족하면 모든 출력에서 똑같이 일반음으로 대체하고 배지로 알린다. 적용 시점에 채널이 없으면 거절한다.
- **MIDI (r4):** 팜뮤트·하모닉스 노트는 계획에서 받은 연주법 채널에 원래 트랙의 GM 프로그램과 들리는 음 S로 기록한다. 겹친 음은 보존되고, 음색은 담기지 않는다.

## 클릭 경로
1. 기타 트랙 → `그리드` → 도구줄 **"기타 연주"**
2. 패널의 **"연주법"** 줄: 일반 / 짧게 / 팜뮤트 근사 / 하모닉스 근사
3. 선택이 없으면 트랙 전체에 적용된다. 결과 줄에 "적용 N, 지원 범위 밖 M, 채널 부족 K"가 나온다.
4. 그리드 표시: 짧게는 `s`, 팜뮤트는 `PM`과 점선, 하모닉스는 `◇`.
5. 단축키는 새로 만들지 않았다.

## 검증 (Claude)
- `flutter analyze` 문제 없음: `artifacts/g3-impl-20261022/lead-analyze.log`
- 전체 테스트 **677 통과 / 3 건너뜀**: `lead-full-test.log`
  - 구현 기준선: 609 / 3
  - 신규 테스트: data 23, export 13, engine 16, live·UI 16
- G0–G2 골든은 바이트 단위로 같다.
- 설계 근거: `artifacts/g3-design-20261022/`
  - SF2 존 메타데이터
  - FluidSynth와 MeltySynth 배음 구조 측정
  - 프로브 테스트 `mobile/test/probe/articulation_probe_test.dart`

Codex 독립 로그: `codex-g0-g2-regression.log`, `codex-g3-data.log`, `codex-g3-export.log`, `codex-g3-engine.log`, `codex-g3-ui.log`

## 한계
- 청취는 하지 않았다.
- 팜뮤트 근사는 나일론이 아닌 일렉 뮤트 음색이다. 나일론 계열의 실제 팜뮤트(어두워짐)는 녹음 샘플이나 노트별 필터가 필요해서 이번 범위에서 뺐다.
- 하모닉스 근사는 소리 74..110만 지원한다. 저음 줄의 12프렛 하모닉스는 지원하지 않는다.
- Android 경로는 가짜 MidiPro로 단위 테스트만 했다:
  - 채널 해제 직렬화와 역할 세대 검사
  - 폰트 로딩 중 일반음 대체
  - 연주법 채널의 프로그램 28/31 바인딩
  - 같은 키 재타현 순서
- 섹션 전환과 트랙 삭제는 같은 정리 경로를 쓰지만 별도 테스트는 없다. redo도 별도 테스트하지 않았다.
- 기본값(짧게 120ms, 팜뮤트 250ms·×0.85)은 청취 후 조정이 필요하다.

## 데모·빌드

### 비교 데모 (`C:/src/humming-v2/artifacts/guitar-articulation-demo-20261022/`, README.md 참조)
- 자체 작곡 8마디, 80 BPM, Em–Am–C–G ×2, 나일론 슬롯 1001 오프라인. 생성 테스트: `mobile/test/looptap/guitar_articulation_demo_test.dart`
  - 환경변수 없이: 6 통과 / 1 건너뜀
  - `HUMTRACK_DEMO_OUT` 지정 시: 7 통과
  - 재생성 명령은 README에 있다.
- **A3 일반 / 짧게 / 팜뮤트 근사:** 세 파일 모두 G2 데모 A2와 같은 포크 스트로크 데이터를 쓰고, 연주법만 다르다.
  - 이유: 손대지 않은 블록 화음은 기존 자동 스트럼을 타지만, 연주법이 붙은 노트는 자동 스트럼을 타지 않는다. 블록 화음으로 만들면 타이밍 차이가 비교에 섞인다.
  - 적용 개수: 짧게 288, 팜뮤트 288.
- **B3 일반 / 하모닉스 근사:** 64음 중 74 이상인 14음에만 적용됐다. 나머지 50음은 범위 밖으로 거절되어 일반음이며, 음높이는 그대로다.
- **MIX-samepitch:** 일반 52(0–2.06초)와 팜뮤트 52 두 번(0.25초, 1.0초).
  - 1.5–1.95초 RMS를 일반음만 있는 기준과 비교했다.
  - WAV 스템: 비율 0.995
  - 내보낸 `.mid`를 실제 렌더: 비율 1.023
  - 일반음이 끊기지 않는다.
- **음량 맞춤:** 모든 파일을 RMS −21.1 dBFS로 맞췄다(피크 ≤ −1 dBFS 제한 때문에 목표를 낮춤, `levels.json`). `*.matched.wav`로 비교한다.
- 테스트 곡 경로(앱 리뷰): 곡 목록 `MIDI +` → `A3-normal.mid` 또는 `B3-normal.mid` → 악기 Nylon(FreePats) → `그리드` → "기타 연주" → "연주법"을 적용한 뒤 `*.matched.wav`와 비교.

### Windows 릴리스 (2026-10-22 19:24) → current
- 명령: `cd C:/src/humming-v2/mobile && flutter build windows --release --no-pub --target lib/main.dart` (기존 `mobile/build` 재사용), exit 0, 43.1초. 로그 `artifacts/g3-impl-20261022/build-release.log`
- 실행 경로: `C:/src/humming-v2/artifacts/releases/current/HumTrack.exe` (빌드 폴더와 파일 86개 sha256 동일)
- 해시
  - `data/app.so` `f883226305004e1826c48c8a020fac3a94e5a7682182b3a7b2edfe8fdb8fd0de`
  - `HumTrack.exe` `62935987be788d1d116c4cfd25b456d85e2e1e364926cbad9aa7e031699e6c91`
  - 소스 해시 목록(138개 파일): `artifacts/g3-impl-20261022/source-manifest.sha256`, sha256 `cef0a480e11e8c53bafa8bbfd596638af2cb36714ebf5dad9644a5b84045a016`. git HEAD `275ef49` + 커밋 안 된 작업.
- 이전 current는 `artifacts/build-history/release-20261022-1714-g0g2`에 보존했다. `current-source.json`을 갱신했고, `사용법.txt`는 G3 내용이다.
- 데모 테스트는 빌드 이후에 추가됐다. 테스트 파일뿐이고 `lib/`은 바뀌지 않았으므로 패키지에 영향이 없다.


---

# gt-004 인계: 줄별 울림 유지

2026-10-23 · 사양 [gt-004](../specs/guitar/gt-004-stroke-sustain.md) (Codex 리뷰 반영) · 커밋하지 않음 · 사용자 A/B 청취 승인(`guitar-stroke-ring-20261022`)

## 결과
- **함수:** 순수 함수 `applyStrokeSustain`(`mobile/lib/looptap/music/guitar_sustain.dart`)
- **UI:** "기타 연주" 패널의 **[줄별 울림 유지]** 버튼. [울림 아르페지오]와 별개다.
- **규칙:**
  - 대상은 명시적으로 스트로크를 적용한 화음뿐이다. 인접한 두 타격의 소리 나는 음 구성이 정확히 같아야 한다.
  - 각 노트는 자기 원래 끝이 다음 타격에 닿을 때만 늘어나고, 다음 타격의 같은 줄·같은 음 시작까지만 이어진다.
  - 다음은 원래 길이를 유지한다: 화음 변경, 쉼, 부분 선택, 떨어진 선택 경계, 태그 없는 음이 섞인 경우, 연주법·잠긴·음소거 노트, 직접 지정한 줄, 충돌, 섹션 끝.
  - 줄 배정은 임시 사본에서 하고, 줄 정보는 실제로 연장된 노트에만 기록한다. 보호 대상 노트는 JSON 전체가 바이트 단위로 같다.
- **동등성:** A3에 적용한 결과가 승인된 AFTER와 288음 길이 모두 같다(연장 200, 그대로 88). 그대로 둔 88음에는 `guitarString`이 없다(가장 좁은 기록 규칙).

## 클릭 경로
기타 트랙 → `그리드` → 도구줄 "기타 연주" → (스트로크 적용) → **[줄별 울림 유지]**
- 실행 결과 줄에 "연장 N · 그대로 M (사유)"가 나온다.
- 실행 취소 한 번으로 자동 줄 배정까지 복원된다. [울림 되돌리기]로도 되돌릴 수 있다.

## 검증 (Claude)
- `flutter analyze` 문제 없음
- gt-004 테스트 25개 통과 (`guitar_sustain_test.dart` 20, `guitar_sustain_ui_test.dart` 5)
- 전체 테스트 **719 통과 / 5 건너뜀** (작업 전 694 / 5)
- 로그: `artifacts/guitar-sustain-20261023/` (`lead-analyze.log`, `lead-full-test.log`, `test-before.log`, `test-after.log`, `build-release.log`)

## 빌드 · current
- 2026-10-23 00:25 릴리스 빌드. `mobile/build` 재사용, exit 0.
- `current`를 교체했다. 빌드 폴더와 파일 86개 sha256이 같다.
  - `data/app.so` `a342861cf6494135a2687f889ed075b4efb2f3d2c47f6277643c3c17575b98f8`
  - `HumTrack.exe` `62935987…6c91`
- 소스 해시 목록(139개 파일): `artifacts/guitar-sustain-20261023/source-manifest.sha256`, sha256 `b36408956751175d9c81e52ec59ee87f6a99008ae73a625b38aad395738a56d5`
- 이전 `current`는 `artifacts/build-history/release-20261022-1924-g3`에 보존했다.
- `current-source.json`과 `사용법.txt`를 갱신했다.

## 한계
- 같은 화음이라도 다른 보이싱이나 다른 줄로 치면 연결하지 않는다(의도한 보수적 동작).
- 태그 없는 기존 화음은 지원하지 않는다("스트로크 미적용"으로 안내).
- 그루브 경계 오차는 gt-002와 같다.
- 링크된 섹션과 복사/붙여넣기는 gt-002 테스트에 의존한다.
- UI 테스트는 영어 로케일로만 실행했다. 한국어 결과 문장은 순수 함수 테스트로 확인했다.
- 앱 빌드에서는 청취하지 않았다. A/B 데모만 사용자가 청취해 승인했다.


---

# 그리드 사용성 인계 (2026-10-23)

설계: [grid-usability.md](../specs/grid-usability.md) · 리뷰 기준·결과: [grid-usability-review.md](grid-usability-review.md) (Codex) · 커밋하지 않음

- **편집 공간 (1266×714 노트 영역)**
  - 기본: 134 px
  - 편집 확대 1클릭: 336 px
  - 타임라인 접기만: 296 px
  - 1920×1040: 315 / 662 px
  - 390×844: 246 / 466 px
- **좌표:** 그리드, 눈금, 플레이헤드, 히트, 건반, 세기 레인, 영역 선택이 모두 `PitchGridAxis` 하나를 쓴다.
- **UI 설정 (LoopPrefs):** `gridFocus`, `gridToolsExpanded`, `gridVelocityLane`, `timelineCollapsed`. 곡 데이터 형식은 바뀌지 않는다.
- **테스트:** 새 13개 (`mobile/test/looptap/grid_usability_test.dart`, 실제 포인터 좌표, 3가지 창 크기). 기존 테스트는 수정하지 않았다. 전체 **732 통과 / 5 건너뜀**, analyze 문제 없음.
- **스크린샷:** `artifacts/grid-ux-20261023/screens/` (5장)
- **빌드 (01:21):**
  - 빌드하는 동안 소스가 바뀌지 않았다. 소스 해시 목록 139개 파일, sha256 `24e39de7efbb167142ba28f5e4a46d297ba4f3c9370874caee6f116f53666a18`
  - `data/app.so` `ae7074618804c46d069a25acf489d6e72cd6fcec4f673a770a9a68cdd84ec110`
  - `HumTrack.exe` `62935987…6c91`
  - `current`는 빌드 결과와 파일 86개가 같다.
  - 이전 G4는 `artifacts/build-history/release-20261023-0025-g4`에 보존했다.
- **한계:**
  - 기본 상태(편집 확대 꺼짐)는 1266×714에서 134 px로 200 px 미만이다. 편집 확대 한 번으로 336 px가 된다.
  - 그리드 텍스트에 Inter 폰트를 명시해서 글꼴이 약간 달라질 수 있다.
  - 390 px 화면에서 헤더 왼쪽이 축소되는 문제는 이전부터 있던 것이다.
  - 실기기 확인과 네이티브 UI 리뷰는 Codex 몫이다.

## 실행 취소 단축키 보완과 최종 상태 (2026-10-23 01:37 빌드 = current)
- **보완:** `DesktopCommands`의 글자 단축키(S, Shift+R, Z/Shift+Z, G, Shift+D) 판정에 물리 키 위치를 함께 쓴다(`_letter`).
  - 논리 키가 다른 라틴 글자면 그 글자를 우선한다. AZERTY·Dvorak 배열을 유지하기 위해서다.
  - 테스트: 실제 편집 화면에서 실제 좌표·키 이벤트로 13개 추가(`grid_usability_test.dart`). 전체 **745 통과 / 5 건너뜀**, analyze 문제 없음.
- **빌드:** `data/app.so` `9f73fe48dc624e7de68c3c00d4fbf55bd0fabf910c59d9b2c68c2b74a95c18ff`
  - 소스 해시 목록: `artifacts/grid-ux-20261023/source-manifest-undo.sha256`(139개 파일)
  - `current`는 빌드 결과와 파일 86개가 같다.
  - 01:21 중간 빌드는 백업 없이 교체했고, G4 스냅샷은 보존했다.
- **최종 확인:**
  - Codex가 레이아웃·마우스 리뷰를 통과했다(작은 창·최대화, 편집 확대, 마디·박 눈금, 피아노 건반, 흰 선택·영역 선택, 줌·스크롤).
  - 사용자가 실제 키보드로 그리드에서 노트를 이동한 뒤 Ctrl+Z로 원래대로 돌아오는 것을 확인했다.
  - 자동화 도구로 보낸 키 조합에는 반응이 없었다. 이는 자동 입력의 한계로 관찰된 것이며 앱 결함으로 확정하지 않았다.
  - Codex 독립 검증: `artifacts/grid-ux-review-20261023/codex-shortcut-final.log`(35 통과), `codex-final-package-verification.json`
