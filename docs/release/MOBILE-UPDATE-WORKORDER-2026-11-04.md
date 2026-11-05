# 모바일 앱 업데이트 준비 · Claude/Codex 분담

2026-11-04 KST. 사용자 요청은 Android/iOS 앱을 먼저 업데이트하는 것이다.
Windows/Mac 프로그램 출시는 다음 순서이며 이번 신규 구현 범위가 아니다.
후속 사용자 지시: **iOS는 사용자가 별도 MacBook에서 작업한다.** 이 PC에서는 Android
후보·develop 반영·검증을 진행하고, iOS CI/서명 빌드/TestFlight는 실행하지 않는다.
공통 파일 변경의 iOS 영향과 Mac에서 이어갈 정확한 커밋·검사 명령만 인계한다.
코딩·관련 테스트는 기존 VS Code Claude, 빌드/스토어·설정·독립 검토는 Codex가 담당한다.

## 권한과 보존

- PR, main 병합, 공개 배포, 운영 DB/백엔드 교체, 고객 공지 게시를 하지 않는다.
- 사용자 답변으로 **develop에만 push 허용**, PR·공개 배포 금지를 확인했다.
  검토한 커밋의 develop push와 CI 관측은 Codex가 담당한다. Claude는 로컬 구현과
  커밋/검증까지만 수행하며 직접 push하지 않는다.
- 루트의 현재 미커밋 원본과 브랜치, 오류가 있는 changelogs 폴더를 보존한다.
  이전 아카이브/staging 앱 소스로 루트를 덮어쓰지 않는다. stash/reset/clean 금지.
- 검토 완료 후보는 `.worktrees/develop-integration`의 `23097b8` (11개 로컬 커밋),
  기준 origin/develop은 d1dfb24였다. 최신 원격과 루트의 후속 변경을 확인하고 차이가
  있으면 먼저 기록한다. 기존 검토 커밋의 이력을 보존하고 새 변경은 식별 가능하게 만든다.
- 모든 작업/추가 worktree/빌드/로그는 C:/src/humming-v2 안에서 한다.
  실제 후보 checkout의 mobile/에서 빌드하고 기존 build/를 재사용한다.
  별도의 축약 앱이나 예전 lib/ 사본을 빌드하지 않는다.
- 시크릿/키/keystore/plist 원문, 음원, artifacts, 독립 지식 메모와 Ableton 도구는
  Git에 넣지 않는다. 한 번에 git add -A 하지 않는다.

## Claude의 구현 및 코드 검증

1. 모바일 업데이트의 최소 변경만 수행한다. 저장/복구, 허밍, 모바일 로그인/결제,
   다운로드, 공지, 오류 수신 경로를 현재 후보 기준으로 확인한다. 이미 검토한 기존
   Windows/Mac/백엔드 통합 커밋은 보존하되 신규 프로그램 UI/설치 작업은 하지 않는다.
2. 내부44는 최신 UI 통합 수정 전 빌드다. 새 후보 버전은 1.0.14+45를 준비하되,
   Codex가 스토어 최고 번호를 확인하기 전에는 미사용 번호라고 확정하지 않는다.
   45가 이미 사용됐다면 Codex와 조율해 더 큰 번호로 정한다.
   changelogs/45.txt는 건강한 후보 checkout의 ko/en에 실제 변경만 적는다.
3. develop CI는 현재 테스트+디버그 컴파일만 하며 설치본/스토어 업로드를 제공하지 않는다.
   기존 release-mobile.yml의 destination=build/internal과 CI 역할을 명확히 기록한다.
   필요하다면 최소한의 모바일 검사/산출물 개선만 하되, push가 스토어 업로드·배포로
   이어지게 만들지 않는다. 기존 production/submit_ios lane은 실행하지 않는다.
4. 테스트용과 출시용 설정을 구분한다. release main.dart, 실제 공개 인증 설정,
   실제 서명 identity로 검사한다. QA 엔트리, mock plist, forcePro, 관리자 키를
   설치 가능한 후보에 사용하지 않는다. Sentry는 internal 환경/정확한 release를 쓴다.
5. 클라우드를 최종 앱 공개 범위에서 누락하지 않는다. 다만 운영 lifecycle006/008과
   백엔드/음원 공개는 미완료다. 기존 운영을 향해 클라우드를 임의로 켜지 않는다.
   당장 만드는 내부 앱의 cloud 플래그와 검증 가능 범위, 최종 공개 전 추가 조건을
   명시한다. 실제 서비스 검증 전 cloud ON 후보를 출시 준비 완료로 표시하지 않는다.
6. 현재 소스에서 analyze, 전체 앱 테스트, Android auth/release-helper 검사,
   저장/내보내기·계정/구독·공지·다운로드 회귀를 적절히 수행한다. 추가 테스트는
   의미 있는 회귀에 한한다. 기존 검증을 지우거나 skip을 늘려 통과시키지 않는다.
   승인된 ignored fixture는 최소한으로 보충하고 이유를 기록한다.
7. 제품 수정이 필요하면 Claude가 고치고 관련 검사를 재실행한다. 문제를 숨기는
   기본값/우회 코드를 넣지 않는다. final commit을 고정한 후 Codex가 실제 Android
   서명 빌드와 구조/서명/16KB/공개 설정/해시를 점검할 수 있게 준비한다.
8. 로컬 기능별 커밋은 가능하다. 산출물과 결과, 정확한 후보 브랜치/커밋,
   수정 목록/검증 결과/남은 실제 기기 항목을
   `artifacts/mobile-update-2026-11-04/CLAUDE-REPORT.md`에 남긴다.
   **Claude는 push/PR/스토어 업로드/공개 배포를 하지 않고 Codex 검토를 기다린다.**

## Codex 병행 작업

- 최신 Play/ASC 사용 빌드 번호, 기존 내부 테스트/릴리스 동작과 설정을 읽기 전용 확인.
- develop push 범위 답변 확인, 원격 선행 커밋과 CI/자동 배포 영향 검토.
- 기존 원본 업로드 키·공개 설정 보존. 값은 로그/채팅/Git에 노출하지 않는다.
- Claude 최종 소스/테스트 독립 검토 후 실제 서명 Android 후보를 빌드/검증한다.
  iOS는 Mac/CI 실행 가능 여부를 구분한다. debug/unsigned 결과를 설치본으로 취급하지 않는다.
- 실제 업데이트 설치·권한·청취·스토어 거래·계정 인증은 사용자에게 짧은 절차로 남긴다.
- 클라우드 운영 준비/잔여 보안/고지·보관 정책·Sentry/공지의 실제 수신 조건을
  모바일 기준으로 정리한다. 배포/정책 변경을 이 작업에 섞어 실행하지 않는다.

## 이전 검증 (이번 후보의 결과로 재표시하지 않음)

23097b8: analyze 0, 앱1123 pass/22 skip, Mac Store 매트릭스16 pass,
fixture 보충32 pass/3 skip, Linux339 pass/11 skip.
11/01 Android44 internal 업로드 완료. 최신 앱45의 설치·실제 거래·Sentry 수신 결과가 아니다.
기존 기록: `artifacts/develop-integration-2026-11-03/INTEGRATION-REPORT.md`,
`docs/release/ANDROID-INTERNAL-TEST-2026-11-01.md`.
