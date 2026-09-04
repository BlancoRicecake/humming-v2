# Humming V2 — SoundLab (voice-to-MIDI)

허밍/비트박스를 녹음해 **로컬에서** 단선율 MIDI/오디오로 변환·편집·재생하는 오프라인 voice-to-MIDI 웹앱.
Dubler 2 류이되 완전 오프라인: 브라우저 녹음 → Python 백엔드 분석 → 시각화/편집 → `.mid`/`.wav` 내보내기. **유료 API·클라우드·모델 학습 없음.**

> 📍 **먼저 읽기**
> - 워크스페이스 전체 지도(랜딩/사운드랩/앱/데이터셋 위치·역할): [`PROJECT_MAP.md`](PROJECT_MAP.md)
> - 사운드랩 상세 현황·설계 근거·로드맵: [`docs/STATUS.md`](docs/STATUS.md)
>
> 이 README는 **사운드랩(엔진 실험용 web: `frontend/` + `backend/`) 실행법** 위주다.

## 구성 (요약)
| 위치 | 역할 |
|------|------|
| `frontend/` + `backend/` | 🔬 **사운드랩** — 엔진을 앱에 탑재하기 전 로컬로 사운드 변환을 체크하는 실험 공간 |
| `mobile/` | 📱 **앱** (Flutter) — 검증된 엔진을 탑재할 제품 |
| `landing/` | 🌐 랜딩페이지 (Vercel) |
| `../datasets/` | 🧪 실험 데이터셋 (backend 평가/튜닝 스크립트가 `../../datasets/`로 참조) |

## 파이프라인 (현재 코드 기준, 9-stage)
입력(브라우저 녹음/샘플) → 전처리(mono 22.05kHz) → RMS 엔벨로프 voiced 구간(`envelope.py`) → chunk 분할(상태머신 + 내부 세분화) → **pYIN** 피치(`pitch.py`) → Note 생성(멜로딕/퍼커션 자동 분기) → Auto Key + Pitch Assistant(`key_detect.py`/`assistant.py`) → 재생(Tone.js)/렌더(FluidSynth SF2, `render.py`) → MIDI export(mido, `midi_build.py`).

> 피치 엔진은 **librosa pYIN 단일**. (Basic Pitch는 평가 후 미채택, CREPE 경로는 메인 빌드에서 제거 — [STATUS §9.2](docs/STATUS.md).)

## 실행

### 백엔드 (Python 3.11 권장)
```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m pip install pyfluidsynth   # 선택: SoundFont 미리듣기
.\.venv\Scripts\python -m uvicorn app.main:app --reload --port 8000
```

#### SoundFont(FluidSynth) 미리듣기 — 선택
`/render_audio`는 사용자 SF2(GeneralUser GS)를 FluidSynth로 합성한다. 번들 FluidSynth 2.5.4 win64가 [`backend/bin/`](backend/bin/)에 있고 백엔드가 시작 시 PATH에 자동 추가한다.
- `HUMMING_SF2_PATH` — 미설정 시 `/render_capabilities`가 `soundfont_available:false` + error 반환.
```powershell
curl http://127.0.0.1:8000/render_capabilities   # soundfont_available 확인
```

### 프론트엔드
```powershell
cd frontend
npm install
npm run dev   # http://localhost:5173, /api/* → 127.0.0.1:8000 프록시
```

## 회귀 테스트 (CI와 동일)
GitHub Actions가 **바뀐 영역만** 자동으로 돌린다 — `backend/**` → [`ci-backend.yml`](.github/workflows/ci-backend.yml), `mobile/**` → [`ci-mobile.yml`](.github/workflows/ci-mobile.yml). 둘 다 main 푸시 + PR 트리거이고, 검증 전용(배포/시크릿 없음)이다. 아래 명령이 CI가 실행하는 것과 동일하니 푸시 전에 로컬에서 통과시킬 것.

### 백엔드 — pytest (153 tests)
```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements-test.txt   # = requirements.txt + pytest
.\.venv\Scripts\python -m pytest tests -q
```
기대 결과: **`153 passed, 11 skipped`**.
- **ffmpeg 바이너리가 PATH에 있어야 한다.** `tests/test_autotune.py::test_endpoint_undecodable_upload_is_400`이 디코드 실패 경로를 타므로, 없으면 이 테스트 하나만 `500 {"detail":"ffmpeg binary not available on server"}`로 실패한다. Windows는 `winget install Gyan.FFmpeg`, CI(ubuntu)는 `apt-get install -y ffmpeg`.
- **`requirements-dev.txt`는 테스트에 쓰지 말 것.** torchcrepe → torch(CPU, ~2GB)를 끌어오는데 테스트는 이를 전혀 import하지 않는다(CREPE A/B 실험 전용).
- skip 11개는 `tests/test_cloud_sync.py` — `TEST_USER_JWT` 등 **라이브 Supabase 자격증명**이 있어야 돈다. CI는 자격증명을 주지 않으므로 skip이 정상 상태다.

### 모바일 — analyze + flutter test (132 tests)
```powershell
cd mobile
flutter pub get
flutter analyze --no-fatal-infos
flutter test
```
기대 결과: **`4 issues found`(전부 info) + `All tests passed!`**.
- Flutter **3.47.1 stable** 기준(CI가 핀으로 박아둔 버전). `pubspec.lock`이 Dart `>=3.10.0-0`을 요구한다.
- `flutter analyze`는 **기본값이 `--fatal-infos`**라 알려진 deprecation info 4건만으로도 exit 1이 된다. `--no-fatal-infos`를 붙여야 하며, warning/error는 그대로 fatal이다(에러 0 유지가 기준선).
- `flutter analyze`가 `mobile/analysis_options.yaml`에 `analyzer: exclude:` 블록을, `pub get`이 `pubspec.lock`을 자동으로 고쳐 쓸 수 있다 — **커밋하지 말 것**(`git checkout -- mobile/analysis_options.yaml mobile/pubspec.lock`).

## 하드 제약
유료 API ✗ · 클라우드 ✗(전부 localhost) · 모델 학습 ✗(기성 pretrained/DSP만) · 디버그 시각화 우선. 상세·근거는 [`docs/STATUS.md`](docs/STATUS.md).
