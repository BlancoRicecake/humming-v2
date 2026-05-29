# Humming V2 (SoundLab) — MVP 스냅샷

> 기준일: 2026-05-29 · 이 시점을 **MVP 기능 작업 분기점**으로 고정.
> 이 문서 = 현재 상태 요약본(canonical). 상세 작업 로그/이력은 [STATUS.md](STATUS.md), 평가 기록은 [experiments/](experiments/).

---

## 1. 제품 한 줄 정의
허밍/비트박스를 녹음 → 로컬에서 분석 → MIDI/오디오로 변환·편집·재생하는 **오프라인 voice-to-MIDI 웹앱** (Dubler 2 류). 녹음 후 분석(record-then-analyze) 방식.

**하드 제약(불변):** 유료 API 없음 · 클라우드 없음(전부 localhost) · 모델 학습 없음(기성 pretrained/고전 DSP만) · 디버그 시각화 우선.

---

## 2. 현재 동작하는 전체 플로우
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
- **chunk 감지**: RMS 엔벨로프 + 히스테리시스 상태머신 + 긴 chunk 내부 세분화(RMS 골 / 피치 전조).
- **피치 인식**: librosa **pYIN** 단일 엔진, chunk별 트림+median+2단 fallback.
- **모드 자동 분기**: voiced/chunk 비율로 멜로딕 vs 퍼커션 판정. 멜로딕 복구(이웃 피치 차용).

### 3.2 Auto Key (추천 키)
- Krumhansl-Schmuckler(메이저/마이너), duration·confidence·voiced 가중 히스토그램 × 24 프로파일 상관.
- **confidence tier**: high(≥0.15)/mid(≥0.05)/low(<0.05) + thin-input 가드(노트<4 / unique PC<3 / <1s → penalty).
- 응답에 `detected_key`(tonic/scale/confidence/key_tier/key_applied) + `key_candidates`(top-3).

### 3.3 Pitch Assistant (키 밖 음 보정) — "틀릴 때 망치지 않는 보정"
- 키 밖 노트만 in-key 후보(아래/위) 생성, **voice-leading 비용**(raw 근접 최우선: `1.0·|c−raw|+0.35·|c−prev|+0.25·|c−next|`)으로 추천.
- **tier 게이트**: low→자동 보정 중단(추천만), mid→약보정(≤1.0st), high/수동→≤1.5st. 저 pitch-confidence(<0.2) 보류.
- 노트별 `pitch_original/assisted/candidates/source/in_key/correction_cents` + 억제 사유(`suppressed_reason`) 기록.
- **노트 편집**: 피아노롤/테이블 클릭 → 후보 선택기(원본 유지 포함), `source="user"`. 즉시 시각 반영.

### 3.4 역할별 악기 팔레트 + 코드 모드 (단일 악기 선택)
| 역할 | 악기 | 모드 |
|------|------|------|
| 드럼 | 퍼커션 입력 자동 → **Kick(36)/Snare(38)/HiHat(42)** 분류 | — |
| 베이스 | 베이스기타(33) / 신스베이스(39) | 단음 |
| 키보드 | 피아노(0) / 신스(90) | 단음 / **코드** |
| 기타 | 어쿠스틱(25) / 일렉(27) | 단음 / **코드** |
- **드럼 분류**: 청크 스펙트럼(저역비/centroid/ZCR) 휴리스틱. MIDI는 퍼커션을 채널 10으로 라우팅.
- **코드 모드**: detected_key 기준 **자동 다이아토닉 트라이어드**(루트+3음+5음)로 확장 → 피아노롤/재생/렌더/내보내기 반영. 편집은 단음 모드에서.

### 3.5 출력/디버그
- FluidSynth SF2 렌더(폴리포니·드럼 채널), mido MIDI 내보내기(악기 program·드럼 ch10·코드 동시 노트).
- 디버그: 파형/엔벨로프/chunk/피치 오버레이/피아노롤(provenance 색)/노트 테이블(cents·src·orig).
- `diagnose.py`(샘플별 히스토그램·top-3 키·노트별 cost/cents/사유 덤프), `/assist`(키·어시스턴트 빠른 재적용).

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
  envelope.py    Stage 3-4 chunk DSP
  pitch.py       Stage 5 pYIN
  key_detect.py  Auto Key (KS, score_keys, key_weight, 가드)
  assistant.py   Pitch Assistant + run_key_and_assistant(키+어시스턴트 단일 진입)
  drums.py       Kick/Snare/HiHat 분류
  scales.py      스케일/피치클래스
  midi_build.py  mido MIDI (드럼 ch10 라우팅)
  render.py      FluidSynth SF2 렌더
  schemas.py     Pydantic 모델
  diagnose.py    (standalone) 진단 덤프
  bin/           번들 FluidSynth 2.5.4
frontend/src/
  App.tsx                오케스트레이션(녹음→분석→결과/편집→재생/내보내기)
  lib/wav.ts             blob→mono WAV
  lib/api.ts             analyze/assist/render/export/samples
  lib/playback.ts        Tone.js 미리듣기 + SF2 WAV 재생
  lib/instruments.ts     역할별 악기 팔레트(program 매핑)
  lib/chords.ts          다이아토닉 트라이어드 확장
  hooks/useRecorder.ts   MediaRecorder
  components/             Waveform / PianoRoll / ControlPanel / NoteTable / SamplePicker / CandidatePicker
```

---

## 6. 스택 & 실행
- 백엔드: FastAPI(Python 3.11.9), librosa+numpy(2.0.2)+scipy+soundfile, mido, pyfluidsynth. (BasicPitch/TF 미사용 — 평가 후 제거)
- 프론트: React 18 + Vite + TypeScript, Tone.js, Canvas 직접 렌더.
- 내부 SR 22050, hop 256.
```powershell
cd backend; python -m venv .venv; .\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m uvicorn app.main:app --reload --port 8000
cd frontend; npm install; npm run dev   # http://localhost:5173 → /api → 8000
```
- SF2: `HUMMING_SF2_PATH`(기본 GeneralUser GS) · 샘플: `HUMMING_SAMPLES_DIR`(기본 Downloads\soundsample).

---

## 7. 검증 상태 (이 분기점 기준)
- 회귀: `2.연음`=7 / `4.Du`=24 노트, `5.비트`→percussive(Kick/Snare/HiHat 분포).
- 라이브: `/analyze`·`/assist`·`/render_audio`·`/export_midi` 정상. 코드 7→21 동시 노트, 드럼 ch10.
- 프론트 `npx tsc --noEmit` 통과.
- 제약 4종 모두 준수.

---

## 8. 알려진 한계 / 다음 작업
- **4단계 메인 멜로디(보컬) + 보컬 효과**: 미착수(다음 후보).
- **드럼 분류기**: `5.비트.wav` 1개로만 캘리브레이션 — 다른 비트박스로 임계값([drums.py](../backend/app/drums.py) 상단) 튜닝 필요. 오픈햇/탐 등 미분류.
- **"오리지널 무조건 WAV"**: 클라이언트 디코드 실패 시 raw 전송 폴백 잔존(완전 보장 미구현).
- **코드 모드**: 블록 코드만(기타 스트럼/7화음/파워코드 없음), 저신뢰 키에서는 폴백 메이저 트라이어드.
- **멀티트랙**: 현재 단일 악기 선택만(드럼+베이스+코드 동시 레이어링 없음).
- **저장/공유**: MIDI/WAV 다운로드만(공유·프로젝트 추가 미구현).
- **Auto Key**: 메이저/마이너만(모드/펜타토닉 자동 감지 없음), 상대조 모호성은 tier로 완화.
- **Tone.js 드럼 미리듣기**: 노트별 드럼 음색 구분 약함(SF2 렌더가 본 경로).
- **튜닝 상수**: key_detect/assistant/drums 상단 상수는 소수 샘플 기준 — 더 많은 입력으로 조정 여지.
