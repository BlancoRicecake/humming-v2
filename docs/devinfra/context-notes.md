# 개발·검증 인프라 컨텍스트 노트

## 2026-10-12 — 위험 검토와 인프라 1차

**요청 (Heo)** — PC·iPad·Android 폰으로 검증하고 원격 Mac으로 iOS·macOS 빌드·테스트. 개발·테스트·검증이 막힘 없이 돌도록 인프라부터. 과거 문제와 잠재 위험을 먼저 검토한 뒤 진행.

**Heo가 맡긴 결정** — 접속 방식 등은 "가장 알맞은 방법으로". Mac에도 같은 계정의 Claude가 있다.

**Claude가 정한 것과 이유**
- **원격 Mac은 Tailscale + macOS 원격 로그인(SSH), 화면은 필요할 때만 화면 공유.** 명령 한 줄로 반복 가능하고 PC의 Claude Code도 같은 방식으로 Mac을 부릴 수 있다. self-hosted 러너는 Mac에 출시 비밀을 두게 되어 제외.
- **출시 서명 빌드는 GitHub Actions만.** 출시 장애 두 건이 모두 로컬·수동 빌드 경로에서 났다. Actions에는 이미 설정 검사·테스트·서명이 묶여 있다. Mac에서 출시 비밀이 빠지는 효과도 있다.
- **시크릿 보관 방식은 그대로, 대신 지문 검사.** 비밀번호 관리자 도입은 새 도구·비용이 생긴다. 장애의 실제 원인은 "기기 간 불일치를 모름"이었으므로 해시 지문 비교로 먼저 잡는다.
- **도구는 Python 표준 라이브러리.** PC(백엔드 venv)와 Mac(기본 python3) 양쪽에 이미 있고, 저장소의 기존 도구(`test_android_auth_guard.py`, `infra/scripts/*.py`)와 같은 언어. Dart는 sha256에 외부 패키지가 필요하고, bash·PowerShell은 두 벌을 유지해야 한다.
- **기존 워크플로·fastlane은 수정하지 않음.** 브랜치가 흩어진 상태에서 고치면 다른 worktree와 충돌한다. 새 파일만 추가했다.

**확인된 사실 (이번 세션)**
- git ref 파일 기준: `codex/humtrack-first-song-funnel`(395e7cb), `codex/humtrack-feedback-plan`(e2c6691)은 원격 ref 없음. 로컬 `codex/humtrack-desktop`은 10-05에 origin/main(77f7c37)으로 fast-forward됨 → 앞서 로드맵 문서에서 "desktop에 이후 수정이 빠졌을 수 있다"고 쓴 추정은 main 기준으로는 해소됐을 가능성이 높다. 단 login-hotfix·ios-firebase-plist·first-song-funnel이 main에 들어갔는지는 git 실행으로 확인해야 한다.
- 작업 사본 위치: `C:\src\humming-v2`, `C:\dev\Handy_code\humtrack-songplan`, `C:\Users\jlion\.codex\worktrees\{35fd,76f2,humtrack-login-hotfix}`, `.worktrees\{mobile-quality,landing-product-update}`.
- PC의 `backend\secrets\humtrack-transfer\GoogleService-Info.plist`는 Sign-In 전용 옛 파일 (키 이름만 확인). PC에 `mobile/android/app/google-services.json` 없음.
- `.worktrees/`가 `.gitignore`에 없음.

**변경 (같은 날, Heo)**
- 설명이 어렵다는 피드백 → 앞으로 Heo에게는 "할 일 / 결정할 것" 형식으로만 전달한다.
- Mac 원격 작업은 Mac의 Codex로 한다. Claude가 붙여 넣을 프롬프트를 주고, 결과 요약을 돌려받는다. Tailscale·SSH 계획은 폐기. `MAC-REMOTE-SETUP.md`를 프롬프트 기록 문서로 바꿨다.
- PC 작업도 VS Code Claude Code에 붙여 넣는 프롬프트로 진행한다 (이 Cowork 세션은 PC에서 명령을 실행할 수 없음). 점검 스크립트를 Mac으로 옮기기 위해 `chore/devinfra` 브랜치를 push하기로 했다.

**검증**
- `test_dev_doctor.py` 9개 통과 (Python 3.13, 클라우드). 임시 git 저장소에서 잘못된 Sentry DSN, 지문 불일치, upstream 없는 브랜치, 미푸시 커밋, 바깥 worktree, Sign-In 전용 plist를 모두 FAIL/WARN으로 잡는 것 확인.
- **PC·Mac 실행은 아직 안 함.** 이 Cowork 세션은 PC에서 명령을 실행할 수 없다. Windows에서 `.bat`인 `flutter` 호출, `flutter config --list`의 jdk-dir 파싱은 실기 확인이 필요하다.
