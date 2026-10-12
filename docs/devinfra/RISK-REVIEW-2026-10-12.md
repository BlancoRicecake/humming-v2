# 개발·검증 인프라 위험 검토 — 2026-10-12

목적: Windows PC · iPad · Android 폰 · 원격 Mac 네 기기로 개발·빌드·검증이 막힘 없이 돌게 하기 전에, 과거 장애와 잠재 위험을 한 곳에 모은다.

근거: `docs/`의 장애·배포·인계 문서, `.github/workflows/`, `mobile/{ios,android}/fastlane`, `mobile/tool/release_support.rb`, `mobile/scripts/run.sh`, `.git`의 ref·worktree·reflog 파일 (2026-10-12 PC에서 읽음). git 명령은 실행하지 못했으므로 **커밋 포함 관계(어느 브랜치가 main에 들어갔는지)는 미확인**이다.

---

## 1. 과거 장애에서 반복된 패턴

| 날짜 | 장애 | 직접 원인 | 공통 뿌리 |
|---|---|---|---|
| 2026-06 | iOS 녹음 중 합성음 지직거림 | PCM 버퍼 언더런 | 실기기에서만 재현 → 실기기 검증 경로 부족 |
| 2026-06 | 디버그 빌드가 출력 없이 종료, Clarity 누락 위험 | `run.sh`의 `set -e` 조기 종료, fastlane 시크릿 all-or-nothing 폴백 | 시크릿 주입 경로가 여러 개 |
| 2026-09-12 | iOS 컴파일 실패 (Swift 상수명) | Windows에서 네이티브 코드를 컴파일 없이 작성 | Mac 빌드가 늦게 돎 |
| 2026-09-15 | 스토어 제출 첫 실행 실패 | Billing 7 → 8 요구, Apple 대기 버전 충돌 | 스토어 규칙 변화, 수동 복구 |
| 2026-09-29 | Android 1.0.9 로그인 불가 → 프로덕션 롤백 | 설정 빠진 AAB를 공식 가드 밖에서 빌드·업로드 | **수동 빌드 경로가 가드 우회** |
| 2026-10-02 | iOS 1.0.9 실행 즉시 크래시 | Mac에 남아 있던 옛 `GoogleService-Info.plist` | **기기별 수동 설정 파일 불일치** |
| ~2026-10 | 모바일 Sentry 30일간 0건 | 다른 프로젝트의 DSN | **설정 값이 맞는지 검증하지 않음** |
| 2026-10-03 | iOS 크래시를 하루 넘게 못 봄 | Sentry는 Dart `main()` 이후 시작, 네이티브 시작 크래시는 못 잡음 | 모니터링 맹점 |

출시 장애 두 건 모두 코드 버그가 아니라 **"어느 기기에서, 어느 사본으로, 어떤 설정 파일로 빌드했나"**의 문제였다. 인프라의 1순위는 이것을 하나로 만드는 일이다.

---

## 2. 현재 위험 (심각도순)

### 🔴 A. 소스가 여러 곳에 흩어져 있음

1. **작업 사본이 최소 7곳**이다.
   - `C:\src\humming-v2` (현재 `codex/humtrack-desktop`)
   - `C:\dev\Handy_code\humtrack-songplan` (`codex/humtrack-product-analytics`) — 1.0.9 AAB가 여기서 빌드됨
   - `C:\Users\jlion\.codex\worktrees\35fd`, `76f2`, `humtrack-login-hotfix` (Codex 작업 공간)
   - `C:\src\humming-v2\.worktrees\mobile-quality`, `landing-product-update`
2. **origin에 없는 커밋**이 있다. `codex/humtrack-first-song-funnel` (Android 1.0.11 빌드 40), `codex/humtrack-feedback-plan` (빌드 41, 10-06)은 원격 ref가 없다. PC 디스크가 고장 나면 사라지고, Mac에서는 가져갈 수 없다.
3. **출시가 main이 아닌 기능 브랜치에서 나갔다.** 1.0.9는 product-analytics 계열, 1.0.10은 login-hotfix와 fix/ios-firebase-plist, 1.0.11은 first-song-funnel. main(10-05, `77f7c37`)에 무엇이 들어갔는지 불명이다.
4. **플랫폼 버전이 갈라졌다.** iOS 1.0.10(39), Android 1.0.11(40) / 내부 41.
5. 원격 브랜치 20개 이상이 방치돼 있다 (`claude/*`, `DAW`, `feat/*` 등).
6. Codex와 Claude 여러 세션이 서로 다른 worktree에서 동시에 작업한다. 작업 공간 위치가 문서마다 달라 다음 세션이 어디서 이어야 할지 헷갈린다.

### 🔴 B. 시크릿·설정 파일이 기기마다 따로 있음

7. 같은 설정이 **PC, Mac, GitHub Secrets 세 곳**에 손으로 복사돼 있다. `backend/.env.secrets`, `GoogleService-Info.plist`, `google-services.json`, `android/key.properties`, ASC `.p8`, 배포 `.p12`. 한 곳만 바뀌면 다른 곳은 낡은 채 남는다 (iOS 1.0.9 크래시의 원인).
8. 값의 **존재만 검사하고 정합성은 검사하지 않는다.** Sentry DSN이 엉뚱한 프로젝트를 가리켜도 통과했다.
9. iOS 로컬 빌드는 fastlane을 거칠 때만 가드가 돈다. Mac에서 Xcode로 직접 Archive하면 우회된다 (Android는 Gradle 가드로 막음).
10. 키 원본이 `C:\src\keys`와 `backend\secrets\humtrack-transfer\`(배포 .p12, 업로드 keystore, Play 서비스 계정)에 평문으로 있다. git에서는 제외되지만 안전한 보관소가 어디인지 정해지지 않았다.
10-1. ⚠️ **확인됨 (10-12):** PC의 `backend\secrets\humtrack-transfer\GoogleService-Info.plist`는 iOS 1.0.9를 크래시시킨 바로 그 Sign-In 전용 plist다 (`GOOGLE_APP_ID`·`API_KEY`·`GCM_SENDER_ID`·`PROJECT_ID` 없음, 키 이름만 확인하고 값은 읽지 않음). 올바른 병합본은 Mac에만 있다. 이 transfer 폴더로 새 Mac이나 다른 기기를 세팅하면 같은 크래시가 재발한다. PC에는 `google-services.json`도 없다.

### 🟠 C. 빌드 환경 차이

11. Windows에는 Ruby가 없어 `release_support_test.rb`와 fastlane을 로컬에서 못 돌린다. `run.sh`는 bash 전용이다.
12. Windows에 symlink 권한이 없어 플러그인 링크를 junction으로 우회했다. `flutter pub get`이 다시 깨질 수 있다.
13. JDK 25가 자동 선택되면 Android 빌드가 실패한다. JDK 17을 명시해야 한다.
14. Flutter 3.47.1 고정. PC와 Mac 버전이 어긋나면 analyze 결과와 iOS 최소 버전이 달라진다.
15. **iOS 빌드 경로가 둘이다.** GitHub `macos-26` 클라우드와 로컬 Mac. 설정 출처가 달라 결과가 달라질 수 있다.
16. **CI가 main 푸시와 PR에서만 돈다.** 기능 브랜치에서 바로 출시하는 현재 방식에서는 CI가 거의 안 돈다. Windows·macOS 데스크톱 빌드 CI는 없다.
17. `flutter analyze` / `pub get`이 `analysis_options.yaml`, `pubspec.lock`을 자동 수정하는데, 실수로 커밋될 수 있다.

### 🟠 D. 실기기 검증

18. 검증 기기에 **iPhone이 없다** (iPad만). 작은 세로 화면, 통화 인터럽션, 이어폰 경로는 iPad로 일부만 확인된다.
19. Android 기기가 1대라 Android 9 이하(Opus → AAC 폴백), 저사양 기기 오디오는 커버하지 못한다.
20. 실기기 체크리스트는 문서마다 따로 있고(`MAC-WORKORDER` 7장, `TESTFLIGHT-SONGPLAN` 등) 결과 기록 형식이 없다.
21. 오디오 회귀 이력(언더런, 인터럽션, 블루투스 경로, Android 다성음)이 있는데 매 빌드 듣기 검증 절차가 고정돼 있지 않다.
22. 업데이트 설치(기존 곡·보컬·구독 상태 유지) 검증이 매번 빠지기 쉽다.

### 🟠 E. 원격 Mac

23. 접근 방식이 정해지지 않았다 (문서에 SSH·원격 데스크톱 기록 없음).
24. 원격 빌드의 흔한 막힘: Mac 절전·잠금, 로그인 키체인 잠김으로 codesign 대기, Xcode Apple ID 세션 만료와 2단계 인증, GUI 동의 팝업.
25. Mac의 git 인증, 시크릿 배치, Flutter·Xcode·CocoaPods 버전을 맞추는 절차가 문서에만 있고 스크립트가 없다.

### 🟡 F. 운영

26. 모니터링 맹점: 네이티브 시작 크래시는 Sentry가 못 본다. App Store Connect 크래시, Play Console Android vitals를 출시 직후 확인하는 절차가 없다. Firebase 수집은 꺼져 있다.
27. 백엔드(Fly `humming-api`)는 JWT 검증이 fail-closed다. `SUPABASE_JWT_SECRET`이 빠지면 유료 사용자 전원이 Pro를 잃는다. 배포 순서는 마이그레이션 → 백엔드 → 앱이다.
28. 개인정보처리방침 1.4 시행일(제안 2026-11-01)과 30일 전 고지 일정 확인이 필요하다.

---

## 3. 이 세션의 한계

이 Cowork 세션은 PC 파일을 읽고 쓸 수는 있지만 **PC에서 명령을 실행할 수 없다** (git, flutter, adb 불가). 스크립트·설정·문서는 여기서 만들 수 있고, 실행과 확인은 PC의 VS Code Claude Code 세션이나 Heo가 직접 해야 한다.
