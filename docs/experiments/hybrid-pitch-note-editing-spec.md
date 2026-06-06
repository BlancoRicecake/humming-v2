# 하이브리드 피치+노트 편집 — 작업 명세서 (Humming V2)

> 목적: 음성→악기 트랙의 **편집 정확도**를, "완벽한 자동 분절"을 쫓는 대신
> **연속 F0(피치) 레이어와 이산 노트 레이어를 둘 다 편집 가능**하게 만들어
> 사용자가 빠르게 교정할 수 있는 구조로 해결한다. 재생 표현력은 DDSP의
> *원리만* 따온 경량 harmonic+noise 신디로 보강(옵션).
>
> 이 문서는 **새 세션에서 단독 실행 가능**하도록 자족적으로 작성됨. 코드베이스
> 사전지식 없이 따라올 수 있게 파일·함수·스키마를 명시한다.

---

## 0. 결정 경위 (왜 이 구조인가)

검토 끝에 도달한 결론:

1. **pitch→note 분절 손실은 음성 고유 특성(스쿱·글라이드·비브라토·약한 onset)에서
   오며, 환원 불가능한 주관/의도 성분을 포함**한다. CREPE F0 교체로도 노트 단계
   정확도가 충분히 오르지 않았음(기 실험).
2. **DDSP는 이 손실을 못 줄인다** — timbre transfer는 음색만 바꾸고 피치 다이내믹스를
   보존하므로, 악기음으로 바꿔도 분절 난이도는 그대로다. (정보이론적으로도 합성은
   `(F0, loudness)`의 결정론적 함수라 새 정보가 없다.)
3. **재생은 이미 SoundFont(FluidSynth)로 빠르게 됨.** DDSP 풀 모델은 오프라인/모바일
   제약상 무겁고, 정확도엔 무관.
4. 그래서 전략 전환: **"완벽 자동 분절" 대신 "두 레이어 하이브리드 편집"** 으로
   사용자가 손실을 즉시 교정. 재생 표현력은 **DDSP 원리만 떼온 경량 HNM 신디**
   (= harmonic+noise / spectral modeling synthesis, 신경망 없음)로 옵션 보강.

→ 핵심 산출물은 **두 레이어가 연동되는 편집 모델**이다. DDSP 풀 모델은 범위에서 제외.

---

## 1. 하드 제약 (위반 금지)

- **오프라인 / 로컬-퍼스트**, **유료 클라우드 API 없음**, **모바일(Flutter) 타깃**.
- HNM 신디는 numpy/scipy(서버) 또는 Web Audio/Tone.js(클라) 수준의 경량 DSP로 구현.
  무거운 ML 프레임워크(TensorFlow 등) 도입 금지. 신규 의존성은 `constraint-guardian`
  에이전트로 사전 검증.
- **디버그 가시성 계약**: 새 중간 신호는 (a) `AnalyzeResponse`에 추가하고
  (b) UI 테이블 컬럼 또는 canvas 오버레이로 노출. 플래그 뒤 은닉 금지. 변경 후
  `debug-viz-enforcer` 에이전트로 확인.

---

## 2. 핵심 개념 — 연동되는 두 레이어

```
┌─ 피치 레이어 (연속) ──────────────────────────────────────┐
│  f0_contour[t] (cents, 노트 피치 기준 잔차) + loudness[t]    │
│  ← 스쿱/비브라토/드리프트 등 사람 연주 뉘앙스를 담음          │
└──────────────┬───────────────────────────────────────────┘
               │ 분절/양자화 (현 파이프라인)
┌──────────────┴── 노트 레이어 (이산) ──────────────────────┐
│  Note{ pitch, start, end, velocity, ... }                  │
│  ← 구조적 편집(이동/transpose/추가/삭제/병합/분할)          │
└───────────────────────────────────────────────────────────┘
```

**두 레벨 편집:**
- **노트 레벨(구조)**: 이동·transpose·추가·삭제·병합·분할. transpose 시 그 구간의
  `f0_contour`를 **비율 이동**(`f0 *= 2**(반음/12)`, cents 기준 비브라토 보존). 인접
  노트 경계는 짧은 크로스페이드로 글라이드 재생성.
- **피치 레벨(뉘앙스)**: 연속 F0 곡선을 직접 편집 — 스쿱 평탄화, 비브라토 감쇠,
  글라이드 그리기, 구간 옥타브 오류 보정, 드리프트 조정. (Melodyne식 피치 커브 편집)

**왜 이게 정확도 문제를 푸는가:** 자동 분절이 틀린 바로 그 케이스(잘못 병합/분할된
노트, 스쿱 때문에 median 피치가 빗나간 노트)를 사용자가 **노트 레벨에서 빠르게,
또는 피치 레벨에서 정밀하게** 고칠 수 있다. 모델을 완벽하게 만들 필요 없이 교정 비용을
낮추는 접근.

---

## 3. 데이터 모델 변경 (backend/app/schemas.py)

현재 보유: `PitchTrack`(L133, 전역 times/hz/midi/voiced_prob/model), `EnvelopeInfo`(L116,
times/rms), `Note`(L72). 전역 F0/loudness는 이미 있으므로, **노트와 컨투어를 연결**하고
편집 가능한 형태로 노출하는 게 핵심.

- `Note`(L72)에 옵셔널 필드 추가 (하위호환 위해 모두 optional):
  - `f0_cents: Optional[List[float]] = None` — 노트 구간 F0의 cents 잔차(노트 pitch 기준), 다운샘플.
  - `loudness: Optional[List[float]] = None` — 노트 구간 loudness(dB), 다운샘플.
  - `contour_hop: Optional[float] = None` — 컨투어 샘플 간 시간 간격(s).
  - `edited_pitch_curve: bool = False` — 사용자가 피치 커브를 손댔는지(미편집 노트는
    원본 컨투어 재사용 → 재생 표현력 보존).
- (대안) 노트별 인라인 대신 **사이드카**로 전역 컨투어를 두고 노트는 `[start,end]`로
  슬라이스. 페이로드 크기 vs 편집 편의 트레이드오프 → §9 결정.
- 신규 디버그 표면이 생기면 `AnalyzeResponse`(L157)에 필드 추가.

---

## 4. 백엔드 작업

### B1. Loudness 컨투어 1급 추출
- `backend/app/features.py`(신규) 또는 `pitch.py`에
  `extract_loudness(y, sr) -> (times, loudness_db)` — A-weighted, 순수 DSP(무의존성).

### B2. 노트↔컨투어 연결
- `analyze.py`(노트 생성부, crepe/pyin 분기 ~L443 이후 세그먼트화 단계)에서 각 노트에
  해당 구간 F0를 **cents 잔차**로, loudness를 함께 슬라이스해 §3 필드 채움.
- 노트 피치(`pitch`) 결정 시 스쿱/릴리스를 제외한 **안정 지속 코어**의 통계를 쓰도록
  분절 로직 점검(부정확 median 완화). — `dsp-analyst`.

### B3. 편집 적용 API
- 기존 `/assist`(main.py L251, 키/어시스트 재실행)와 유사하게, 편집 결과를 받아
  컨투어를 재계산하는 경량 엔드포인트 또는 클라 로직 정의:
  - 노트 transpose → 구간 `f0_cents` 유지(잔차라 자동), 노트 pitch만 변경.
  - 노트 병합/분할 → 컨투어 슬라이스 경계 갱신 + 경계 크로스페이드.
  - 피치 커브 직접 편집 → 해당 노트 `f0_cents` 교체, `edited_pitch_curve=true`.

### B4. (옵션, 후순위) HNM 재생 신디 — "DDSP 원리만"
- `backend/app/hnm_render.py`(신규): `(f0_hz[t], loudness[t], harmonic_profile)` →
  가산 사인 합성 + filtered noise → WAV bytes. 신경망 없음.
- `render.py`의 `render_notes_to_wav`(L205)와 **동일 출력 계약**으로
  `render_notes_hnm_to_wav(...)` 추가. `/render_audio`에 `engine:"soundfont"|"hnm"`
  옵션(기본 soundfont). 편집된 노트 컨투어를 1패스 위상연속 합성.
- 게이트: SoundFont 대비 표현력이 체감되는지 §5 기준으로 검증 후 진행.

---

## 5. 프론트엔드 작업 (frontend/src/components)

- **PianoRoll.tsx**: 노트 위에 **피치 커브 오버레이**(노트별 `f0_cents`) 표시.
  노트 레벨 편집(드래그 이동/transpose/길이/추가/삭제) 유지·강화.
- **피치 레벨 편집 모드**(신규 or PianoRoll 내 토글): 곡선 직접 드래그/평탄화/비브라토
  감쇠. 편집 시 해당 노트 `edited_pitch_curve` 마킹.
- **Waveform.tsx**: loudness 컨투어 오버레이(디버그 가시성).
- **NoteTable.tsx**: `edited_pitch_curve`, 컨투어 요약(평균 cents 편차 등) 컬럼.
- **playback.ts**: 기존 SoundFont/Tone.js 경로 유지. HNM 엔진(B4) 도입 시 선택 토글.
- 담당: `canvas-viz`.

---

## 6. 수용 기준 (Acceptance)

- **편집 정확도**: 자동 분절이 틀린 대표 케이스(병합 오류/스쿱 median 오류)를 노트
  레벨·피치 레벨에서 각각 교정 가능, 결과가 MIDI/트랙에 반영.
- **재생 연속성**: 한 노트 transpose 후 전이부 피치 점프 없음(경계 보간 동작),
  미편집 구간 표현력(비브라토/다이내믹) 보존, 클릭/갭 없음.
- **가시성**: 컨투어/loudness가 `AnalyzeResponse`+UI에 노출, `debug-viz-enforcer` 통과.
- **회귀**: `audio-regression`으로 기존 샘플셋 노트 수/키/cost 드리프트 없음.
- **(HNM 도입 시)**: SoundFont 대비 표현력 우위가 블라인드로 체감되는지 정성/정량 비교.

---

## 7. 권장 진행 순서 (체크리스트)

- [ ] B1: loudness 추출 (무의존성 DSP)
- [ ] B2: 노트↔컨투어 연결 + 안정코어 기반 피치 결정 점검
- [ ] §3: 스키마 필드 추가 + `AnalyzeResponse` 노출 + `debug-viz-enforcer`
- [ ] 프론트: 피치 커브 오버레이 + 노트 레벨 편집 강화
- [ ] 프론트: 피치 레벨 편집 모드
- [ ] B3: 편집 적용 로직(transpose 비율 이동/병합·분할 경계 보간/커브 교체)
- [ ] `audio-regression` 회귀 확인
- [ ] (옵션) B4: HNM 신디 + `/render_audio engine=hnm`, SoundFont 대비 검증

---

## 8. 열린 질문 (착수 전 결정)

1. 컨투어 저장: `Note` 인라인 vs 전역 사이드카(payload 크기 vs 편집 편의)?
2. 피치 레벨 편집 UX: 별도 모드 vs PianoRoll 내 인라인 토글?
3. HNM 재생을 실제로 도입할지(SoundFont가 이미 충분하면 후순위/보류)?
4. 컨투어 다운샘플 해상도(편집 정밀도 vs 페이로드)?

---

### 부록: 관련 에이전트
- `dsp-analyst` — B1/B2/B3, HNM 신디(B4)
- `debug-viz-enforcer` — §3 가시성 계약
- `canvas-viz` — 피치 커브/노트 하이브리드 편집 UI
- `audio-regression` — 회귀 확인
- `backend-api` — `/render_audio` engine 옵션, 편집 엔드포인트
- `constraint-guardian` — 신규 의존성 게이트
