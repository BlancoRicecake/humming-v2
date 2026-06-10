# ACE-Fusion Lab (서브 실험 프로젝트)

허밍 → 노트 → **ACE-Step 텍스트 기반 AI 음원** → CREPE 전사 → **편집 가능한 병합 MIDI** 를
로컬 웹에서 실험하는 격리된 서브프로젝트입니다.

> ⚠️ **격리 원칙**: 모바일 앱 · 랜딩페이지 · 기존 `backend/` · `frontend/` 코드를 **전혀 수정하지 않습니다.**
> 기존 백엔드(:8000)는 HTTP로 호출만 하고, 기존 프론트 편집 컴포넌트는 읽기 전용 import로 재사용합니다.
> 이 폴더(`labs/ace-fusion/`) 밖의 파일은 건드리지 않습니다.

## 무엇을 하나
1. HumTrans 허밍 샘플(3개) 선택 → 기존 `/analyze`(CREPE)로 **멜로디 노트** 추출
2. 노트를 `/render_audio`로 **깨끗한 멜로디 WAV** 로 재합성 (방법 B)
3. 그 오디오 + 텍스트 프롬프트를 **ACE-Step `cover`/`complete`** 에 투입 → AI 풀트랙 WAV
   - ACE-Step 미설치/미가동이면 자동으로 **Mock 생성기**로 폴백 (웹은 항상 끝까지 동작)
4. AI 오디오를 다시 `/analyze`(CREPE)로 **전사** → AI 트랙 노트
5. 멜로디 + AI 트랙을 피아노롤에 표시, **기존 편집 기능**(음정 후보 수정)으로 다듬고
   **멀티트랙 `.mid`** 로 내보내기

## 구조
```
labs/ace-fusion/
├── server/   FastAPI 오케스트레이터 (:8200) + ace_client(어댑터) + 샘플 3개
├── web/      Vite + React 실험 웹 (:5273), 기존 피아노롤/편집 컴포넌트 재사용
└── out/      생성된 오디오 임시 저장(런타임)
```

## 실행 (Windows PowerShell)

### 한 번에 (권장)
```powershell
cd "C:\Users\jlion\Documents\Humtrack\Humming V2\labs\ace-fusion"
./run_lab.ps1
```
→ 브라우저에서 **http://localhost:5273**

### 수동 (3개 터미널)
```powershell
# 1) 기존 백엔드 (:8000) — CREPE 위해 torch/torchcrepe 설치돼 있어야 함
cd "C:\Users\jlion\Documents\Humtrack\Humming V2\backend"
.\.venv\Scripts\python -m uvicorn app.main:app --port 8000 --reload

# 2) 랩 오케스트레이터 (:8200)
cd "C:\Users\jlion\Documents\Humtrack\Humming V2\labs\ace-fusion\server"
python -m venv .venv
.\.venv\Scripts\python -m pip install -r requirements.txt
.\.venv\Scripts\python -m uvicorn main:app --port 8200 --reload

# 3) 랩 웹 (:5273)
cd "C:\Users\jlion\Documents\Humtrack\Humming V2\labs\ace-fusion\web"
npm install
npm run dev
```

## ACE-Step 실제 연동 (선택)
미설치여도 Mock으로 전체 흐름이 동작합니다.

> 참고: 4GB GPU(MX570)에서 실제 생성이 GPU 0%로 정지(INT8+CPU오프로드 VAE 병목)
> 확인되어, 설치했던 `ACE-Step-1.5`(모델 9.4GB + venv 7GB)는 용량 회수를 위해
> **삭제했습니다.** ≥8GB GPU에서 쓰려면 아래로 재설치하세요:

```powershell
git clone https://github.com/ace-step/ACE-Step-1.5
cd ACE-Step-1.5
uv sync
uv run acestep-download   # 모델 번들(main) → ./checkpoints
```

ACE 서버 기동은 **반드시 동봉 스크립트**로 (중요 수정 사항이 들어있음):
```powershell
labs/ace-fusion/run_acestep.ps1     # UTF-8 모드 + :8011 + LLM off
```
이유:
- **PYTHONUTF8=1 필수** — 한글(cp949) Windows 로케일에서 ACE-Step이 내부
  em-dash(`—`)를 기본 코덱으로 쓰다 즉시 크래시함(작업 실패). UTF-8 모드로 해결.
- **포트 :8011** — 기본 :8001이 이 PC에선 다른 백엔드에 점유됨.

오케스트레이터를 ACE에 연결하려면 `ACE_BASE_URL`을 맞춰 기동:
```powershell
$env:ACE_BASE_URL="http://127.0.0.1:8011"; $env:ACE_TIMEOUT="1800"
# (server 폴더에서) uvicorn main:app --port 8200
```
환경변수:
- `ACE_ENABLE=auto|on|off` (기본 auto — ACE `/v1/models` 응답 시 자동 사용)
- `ACE_BASE_URL=http://127.0.0.1:8011`
- `ACE_TIMEOUT` 초 (기본 600)

### ⚠️ 4GB GPU(MX570) 주의
- DiT-only + INT8 + full offload + turbo 설정에서만 동작, 클립당 **수 분** 소요.
- **LLM(`thinking`) 비활성 필수** — 켜면 VRAM ~4GB 미해제 OOM(ACE-Step issue #198).
  이 랩은 요청 시 `thinking=false`로 강제합니다.
- `audio_duration`을 짧게(20~30s) 유지 권장.
- 요청 형식은 ACE-Step 1.5 `docs/en/API.md` 기준으로 맞춰져 있습니다
  (`POST /release_task` multipart + `src_audio` 파일 업로드, `task_type=cover`,
  `/query_result`의 `task_id_list`, 중첩 `result` JSON 파싱). 빌드가 다르면
  `server/ace_client.py`의 `_build_form`/`ace_generate`만 조정하세요.

## 알려진 한계 (실험적)
- ACE-Step은 음정 lock 보장이 없어 AI 트랙이 멜로디를 "느슨하게"만 따라갑니다.
- CREPE는 단음 전사라 AI 풀트랙의 다성부는 지배적 1개 라인만 MIDI화됩니다.
- 샘플 출처: HumTrans 데이터셋. `server/samples/reference_midi/`에 정답 MIDI 동봉(참고용).
