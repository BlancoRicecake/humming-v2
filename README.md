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

## 회귀 테스트
```powershell
cd backend
.\.venv\Scripts\python -m pytest tests/ -v
```

## 하드 제약
유료 API ✗ · 클라우드 ✗(전부 localhost) · 모델 학습 ✗(기성 pretrained/DSP만) · 디버그 시각화 우선. 상세·근거는 [`docs/STATUS.md`](docs/STATUS.md).
