> ⚠️ **SUPERSEDED** — 검토 결과 DDSP는 노트 정확도를 못 올리고(음성 피치 특성
> 보존), 재생은 이미 SoundFont로 충분함이 확인됨. 작업 방향은
> [`hybrid-pitch-note-editing-spec.md`](./hybrid-pitch-note-editing-spec.md)로 이관.
> 아래는 초기 검토 기록으로만 보존한다.

# DDSP 통합 작업 명세서 (Humming V2)

> 목적: 유저 음성 → 악기 트랙 변환의 **노트 추출 정확도**와 **재생 음색 품질**을
> Google Magenta DDSP 아이디어로 끌어올린다. 단, 편집 가능성과 오프라인/로컬-퍼스트
> 제약을 깨지 않는다.
>
> 이 문서는 **새 세션에서 단독으로 실행 가능**하도록 자족적으로 작성됨. 코드베이스
> 사전지식 없이도 따라올 수 있게 파일 경로·함수·스키마를 명시한다.

---

## 0. 배경 / 핵심 가설

원 가설: "음성을 DDSP로 악기음으로 바꾼 뒤, **악기음에서** MIDI를 추출하면
보컬에서 바로 추출하는 것보다 피치 정확도가 오른다."

**중요한 사실 점검 (이 명세의 전제):**

1. DDSP 표준 오토인코더(timbre transfer)는 **F0(피치)를 사전학습 CREPE로 추출**하고,
   **loudness는 DSP로 직접 계산**한다. 이 `(F0, loudness)` 제어 신호가 디코더 NN에
   입력되어 harmonic+noise 신디 파라미터를 만든다.
2. 따라서 "악기음 → 다시 피치추출 → MIDI"는 **CREPE가 이미 뽑은 F0를 손실 동반해
   재추출하는 순환 구조**다. 피치 정확도 이득의 실체는 "악기로 바꿔서"가 아니라
   **더 강건한 피치 추정기(CREPE) + loudness 컨투어를 노트화에 쓰는 것**에서 나온다.
3. DDSP 신디는 파형이 아니라 `(F0, loudness)` 제어 신호로 합성한다. 그래서 편집된
   MIDI를 제어 신호로 되돌려 디코더+신디에 넣으면, **원본 음성을 재인코딩하지 않고도**
   악기 사운드를 재생성할 수 있다. (편집-재생 분리가 가능)

→ 결론: 작업을 **두 트랙으로 분리**한다.
- **Track A (정확도, 저위험):** DDSP 합성 없이 CREPE F0/loudness를 노트화에 활용해
  정확도 가설을 먼저 검증. (필요 인프라 대부분 이미 존재)
- **Track B (음색, 고위험·옵션):** DDSP 합성을 **오프라인 배치 렌더** 경로로 추가.
  실시간 온디바이스 합성은 범위에서 제외.

---

## 1. 하드 제약 (위반 금지)

- **오프라인 / 로컬-퍼스트**: 분석·렌더는 로컬에서 동작해야 함. 외부 추론 API 금지.
- **유료 클라우드 API 없음.**
- **모바일(Flutter) 타깃**: 무거운 실시간 온디바이스 추론은 비현실적. DDSP 합성은
  서버/데스크톱 배치 렌더 또는 사전 렌더로 한정.
- **디버그 가시성 계약**: 새 중간 신호는 (a) `AnalyzeResponse`에 추가하고
  (b) UI 테이블 컬럼 또는 canvas 오버레이로 노출해야 한다. 플래그 뒤에 숨기지 말 것.
- **새 의존성/모델은 도입 전 `constraint-guardian` 에이전트로 검증** 필수
  (특히 TensorFlow 기반 DDSP, 추가 모델 가중치).

---

## 2. 현재 코드베이스 지형 (관련 부분만)

```
backend/app/
  analyze.py    파이프라인 본체. L443 부근에서 opts.pitch_model == "crepe" 분기로
                extract_pitch_crepe / extract_pitch_pyin 선택. notes 생성.
  pitch.py      extract_pitch_pyin (기본) / extract_pitch_crepe (opt-in).
                반환 계약: (times, hz, voiced_flag, voiced_prob).
                CREPE는 bin/crepe/crepe-tiny.onnx 우선, 없으면 torchcrepe(dev).
  schemas.py    AnalyzeOptions(L18), Note(L72), PitchTrack(L133, model 필드 있음),
                AnalyzeResponse(L157).
  render.py     FluidSynth 직접 렌더. render_notes_to_wav(L205),
                render_tracks_to_wav(L285). SoundFont(SF2) 기반.
  main.py       /analyze, /process_vocal, /assist, /render_audio,
                /render_capabilities 등.
frontend/src/components/
  Waveform.tsx, PianoRoll.tsx, NoteTable.tsx (디버그 테이블), ControlPanel.tsx
```

핵심: **CREPE 백엔드는 이미 배선되어 있다.** loudness 컨투어 활용과 DDSP 합성만 신규.

---

## 3. Track A — 정확도 검증 (우선, 저위험)

### A1. CREPE 노트화 A/B 측정 (코드 변경 최소)
- `opts.pitch_model="pyin"` vs `"crepe"`로 동일 샘플셋 분석.
- `audio-regression` 에이전트로 노트 수/키/cost 드리프트 비교.
- 산출물: `docs/experiments/ddsp_crepe_ab.md` — 샘플별 노트 정확도(가능하면 GT 대비),
  octave-error 빈도, voiced_prob 분포 비교.
- **결정 게이트**: CREPE가 의미 있는 개선(특히 저음 허밍 octave 안정성)을 보이면 진행.

### A2. Loudness 컨투어를 1급 신호로 승격
- 현재 envelope/RMS는 있으나, DDSP식 **A-weighted loudness**를 별도 추출해
  노트 분절(onset/offset)·벨로시티 추정에 활용.
- `pitch.py`(또는 신규 `features.py`)에 `extract_loudness(y, sr) -> (times, loudness_db)`
  추가. (CREPE 없이 순수 DSP — 의존성 없음)
- **디버그 가시성 계약 준수**:
  - `schemas.py`에 `LoudnessTrack` 모델 추가 → `AnalyzeResponse`에 필드 추가.
  - `NoteTable.tsx` 컬럼 또는 `Waveform.tsx` 오버레이로 노출.
  - 변경 후 `debug-viz-enforcer` 에이전트로 계약 충족 확인.

### A3. (선택) F0 잔차 보존 — Track B의 준비물
- 노트별로 원본 `(f0_cents_residual[t], loudness[t])`를 저장하는 자료구조 설계.
  편집 시 미편집 노트는 잔차 재사용, 편집 노트만 재합성하기 위한 기반.
- `Note` 스키마에 옵셔널 `f0_contour` / `loudness_contour`(다운샘플)를 붙일지 결정.

---

## 4. Track B — DDSP 합성 (오프라인 렌더, 고위험·옵션)

> 게이트: Track A가 끝나고, `constraint-guardian`이 DDSP 의존성/모델을 통과시킨 뒤에만 착수.

### B1. 의존성·모델 검증
- DDSP는 TensorFlow 기반. 패키지 크기/런타임/라이선스, 사전학습 악기 모델 가중치의
  번들 가능성(오프라인) 검토. `constraint-guardian`으로 4대 제약 pass/fail 판정.
- 결과가 fail이면: 경량 대안(예: 단순 harmonic+noise 신디를 자체 구현하거나
  DDSP 추론을 데스크톱 전용 옵션으로) 제안하고 중단.

### B2. MIDI → 제어 신호 변환기
- 신규 모듈 `backend/app/ddsp_render.py`:
  - `notes_to_control(notes, sr, hop) -> (f0_hz[t], loudness_db[t])`
    - F0는 **비율 transpose**: 편집된 피치를 `f0 = base * 2**(semitones/12)`로 적용.
      (Hz 가산 금지 — cents 기준 비브라토 보존)
    - 미편집 노트: A3의 원본 잔차/loudness 재사용.
    - 편집 노트: MIDI 값에서 컨투어 합성(또는 원본 컨투어 transpose/time-stretch).
  - **노트 경계 보간(중요)**: 인접 노트 전이부 수십 ms의 F0를 크로스페이드/글라이드로
    이어 붙여 피치 점프 제거. (DDSP 합성 자체는 위상 연속이라 클릭은 안 나지만,
    F0 궤적의 자연스러움은 여기서 결정됨)
- `render_notes_to_wav`와 동일한 입출력 계약(WAV bytes)을 따르는
  `render_notes_ddsp_to_wav(...)` 추가 → 기존 SoundFont 경로와 **나란히 선택 가능**하게.

### B3. 엔드포인트 / 모드
- `/render_audio`에 `engine: "soundfont" | "ddsp"` 옵션 추가(기본 soundfont).
- DDSP는 **편집 확정 후 배치 렌더**로 호출. 실시간 미리듣기는 SoundFont 유지.
- 모바일은 서버 배치 렌더 결과(WAV/Opus)를 받아 재생.

### B4. 편집-재생 아키텍처 (결정 기록)
- 재생 시 음성 재인코딩 **불필요**. 디코더+신디는 고정, 입력 제어 신호만 MIDI에서 재생성.
- 합성은 전체 타임라인 1패스 → 미편집/편집 노트가 같은 패스에서 위상 연속으로 렌더됨.

---

## 5. 수용 기준 (Acceptance)

- **A1**: CREPE vs pYIN 정량 비교표 존재, octave-error·노트 수 드리프트 수치화,
  진행/중단 결정 근거 기록.
- **A2**: `AnalyzeResponse`에 loudness 신호 노출 + UI 가시화, `debug-viz-enforcer` 통과.
- **B (착수 시)**: `engine=ddsp`로 편집된 MIDI를 렌더했을 때
  (1) 클릭/갭 없음, (2) 한 노트 transpose 후 전이부 피치 점프 없음(보간 동작),
  (3) 미편집 구간 표현력(비브라토/다이내믹) 보존.
- 모든 단계: `audio-regression`으로 기존 샘플셋 회귀 없음 확인.

## 6. 권장 진행 순서 (체크리스트)

- [ ] A1: CREPE/pYIN A/B 측정 → 결정 게이트
- [ ] A2: loudness 추출 + 스키마/UI 노출 + debug-viz 검증
- [ ] A3: 노트별 F0/loudness 잔차 보존 설계
- [ ] (게이트) constraint-guardian로 DDSP 도입 가부 판정
- [ ] B2: MIDI→제어신호 변환기 + 경계 보간
- [ ] B3: /render_audio engine=ddsp 경로
- [ ] B 수용 기준 검증 + 회귀 테스트

## 7. 열린 질문 (착수 전 결정 필요)

1. DDSP 합성을 **서버 전용**으로 둘지, **데스크톱 옵션**까지 열지? (모바일은 배치 결과 수신만)
2. 지원 악기 수 = DDSP 모델 수. 초기엔 1~2종으로 제한할지?
3. `Note` 스키마에 컨투어를 인라인할지, 별도 사이드카(audio_id 기준)로 저장할지?
4. constraint-guardian가 DDSP(TensorFlow)를 reject할 경우의 폴백(자체 harmonic+noise 신디)?

---

### 부록: 관련 에이전트
- `dsp-analyst` — A1/A2/A3, B2 변환기·보간 로직
- `debug-viz-enforcer` — A2 가시성 계약
- `constraint-guardian` — B1 의존성/모델 게이트
- `audio-regression` — 전 단계 회귀 확인
- `backend-api` — /render_audio engine 옵션, 엔드포인트
- `canvas-viz` — loudness/F0 오버레이 UI
