# HumTrack 클라우드 Mac 빌드

걱정관리소에서 검증한 GitHub Actions `macos-26` 러너를 사용한다.
개인 Mac 없이 Windows에서 코드를 올리고 iOS 컴파일 결과를 확인할 수 있다.
Flutter는 모바일 CI와 같은 3.47.1, CocoaPods/fastlane은 `ios/Gemfile.lock`을 따른다.

2026-09-11 현재: 워크플로를 로컬에 준비했고 actionlint 1.7.12 검사에 통과했다.
HumTrack의 클라우드 실행 결과는 아직 없다. 걱정관리소의 검증 근거는
[2026-09-10 TestFlight 성공 실행](https://github.com/BlancoRicecake/worry_sorter/actions/runs/34441198485)이다
(Xcode 26.6 / iOS SDK 26.5).

## 컴파일 검증

워크플로: `.github/workflows/ci-ios.yml` → **iOS Cloud Build**.

- 기본 브랜치에 반영된 후 Actions에서 수동 실행할 수 있다.
- 최초 검증은 `build/ios/*` 전용 브랜치에 모바일/워크플로 변경을 푸시해 실행한다.
- `flutter build ios --release --no-codesign`으로 Dart와 iOS 네이티브 코드를 컴파일한다.
- 실제 운영 Google plist는 git 밖에서 관리하므로, 이 검증에서는 러너에만
  컴파일용 plist를 만든다. 운영 로그인·분석 설정과 서명을 넣지 않는다.
- 배포용 IPA 생성, TestFlight 업로드, App Store 심사 제출은 실행하지 않는다.

## 서명과 TestFlight 연결에 필요한 설정

걱정관리소와 같은 Apple 팀 `V7XPTJL83T`를 사용하므로 기존 배포 인증서와
팀 API 키를 재사용할 수 있다. 기존 인증서를 폐기하거나 새로 발급할 필요가 없다.
GitHub 저장소 시크릿은 다른 저장소에 자동 공유되지 않는다.

HumTrack에 연결할 값:

| 설정 | 용도 |
|---|---|
| `IOS_DIST_CERT_P12` | 기존 배포 인증서/개인키의 base64 |
| `IOS_DIST_CERT_PASSWORD` | 해당 p12를 내보낼 때 정한 암호 |
| `ASC_API_KEY_P8`, `ASC_KEY_ID`, `ASC_ISSUER_ID` | App Store Connect 팀 API 인증 |
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `GOOGLE_WEB_CLIENT_ID` | 운영 로그인 설정 |
| `ENGINE_URL`, `CLARITY_PROJECT_ID`, `SENTRY_DSN_MOBILE` | 운영 API·분석·오류 수집 설정 |
| 운영 `GoogleService-Info.plist` | iOS Google 로그인 클라이언트 설정 |

로컬 Mac의 `backend/.env.secrets` 및 별도 보관한 키를 사용한다. 키나 암호를
소스에 넣지 않는다. GitHub 시크릿에는 저장만 가능하며 기존 값은 조회할 수 없다.

서명 워크플로를 연결할 때는 임시 키체인에 기존 p12를 설치하고,
`build_app`의 아카이브 `xcargs`에 `-allowProvisioningUpdates`와
`-authenticationKeyPath / -authenticationKeyID / -authenticationKeyIssuerID`를
넘긴다. 걱정관리소와 같이 API 키로 프로비저닝을 처리한다.
fastlane이 내보내기 인증 인자를 추가하므로 `export_xcargs`에 같은 인자를
중복 전달하지 않는다.

서명 준비 후 기존 `beta` 레인으로 TestFlight를 이용할 수 있다. 출시는
[Mac 작업지시서](MAC-WORKORDER-2026-09.md)의 버전·실기기 검증 절차를 따른다.
컴파일 성공으로 녹음 인터럽션·구매·복원·기존 버전 위 설치 검증을 대신하지 않는다.
