# Humming V2 (SoundLab) — 현황 (STATUS)

> 최종 갱신: 2026-06-07 · 작업 경로: `c:\Users\jlion\Documents\Humtrack\Humming V2`
> **단일 기준 현황 문서** (구 `MVP_SNAPSHOT.md` 통합). 워크스페이스 전체 지도 = [PROJECT_MAP.md](../PROJECT_MAP.md). 실험 기록 = [experiments/](experiments/).
> 한 줄 요약: **chunk 분할 + pYIN 피치 파이프라인 안정화(사용자 만족)** + Auto Key / Pitch Assistant / 역할 악기 팔레트·코드 모드 구현. Basic Pitch는 평가 후 미채택(§9.2).

---

## 1. 제품 정의 & 하드 제약

허밍/비트박스를 녹음 → 로컬에서 분석 → MIDI/오디오로 변환·편집·재생하는 **오프라인 voice-to-MIDI 웹앱**(Dubler 2 류). **녹음 후 분석(record-then-analyze)** 방식 (실시간 아님).

**하드 제약(불변):**
1. 유료 API 없음
2. 클라우드 없음 — 전부 localhost
3. 모델 학습 없음 — 기성 pretrained / 고전 DSP만
4. 디버그 시각화(파형·엔벨로프·피치 오버레이·피아노롤·노트 테이블) 우선 — 모든 중간 신호를 응답·UI에 그대로 노출

---

## 2. 현재 동작 플로우 (9-stage)

```
[1] 입력      브라우저 녹음(MediaRecorder) 또는 샘플/파일 → 클라이언트에서 mono 22.05kHz WAV 인코딩
[2] 전처리    디코드 → mono float32 22.05kHz → 피크 정규화
[3] 보이스    RMS 엔벨로프 + 적응형 히스테리시스(enter/exit)
[4] chunk     상태머신 forward pass → 병합/최소길이 → 내부 세분화(rms-dip / pitch)
[5] 피치      pYIN 1-pass → chunk별 대표 MIDI(median) + confidence + voiced_ratio
[6] 노트      chunk → Note. (멜로딕) 또는 퍼커션 자동 분기
[7] 키/보정   Auto Key(KS) → Pitch Assistant(키 밖 음 보정, 후보/추천)
[8] 악기      역할 팔레트(드럼/베이스/코드) 선택 + 코드 모드 → Tone.js 미리듣기 / FluidSynth SF2 렌더
[9] 출력      .mid (mido) / .wav (FluidSynth) 다운로드
```

---

## 3. 구현 완료 기능

### 3.1 분석 코어 (사용자 승인)
- **chunk 감지**(`envelope.py`): RMS 엔벨로프(frame 1024/hop 256, 5-tap median) + 적응형 히스테리시스 상태머신 + 긴 chunk(>0.30s) 내부 세분화(RMS 골 / 피치 전조). 병합 먼저 → 최소길이 필터 나중.
- **피치 인식**(`pitch.py` + `analyze._chunk_pitch`): librosa **pYIN** 단일 엔진. head 15%/tail 25% 트림 → 5-tap median → voiced median, 2단 fallback.
- **모드 자동 분기**: `voiced_notes/chunks < 0.55` → 퍼커션. 멜로딕 복구(피치 못 잡은 chunk는 이웃 피치 차용, confidence=0 표기).

### 3.2 Auto Key (추천 키, `key_detect.py`)
- Krumhansl-Schmuckler(메이저/마이너), duration·confidence·voiced 가중 히스토그램 × 24 프로파일 상관.
- **confidence tier**: high(≥0.15)/mid(≥0.05)/low(<0.05) + thin-input 가드(노트<4 / unique PC<3 / <1s → penalty).
- 응답: `detected_key`(tonic/scale/confidence/key_tier/key_applied) + `key_candidates`(top-3).

### 3.3 Pitch Assistant (키 밖 음 보정, `assistant.py`) — "틀릴 때 망치지 않는 보정"
- 키 밖 노트만 in-key 후보(아래/위) 생성, **voice-leading 비용**(`1.0·|c−raw|+0.35·|c−prev|+0.25·|c−next|`, 부른 음 근접 최우선)으로 추천.
- **tier 게이트**: low→자동 보정 중단(추천만), mid→약보정(≤1.0st), high/수동→≤1.5st. 저 pitch-confidence(<0.2)·1.5st 초과 보류(`suppressed_reason` 기록).
- 노트별 `pitch_original/assisted/candidates/source/in_key/correction_cents`.
- **노트 편집**: 피아노롤/테이블 클릭 → 후보 선택기(원본 유지 포함), `source="user"`, 즉시 시각 반영.
- 로직 단일화: `run_key_and_assistant`를 `/analyze`·`/assist`·`diagnose`가 공유.

### 3.4 역할별 악기 팔레트 + 코드 모드 (단일 악기 선택)
| 역할 | 악기 | 모드 |
|------|------|------|
| 드럼 | 퍼커션 입력 자동 → **Kick(36)/Snare(38)/HiHat(42)** 분류 | — |
| 베이스 | 베이스기타(33) / 신스베이스(39) | 단음 |
| 키보드 | 피아노(0) / 신스(90) | 단음 / **코드** |
| 기타 | 어쿠스틱(25) / 일렉(27) | 단음 / **코드** |
- **드럼 분류**(`drums.py`): 청크 스펙트럼(저역비/centroid/ZCR) 휴리스틱. MIDI는 퍼커션을 채널 10으로 라우팅.
- **코드 모드**(`lib/chords.ts`): detected_key 기준 **자동 다이아토닉 트라이어드**(루트+3음+5음) 확장 → 피아노롤/재생/렌더/내보내기 반영. 편집은 단음 모드에서.

### 3.5 출력/디버그
- FluidSynth SF2 렌더(폴리포니·드럼 채널), mido MIDI 내보내기(악기 program·드럼 ch10·코드 동시 노트).
- 디버그: 파형/엔벨로프/chunk/피치 오버레이/피아노롤(provenance 색)/노트 테이블(cents·src·orig).
- `diagnose.py`(standalone, 샘플별 히스토그램·top-3 키·노트별 cost/cents/사유 덤프 → `experiments/keyassist_diag.txt`), `/assist`(키·어시스턴트 빠른 재적용, pYIN 없이).

---

## 4. API
- `GET /health` · `GET /samples` · `GET /samples/{slug}`
- `POST /analyze` (audio + options) → notes + 디버그 + detected_key + key_candidates
- `POST /assist` (notes + options) → 키/어시스턴트만 재적용(pYIN 없이, 빠름)
- `GET /render_capabilities` · `POST /render_audio` (notes, program) → WAV · `POST /export_midi` (notes, program, tempo) → MIDI

---

## 5. 파일 맵
```
backend/app/
  main.py        FastAPI 엔드포인트
  analyze.py     메인 파이프라인 (Stage 2~7 + 퍼커션/멜로딕 분기)
  envelope.py    Stage 3-4 chunk DSP (RMS 엔벨로프, 상태머신, 세분화 splitter)
  pitch.py       Stage 5 pYIN + hz→midi
  key_detect.py  Auto Key (KS, score_keys, key_weight, 가드)
  assistant.py   Pitch Assistant + run_key_and_assistant(키+어시스턴트 단일 진입)
  drums.py       Kick/Snare/HiHat 분류
  scales.py      스케일/피치클래스 양자화
  midi_build.py  mido MIDI (드럼 ch10 라우팅)
  render.py      FluidSynth SF2 렌더 → WAV
  schemas.py     Pydantic 모델
  diagnose.py    (standalone) 진단 덤프
  bin/           번들 FluidSynth 2.5.4 (PATH 자동 주입)
frontend/src/
  App.tsx                오케스트레이션(녹음→분석→결과/편집→재생/내보내기)
  lib/wav.ts             blob→mono WAV  ← "오리지널 WAV" 핵심(§8)
  lib/api.ts             analyze/assist/render/export/samples
  lib/playback.ts        Tone.js 미리듣기 + SF2 WAV 재생
  lib/instruments.ts     역할별 악기 팔레트(program 매핑)
  lib/chords.ts          다이아토닉 트라이어드 확장
  hooks/useRecorder.ts   MediaRecorder
  components/             Waveform / PianoRoll / ControlPanel / NoteTable / SamplePicker / CandidatePicker
```
> 백엔드 최상위의 `diag_*.py` / `train_*.py` / `extract_*.py` / `eval_*.py` 는 실험·평가용 스크립트로, `../../datasets/` 를 참조한다(PROJECT_MAP §4).

---

## 6. 스택 & 실행
- 백엔드: FastAPI(Python 3.11.9), librosa+numpy(2.0.2)+scipy+soundfile, mido, pyfluidsynth. (BasicPitch/TF 미사용 — §9.2)
- 프론트: React 18 + Vite + TypeScript, Tone.js, Canvas 직접 렌더. 내부 SR 22050, hop 256.
```powershell
cd backend; python -m venv .venv; .\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m uvicorn app.main:app --reload --port 8000
cd frontend; npm install; npm run dev   # http://localhost:5173 → /api → 8000
```
- SF2: `HUMMING_SF2_PATH`(기본 GeneralUser GS) · 샘플: `HUMMING_SAMPLES_DIR`(기본 `Downloads\soundsample`).

### 6.1 디버그 노브 (ControlPanel / AnalyzeOptions 기본값)
| 노브 | 기본값 | Stage |
|------|--------|-------|
| fmin_hz / fmax_hz | 65 / 1000 | 2 |
| enter_ratio / exit_ratio | 0.20 / 0.12 | 3 |
| exit_hold_sec | 0.025 | 3 |
| min_chunk_dur_sec / merge_gap_sec | 0.06 / 0.04 | 4 |
| rms_dip_split / pitch_split | true / true | 4 |
| voiced_prob_threshold | 0.45 | 5 |
| key_tonic / scale / quantize_strength | null / null / 1.0 | 7 |

---

## 7. 검증 상태
- 회귀: `2.연음`=7 / `4.Du`=24 노트, `5.비트`→percussive(Kick/Snare/HiHat 분포).
- 라이브: `/analyze`·`/assist`·`/render_audio`·`/export_midi` 정상. 코드 7→21 동시 노트, 드럼 ch10.
- 프론트 `npx tsc --noEmit` 통과. 하드 제약 4종 준수.
- 샘플 라이브러리(기본 `Downloads\soundsample`): `1.왈츠`/`2.연음`/`3.take5`/`4.Du`(약 voiced)/`5.비트`(percussive). wav/m4a 혼재.

---

## 8. 알려진 한계 / 다음 작업
- **"오리지널 무조건 WAV"**: 클라이언트 디코드 실패 시 raw 전송 폴백 잔존(완전 보장 미구현). 상세 §9.3.
- **4단계 메인 멜로디(보컬) + 보컬 효과**: 미착수(다음 후보).
- **드럼 분류기**: `5.비트.wav` 1개로만 캘리브레이션 — 타 비트박스로 임계값(`drums.py` 상단) 튜닝 필요. 오픈햇/탐 미분류.
- **코드 모드**: 블록 코드만(스트럼/7화음/파워코드 없음), 저신뢰 키 → 폴백 메이저 트라이어드.
- **멀티트랙**: 단일 악기 선택만(드럼+베이스+코드 동시 레이어 없음).
- **저장/공유**: MIDI/WAV 다운로드만.
- **Auto Key**: 메이저/마이너만(모드/펜타토닉 자동감지 없음). Viterbi 보류.
- **튜닝 상수**: key_detect/assistant/drums 상단 상수는 소수 샘플 기준 — 더 많은 입력으로 조정 여지.

---

## 9. 설계 근거 & 이력 (왜 이렇게 됐나)

### 9.1 v2 정확도 — "틀릴 때 망치지 않는 보정" (2026-05-29)
목표는 더 똑똑한 보정이 아니라 **불확실하면 멈추는 것**.
- **진단 우선**: `diagnose.py`로 샘플별 히스토그램/top-3 키/margin/tier + 노트별 raw·후보·cost·cents·`suppressed_reason` 덤프.
- **confidence 정책**: thin-input 가드 + tier(high≥0.15/mid≥0.05/low<0.05). low→자동 보정 중단(추천만), mid→≤1.0st, high/수동→≤1.5st.
- **히스토그램 가중**: `key_weight = min(dur,0.8)·clamp(conf,0.10..1)·clamp(voiced,0.15..1)` — 긴 tail 독점·저신뢰 과대평가 방지.
- **효과**: 왈츠(키 margin 0.014 coin-flip) v1 7보정(오보정 포함) → v2 2보정. Du 11→3. 연음 큰 보정 차단.

### 9.2 Basic Pitch 평가 → 미채택 (2026-05-29)
> 결론: 평가 완료 후 **pYIN 유지, BP는 앱에서 제거**. 비교 로그 보존: [`experiments/bp_compare_result.txt`](experiments/bp_compare_result.txt).

BP는 하드 제약(유료X·클라우드X·학습X·로컬) 모두 통과하나 런타임(TF/onnx) 의존성이 무겁고 **폴리포닉 전사** 모델이라 출력 형태가 pYIN(모노포닉)과 근본적으로 다름.

| 샘플 | pYIN | Basic Pitch | 관찰 |
|------|------|-------------|------|
| 1 왈츠 | 18, mono | 21, mono | 거의 일치, BP가 지속음 잘게 쪼갬(가장 깔끔) |
| 2 연음 | 7 | 21, poly(겹침6) | BP 과분할 + 고음 유령노트(배음 오검출) |
| 3 take5 | 16 | 23, poly | 주선율 일치, 옥타브 유령 일부 |
| 4 Du | 24(D2 옥타브오류) | 27, poly | **BP가 pYIN 옥타브오류 교정** + C5/C#5 유령 |
| 5 비트 | 12 hits, percussive | 8, 피치부여 시도 | **BP는 타악 개념 없음** → percussive fallback 우월 |

**결정 근거**: ①명확한 단선율은 pYIN과 거의 동일 ②BP는 폴리포닉이라 유령 노트(amp 낮음) ③BP가 옥타브 오류 일부 교정 ④비트박스는 BP 부적합. → pYIN 유지. 재도입 시 모노포닉 강제 + amp 게이트 필요. (venv에 `basic-pitch`/`tensorflow`/`onnxruntime` 패키지는 import 안 됨 — 동작 영향 없음, 원하면 uninstall 가능.)

### 9.3 "오리지널은 무조건 WAV로 처리" 요구 (미해결)
- **요구**: 입력 오리지널 오디오는 항상 WAV로 처리되도록 보장.
- **현 동작**: 정상 경로는 클라이언트가 `encodeWav`로 mono WAV 업로드(✅). 단 **디코드 실패 시 raw 바이트 전송 폴백**이 있어 백엔드 `_load_audio`(soundfile/librosa m4a/mp3 폴백)로 흘러 "무조건 WAV" 보장이 깨짐.
- **관련 위치**: `frontend/src/lib/wav.ts`, `frontend/src/App.tsx`(폴백 분기), `backend/app/analyze.py`(`_load_audio`), `backend/app/main.py`(`/samples` 다포맷 허용).
- **방향 후보**: (A) 클라 디코드 실패 시 raw 전송 대신 에러 → 항상 WAV / (B) 백엔드 1차 WAV 정규화 후 정본 보관 / (C) 둘 다. (mobile Opus 업로드 도입은 [opus-integration-plan.md](opus-integration-plan.md) 참고.)
