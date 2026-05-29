# Humming V2 (SoundLab) — 현황 총정리

> 최종 갱신: 2026-05-29
> 한 줄 요약: **chunk 분할 + pYIN 피치 인식 파이프라인이 안정화된 상태(사용자 만족).** Basic Pitch는 평가 후 미채택(서비스에서 제거, §5). 다음 과제는 "오리지널 입력을 무조건 WAV로 처리" 보장(§4).

이 문서는 이전 대화에서 합의된 설계와 **현재 코드의 실제 상태**를 한 곳에 모은 것이다.
README.md 는 일부 구버전(onset.py / grid.py / articulation / torchcrepe 기반) 설명이 남아 있어 **실제 코드와 어긋난다.** 신뢰 기준은 이 문서다.

---

## 0. Auto Key + 피치 어시스턴트 (2026-05-29 구현 완료)

6단계 서비스 플로우(Create→Record→Analyze→Result→Edit→Save)를 위한 두 핵심 기능을 **추가·옵트아웃** 방식으로 구현. 승인된 chunk+pYIN 코어는 불변, 피치 추출 이후 단계에만 더함.

- **Auto Key 감지** — `app/key_detect.py`: Krumhansl-Schmuckler(메이저/마이너만), duration 가중 피치클래스 히스토그램 × 24 회전 프로파일 상관. 기본 ON.
- **피치 어시스턴트** — `app/assistant.py`: key 밖 노트에 in-key 후보(아래/위 이웃) 생성, voice-leading(이웃 거리 최소, 동률 시 raw 근접→낮은 음)로 추천 자동 적용. 노트별 `pitch_original/assisted/candidates/source/in_key` 기록. 기본 ON.
- **빠른 재적용** — `POST /assist`: 이미 분석된 notes(`pitch_raw` 보유)에 key/어시스턴트만 다시 적용(pYIN 재실행 X). 클라이언트의 Key 변경·어시스턴트 토글에 사용.
- **노트 편집** — 피아노롤/테이블 클릭 → `CandidatePicker`로 후보(원본 유지 포함) 선택, `source="user"`로 로컬 반영(재생/내보내기에 즉시 반영, 오디오 재렌더는 수동 Play).
- **결과 표시** — 추천 Key, 보정 노트 개수, source별 색상(raw/보정/수정), Key=Auto/수동, 어시스턴트 ON/OFF (App.tsx Step-4 바).
- 검증: 강제 C major에서 `C-D-F#-G → F#→F`(spec 일치); 라이브 `/analyze`+`/assist` 통과; 회귀(연음=7, Du=24, 비트=percussive/key=None) 유지; `tsc` 통과.

### v2 정확도 개선 (2026-05-29) — "틀릴 때 망치지 않는 보정"
목표는 더 똑똑한 보정이 아니라, 불확실하면 멈추는 것. (계획 [nifty-prancing-dawn] 참고)

- **진단 우선**: `backend/diagnose.py`(standalone) — 샘플별 히스토그램/top-3 키/margin/tier + 노트별 raw·후보·cost·cents·`suppressed_reason` 덤프(`docs/experiments/keyassist_diag.txt`). API에도 `key_candidates`(top-3), `Note.correction_cents`, `DetectedKey.key_tier`/`key_applied` 노출.
- **confidence 정책**: `detect_key`에 thin-input 가드(노트<4 / unique PC<3 / 총<1s → confidence penalty). tier: high≥0.15 / mid≥0.05 / low<0.05. low → **자동 보정 중단**(추천만, `key_applied=false`), mid → 약보정(≤1.0st), high/수동 → ≤1.5st.
- **히스토그램 가중**: `key_weight = min(dur,0.8)·clamp(conf,0.10..1)·clamp(voiced,0.15..1)` — 긴 tail 독점·저신뢰 노트 과대평가 방지.
- **어시스턴트 비용식**: float(`pitch_raw`) 기준 `1.0·|c-raw| + 0.35·|c-prev| + 0.25·|c-next|` (부른 음 근접 최우선) + 보정 한계(저pitch-conf<0.2 / 1.5st 초과 → 보류, `suppressed_reason` 기록).
- **로직 단일화**: `assistant.run_key_and_assistant`를 `/analyze`·`/assist`·diagnose가 공유 → 정책 일관.
- **효과(덤프 전후)**: 왈츠(키 margin 0.014의 coin-flip) v1 7보정(±100¢ 넘는 오보정 포함) → v2 2보정(나머지 low_pitch_confidence/correction_too_large로 억제). Du 11→3. 연음 mid→큰 보정 차단.
- 상수는 `key_detect.py`/`assistant.py` 상단에 모음(덤프 보며 튜닝). Viterbi는 향후 과제로 보류.

---

## 0-2. 역할별 악기 팔레트 + 코드 모드 (2026-05-29, 1·2·3단계 구현)

한 테이크를 **하나의 악기로** 재생하는 단일 선택 구성. (4단계 보컬은 추후.)

- **1) 드럼**: `app/drums.py` `classify_drum` — 청크 오디오 스펙트럼(저역비/centroid/ZCR)으로 **Kick(36)/Snare(38)/HiHat(42)** 분류. analyze 퍼커션 분기에서 청크별 적용(`y`/`sr` 슬라이스). `5. 비트.wav` → `Kick HiHat Snare HiHat …` 패턴(4/2/6). midi_build는 퍼커션을 **채널 10(ch9)**으로 라우팅. (render는 이미 ch9/bank128 지원.)
- **2) 베이스**: 역할 팔레트에 베이스기타(33)/신스베이스(39). 기존 program 경로 재사용(렌더/MIDI 백엔드 무변경). 808 제외.
- **3) 코드 악기 + 코드 모드**: 키보드(피아노0/신스90)·기타(어쿠스틱25/일렉27), 단음↔코드 토글. `frontend/src/lib/chords.ts` `expandChords`가 detected_key 기준 **자동 다이아토닉 트라이어드**로 각 노트를 확장(루트+3음+5음). 렌더/MIDI는 동시 노트를 이미 처리 → 백엔드 무변경. 코드 모드 시 피아노롤에 화음 표시(편집은 단음 모드에서).
- 팔레트는 프론트 `lib/instruments.ts`(역할→GM program)로 정의, 선택 program을 `renderAudio`/`exportMidi`에 전달. (MIDI export가 이제 선택 program 반영 — 기존 0 하드코딩 수정.)
- 검증: tsc 통과, 회귀(연음7/Du24) 유지, 라이브 드럼 렌더·코드(7→21 note_on) MIDI/WAV 정상.

---

## 1. 제품 정의 & 하드 제약

- **무엇:** Dubler 2 스타일 로컬 voice-to-MIDI 웹앱. **녹음 후 분석(record-then-analyze)** 방식 (실시간 아님).
- **작업 경로:** `c:\Users\jlion\Desktop\Humming V2`
- **하드 제약 (절대 위반 금지):**
  1. 유료 API 없음
  2. 클라우드 없음 — 전부 localhost
  3. 모델 학습 없음 — 기성 pretrained / 고전 DSP만 사용
  4. 디버그 시각화(파형·엔벨로프·피치 오버레이·피아노롤·노트 테이블)가 UI polish보다 우선
- **우선순위:** 분석 정확도 + 디버그 가시성 > UI 미려함. 모든 중간 신호(엔벨로프, 피치 컨투어, voiced 확률, 노트 confidence)는 응답과 UI에 그대로 노출한다.

---

## 2. 기술 스택 (실제)

| 영역 | 구성 |
|------|------|
| 백엔드 | FastAPI (Python **3.11.9**), librosa + numpy + scipy + soundfile, mido |
| 피치 | librosa **pYIN** 단일 백엔드 (CREPE/torchcrepe 경로는 이 빌드에서 제거됨) |
| 사운드폰트 렌더 | pyfluidsynth + 번들 FluidSynth 2.5.4 win64 portable (`backend/bin/`) — 선택 기능 |
| 프론트 | React 18 + Vite + TypeScript, Tone.js(미리듣기), Canvas 직접 그리기(차트 라이브러리 없음) |
| 내부 처리 SR | 22050 Hz mono, hop=256 |

> 설치 확인됨: `basic-pitch`, `tensorflow`, `onnxruntime`, `tflite_runtime` 모두 **미설치**. 즉 현재 피치 엔진은 순수 pYIN. (§9 참고)

---

## 3. 파이프라인 (실제 코드 기준, 9-stage)

```
[1] 브라우저 녹음/샘플 입력
[2] 전처리      _load_audio: 디코드 → mono float32 22.05kHz → 피크 정규화
[3] 보이스 구간  RMS 엔벨로프 + 적응형 히스테리시스 임계값(enter/exit)
[4] chunk 분할   상태머신 forward pass → 후처리(병합/최소길이) → 내부 세분화
[5] 피치 분석    pYIN 1-pass → chunk별 대표 MIDI(median) + confidence + voiced_ratio
[6] 노트 생성    chunk → Note 이벤트, velocity = peak_rms 매핑
[7] 키/스케일    quantize_midi_to_scale (선택)
[8] 재생/렌더    Tone.js 또는 FluidSynth SF2 (백엔드 /render_audio)
[9] MIDI export  /export_midi → mido .mid
```

### 3.1 chunk 파악 — 현재 상태 ✅ (사용자 만족)
`backend/app/envelope.py`

- `compute_rms_envelope`: frame=1024, hop=256, 5-tap median 스무딩(≈58ms).
- `compute_thresholds`: RMS 분포 기반 적응형. noise_floor=15%ile, peak=95%ile(단일 트랜지언트 방지), enter=0.20·dyn, exit=0.12·dyn.
- `segment_chunks_streaming`: silence⇄active 상태머신 단일 forward pass + 히스테리시스 + `exit_hold_sec`(기본 25ms) 유지.
- `post_process_chunks`: **병합 먼저, 최소길이 필터 나중** (near-touching 두 조각을 먼저 합침). merge_gap=40ms, min_chunk_dur=60ms.
- 내부 세분화(0.30초 초과 chunk에만 적용 — 비브라토 오분할 방지):
  - `split_chunk_by_rms_dip`: 내부 RMS 골(peak의 40% 이하 local minima)에서 분할 → "같은 음 반복(소리 약해짐)" 케이스.
  - `split_chunk_by_pitch`: 스무딩 피치가 새 앵커로 ≥1 semitone, ≥120ms 유지될 때 분할 → legato 전조.

### 3.2 피치 인식 — 현재 상태 ✅ (사용자 만족)
`backend/app/pitch.py` + `analyze._chunk_pitch`

- 엔진: **librosa pYIN** (단일). `frame_length` 를 fmin에서 자동 산출(기본음 4주기 확보, 최소 2048).
- chunk별 대표 피치: head 15% / tail 25% 트림(글라이드인·릴리스 제거) 후 5-tap median 필터 → voiced 프레임 median.
- **2단 fallback:** voiced 프레임 ≥2 면 그 median, 아니면 pYIN이 피치를 잡았지만 voiced_prob가 낮은 경우(짧은/약한 어택 "두" 등) finite 프레임(≥3개, finite_ratio≥0.25)의 median을 신뢰.
- velocity: chunk peak_rms / global_peak → 20~120 매핑.

### 3.3 모드 자동 분기
- **percussive fallback:** `voiced_notes / chunks < 0.55` 이면 비트박스/드럼으로 판단 → 전 chunk를 GM Acoustic Snare(38)로 1:1 재발행.
- **melodic 복구:** 엔벨로프는 잡혔으나 pYIN이 피치를 못 잡은 chunk(노이즈 floor·3배 이상 peak)는 이웃 노트 피치를 빌려와 롤에서 사라지지 않게 함(confidence=0 으로 표시).

---

## 4. ⚠️ 다음 요구사항 ① — "오리지널은 무조건 WAV로 처리"

**요구:** 입력 오리지널 오디오는 항상 WAV로 처리되도록 보장해야 한다.

**현재 동작** (`frontend/src/App.tsx` `runAnalyze`):
1. 녹음/샘플 blob → `blobToMonoPcm`(Web Audio 디코드, mono 22.05kHz) → `encodeWav`(16-bit mono WAV) → `/analyze` 업로드. ✅ 정상 경로
2. **디코드 실패 시 raw 바이트를 그대로 전송하는 fallback 존재** → 백엔드 `_load_audio` 가 soundfile/librosa로 처리. ❗ 이 경로 때문에 "무조건 WAV" 보장이 깨짐.

**관련 코드 위치:**
- 클라이언트 WAV 인코딩: `frontend/src/lib/wav.ts` (`encodeWav`, `blobToMonoPcm`)
- fallback 분기: `frontend/src/App.tsx:58-80`
- 백엔드 다포맷 디코드: `backend/app/analyze.py:51-72` (`_load_audio` — m4a/mp3 librosa 폴백)
- 샘플 라이브러리: `backend/app/main.py` `/samples` (m4a/wav/mp3/flac/ogg/aif 허용)

**해결 방향 후보 (미구현):**
- (A) 클라이언트 디코드 실패 시 raw 전송 대신 **명확히 에러** 처리 → 항상 WAV만 업로드 보장.
- (B) 백엔드에 입력을 무조건 WAV로 정규화(soundfile write)하는 단계를 명시 추가하고, 그 WAV를 정본(canonical original)으로 보관/재생/분석에 사용.
- (C) 둘 다: 클라이언트 WAV 우선 + 백엔드 1차 WAV 정규화 후 파이프라인 진입.

> 결정 필요: "오리지널 WAV"가 (1) 업로드 포맷만 WAV 강제인지, (2) 서버가 원본 WAV 파일을 보관/제공해야 하는지에 따라 구현이 갈린다. 현재는 분석용 PCM만 메모리에 있고 원본 WAV를 디스크에 보관하지는 않는다.

---

## 5. 🔬 Basic Pitch 평가 → 미채택(서비스에서 제거)

> 결론 먼저: **평가 완료 후 pYIN 유지로 결정, BP는 앱에서 제거됨.** 아래는 평가 기록. 운영 코드 기준은 §3.2(pYIN).

**배경:** 현재 피치 엔진은 pYIN(모노포닉, chunk별 median). 사용자가 **Spotify Basic Pitch**가 SoundLab 입력에 대해 어떤 결과물을 만드는지 직접 비교해보고 싶어 함.

- **제약 충족 여부:** Basic Pitch는 pretrained(ICASSP 2022) 모델 + Apache-2.0 + 완전 로컬 + 무료 → **하드 제약(유료X·클라우드X·학습X·로컬) 모두 통과.** 단 런타임(tensorflow / onnxruntime / coreml / tflite 중 하나) 의존성이 무겁다.
- **현재 미설치:** §2 확인대로 백엔드 venv에 전혀 없음. 평가하려면 별도 설치 필요.
- **특성 차이:** Basic Pitch는 **폴리포닉 노트 전사** 모델(onset/offset/pitch/amplitude + pitch bend, MIDI 직접 출력). pYIN(모노포닉 컨투어)과 출력 형태가 근본적으로 다름.

### 5.1 실험 결과 (2026-05-29, 실행 완료) ✅

- 설치: `basic-pitch 0.4.0` + `onnxruntime`(실제로는 번들 TF saved_model로 추론). numpy 2.0.2→1.26.4 다운그레이드됨(제약 내 안전). tensorflow 2.15도 함께 설치됨(무겁지만 로컬·무료·학습X → 제약 통과).
- 격리 스크립트로 5개 WAV 전부 비교(스크립트·생성 오디오는 평가 후 제거). 비교 로그만 보존: [`docs/experiments/bp_compare_result.txt`](experiments/bp_compare_result.txt).
- Basic Pitch 호출은 앱과 동일 범위로 맞춤: `minimum_frequency=65, maximum_frequency=1000, minimum_note_length=58ms`.

| 샘플 | pYIN | Basic Pitch | 관찰 |
|------|------|-------------|------|
| 1 왈츠 | 18 notes, mono | 21 notes, **mono(겹침0)** | 피치·타이밍 거의 일치. BP가 지속음을 잘게 쪼갬. 가장 깔끔한 일치 |
| 2 연음 | 7 notes | 21 notes, **poly(겹침6)** | BP가 legato를 과분할 + **D5/F#5/A#5 고음 유령노트**(배음을 별도 노트로 오검출, amp≈0.3) |
| 3 take5 | 16 notes | 23 notes, poly(겹침3) | 주선율 피치 일치. C5/C#5 옥타브 유령노트 일부 |
| 4 Du | 24 notes (octave 오류 D2 포함) | 27 notes, poly(겹침5) | **BP가 pYIN의 옥타브 오류를 교정**(pYIN D2 raw37.8 → BP D3). 단 C5/C#5 유령 추가 |
| 5 비트 | 12 hits, **percussive 모드** | 8 notes, 피치 부여 시도 | **BP는 타악 개념 없음** → 비트박스엔 pYIN percussive fallback이 우월 |

**핵심 결론:**
1. **명확한 단선율(샘플1)에선 pYIN과 거의 동일** + BP는 노트별 pitch-bend(부드러운 글라이드)를 풍부하게 제공.
2. BP는 **폴리포닉**이라 지속/강한 보컬음에서 **고음 배음을 유령 노트로 추가**(amp 낮음 ~0.3) → amp 임계 필터 또는 모노포닉 후처리 필요.
3. BP가 pYIN의 **옥타브 오류를 일부 교정**(샘플4) — 험밍 피치 안정성에서 이점.
4. **비트박스/드럼은 BP 부적합** — pYIN의 percussive fallback 유지가 맞음.

### 5.2 결정 (2026-05-29) — **pYIN 채택, BP는 서비스에서 제거**

통합·청취 비교까지 마친 뒤 사용자 결정: **메인 엔진은 pYIN 유지, Basic Pitch는 서비스(앱 코드)에서 제거.**

- **앱 코드에서 제거됨:** `app/basic_pitch_engine.py`(삭제), `analyze.py`의 BP 분기, `schemas.AnalyzeOptions`의 `pitch_engine`/`bp_amp_threshold`/`bp_monophonic`, 프론트 `types.ts`/`App.tsx`/`ControlPanel.tsx`의 BP 항목, `requirements.txt`의 BP 선택 항목. 실험 스크립트와 생성 오디오(`docs/experiments/bp_out/`)도 제거.
- **현재 상태:** 앱은 다시 **pYIN 단일 엔진**. §3.2 그대로. BP 도입 전과 코드상 동일.
- **남은 잔여물(서비스 무관):** venv에 `basic-pitch`/`tensorflow`/`onnxruntime` 패키지는 설치된 채 남아 있음(앱이 import하지 않으므로 동작·성능 영향 없음). numpy는 1.26.4(설치 시 2.0.2→다운, 앱 제약 내). 완전 정리를 원하면 `pip uninstall basic-pitch tensorflow onnxruntime` 가능(선택).
- **재도입 시:** §5.1 결론(모노포닉 강제 + amp 게이트로 유령 제거, 비트박스는 percussive 유지)과 [`bp_compare_result.txt`](experiments/bp_compare_result.txt) 참고. 옵트인 백엔드로 다시 붙이면 됨.
- **평가 기록 보존 이유:** 결론을 남겨 동일 검토를 반복하지 않기 위함.

---

## 6. 샘플 라이브러리

기본 디렉터리: `C:\Users\jlion\Downloads\soundsample` (`HUMMING_SAMPLES_DIR` 로 변경). 현재 파일:

| 파일 | 성격 |
|------|------|
| `1. 왈츠.wav` / `1번 기본.m4a` | 기본 멜로디 / 왈츠(약한 박) |
| `2. 연음.wav` / `2번 연음.m4a` | legato 연음 |
| `3. take 5.wav` / `3번 빠르지만 스타카토.m4a` | 빠른 스타카토 |
| `4. Du.wav` / `4번 비트.m4a` | "두" 어택 (약한 voiced) |
| `5. 비트.wav` | 비트박스 → percussive fallback 대상 |

> wav / m4a 가 혼재. §4 "오리지널 무조건 WAV" 요구는 m4a 입력 경로와 직접 연관.

---

## 7. 파일 맵 (실제)

```
backend/app/
  main.py        FastAPI: /health /samples /samples/{slug} /analyze
                 /render_capabilities /render_audio /export_midi
  analyze.py     메인 파이프라인 (Stage2~7 + percussive/melodic 분기)
  envelope.py    Stage3-4 순수 DSP (RMS 엔벨로프, 상태머신 chunk, 세분화 splitter)
  pitch.py       Stage5 pYIN 래퍼 + hz→midi
  scales.py      다이어토닉/모달/펜타토닉 스케일 양자화
  midi_build.py  Note → .mid 바이트 (mido)
  render.py      FluidSynth SF2 직접 렌더 → WAV 바이트
  schemas.py     AnalyzeOptions / Note / Chunk / EnvelopeInfo / PitchTrack / AnalyzeResponse
backend/bin/     번들 FluidSynth 2.5.4 (PATH 자동 주입)
frontend/src/
  App.tsx                record→analyze→visualize→playback→export 오케스트레이션
  lib/wav.ts             blob→mono PCM, PCM→16bit WAV  ← "오리지널 WAV" 핵심
  lib/api.ts             /analyze /export_midi /render_audio /samples fetch
  lib/playback.ts        Tone.js 미리듣기 + HTMLAudio(SF2 렌더 재생)
  hooks/useRecorder.ts   MediaRecorder 훅
  components/            Waveform / PianoRoll / ControlPanel / NoteTable / SamplePicker
```

---

## 8. 디버그 노브 (ControlPanel / AnalyzeOptions 기본값)

| 노브 | 기본값 | Stage |
|------|--------|-------|
| fmin_hz / fmax_hz | 65 / 1000 | 2 |
| enter_ratio / exit_ratio | 0.20 / 0.12 | 3 |
| exit_hold_sec | 0.025 | 3 |
| min_chunk_dur_sec / merge_gap_sec | 0.06 / 0.04 | 4 |
| rms_dip_split / pitch_split | true / true | 4 |
| voiced_prob_threshold | 0.45 | 5 |
| key_tonic / scale / quantize_strength | null / null / 1.0 | 7 |

응답 디버그 신호: `envelope`(times/rms/임계값들), `pitch_track`(times/hz/midi/voiced_prob), `chunks`, `waveform.peaks`, 노트별 `confidence`·`voiced_ratio`·`pitch_raw`·`kind`.

---

## 9. 로드맵 위치

1. Humming → 모노포닉 MIDI — ✅ 완료
2. 스케일 양자화 — ✅ 완료
3. Ghost note 필터 + 동일음 병합 — ✅ 완료
4. Legato/staccato 자동 분류 — envelope chunk 기반으로 재구성 반영됨
5. 드럼 트리거 few-shot — percussive fallback로 기초만 존재
6. 코드(chord) 생성 — 미착수
7. 실시간 WebSocket — 미착수

**현재 단계:** chunk/피치(pYIN) 코어 안정화 완료(사용자 만족). Basic Pitch는 평가 후 미채택(§5). 다음:
- (A) §4 오리지널 WAV 처리 보장

---

## 10. 실행

```powershell
# 백엔드
cd backend
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m uvicorn app.main:app --reload --port 8000

# 프론트
cd frontend
npm install
npm run dev   # http://localhost:5173, /api/* → 127.0.0.1:8000 프록시
```

SF2 기본 경로: `HUMMING_SF2_PATH` (없으면 `/render_capabilities` 가 `soundfont_available:false` + error 반환).
```
```
