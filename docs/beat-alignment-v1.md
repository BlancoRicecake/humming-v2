# 박자 보정 개선안 v1 — Anchor 기반 시작점 정렬

> 방향: **각 트랙을 완벽히 quantize 하지 않는다. 트랙을 쌓을 때 전체가 듣기 좋게 맞물리도록, 첫 유의미 노트를 공통 기준(timeline 0)에 정렬한다.**

## 1. 결정 사항 (확정)

- v1 범위: **A 정렬 엔진 + B 녹음 UX** 둘 다.
- 정렬 기준: **모든 트랙의 첫 유의미 노트를 timeline 0 에 정렬** (리딩 무음 트림). 음수 offset / 클램프 충돌 없음.
- 하지 않는 것: 노트별 quantize, BPM top-3 후보, phase 최적화, duration quantize, swing/humanize, triplet grid, tolerance 윈도우.

## 2. 현재 코드 현실 (조사 결과)

### B(앵커 재생 + 카운트인)는 이미 대부분 존재한다
인라인 녹음 플로우([edit_screen.dart](../mobile/lib/screens/edit_screen.dart))에 이미 구현됨:

- **카운트인** — `_runCountdown(bpm)` ([edit_screen.dart:213](../mobile/lib/screens/edit_screen.dart#L213)): `store.bpm` 기준 3비트 카운트.
- **녹음 중 백킹 재생** — `_startActualRecording` ([edit_screen.dart:241](../mobile/lib/screens/edit_screen.dart#L241)): `accompanimentSynthTracks` + `accompanimentVocalPath` 로 **기존 트랙 전체를 반주로 재생**하며 그 위에 녹음. 즉 "기준 트랙을 들으며 쌓는" UX는 이미 동작.
- **헤드셋/스피커 분기** — 헤드셋이면 소리 재생, 스피커뿐이면 마이크 누수 방지로 음소거 + 플레이헤드 시각 가이드, `metroOn`이면 메트로놈 클릭.

→ B는 신규 구현이 아니라 **소폭 보강** 대상 (3절).

### A(정렬)는 빠져 있다 — v1의 핵심
녹음 종료 → `analyzeForPending` → `commitPendingRecording`([project_store.dart:679](../mobile/lib/state/project_store.dart#L679))에서 청크가 항상 `inPoint: 0, timelineStart: 0` 으로 커밋됨([:722](../mobile/lib/state/project_store.dart#L722), 보컬 [:699](../mobile/lib/state/project_store.dart#L699), 레거시 [:539](../mobile/lib/state/project_store.dart#L539)).
→ 백킹에 맞춰 불러도 **리딩 무음·반응 지연이 그대로 남아 어긋난다.** 이 마지막 한 스텝이 비어 있다.

### 재사용할 기존 메커니즘
청크는 이미 `effectiveStart = note.start - inPoint + timelineStart` 로 시간축 이동을 지원([models.dart:85](../mobile/lib/models/models.dart#L85), [project_store.dart:88](../mobile/lib/state/project_store.dart#L88)).
→ **첫 유의미 노트를 0에 정렬 = `inPoint = firstStart`, `timelineStart = 0`.** 별도 필드/연산 불필요. inPoint 앞쪽 무음·노이즈 노트는 `effectiveRenderNotes` 클립 로직이 자동으로 제거.

기존 `quantizeEnabled`/`effectiveRenderNotesFor`([project_store.dart:235](../mobile/lib/state/project_store.dart#L235)) 노트별 quantize는 **건드리지 않고 보존** (기본 off, 후순위 고급 기능으로 유지).

## 3. 구현 계획

### A. 정렬 엔진 (핵심)

**A-1. `firstMeaningfulStart` 헬퍼 (트랙 타입별 분기)**
- 멜로딕/드럼: `notes` 중 `duration >= kMinNoteSec`(예 0.06s) 인 첫 노트의 `start`. (필요 시 `confidence` 하한 병행.)
- 보컬: `vocalPeaks` 에서 임계값 초과 첫 인덱스 → `idx / peaks.length * vocalDuration`.
- 유의미 노트가 없으면 `0.0` 반환(정렬 미적용).

**A-2. 커밋 시 정렬 적용**
`commitPendingRecording` 의 멜로딕/보컬/드럼 청크 생성부 + 레거시 `analyze` 경로에서:
```
final lead = firstMeaningfulStart(...);   // 0 이면 no-op
inPoint:      lead,        // 0 대신
timelineStart: 0,
outPoint:     span,        // 그대로
originalLength: span,
```
outPoint/originalLength 불변 → 우측 트림 핸들 동작 영향 없음. inPoint 가 lead 로 시작될 뿐.

**A-3. 디버그 가시화 (프로젝트 원칙: intermediate signal 노출)**
- 정렬 trim 量 `lead` 를 `debugPrint('[align] track=.. lead=..s')`.
- 펜딩 사용/삭제 시트 또는 박자보정 카드에 "시작점 정렬: -0.30s" 한 줄 표시 → 사용자가 무엇이 일어났는지 보이게.

### B. 녹음 UX 보강 (소폭)

- **카운트인 1마디 옵션** — 현재 3비트. 4비트(1마디)로 늘릴지 결정(선택). 변경 시 [edit_screen.dart:228](../mobile/lib/screens/edit_screen.dart#L228) `beat >= 3` → `>= 4`.
- **스피커 가이드 강화(선택)** — 스피커 단독일 때 기본 메트로놈 클릭을 켜 박자 기준을 청각적으로 제공(현재는 `metroOn` 의존).
- 백킹 재생/정렬은 이미 "기존 트랙 위에 쌓기"로 일관 — 별도 anchor 트랙 모델 없이 동작.

### 제외 (후순위)
노트별 quantize 강화, BPM 자동 감지(librosa.beat 미사용 상태 유지), phase/grid/swing/duration quantize.

## 4. 데이터 모델 영향

**추가 필드 없음.** 기존 `Chunk.inPoint` 재사용. (선택적으로 디버그 표시용 `alignLeadSec` 를 Chunk 또는 PendingRecording 에 둘 수 있으나 `inPoint` 로 충분.)

## 5. 한계 (의도된 것)

- 트랙 내부 박자 흔들림/점진적 빨라짐은 보정 못 함 — v1 범위 밖.
- 첫 트랙이 엉성하면 이후 트랙도 그 위에 쌓임 — 단, 과개입 안 함이 초기 서비스엔 장점.
- 첫 유의미 노트 판정이 노이즈에 민감할 수 있음 → 임계값 튜닝 필요(샘플 회귀로 검증).

## 6. 작업 순서 제안

1. `firstMeaningfulStart` 헬퍼 + 임계 상수.
2. `commitPendingRecording` 3개 청크 경로 + 레거시 `analyze` 경로에 적용.
3. 디버그 로그 + 시트/카드 표시.
4. (선택) 카운트인 4비트, 스피커 메트로놈 기본 on.
5. 샘플 회귀(audio-regression)로 trim 임계값 검증 + 온디바이스 박자 체감 확인.
