# HumTrack — MacBook 인계 / iOS App Store · macOS 배포 준비

작성일: 2026-09-18. **최신 앱 작업은 `codex/humtrack-desktop` 브랜치에 있다. `main`만 pull하면 이번 기능을 받지 못한다.**
이 문서는 후속 작업 지시서다. 이번 Windows 세션에서 iOS 업로드, 심사 제출, Mac 빌드 또는 Mac 배포는 수행하지 않았다.

## 1. MacBook에서 가장 먼저 실행

기존 저장소 디렉터리에서 실행한다. 작업 중인 변경이 있으면 먼저 별도 커밋/보관하고 진행한다. 강제 reset/clean은 필요 없다.

```bash
git status --short
git fetch origin
git switch codex/humtrack-desktop
# 로컬 브랜치가 없고 자동 추적 전환도 실패하는 경우에만:
# git switch --track origin/codex/humtrack-desktop
git pull --ff-only origin codex/humtrack-desktop
git log -8 --oneline
cat docs/MAC-HANDOFF-2026-09-18.md
```

아래 앱 커밋과 이 문서 커밋이 포함되어야 한다:

| 커밋 | 작업 |
|---|---|
| `06c94d0` | 모바일 녹음·내보내기 수정 / 내부 테스트 기준 |
| `f3486d7`, `80b831c` | 기존 Hum → MIDI 활용 안내형 창작, 반주, 재사용 샘플 작업실 |
| `e3f0c45` | Windows PCM 출력, 데스크톱 실행 기반, Mac 마이크 권한 준비 |
| `8b83422` | 사용자 지정 연주 키, 어두운 창 제목 표시줄 |
| `5f3c255` | 영역 크기 조절, 타임라인 확대·스크롤, 재생·녹음·저장 단축키 |

웹사이트 업데이트는 별도 PR #6으로 `main`에 배포됐다. 앱 배포를 위해 웹 변경을 다시 배포할 필요는 없다.

## 2. 현재 확인된 상태와 미확인 상태

- `mobile/pubspec.yaml`: **1.0.7+35**. 그대로 업로드하지 말고 App Store Connect의 실제 최신 버전/빌드 번호와 비교할 것.
- Windows: 일반 Release 실행 파일, PCM 출력, WAV 내보내기, 편집 저장, 연주/재생 키 입력 검증 완료. Flutter 테스트 **162개 통과**.
- iOS: 예전 커밋의 클라우드 컴파일 성공 이력은 있으나, **현재 데스크톱 브랜치 전체의 iOS 빌드·실기기 검증은 아직 하지 않았다.**
- macOS: 코드/권한 준비만 완료. **컴파일, 소리, 마이크, 로그인, 내보내기, 서명, 공증 모두 Mac에서 확인해야 한다.**
- 이 저장소의 `test/desktop_smoke_app.dart`는 Windows 전용 검증 진입점이다. 배포는 항상 `lib/main.dart`를 사용한다.
- Windows 로컬 산출물은 Git에 들어 있지 않다. Mac에서는 소스를 빌드한다.

## 3. 도구와 운영 설정

저장소 루트에서:

```bash
xcodebuild -version
xcode-select -p
flutter --version
flutter doctor -v
cd mobile
flutter precache --ios --macos
flutter pub get
cd ios
bundle install
bundle exec fastlane ios hello
cd ../..
```

개발/Windows 검증 Flutter는 **3.47.1**이다. 우선 같은 버전으로 재현하고, Xcode/SDK와 안 맞으면 변경 사유와 검증 결과를 기록한다. Xcode 계정에 Apple 팀 **V7XPTJL83T**와 필요한 인증서/개인키가 있어야 한다.

Git으로 전달되지 않는 파일/설정:

- `backend/.env.secrets`: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `GOOGLE_WEB_CLIENT_ID`, `ENGINE_URL`, `CLARITY_PROJECT_ID`, `SENTRY_DSN_MOBILE`.
- 운영 `mobile/ios/Runner/GoogleService-Info.plist`. `CLIENT_ID`/번들 ID를 확인한다. `CI_COMPILE_ONLY` 파일은 배포용이 아니다.
- App Store Connect API 키 `.p8`와 `ASC_KEY_ID`, `ASC_ISSUER_ID`, **절대경로** `ASC_KEY_FILEPATH` 환경변수.
- iOS 배포 인증서/개인키와 프로비저닝 접근 권한. Mac 외부 배포에는 별도의 **Developer ID Application** 서명 자격이 필요하다.

시크릿은 기존 안전한 보관소에서 가져온다. GitHub Secrets는 등록된 값을 다시 다운로드할 수 없다. `.p8`, `.p12`, 비밀번호, 운영 설정 파일을 Git에 넣지 않는다. 모바일에 넣는 Supabase 키는 anon/publishable 용도이며 service-role 키를 넣으면 안 된다.

운영 define 존재 여부만 검증하는 명령(값은 출력하지 않음):

```bash
cd mobile/ios
bundle exec ruby -r ../tool/release_support -e 'puts HumTrackRelease.defines.keys; HumTrackRelease.require_google_plist!'
bundle exec fastlane ios doctor
cd ../..
```

`doctor`는 현재 최신 TestFlight 빌드 번호를 확인한다. API 변수는 실행 전에 로컬 환경에 설정해야 한다. `fastlane/.env.secrets`라는 이름의 파일이 있다고 자동으로 로드된다고 가정하지 않는다.

## 4. 공통 검증

```bash
cd mobile
flutter analyze --no-fatal-infos
flutter test
flutter devices
cd ..
```

컴파일 오류와 새 경고를 해결하고 진행한다. 기존 문서의 143개/156개 테스트 기록보다 이번 문서의 162개 기준이 최신이다. 결과 수는 후속 테스트 추가에 따라 늘 수 있다.

## 5. iOS: 빌드 → TestFlight → 실기기 → App Store

### 5-1. 버전 결정과 변경 설명

App Store Connect 앱 ID: **6775845423** / Bundle ID: **com.humtrack.app**.

1. 현재 판매 버전, 심사 대기 버전, 최신 업로드 빌드 번호를 확인한다.
2. `HUMTRACK_VERSION`과 `HUMTRACK_BUILD_NUMBER`를 이번 릴리스 값으로 설정한다. 빌드 번호는 최신 업로드보다 크게 한다. `1.0.7+35`나 임의의 `36`이 사용 가능하다고 가정하지 않는다.
3. 확정 값을 `mobile/pubspec.yaml`에도 맞추고 기록한다. fastlane은 환경변수 값이 있으면 이를 우선한다.
4. `mobile/ios/fastlane/metadata/ko/release_notes.txt`, `en-US/release_notes.txt`는 아직 이전 수정 내용이다. 안내형 창작·반주·샘플 편집 등 **iOS에서 검증한 기능만** 추가한다. PC 단축키를 iOS 기능으로 홍보하지 않는다.

### 5-2. 로컬 서명 빌드와 업로드

```bash
cd mobile/ios
# 위 단계에서 확정한 HUMTRACK_VERSION/HUMTRACK_BUILD_NUMBER 및 ASC 환경변수가 설정되어 있어야 함
bundle exec fastlane ios build
# 생성: mobile/build/export/HumTrack.ipa
# 빌드와 설정을 확인한 뒤 TestFlight 업로드:
bundle exec fastlane ios beta
```

`build`는 운영 define 검증 → iOS 무서명 컴파일 → Xcode 서명/IPA 생성까지 한다. `beta`는 다시 build를 호출한 뒤 TestFlight로 업로드하고 Apple 처리를 기다린다. 외부 테스터 배포나 App Store 심사 제출은 하지 않는다. 이미 업로드한 번호로 beta를 재실행하면 번호 검증에서 중단되므로, 성공 후에는 같은 IPA를 다시 올리지 않는다.

처리 완료 뒤 TestFlight 그룹에 정확한 빌드를 연결한다. iPhone/iPad에서:

- [ ] 기존 설치 위 업데이트 후 곡·보컬 파일·구독 상태 유지
- [ ] 허밍 → MIDI → 악기 변경 → 반주 → 저장 → 재실행
- [ ] 샘플 녹음/WAV 가져오기 → 자르기 → 반복 미리듣기 → 곡에 넣기
- [ ] 녹음 권한 허용/거부, 전화·오디오 인터럽션, 앱 전환/화면 잠금 후 복귀
- [ ] 드럼/멜로디/베이스, 보컬 재생, 믹서, 실행 취소/재실행
- [ ] WAV/MIDI/스템 내보내기, 한글 파일명, 실제 비무음 파일 확인
- [ ] 실제 운영 로그인, 로그아웃, 구매·복원과 Pro 제한 (테스트 우회 권한에 의존하지 않기)
- [ ] 작은 iPhone 및 iPad 가로 화면, 저장 실패/다시 저장/트랙 비우기 안내

### 5-3. 검증한 빌드만 심사 제출

같은 버전/빌드 환경변수를 유지하고, 리뷰 계정·스크린샷·수출 규정 답변·스토어 설명을 확인한 뒤:

```bash
# mobile/ios 디렉터리
export HUMTRACK_AUTOMATIC_RELEASE=false
export HUMTRACK_REPLACE_PENDING_RELEASE=false
bundle exec fastlane ios submit_release
```

`submit_release`는 해당 버전/번호의 처리 완료된 iOS 빌드만 제출한다. 바이너리를 새로 업로드하지 않는다. 기본 흐름은 심사 통과 후 수동 공개다. `release` 레인은 beta+심사 제출을 연속 실행하므로 실기기 검증을 건너뛰는 최초 명령으로 사용하지 않는다.

이미 심사 중/승인 대기인 같은 버전을 교체해야 할 때는 App Store Connect 상태부터 확인한다. `HUMTRACK_REPLACE_PENDING_RELEASE=true`는 기존 심사 제출을 취소할 수 있으므로 실제 교체를 의도할 때만 사용한다. 관련 구현은 `mobile/tool/release_support.rb`.

## 6. macOS: 먼저 로컬 프리뷰를 완성

### 6-1. 남아 있는 배포 전 작업

- `macos/Runner/Configs/AppInfo.xcconfig`의 PRODUCT_NAME이 아직 **humming**이다. 최종 명칭 HumTrack으로 변경할 때 Xcode 프로젝트의 `.app` 참조, 테스트 TEST_HOST/실행 파일 경로도 함께 맞출 것. 변경 전 출력은 `humming.app`이다.
- Bundle ID는 현재 `com.humtrack.app`. iOS/macOS 앱 레코드를 어떻게 운영할지 결정하고 Apple 포털의 등록·프로파일과 일치시킨다. 임의로 바꾸지 않는다.
- Mac 팀/배포 서명은 미완성이다. 프로젝트에 `CODE_SIGN_IDENTITY = "-"` 설정이 남아 있으므로 release 빌드만으로 Developer ID 서명이 됐다고 판단하지 않는다.
- 최종 아이콘, 앱 메뉴/표시 이름, 최소 macOS 버전과 지원 아키텍처를 확인한다. Podfile의 10.15만 보고 실제 지원 버전을 약속하지 않는다. 사용 SDK와 플러그인 요구 조건이 우선이다.
- `AuthService` OAuth 반환 주소는 `humtrack://auth/callback`이나 Mac Info.plist에 URL scheme 구성이 아직 없다. 프로토콜 등록, Supabase 허용 redirect, 플러그인의 Mac 복귀 처리를 검증한다. 운영 define을 넣는 것만으로 로그인이 완성되지는 않는다.
- 현재 IAP 초기화는 Android/iOS에만 적용된다. **Mac 신규 결제·복원은 구현 완료가 아니다.** Mac App Store용 StoreKit, 기존 계정 Pro 접근, 무료 프리뷰 중 배포 범위를 결정하고 제한/안내를 맞춘다. 테스트 Pro 권한을 배포하지 않는다.
- Release 권한에는 sandbox/audio-input/network.client/user-selected.read-write가 있다. 실제 샘플 파일·최근 작업 재열기에서 sandbox 접근이 유지되는지 검증한다.

### 6-2. 빌드 및 실행

```bash
cd mobile
flutter config --enable-macos-desktop
flutter pub get
# Gemfile.lock의 CocoaPods 사용
(cd macos && BUNDLE_GEMFILE=../ios/Gemfile bundle exec pod install)
flutter run -d macos -t lib/main.dart
```

위 명령은 운영 define 없는 **로컬 음악 기능 점검용**이다. 운영 계정/허밍 API 동작 검증에는 위 3장의 설정을 사용한다. 저장소 루트에서 다음 명령은 기존 helper로 운영 define을 일시 파일에 전달하고 자동 정리한다:

```bash
cd mobile/ios
bundle exec ruby -r ../tool/release_support -e 'HumTrackRelease.with_defines(HumTrackRelease.defines) { |p| Dir.chdir(HumTrackRelease::MOBILE) { abort "macOS build failed" unless system("flutter", "build", "macos", "--release", "--target", "lib/main.dart", "--dart-define-from-file=#{p}") } }'
cd ../..
# 이름 변경 전 산출물:
open mobile/build/macos/Build/Products/Release/humming.app
```

Apple Silicon에서 빌드했다고 Intel 호환까지 보장하지 않는다. 배포 앱의 아키텍처를 `lipo -archs <앱 내부 실행 파일>`로 확인하고 지원 대상으로 안내할 장비에서 실행한다.

### 6-3. Mac 실사용 검증

- [ ] 앱 시작/종료, 어두운 제목 표시줄, 창 최소 크기·확대·최소화, 메뉴
- [ ] 실제 스피커/헤드폰에서 피아노·드럼 출력, 동시 연주, 키를 뗀 뒤 음 종료
- [ ] 다른 앱으로 포커스 이동 시 음 종료, 재생 중 창 이동 시 동작
- [ ] 한글/영문 입력 상태에서 물리 연주 키, 사용자 키 변경·중복 방지·재실행 후 유지
- [ ] Space 재생/일시정지, Cmd+Shift+R 녹음, Cmd+S 저장, Cmd+Z 취소, Cmd+Shift+Z 재실행
- [ ] 제목 입력/설정 창에서는 연주·작업 단축키가 방해하지 않는지
- [ ] 분할 손잡이 크기 조절·더블클릭 초기화, 타임라인 100–400% 확대·스크롤·전체 보기
- [ ] 내장/외장 마이크, 권한 거부/재허용, 녹음 지연·장시간 재생·장치 변경
- [ ] Hum → MIDI, 반주, 샘플 저장·재열기, 한글 경로/외부 폴더, 내보내기
- [ ] 운영 로그인 복귀/로그아웃, 실제 Pro 정책과 결제 안내

## 7. macOS 배포 경로

### A. 웹에서 다운로드하는 Mac 프리뷰

첫 외부 배포 경로로 검토할 수 있다. 아래는 **기능 검증을 마친 앱을 Xcode Organizer에서 Developer ID로 서명·Export한 뒤** 사용하는 명령이다. 로컬 adhoc 서명 앱을 그대로 배포하는 명령이 아니다.

1. `mobile/macos/Runner.xcworkspace`를 열어 Release/Archive 팀·서명·Hardened Runtime을 설정한다. 배포 아카이브에 디버그용 권한이 불필요하게 포함되지 않도록 확인한다.
2. Product → Archive → Organizer에서 Developer ID 배포로 내보낸다. iOS용 Apple Distribution 인증서와 Developer ID Application을 혼동하지 않는다.
3. Xcode에서 공증까지 수행하거나, 아래처럼 notarytool을 사용한다. 기존 키체인 프로필을 쓰고, 없다면 `xcrun notarytool store-credentials --help`에 따라 안전하게 만든다.

```bash
# 실제 서명된 export 경로로 바꿀 것
APP_PATH="/absolute/path/to/export/HumTrack.app"
DIST_DIR="/absolute/path/to/distribution"
mkdir -p "$DIST_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=4 "$APP_PATH"  # Authority/TeamIdentifier 및 runtime 확인

ditto -c -k --keepParent "$APP_PATH" "$DIST_DIR/HumTrack-notarize.zip"
xcrun notarytool submit "$DIST_DIR/HumTrack-notarize.zip" --keychain-profile "humtrack-notary" --wait
# 결과가 Accepted일 때만 다음 단계 진행. 실패 시 반환 ID로 notarytool log 확인.
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=2 "$APP_PATH"
# 공증 티켓을 붙인 뒤 최종 압축을 새로 만든다.
ditto -c -k --keepParent "$APP_PATH" "$DIST_DIR/HumTrack-macOS.zip"
shasum -a 256 "$DIST_DIR/HumTrack-macOS.zip"
```

다운로드한 최종 ZIP을 다른 Mac/깨끗한 사용자 계정에서 풀어 Gatekeeper·마이크·파일 저장을 확인한 후 공개 링크를 게시한다. Gatekeeper 해제나 quarantine 삭제를 설치 방법으로 안내하지 않는다. ZIP 안에는 `.app` 전체가 있어야 한다.

### B. Mac App Store

Mac App Store를 택하면 별도 macOS 플랫폼/앱 레코드, sandbox·서명 프로파일·스토어 자료·결제 지원을 준비한다. 현재 `mobile/ios/fastlane/Fastfile`은 **iOS 전용**이며 Mac 제출 레인으로 쓰면 안 된다. Mac용 빌드/업로드 경로를 만든 후 TestFlight 및 심사를 진행한다. Developer ID 공증 ZIP 절차와 Mac App Store 제출을 혼합하지 않는다.

## 8. 마무리 기록과 웹페이지

- 수정 파일/커밋을 같은 작업 브랜치에 올린다. 앱 출시가 검증되면 main 통합을 진행한다.
- iOS 버전/빌드, TestFlight 처리/그룹, 심사 상태/공개 여부를 기록한다.
- Mac: OS/Xcode/Flutter 버전, CPU/앱 아키텍처, 서명 팀, 공증 ID/결과, 파일 SHA-256, 다운로드 주소를 기록한다. 비밀값은 제외한다.
- `hum-track.com`은 Windows 공개 다운로드 없음, Mac 준비 중으로 안내 중이다. Mac 파일이 실제 공개되고 검증된 뒤 `landing/index.html`의 플랫폼 현황·FAQ·다운로드 링크를 함께 갱신한다.
- 작업영역 크기/확대 배율은 현재 세션 설정이다. 연주 키만 재실행 후 유지된다. 트랙 이름도 가로 스크롤하며 고정 열은 아직 없다.

### 다음 작업자에게 전달할 한 문장

> docs/MAC-HANDOFF-2026-09-18.md를 먼저 읽고 codex/humtrack-desktop의 최신 코드를 기준으로 iOS 실기기/TestFlight 검증과 macOS 빌드·서명 준비를 이어가세요. 현재 Mac 실행 성공이나 Mac 결제 지원을 가정하지 말고, 실제 검증한 플랫폼과 빌드만 배포하세요.

### 참고

- [프로젝트 데스크톱 구현 기록](DESKTOP-PROTOTYPE-2026-09-18.md)
- [iOS fastlane 실제 레인](../mobile/ios/fastlane/Fastfile)
- [운영 define/버전 검사 코드](../mobile/tool/release_support.rb)
- [Flutter macOS 배포](https://docs.flutter.dev/deployment/macos)
- [Apple Developer ID](https://developer.apple.com/developer-id/)
- [Apple 공증 절차](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Xcode의 Mac App Store 외부 배포](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)
