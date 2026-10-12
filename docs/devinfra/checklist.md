# 개발·검증 인프라 체크리스트

계획: [`PLAN.md`](PLAN.md) · 시작일: 2026-10-12. 🖐 = Heo가 프롬프트를 붙여 넣어 실행하는 항목 (PC는 VS Code Claude Code, Mac은 Codex).

## 0. 지금 바로 (분실·재발 방지)

- [ ] 🖐 GitHub에 없는 브랜치 push — `codex/humtrack-first-song-funnel`, `codex/humtrack-feedback-plan` (P1 프롬프트)
- [ ] 🖐 PC doctor 결과·브랜치 현황표 저장 (P1 프롬프트)
- [ ] 현황표 보고 main 통합 순서 결정 (Claude와 같이)
- [ ] 🖐 transfer 폴더의 옛 `GoogleService-Info.plist`를 Mac 병합본으로 교체 (`MAC-REMOTE-SETUP.md`)

## 1. dev_doctor 도입

- [x] `infra/scripts/dev_doctor.py` + 단위 테스트 9개 (클라우드에서 통과, 과거 장애 재현 시나리오 확인)
- [x] `infra/dev-config-fingerprints.json` (Sentry 프로젝트 ID만 들어 있음)
- [ ] 🖐 PC에서 `python -m unittest infra/scripts/test_dev_doctor.py` 와 `python infra/scripts/dev_doctor.py` 실행 → 결과 공유
- [ ] PC·Mac 중 맞는 설정을 원본으로 정하고 그 기기에서 `--write-fingerprints` → 커밋
- [ ] 🖐 다른 기기에서 doctor `config` 전부 PASS
- [ ] `.gitignore`에 `.worktrees/` 추가

## 2. 브랜치·사본 정리

- [ ] main 통합 (출시된 브랜치부터: login-hotfix → fix/ios-firebase-plist → first-song-funnel → feedback-plan → desktop)
- [ ] 통합 후 `pubspec.yaml` 버전을 두 플랫폼 공통으로 맞춤 (Android 41 이후 번호)
- [ ] 바깥 worktree 정리 (`C:\dev\Handy_code\humtrack-songplan`, `C:\Users\jlion\.codex\worktrees\*`) — 미푸시 커밋 0 확인 후 `git worktree remove`
- [ ] 방치된 원격 브랜치 정리 (`claude/*`, `DAW`, `feat/*` 등) — 목록 확인 후
- [ ] 출시 태그 소급: 현재 스토어 버전 커밋에 `v1.0.10+39`(iOS), `v1.0.11+40`(Android)
- [ ] CI 트리거를 모든 브랜치 push로 확대 (`ci-mobile.yml`) — 통합 후 main에서 수정

## 3. 원격 Mac (Codex 프롬프트로 진행)

- [ ] 🖐 PC에서 `chore/devinfra` 브랜치 push (P1 프롬프트)
- [ ] 🖐 Mac Codex에 M1(상태 점검) 붙여 넣기 → 결과 요약을 Claude에게
- [ ] M1 결과로 Mac 정비 프롬프트(M2) 작성 — 도구 버전, 절전, 저장소 위치
- [ ] 🖐 Xcode 계정 로그인, iPad 페어링(USB 1회 → 네트워크) — 화면에서 직접
- [ ] Mac dev_doctor 전부 PASS
- [ ] Mac에서 `flutter build ios --debug --no-codesign`, `flutter build macos --debug` 성공

## 4. 실기기 검증 체계

- [ ] 🖐 Android 폰 USB 디버깅 → PC에서 `run.sh -d <id>` 성공
- [ ] 🖐 iPad에 Mac에서 `run.sh -d <id>` 성공 (같은 Wi-Fi일 때)
- [ ] main 기준 Actions `internal` 빌드 → Play 내부 / TestFlight 수신 확인
- [ ] 첫 스모크 기록 `docs/qa/<날짜>-<버전>.md`
- [ ] ✅ 완료 기준: main 한 커밋으로 Android 폰·iPad·Windows·Mac 네 곳에서 스모크 통과, 네 기기 doctor PASS
