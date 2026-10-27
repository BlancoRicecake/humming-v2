# Note chance and velocity variation

- **ID:** piano-roll-007
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Note probability (Chance) and Velocity Deviation (카탈로그 PR-06, PR-07)

## Sources
- https://www.ableton.com/en/live-manual/12/editing-midi/ (Editing probabilities 절): 노트마다 0–100% 확률을 주면 클립이 재생될 때 그 확률로 노트가 울린다. 위/아래 키로 10%씩 바꿀 수 있다.
- 같은 페이지 (Editing velocities 절): 노트마다 세기 편차(위 또는 아래 방향 범위)를 주면, 노트가 울릴 **때마다** 그 범위 안에서 새 세기가 정해진다. 범위는 세기 막대 위 음영으로 보인다.
- 루프를 도는 매 회차마다 새로 정해진다는 해석은 "울릴 때마다"에서 나온 것이며, 회차 단위 재현성(seed)과 내보내기 규칙은 HumTrack 자체 설계다.

## User-visible behavior
1. 노트를 선택하고 인스펙터에서 **Chance**(0–100%, 기본 100%)와 **Velocity variation**(−64…+64, 기본 0)을 정한다.
2. 재생 중 루프가 한 바퀴 돌 때마다 노트마다 새로 판정한다: Chance 확률로 울리고, 울리면 세기가 [세기, 세기+편차](편차 양수) 또는 [세기+편차, 세기](편차 음수) 안의 값이 된다.
3. Chance < 100%인 노트는 확률에 비례해 흐리게 그려지고, 노트가 충분히 넓으면 "50%" 같은 숫자가 보인다. 편차는 세기 레인 막대 위 음영 범위로 보인다.
4. 세기 레인은 "강약 | 확률" 전환을 가진다. 확률 모드에서 막대를 끌면 선택 노트의 Chance가 바뀐다(드래그 1회 = Undo 1회).
5. 곡 단위 **Variation seed**가 있다. 내보내기 시트의 "다른 변주로" 버튼이 seed를 새로 뽑는다(Undo 가능).

## 판정 규칙 (결정적)
- 판정 함수: `realizePitchNote(note, {seed, sectionId, trackId, pass})` → 울릴 노트(세기 반영 copy) 또는 null.
- 키 문자열 `"$seed|$sectionId|$trackId|${note.midi}|${(note.startSteps*1000).round()}|$pass"`를 FNV-1a 32-bit로 해시해 PR-006의 `HumRng` seed로 쓰고, 첫 값 u₁(Chance), 둘째 값 u₂(세기)를 뽑는다. 노트 리스트 인덱스를 쓰지 않으므로 다른 노트를 추가/삭제해도 이 노트의 결과는 변하지 않는다.
- 울림: u₁ < chance. chance=1이면 항상, 0이면 절대 안 울림.
- 세기: base = velocity ?? 100, v = clamp(base + round(u₂·deviation), 1, 127). deviation == 0이면 원래 `velocity`(null 포함) 그대로.
- `muted`(PR-001)이면 판정 없이 항상 안 울림.

## Export rule (WAV/stem/MIDI)
- **내보내기는 "들리는 그대로" 한 가지 변주를 굽는다.** `flattenSong`이 섹션 반복 r(0부터)을 pass로 써서 판정하고, 살아남은 노트만(세기 반영) FlatSong에 넣는다. seed는 `Song.variationSeed`.
- 같은 곡을 다시 내보내면 **같은 결과**가 나온다(seed 고정). WAV 믹스, 각 stem, MIDI가 모두 같은 FlatSong에서 나오므로 서로 일치하고 stem을 합치면 믹스와 같다.
- MIDI 파일에는 확률/편차 메타데이터를 쓰지 않는다(표준 MIDI에 대응 개념 없음). 판정된 노트만 고정 세기로 들어간다.
- 실시간 재생도 같은 함수를 쓴다. 단일 섹션 루프 재생은 재생 시작 후 첫 바퀴가 pass 0이고 바퀴마다 +1, Play Song은 섹션 반복 인덱스가 pass다. 따라서 Play Song으로 듣는 결과와 내보낸 WAV가 같다.

## Edge cases
- 기타 strum: 판정을 먼저 하고, 살아남은 노트로 기존 strum 묶음을 만든다. deviation ≠ 0인 노트는 세기가 명시되므로 기존 규칙대로 strum 대상에서 빠진다.
- 길게 울리는 노트가 루프 경계를 넘는 경우 판정은 그 노트의 시작이 속한 pass 기준이며, 이어 울리기(`_chasePitched`)는 그 pass의 판정을 다시 계산해 따른다.
- 판정이 안 울림이면 패드 하이라이트(`litM`)에도 넣지 않는다.
- Chance/편차를 바꾼 직후 이미 예약된 노트는 실행 직전 판정을 다시 한다.

## HumTrack design
- Code:
  - `mobile/lib/looptap/models/loop_models.dart`: `PitchNote`에 `final double chance`(기본 1.0, JSON은 ≠1일 때만, 0–1 clamp), `final int velocityDeviation`(기본 0, ≠0일 때만, −127…127 clamp) 추가, `copyWith/toJson/fromJson` 반영. `Song`에 `int? variationSeed`(null이면 `id`의 FNV-1a 해시 사용, 값이 있을 때만 저장).
  - `mobile/lib/looptap/music/note_random.dart`: `HumRng`(PR-006 공용), `fnv1a32(String)`, `realizePitchNote(...)`.
  - `mobile/lib/looptap/music/pitch_note_edit.dart`: `setPitchChance(notes, selected, double)`, `shiftPitchChance(...)`, `setPitchVelocityDeviation(...)`. 잠긴 노트 건너뜀, 바뀐 게 없으면 `identical`.
  - `mobile/lib/looptap/music/song_util.dart`: `flattenSong(sections, {int? variationSeed})`. null이면 판정 없이 모든 비-muted 노트(분석·미리보기용), 값이 있으면 위 규칙으로 판정. `midi_export.dart` `exportMidiSong`, `wav_export.dart` `exportWavSong`/`exportStems`는 song의 seed를 넘긴다.
  - `mobile/lib/looptap/screens/edit_screen.dart`: 루프 pass 카운터 추가, `due` 계산과 `_playAfter` 콜백에서 `realizePitchNote` 사용, `velocity:`에 판정 세기 전달. seed 재생성은 `_pushUndo()` 후 변경.
  - `mobile/lib/looptap/widgets/surfaces/velocity_lane.dart`: 강약/확률 모드, 편차 음영. `pitch_grid_surface.dart`: Chance 비례 alpha와 % 라벨.
  - `mobile/lib/looptap/widgets/surfaces/step_grid.dart`: 인스펙터에 Chance·Variation 슬라이더(`note-chance`, `note-velocity-deviation`), 드래그 1회 = `_commit` 1회.
  - `mobile/lib/looptap/widgets/sheets/export_drawer.dart`: "다른 변주로"(seed 재생성) 버튼, Chance < 1 노트가 있을 때만 표시.
- Model: 필드 3개 추가, 기본값이면 JSON에 안 씀 → 옛 곡은 그대로(모든 노트 100%, 편차 0, seed는 id에서 유도). 구버전 앱이 새 곡을 다시 저장하면 확률/편차가 사라진다.
- UI: 모바일·데스크톱 공통 인스펙터 슬라이더와 세기 레인 모드. 데스크톱 선택 상태에서 레인이 확률 모드일 때 `Ctrl/Cmd+↑/↓` = Chance ±10%.
- Drum notes: v1 제외(하이햇 확률은 매력적이지만 드럼 표면에 선택 UI가 없음). `DrumNote` 확장은 별도 스펙.

## Decisions (2026-10-22, owner approved)
- 단축키(M, K, H, Ctrl/Cmd+U/E/J/L)는 사양대로 확정.
- 드럼 레인은 v1 제외 (드럼 선택 UI가 생기는 2번 묶음에서 다룸).
- **스키마 v3:** 새 필드(`muted`, `chance`, `velocityDeviation`, `Song.variationSeed`)를 추가하면서 `kSchemaVersion`을 3으로 올린다. 저장 시 디스크의 `songs.json` 스키마가 앱이 아는 버전보다 높으면 덮어쓰지 않고 저장 실패로 처리한다(이후 버전 다운그레이드 데이터 손실 방지). v2 파일은 그대로 읽힌다.
- MIDI 내보내기에 **'확률 무시하고 모든 노트 포함'** 체크박스를 추가한다(기본값: 꺼짐 = 사양의 고정 변주 규칙).
- Out of scope의 'MIDI에 모든 노트를 넣는 옵션'은 위 결정으로 범위에 포함되었다.
- 재생 중 탐색(seek)하면 루프 반복 카운트가 0부터 다시 시작한다(수용).

## Acceptance tests
- [x] chance 1.0, deviation 0, velocity null → pass 0–999 모두 울리고 `velocity == null`.
- [x] chance 0.0 → pass 0–999 모두 null. muted + chance 1 → 모두 null.
- [x] chance 0.5, 고정 seed, pass 0–999 → 울린 횟수 450–550.
- [x] velocity 60, deviation +20 → 울린 결과 세기 ∈ [60, 80], 1000회 중 최소 ≤ 62, 최대 ≥ 78. deviation −20 → ∈ [40, 60].
- [x] velocity 120, deviation +20 → 최대 127(clamp).
- [x] 결정성: 같은 (note, seed, sectionId, trackId, pass) → 같은 결과. 다른 노트를 리스트에 추가해도 결과 불변.
- [x] `toJson`: chance 1.0·deviation 0이면 키 없음, 0.25면 `'chance': 0.25`. `fromJson` 기본값 복원.
- [x] `flattenSong([섹션 repeats 4, melody에 chance 0.5 노트 8개], variationSeed: 7)`를 두 번 → 같은 FlatSong. `buildMidi` 바이트 동일.
- [x] `flattenSong(..., variationSeed: null)` → chance와 무관하게 비-muted 노트 전부.
- [x] stem 일치: `exportStems`와 `exportWavSong`이 같은 seed에서 같은 note-on 집합을 쓴다(FlatSong 비교).

## Out of scope
- 확률 그룹(하나만 울림/함께 울림), 확률 무작위화 범위, 드럼 노트 확률, MIDI에 모든 노트를 넣는 내보내기 옵션.
