# Android / iOS 업데이트 — 2026-09-12

## 버전과 현재 스토어 상태

- 준비 버전: `mobile/pubspec.yaml`의 **1.0.6+33**.
- App Store Connect API 조회: 공개 버전 1.0.4, 1.0.6은
  `PENDING_DEVELOPER_RELEASE`(수동 출시 대기).
- Apple 최신 업로드는 2026-09-07의 **1.0.6(32)**, 처리 상태 `VALID`.
  32를 다시 사용하지 않는다. 기존 승인 빌드에는 이번 수정이 포함되어 있지 않다.
- Play API: 현재 PC의 걱정관리소 서비스 계정은 HumTrack 접근이 403으로 거절된다.
  HumTrack 권한이 있는 계정으로 번호를 확인한 후 필요하면 33을 더 올린다.
- 이번 수정본의 스토어 업로드와 기존 승인 버전 교체는 아직 실행하지 않았다.

## 빌드에서 찾은 추가 수정

실제 Xcode 컴파일에서 `AVAudioSessionInterruptionOptionsKey`가 존재하지 않아
실패했다. Apple의 실제 상수인
[`AVAudioSessionInterruptionOptionKey`](https://developer.apple.com/documentation/avfaudio/avaudiosessioninterruptionoptionkey)로 수정했다.

Flutter 3.47.1이 iOS 최소 버전을 15.0으로 자동 이행하는 것을 확인했다.
Podfile/Xcode 프로젝트/Flutter 프레임워크 설정을 15.0으로 맞췄다.
따라서 이번 빌드의 대상은 **iOS 15 이상**이다. iOS 13/14 지원을 유지하려면
Flutter/플러그인 버전부터 별도 검토해야 한다.

## 배포 워크플로

`.github/workflows/release-mobile.yml`의 **Mobile Store Release**를 수동 실행한다.
기본 브랜치에 워크플로를 반영해야 GitHub의 실행 버튼을 사용할 수 있다.

- `platform`: `both`, `ios`, `android`.
- `destination=build`: 서명된 IPA/AAB만 생성한다.
- `destination=internal`: TestFlight와 Play 내부 테스트에 업로드한다.
- `destination=production`: App Store 심사 제출 및 Play 프로덕션 심사 요청.
  iOS는 승인 후 자동 출시하도록 요청한다. 스토어 심사가 끝나기 전에는 출시 완료가 아니다.
- `build_number`: 필요할 때만 pubspec 번호를 덮어쓴다. Android changelog도
  해당 번호의 파일을 준비해야 한다.
- `replace_pending_ios_release`: 현재처럼 Apple의 기존 승인/심사 버전이 있으면
  새 빌드 업로드·처리 완료 후 교체하기 위해 사용한다.

소스 푸시만으로는 스토어에 배포되지 않는다. 빌드 전에 테스트와 배포 설정을
검사하고, iOS는 API 키로 프로비저닝한다. 배포 인증서를 새로 발급/폐기하지 않는다.
기존 스토어 스크린샷은 유지하고, 이번에 수정한 설명과 릴리스 노트를 반영한다.

## 필요한 GitHub Actions 시크릿

공통:

- `HUMTRACK_DART_DEFINES_JSON`: `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
  `GOOGLE_WEB_CLIENT_ID`, `ENGINE_URL`, `CLARITY_PROJECT_ID`, `SENTRY_DSN_MOBILE`의
  문자열 값을 담은 JSON 객체. `backend/.env.secrets`에서 해당 6개만 가져온다.
  서버 관리자 키는 포함하지 않는다.

iOS:

- `IOS_DIST_CERT_P12`: 기존 팀 `V7XPTJL83T` 배포 인증서/개인키의 base64.
- `IOS_DIST_CERT_PASSWORD`: p12 내보내기 암호.
- `ASC_API_KEY_P8`: App Store Connect API 개인키의 base64.
- `ASC_KEY_ID`, `ASC_ISSUER_ID`: 해당 API 키 식별자.
- `GOOGLE_SERVICE_INFO_PLIST_BASE64`: 운영 HumTrack iOS Google plist의 base64.
  `BUNDLE_ID=com.humtrack.app`, 실제 `CLIENT_ID`가 있어야 한다.

Android:

- `ANDROID_UPLOAD_KEY_BASE64`: **HumTrack의 기존 업로드 키** 파일의 base64.
- `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`: HumTrack 배포 권한이 있는 서비스 계정 JSON 원문.

현재 PC에서 확인한 파일은 `C:\src\keys\AuthKey_4RL9GSDJ4L.p8`와
`ios_dist.p12`이며 Apple API 인증은 성공했다. HumTrack 운영 설정, Android 키와
Play 계정 파일, p12 암호는 아직 연결하지 못했다. 키/운영 값은 소스에 커밋하지 않는다.

## 로컬 Mac 실행

공통 Ruby 번들은 `mobile/ios/Gemfile.lock`으로 고정한다. Android도 같은 번들을
사용하므로 별도의 전역 fastlane 설치에 의존하지 않는다.

```bash
export BUNDLE_GEMFILE="$PWD/mobile/ios/Gemfile"   # 저장소 루트에서
cd mobile/ios && bundle install
bundle exec fastlane doctor
bundle exec fastlane beta
# 실기기 확인 후 이미 업로드한 정확한 빌드를 제출:
HUMTRACK_AUTOMATIC_RELEASE=true HUMTRACK_REPLACE_PENDING_RELEASE=true bundle exec fastlane submit_release
```

Android는 운영 설정과 `mobile/android/key.properties`를 준비한 뒤 같은
`BUNDLE_GEMFILE`을 유지한 셸에서 `mobile/android`로 이동해 실행한다.
`bundle exec fastlane doctor`, `bundle exec fastlane release` 순서다.

## 검증 범위

- [모바일 CI](https://github.com/BlancoRicecake/humming-v2/actions/runs/34621510243):
  143개 테스트 통과, Dart 오류/경고 없음, Android ARM64 디버그 APK 컴파일 성공.
- [iOS 클라우드 CI](https://github.com/BlancoRicecake/humming-v2/actions/runs/34621122474):
  Xcode 26.6 / iOS SDK 26.5에서 서명 없는 릴리스 컴파일 성공(64 MB).
  Ruby 배포 설정 테스트 5개, assertion 15개 통과 및 양 플랫폼 fastlane 로딩 성공.
- 워크플로 정적 검사: actionlint 통과. 자격증명 준비 Python 4개 블록의 문법,
  줄바꿈이 들어간 base64, Google plist, Java 서명 속성의 공백·Unicode 처리를
  실제 개인키 대신 가짜 값으로 별도 검증했다.
- 운영 설정을 넣은 서명 빌드와 iPhone/Android의 녹음·구매·복원·업데이트 설치는
  아직 검증하지 않았다. 체크리스트는 [Mac 작업지시서](MAC-WORKORDER-2026-09.md)에 있다.

배포 동작 참고: [App Store 제출](https://docs.fastlane.tools/actions/appstore/),
[Play 배포](https://docs.fastlane.tools/actions/supply/).
