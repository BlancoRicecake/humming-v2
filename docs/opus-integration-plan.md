# Opus 인코딩 도입 — Research & 권고안

**작성일**: 2026-06-02
**대상**: Humming V2 (SoundLab) — 모바일 녹음 → `/analyze` 업로드 파이프라인
**목표 효과**: 업로드 1/10, 서버 리샘플 제거, 글로벌 latency 흡수
**현재 상태**: 모바일은 `AudioEncoder.wav` (PCM16, 22.05kHz mono), 백엔드는 `_load_audio` 가 soundfile → librosa 폴백, 비-22050 입력은 무조건 `librosa.resample`

---

## 1. 모바일 권고 — `record: ^6.2.1`

### 결론: **`record` 가 Opus 를 직접 지원하므로 패키지 교체 불필요.**

`record: ^6.x` 의 `AudioEncoder` enum 은 다음을 노출한다 (pub.dev 기준):
- `wav`, `pcm16bits`, `aacLc`, `aacEld`, `aacHe`, `amrNb`, `amrWb`,
- **`opus`** (Android `MediaRecorder.OutputFormat.OGG` + `AudioEncoder.OPUS`, iOS 16+ `AVAudioRecorder` + `kAudioFormatOpus`),
- `flac` (Android only).

권고 설정:
```dart
RecordConfig(
  encoder: AudioEncoder.opus,
  sampleRate: 16000,
  numChannels: 1,
  bitRate: 64000,         // 64 kbps — Hybrid/CELT 자동 선택 영역
  autoGain: false, echoCancel: false, noiseSuppress: false,
)
```
컨테이너는 플랫폼에 따라 Android=Ogg(.ogg), iOS=CAF/MP4 wrapped Opus. 백엔드가 ffmpeg 로 디코드하면 둘 다 투명.

### 위험
- **iOS 15 이하**: `kAudioFormatOpus` 미지원 → 런타임에 `AudioRecorder.isEncoderSupported(AudioEncoder.opus)` 체크 필수. 미지원이면 `AudioEncoder.aacLc` 64kbps 폴백 (record 기본, 무손실은 아니지만 음성 영역 충분).
- **Android API 29 이하**: Opus 인코딩 MediaRecorder 지원이 불완전 (API 29+ 권장). 동일하게 `isEncoderSupported` 게이트.
- iOS/Android 컨테이너 다름 → 서버는 확장자/매직바이트로 분기하지 말고 **항상 ffmpeg pipe 디코드**.

### 대안 패키지 (Opus 미지원 OS 환경 다수일 때만)
- **`flutter_sound: ^9.x`**: 자체 libopus 번들, OS 의존도 낮음. 단점: 패키지 크기 +3MB, `record` 와 API 이질, 권한 처리 중복. 도입 비용 큼 — 현재 `record` 가 정상 지원한다면 채택 불필요.
- **direct FFI libopus**: 오버엔지니어링. 권장하지 않음.

---

## 2. 백엔드 디코딩 권고

### 결론: **pydub 회피, `soundfile` (libsndfile ≥ 1.0.29) + ffmpeg 폴백**

후보 비교:

| 옵션 | 장점 | 단점 | 채택 |
|---|---|---|---|
| `soundfile` (libsndfile) | 기존 코드와 동일 호출, BytesIO 직접 | libsndfile ≥1.0.29 + libopus 필요. Ogg/Opus 만 지원, MP4-wrapped Opus 미지원 | iOS 컨테이너 처리 못함 → 단독 불가 |
| `pyogg` / `opuslib` | 가볍다 | Ogg/Opus 전용, MP4/CAF 미지원, 유지보수 미흡 | X |
| **ffmpeg subprocess (pipe)** | 모든 컨테이너 (Ogg/CAF/MP4) 처리, 리샘플도 한방에 가능 | ffmpeg 바이너리 의존 | **채택** |
| `pydub` | ffmpeg 래퍼지만 임시파일 강제 | 디스크 IO 추가 | X |

권고 구현 흐름: **soundfile 먼저 시도 → 실패 시 ffmpeg stdin pipe → s16le PCM stdout**. ffmpeg 한 콜로 디코드+모노다운믹스+리샘플까지 끝내면 `librosa.resample` 도 스킵.

### Dockerfile 추가 패키지
```
apt-get install -y --no-install-recommends ffmpeg libsndfile1
```
ffmpeg 만 있으면 libopus 코덱은 내부 포함. Fly.io 이미지 크기 +~50MB.

---

## 3. librosa 통합 패치 위치

**대상 파일**: `/Users/heojeongmin/WebstormProjects/humming-v2/backend/app/analyze.py`
**대상 함수**: `_load_audio(file_bytes)` (53–74행)

수정 스텁 (적용 X):
```python
def _load_audio(file_bytes: bytes) -> Tuple[np.ndarray, int]:
    bio = io.BytesIO(file_bytes)
    try:
        y, sr = sf.read(bio, dtype="float32", always_2d=False)
    except Exception:
        # Opus/CAF/MP4 → ffmpeg pipe 디코드 (이미 mono + TARGET_SR 로 강제)
        y, sr = _ffmpeg_decode_to_pcm(file_bytes, target_sr=TARGET_SR, mono=True)
    if y.ndim > 1:
        y = np.mean(y, axis=1)
    if sr != TARGET_SR:
        y = librosa.resample(y, orig_sr=sr, target_sr=TARGET_SR); sr = TARGET_SR
    # ... peak normalize 동일
```

신규 헬퍼: `_ffmpeg_decode_to_pcm(blob, target_sr=22050, mono=True)` — `ffmpeg -i pipe:0 -f s16le -ac 1 -ar 22050 pipe:1` 호출, stdout 을 `np.frombuffer(..., np.int16).astype(np.float32)/32768.0` 변환. 같은 모듈 내 `_load_audio` 위에 추가.

**리샘플 스킵 분기**: ffmpeg 호출 시 이미 `-ar 22050` 이므로 `sr != TARGET_SR` 분기에 절대 안 걸린다. 모바일이 16kHz 로 녹음해도 ffmpeg 가 알아서 리샘플 → 백엔드 코드 변경 최소. **CPU 25% 절감은 librosa.resample 호출 자체 제거가 아니라, scipy 보간 → ffmpeg swresample (SIMD) 이전에서 발생**.

추가로 `schemas.py` 의 `AnalyzeResponse` 에 디버그 필드 노출 권고:
- `input_codec: str` ("wav" / "opus" / "aac" — ffmpeg probe 결과)
- `input_sr: int`, `input_channels: int`, `input_bitrate_kbps: float | None`
- `decoded_via: "soundfile" | "ffmpeg"`

(SoundLab 컨벤션: 모든 분석 신호는 응답에 그대로 노출.)

---

## 4. 회귀 검증 절차 — audio-regression 에이전트 요청 형태

**입력**: `/Users/heojeongmin/WebstormProjects/humming-v2/samples/` 의 기존 WAV 전부.

**스텝 1 — 인코딩/디코딩 라운드트립 코퍼스 생성**
```
ffmpeg -i samples/<name>.wav -c:a libopus -b:a 64k -ac 1 -ar 16000 _tmp/<name>_opus64.ogg
ffmpeg -i _tmp/<name>_opus64.ogg -f wav -ac 1 -ar 22050 _tmp/<name>_opus64_decoded.wav
```
32kbps 도 동일 (`-b:a 32k`).

**스텝 2 — audio-regression 에이전트 호출**
> "다음 두 디렉터리 `samples/` (베이스라인) 과 `_tmp/*_opus64_decoded.wav` (Opus 64kbps 라운드트립) 를 `/analyze` 에 각각 통과시키고 다음 메트릭을 비교하라:
> - per-note pitch cents 차이 (median, p95)
> - per-note onset time 차이 (median, p95 ms)
> - note count 일치율 (matched / max(base, test))
> - detected_key tonic·scale 일치 여부
>
> 통과 기준: pitch p95 < 5 cents, onset p95 < 15ms, note count 일치율 > 98%, key 100% 일치.
> 통과 시 32kbps 동일 비교 수행. 통과한 최저 비트레이트를 권고치로 반환."

**스텝 3** — 추가로 폰 실녹음 코퍼스가 있으면 그것에 대해서도 동일 비교 (마이크 DSP + Opus 인코딩 조합 효과).

---

## 5. 위험 / 미확인 사항

| 항목 | 영향 | 완화 |
|---|---|---|
| iOS 15 이하에서 `AudioEncoder.opus` 미지원 | 일부 사용자 녹음 실패 | 런타임 `isEncoderSupported` 체크 + AAC LC 폴백 |
| Android API 29 미만 Opus 인코더 불안정 | 동일 | minSdk 상향 또는 폴백 |
| iOS Opus 컨테이너가 CAF/MP4 → soundfile 디코드 실패 | 백엔드 500 | ffmpeg 폴백 필수 |
| Fly.io 이미지에 ffmpeg 누락 | 디코드 전체 실패 | Dockerfile `apt-get install ffmpeg` 강제. 빌드시 `ffmpeg -version` 헬스체크 |
| 64kbps Opus 의 SILK 모드 전환 (보컬 single-mode) | 고배음 손실 가능 → pYIN voiced_prob 떨어질 수 있음 | 회귀 검증으로 실측. 영향 있으면 `-vbr on -application audio` 강제로 CELT 비중 ↑ |
| pYIN frame_length(2048 @ 22050 ≈ 93ms) vs Opus frame_size (20ms) | 정렬 어긋남 가능성 | Opus 프레임은 디코드 후 연속 PCM 으로 평탄화되므로 무관. 회귀로 onset p95 확인 |
| 16kHz mono → 22050 업샘플 시 8kHz 이상 대역 0 | 현재 pYIN 은 fmax=1000Hz 영역 사용 (보컬) → 영향 없음 | librosa.pyin fmax 확인 필요 |
| record 패키지의 `bitRate` 파라미터 실제 반영 여부 | iOS/Android 인코더가 무시할 수도 | 라운드트립 후 ffprobe 로 실측 비트레이트 검증 |

---

## 6. 권고 비트레이트 + 샘플레이트

### 시작점: **16kHz mono Opus 64 kbps, VBR on, application=audio**

근거:
- 16kHz 면 Nyquist 8kHz. 보컬 fundamentals 80–800Hz + 9–10차 배음(~8kHz) 영역까지 전부 보존. pYIN 의 fmax(보통 1kHz) 와 충돌 없음.
- 64kbps 면 Opus 가 Hybrid(SILK+CELT) 또는 CELT 모드로 동작 → 배음 보존. 32kbps 는 순수 SILK 로 떨어져 배음 마스킹 위험 (회귀로 확인 필요).
- `application=audio` 명시: VoIP 모드(SILK 강제)로 떨어지지 않게.

### 회귀 결과에 따른 분기
- 64kbps 회귀 통과 → 32kbps 시도. 통과 시 32kbps 채택 (업로드 추가 50% 절감).
- 64kbps 회귀 실패 (pitch p95 ≥ 5 cents) → 96kbps 또는 24kHz 샘플레이트로 상향. (단, 24kHz mono Opus 96kbps 면 WAV 22050 대비 여전히 1/5 절감.)

### 백엔드 TARGET_SR
**현재 22050 유지 권고.** 16kHz 로 백엔드까지 내리는 것은 별도 작업 — pYIN/envelope 의 hop=256 가정과 모든 상수가 22050 기준 캘리브레이션되어 있어, SR 변경은 회귀 전수 재검증 필요. Opus 도입과 분리.

---

## 부록 — 파일 인덱스
- 모바일 녹음 진입점: `/Users/heojeongmin/WebstormProjects/humming-v2/mobile/lib/audio/recorder.dart`
- 모바일 의존성: `/Users/heojeongmin/WebstormProjects/humming-v2/mobile/pubspec.yaml`
- 백엔드 디코드: `/Users/heojeongmin/WebstormProjects/humming-v2/backend/app/analyze.py` (`_load_audio`, 53행)
- 응답 스키마: `/Users/heojeongmin/WebstormProjects/humming-v2/backend/app/schemas.py` (`AnalyzeResponse`)
- 인프라 마스터: `/Users/heojeongmin/WebstormProjects/humming-v2/docs/infra-mvp.html` (450행: "클라이언트 16kHz mono Opus 64kbps")
- 회귀 코퍼스: `/Users/heojeongmin/WebstormProjects/humming-v2/samples/`
