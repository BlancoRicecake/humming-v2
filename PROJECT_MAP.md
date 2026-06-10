# PROJECT MAP — Humming V2 워크스페이스 지도

> 목적: 랜딩페이지 · 사운드랩 · 앱 · 실험 데이터셋이 한 곳에 섞여 생기는 혼동을 없애기 위한 **단일 기준 지도**.
> 본격 수정(대대적 리비전) 전 구조를 고정한다. 최종 갱신: 2026-06-07.

---

## 0. 한눈에 보는 구성

| 개념 | 위치 | 역할 |
|------|------|------|
| 🌐 **랜딩페이지** | `Humming V2/landing/` | 제품 소개 정적 사이트 (Vercel 배포) |
| 🔬 **사운드랩** | `Humming V2/frontend/` + `Humming V2/backend/` | **엔진을 앱에 탑재하기 전**, 로컬로 띄워 사운드 변환을 체크하는 실험 공간 (web UI + Python 엔진) |
| 📱 **앱** | `Humming V2/mobile/` | 실제 제품 (Flutter). 사운드랩에서 검증된 엔진을 탑재할 대상 |
| 🧪 **실험 데이터셋** | `Humtrack/datasets/` (repo 밖) | AVP / HumTrans / IDMT-SMT-DRUMS 등. backend 평가·튜닝 스크립트가 사용 |
| 📄 **문서** | `Humming V2/docs/` | 현황·계획·실험기록·법적문서·목업·QA |
| ⚙️ **인프라** | `Humming V2/infra/` | Cloudflare/R2, 알림, 배포 스크립트, DNS |
| 🗃️ **아카이브** | `Humming V2/_archive/` | 폐기된 실험 보관 (코드만, 재생성 가능한 venv/node_modules 제외) |

---

## 1. 워크스페이스 계층

```
Humtrack/                        ← 워크스페이스 컨테이너 (git 추적 안 함)
├── Humming V2/                  ← 메인 git repo (github: BlancoRicecake/humming-v2)
│   ├── landing/                 🌐 랜딩페이지 (index.html, styles.css, vercel.json, .vercel)
│   ├── frontend/                🔬 사운드랩 web UI (React + Vite + TS, :5173)
│   ├── backend/                 🔬 사운드랩 엔진 (FastAPI, :8000) + ML diag/train/eval 스크립트
│   ├── mobile/                  📱 앱 (Flutter: android/ios/lib/...)
│   ├── docs/                    📄 문서 (§3)
│   ├── infra/                   ⚙️ 인프라 설정
│   ├── _archive/                🗃️ 폐기물 보관 (ace-fusion 등)
│   ├── PROJECT_MAP.md           🧭 이 문서 (전체 기준 지도)
│   └── README.md
└── datasets/                    🧪 실험 데이터셋 (용량 커서 repo 밖에 둠)
    ├── AVP_Dataset/  HumTrans/  IDMT-SMT-DRUMS-V2/
    └── drum_eval_*.csv/json
```

---

## 2. 사운드랩(엔진) 핵심

- **파이프라인 9단계**: 입력 → 전처리(mono 22.05kHz) → RMS 엔벨로프 voiced 구간 → chunk 분할 → **pYIN** 피치 → Note 생성 → 키/스케일 양자화 → 재생/렌더(FluidSynth SF2) → MIDI export. 상세는 [docs/STATUS.md](docs/STATUS.md).
- **피치 엔진**: librosa **pYIN 단일**. (Basic Pitch는 평가 후 미채택 — STATUS §5. CREPE 경로는 메인 빌드에서 제거.)
- **실행**: `backend` → `uvicorn app.main:app --port 8000`, `frontend` → `npm run dev` (:5173, `/api/*`→8000 프록시).
- **하드 제약**: 유료 API ✗ / 클라우드 ✗ / 모델 학습 ✗(기성 pretrained·DSP만) / 디버그 시각화 우선.

## 3. 문서 지도 (`docs/`)

| 문서 | 성격 |
|------|------|
| `STATUS.md` | 사운드랩 **단일 기준 현황** — 현재상태 + 설계 근거·이력(구 MVP_SNAPSHOT 통합) |
| `opus-integration-plan.md` | 모바일 업로드 Opus 인코딩 연구·권고 (2026-06-02) |
| `experiments/` | 실험 **기록(.md/.txt)** — 드럼 파이프라인 계획, HumTrans 계획, 세션 요약, Basic Pitch 비교. *raw 출력(csv/json)은 `_archive/experiments/`로 이전* |
| `legal/` | 개인정보·환불·이용약관·심사노트 |
| `mockups/` | UI HTML 목업 | 
| `qa/` | QA 스크린샷 |
| `beat-alignment-v1.md`, `credits.md`, `mobile-ux-backlog.md`, `infra-*` | 보조 문서/다이어그램 |

---

## 4. 주의할 결합 관계 (이동 시 깨지는 것)

1. **datasets 경로 결합** — `backend/`의 진단/학습 스크립트가 `../../datasets/...` 상대경로로 루트 `Humtrack/datasets/`를 참조. → **`backend/`와 `datasets/`는 현 위치 고정.** (그래서 사운드랩을 별도 폴더로 묶지 않고 현 위치 유지 = "안전안".)
2. **랜딩 Vercel** — `landing/.vercel` + `vercel.json` 배포 링크. 이동 시 재연결 필요.
3. **모바일 Flutter** — `mobile/` 자체 완결. backend는 네트워크(:8000)로만 호출.
4. **포트** — 사운드랩 backend :8000 / frontend :5173. (폐기된 ace-fusion은 :8200/:8011/:5273을 썼음.)

---

## 5. 정리 이력 (2026-06-07)

- ✅ 실험 raw 출력(`docs/experiments/*.csv/*.json/*.npz`) → `_archive/experiments/` 이전.
- ✅ 폐기된 `labs/ace-fusion/` → `_archive/ace-fusion/` 이전 (소스만 3.8MB, `.venv`/`node_modules`/`.vite`/`out` 제외). 빈 `labs/` 제거.
- ✅ 루트 빈 `.git`(630MB 잔존물), 빈 `appicon-export/`, 떠도는 `*.log` 삭제.
- ✅ `STATUS.md` ← `MVP_SNAPSHOT.md` 통합(단일 현황), 옛 Desktop 경로 수정. `README.md` 현재 코드 기준 개정.
