# 개발·검증 인프라 계획

작성일: 2026-10-12 · 위험 근거: [`RISK-REVIEW-2026-10-12.md`](RISK-REVIEW-2026-10-12.md) · 진행: [`checklist.md`](checklist.md) · 결정 기록: [`context-notes.md`](context-notes.md)

## 목표

Windows PC · Android 폰 · iPad · 원격 Mac에서 **"어느 기기에서 빌드해도 같은 코드, 같은 설정, 같은 결과"**가 나오게 한다. 지난 출시 장애 두 건(설정 누락 AAB, Mac의 옛 plist)이 다시 나지 않는 것이 1차 성공 기준이다.

## 원칙 다섯 가지

1. **기기당 저장소 사본 하나.** PC `C:\src\humming-v2`, Mac `~/src/humming-v2`. AI 에이전트(Claude Code, Codex)의 추가 작업 공간은 `.worktrees/` 아래에만 두고, 작업이 끝나면 그날 push한다.
2. **main이 기준.** 짧은 브랜치 → PR(CI 통과) → main. 출시 후보는 main에서만 만든다.
3. **출시용 서명 빌드는 GitHub Actions에서만.** `release-mobile.yml`이 이미 설정 검사·테스트·서명을 묶어 둔 유일한 경로다. 로컬 PC·Mac은 개발 빌드와 실기기 설치만 한다. 이로써 Mac에는 배포 인증서·운영 plist 같은 출시 비밀이 필요 없어진다.
4. **빌드 전에 `dev_doctor` 통과.** 도구 버전, 미푸시 커밋, 설정 파일의 키·형식·지문(해시)을 한 번에 검사한다. 지문 목록은 저장소에 커밋해 PC와 Mac이 같은 값을 쓰는지 비교한다 (값 자체는 커밋하지 않음).
5. **실기기 검증은 고정 스모크 + 기록.** 빌드마다 같은 항목을 같은 양식으로 남긴다.

## 기기 역할

| 기기 | 하는 일 | 앱을 받는 경로 |
|---|---|---|
| Windows PC | 주 개발, Android 디버그 빌드·설치, Windows 데스크톱 빌드, Actions 실행 | — |
| Android 폰 | 실기기 검증 | 개발 중엔 PC에서 USB/무선 `flutter run`. 출시 후보는 Play 내부 테스트 |
| 원격 Mac | iOS/macOS 네이티브 디버깅, macOS 앱 빌드·실행, Mac의 Claude Code 작업 | — |
| iPad | 실기기 검증 | Mac과 같은 네트워크면 Mac에서 `flutter run`. 떨어져 있으면 Actions → TestFlight 내부 |

## 원격 Mac 작업 방식 (결정, Heo)

**Mac의 Codex**로 한다. Claude가 Codex에 붙여 넣을 프롬프트를 만들고, Heo가 붙여 넣은 뒤 Codex의 결과 요약을 Claude에게 돌려준다. PC 작업은 VS Code의 Claude Code에 붙여 넣을 프롬프트로 같은 방식으로 진행한다. Tailscale·SSH는 쓰지 않는다.

프롬프트와 Mac 주의점: [`MAC-REMOTE-SETUP.md`](MAC-REMOTE-SETUP.md).

## 만드는 것

| 산출물 | 해결하는 위험 |
|---|---|
| `infra/scripts/dev_doctor.py` + `infra/dev-config-fingerprints.json` | 기기별 설정 불일치, 잘못된 DSN, 도구 버전 차이, 미푸시 커밋 (A2, B7–B8, C13–C14) |
| `dev_doctor.py branches` 현황표 | 흩어진 브랜치·worktree 파악 (A1–A5) |
| [`WORKFLOW.md`](WORKFLOW.md) | 사본·브랜치·출시 규칙 (A, C15–C16) |
| [`MAC-REMOTE-SETUP.md`](MAC-REMOTE-SETUP.md) | 원격 Mac 막힘 (E23–E25) |
| [`DEVICE-TEST.md`](DEVICE-TEST.md) | 실기기 검증·출시 후 확인 (D18–D22, F26) |

## 하지 않는 것 (이번 범위 밖)

- 기존 워크플로·fastlane 수정. 브랜치 통합 전에 고치면 다른 worktree와 충돌한다. CI 트리거 확대는 체크리스트에 남긴다.
- 비밀번호 관리자 도입. 지문 검사로 불일치는 잡히므로, 보관 방식 변경은 필요해지면 따로 한다.
- 데스크톱 CI. 데스크톱 트랙 D1에서 다룬다.
