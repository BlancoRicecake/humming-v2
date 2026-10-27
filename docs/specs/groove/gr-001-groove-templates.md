# Groove templates (적용·추출, 비파괴)

- **ID:** groove-001
- **Status:** implemented (uncommitted)
- **Inspired by:** Ableton Live 12 — Groove Pool, Groove parameters, Extract Groove; FL Studio — Global swing / channel swing mix (카탈로그 GR-01, GR-02, GR-03, GR-05)

## Sources
- https://www.ableton.com/en/live-manual/12/using-grooves/ : 그루브를 클립에 지정하면 재생할 때만 타이밍과 세기가 바뀌고 클립 내용은 그대로다(비파괴). 파라미터는 Base(기준 격자, 격자 위 노트는 안 움직임), Quantize(그루브 전에 곧은 격자로 0–100% 당김), Timing(그루브 타이밍 적용량), Random, Velocity(−100…+100, 음수는 효과 반전), Global Amount(Timing·Random·Velocity를 함께 키우며 최대 130%). 클립(MIDI/오디오)에서 연주되는 구간의 타이밍·세기를 뽑아 새 그루브를 만들 수 있다(Extract). Commit은 그루브를 노트에 굽고 지정을 해제한다.
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/channelrack.htm : 전역 Swing은 두 번째 16분음표마다 늦춘다. 채널마다 전역 스윙을 얼마나 따를지(0–100%) 따로 정한다.
- HumTrack 기존 동작(코드 읽음): `Song.swing`(0–0.6)은 홀수 16분 step을 `swing × 0.5` step 늦춘다 — 실시간(`edit_screen.dart` `_swFrac`, 클럭 전체를 늦춤)과 내보내기(`midi_export.dart` `onTick`)가 같은 규칙.
- 흥얼거림 테이크에서 추출, 기본 템플릿 값, 지연 보정은 HumTrack 자체 설계다(템플릿 값은 아래 공식으로 우리가 만든 것이며 다른 제품의 그루브 파일을 쓰지 않는다).

## User-visible behavior
1. 트랙의 "그루브" 칩(믹서 줄, 데스크톱 트랙 헤더)을 누르면 그루브 시트가 열린다. 목록에서 템플릿을 고르면 재생 중 바로 느낌이 바뀐다. 노트 자체(편집 화면의 위치·세기)는 바뀌지 않는다.
2. 템플릿마다 조절: **Timing** 0–100%(기본 100%), **Velocity** −100…+100%(기본 100%), **Quantize** 0–100%(기본 0%). 시트 상단에 곡 전체 **Amount** 0–130%(기본 100%).
3. 적용 범위: "곡 전체"(기본, 트랙에 지정) 또는 "이 섹션만"(섹션별 덮어쓰기, "그루브 없음"도 가능).
4. **추출:** "마지막 녹음에서 만들기"는 방금 흥얼거린/비트박스한 테이크의 박 위치와 세기로 새 템플릿("내 그루브 1", 이름 변경 가능)을 만든다. "이 트랙에서 만들기"는 현재 섹션 트랙 노트(불러온 MIDI처럼 미세 타이밍·세기가 있는 노트)로 만든다. 만든 템플릿은 곡에 저장되어 다른 트랙에 입힐 수 있다.
5. **Swing 노브는 그대로 남는다.** 그루브를 지정하지 않은 트랙은 지금처럼 Swing을 따르고, 그루브를 지정한 트랙은 Swing 대신 그 그루브를 따른다(둘이 겹쳐 두 번 흔들리지 않는다). 내보내기(WAV/stem/MIDI)는 들리는 그대로 나간다.

## Swing과의 관계 (결정과 이유)
- **Swing은 별도 값으로 유지하고, "그루브 미지정 트랙의 기본 그루브"로 정의한다.** 그루브를 지정하면 그 트랙에서 Swing을 대체한다.
- 이유: (a) 옛 곡과 그루브를 안 쓰는 곡의 재생·내보내기가 **바이트 단위로 그대로**다. (b) 손잡이 하나로 셔플을 주는 흐름(GR-05, 모바일 첫 사용자)이 사라지지 않는다. (c) Swing을 템플릿으로 흡수하면 마이그레이션이 필요하고 전역 노브와 트랙별 지정이 동시에 존재할 때 우선순위가 모호해진다. (d) 대체(가산 아님)라서 이중 스윙이 생기지 않는다.
- 기본 템플릿에 "Swing 16 약/중/강"을 따로 두어, Swing과 같은 느낌을 트랙별로 다르게 줄 수도 있다.

## 템플릿과 적용 규칙
- 템플릿: 길이 L(16 또는 32 step), 위치별 `timing[p]`(step 단위, −1…+1), `accent[p]`(−1…+1). 위치 = 16분음표 하나.
- 기본 템플릿(공식): Straight(모두 0) · Swing 16 약/중/강(홀수 p에 +0.1/+0.2/+0.3) · Swing 8(p mod 4 == 2에 +0.67) · Laid-back(p ∈ {4, 12}에 +0.15) · Pulse(timing 0, accent: p mod 4 == 0 → +1, p mod 4 == 2 → 0, 홀수 → −0.5).
- 노트 시작 s(섹션 안 step), 기준 격자 g = round(s)(동률은 올림), p = g mod L(**섹션 기준**, 곡 전체 step이 아님). T·V·Q = 지정값, A = Amount.
  - 새 시작 s′ = s + (g − s)·Q + timing[p]·T·A. s′ < 0이면 0. 길이는 그대로(끝이 섹션을 넘으면 기존 flatten 규칙대로 자름).
  - 세기: V·A·accent[p] == 0이면 원래 값(`null` 포함) 그대로. 아니면 v′ = clamp(round((velocity ?? 100)·(1 + 0.5·accent[p]·V·A)), 1, 127).
  - PR-007(Chance/편차)은 그루브가 정한 v′를 기준 세기로 쓴다. PR-006 Humanize는 저장된 노트를 바꾸는 별개 기능이다.
- 드럼 노트도 같은 규칙(시작·세기, 길이 없음).
- 우선순위: 섹션 덮어쓰기 > 트랙 지정 > Swing. 섹션 덮어쓰기 "그루브 없음"은 그 섹션에서 트랙 지정을 끄고 Swing으로 돌아간다는 뜻이다.

## 추출 규칙
- 입력: 박 목록 (s, v) — 마지막 테이크면 엔진 노트의 `start`(초)÷(16분 길이)와 `velocity`, 트랙이면 노트 `startSteps`와 `velocity ?? 100`. 섹션 길이 밖은 버린다. 4개 미만이면 "박이 너무 적어요" 안내 후 중단.
- d = s − round(s). **녹음 지연 제거:** 모든 d의 중앙값을 빼서(사람·기기 지연으로 전체가 늦은 것은 그루브가 아님) 상대값으로 만든다.
- L = 섹션이 1마디면 16, 그 외 32(시트에서 변경 가능). 위치별 d 중앙값 → timing[p], ±0.5로 자름. 박이 없는 위치는 0.
- 세기: 서로 다른 v가 2개 미만이면 accent 전부 0. 아니면 위치별 평균 m_p, 전체 평균 μ, D = max|m_p − μ|; accent[p] = (m_p − μ)/D, 박 없는 위치는 0.

## HumTrack design
- Code:
  - `mobile/lib/looptap/music/groove.dart`(신규): `GrooveTemplate {id, name, length, timing, accent, origin}`, `GrooveAssign {grooveId, timing, velocity, quantize}`, `kBuiltinGrooves`, `({double start, int? velocity}) applyGroove(...)`, `GrooveTemplate? extractGroove(List<({double steps, int velocity})>, {int length, String name})`, `GrooveAssign? grooveFor(Song/섹션, trackId)`.
  - `music/song_util.dart`: `flattenSong(sections, {GrooveContext? groove, ...})`. 지정 그루브가 **하나라도 있는 레인**은 flatten 단계에서 시작·세기를 굽고(그 레인의 그루브 없는 섹션에는 Swing도 여기서 굽는다), 그 레인 id를 `FlatSong.selfTimed`에 넣는다. 그루브가 전혀 없으면 지금과 결과가 같다.
  - `music/midi_export.dart` `buildMidi`: `selfTimed` 레인은 `onTick`의 스윙을 건너뛴다. `wav_export.dart`·`exportMidiSong`은 같은 FlatSong을 쓰므로 믹스·stem·MIDI가 일치한다.
  - `screens/edit_screen.dart`: 실시간 재생도 같은 `applyGroove`를 쓴다. 클럭은 지금처럼 Swing으로 홀수 step을 늦추되, 그루브 트랙의 노트는 "실효 시작 시각 − 실제 트리거 시각"만큼 예약한다. 실효 시작이 자기 step보다 앞서는 노트(음수 timing, Quantize로 당겨지는 노트)는 **한 step 앞 트리거에서 미리 예약**한다. `_humConvert`는 엔진 결과의 (start, velocity)를 `_lastTakeOnsets`로 메모리에 보관(저장 안 함, 다음 녹음이 덮어씀).
  - `widgets/sheets/groove_sheet.dart`(신규), `mixer_sheet.dart`에 그루브 칩(`mixer-groove-<id>`).
- Model (`models/loop_models.dart`, 모두 기본값이면 JSON에 안 씀):
  - `Song.grooves: List<GrooveTemplate>`(추출·사용자 템플릿, 기본 []), `Song.trackGrooves: Map<String, GrooveAssign>`(기본 {}), `Song.grooveAmount`(기본 1.0). 기본 템플릿은 저장하지 않고 `builtin:<name>` id로만 참조.
  - `Section.grooveOverrides: Map<String, GrooveAssign?>`(기본 {}; 값 null = "그루브 없음"). AR-001 연결 섹션에서는 섹션별(공유 안 함).
  - 알 수 없는 grooveId는 "지정 없음"으로 취급(Swing 적용).
- Undo: 지정·슬라이더·추출·이름 변경 모두 `_pushUndo()`(슬라이더 드래그는 `coalesce: true`). `_EditSnapshot`/`_capture`/`_restore`에 `grooves`, `trackGrooves`, `grooveAmount` 추가(섹션 덮어쓰기는 `Section.deepCopy`로 따라옴).
- UI: 데스크톱 `Ctrl/Cmd+G` = 활성 트랙 그루브 시트. 모바일 = 믹서 줄 칩, 편집 화면 트랙 메뉴. Swing 슬라이더 옆에 "그루브 미지정 트랙에 적용" 안내.

## Decisions (2026-10-22, owner approved)
- Swing은 별도 값으로 유지한다. 그루브가 지정된 트랙은 Swing **대신** 그루브를 쓴다(더하지 않음). 옛 곡의 출력은 그대로 유지된다.
- 템플릿은 v1에서 **곡 안에만** 저장한다(앱 전체 라이브러리는 나중).
- Velocity 기본값 100%, Random은 제외한다(PR-006/007과 겹침). Commit은 별도 스펙으로 둔다.

## Acceptance tests
- [x] 그루브 없음: 임의 곡에서 `flattenSong` 결과와 `buildMidi` 바이트가 이 기능 전후 동일(Swing 0.4 포함).
- [x] Swing 16 중(+0.2), T=1, A=1, 노트 s=3 → s′=3.2; s=2 → 2.0. Swing 노브 0.4의 홀수 지연(0.2)과 같은 값.
- [x] Q=0.5, s=2.4, Straight → s′=2.2. T=0이면 s′=s(Quantize만).
- [x] A=1.3, Swing 8, s=2 → 2 + 0.67·1.3 = 2.871. s′ < 0 → 0.
- [x] Pulse, V=1: velocity 80, p=0 → 120; p=1 → 60; velocity null, p=2 → null 유지. V=−1, p=0 → 40.
- [x] 섹션 기준 위치: 1마디 섹션 A 뒤 2마디 섹션 B(L=32)의 첫 노트 → p=0(곡 전체 step 16이 아님).
- [x] 우선순위: 트랙 지정 Swing 8 + 그 섹션 덮어쓰기 null("그루브 없음") → 그 섹션 노트는 곡 Swing만 따른다. 덮어쓰기에 Laid-back 지정 → 그 섹션만 Laid-back, 다른 섹션은 Swing 8.
- [x] 레인에 그루브가 있으면 `FlatSong.selfTimed`에 포함, 그 레인의 그루브 없는 섹션 노트에 Swing이 offset으로 구워짐, `buildMidi`는 그 레인에 스윙을 다시 더하지 않음(이중 적용 없음).
- [x] 추출: (0.1, 0.1+1, 0.1+2 … 16개, 모두 +0.1 늦음) → 지연 제거 후 timing 전부 0. 짝수 0.0·홀수 +0.25 → 홀수 timing ≈ +0.125, 짝수 ≈ −0.125(중앙값 기준 상대값).
- [x] 추출 세기: 짝수 100·홀수 50 → 짝수 accent +1, 홀수 −1. 모두 90 → accent 전부 0. 박 3개 → null.
- [x] JSON 왕복: grooves/trackGrooves/grooveAmount/grooveOverrides(null 값 포함) 보존, 기본값이면 키 없음.
- [x] 실시간 패리티: 순수 함수 `liveGrooveSchedule(section, bpm, swing, groove)`가 내는 (노트, 초) 목록 = 같은 섹션의 FlatSong을 초로 바꾼 목록(오차 1ms).
- [x] Undo: 그루브 지정 → Undo → `trackGrooves` 비어 있음, Redo → 복원.

## Out of scope
- Commit groove(GR-04, 노트에 굽기), Random 파라미터, 그루브 라이브러리 앱 전역 공유/가져오기(GR-06, .agr 등 외부 파일).
- 오디오(보컬 클립) 그루브 — 워프 엔진이 없음.
- 템플릿 위치별 그래프 편집기, 3연음 기준 격자(Base) 선택.
