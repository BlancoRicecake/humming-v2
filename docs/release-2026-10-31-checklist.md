# 릴리스 체크리스트 — iPhone 업데이트 + Mac App Store + 웹 직접 다운로드 (2026-10-31)

- 기준: `.worktrees/develop-build-check` = `develop` @ `4f5f34d` (= `origin/develop`, 2026-10-31 `git fetch --prune origin` 후 확인) + 이 작업 공간의 미커밋 수정(아래 C0).
- 출시 대상: **iPhone 업데이트, Mac App Store, 웹 직접 다운로드 세 가지 모두.** Mac 두 경로는 별도 릴리스 게이트(S, W)이고 공통 코드(C)·QA(Q)·데이터 이전(M)을 공유한다. 순서는 의존성으로 정한다(맨 아래 "순서").
- 앱 버전(코드): `mobile/pubspec.yaml:19` `1.0.13+43`. 공개 App Store(id6775845423)는 iPhone 1.0.10, Apple Silicon Mac에서도 iOS 앱 제공 중(사용자 확인). **ASC 최신 업로드 빌드 번호는 별도 확인 필요**(ASC Chrome 세션 만료, 로컬 ASC 키 미설정).
- 상태: `완료` / `미완료` / `확인필요` / `차단`(외부 조건으로 지금 진행 불가). `(추정)` = 코드로 확정하지 못한 판단.
- 시크릿은 키 이름의 존재 여부만 확인했다. 운영 설정(로그인 redirect 허용 목록, 인증서, ASC)은 변경하지 않고 필요한 항목만 적었다.

---

## 0. 인벤토리 (2026-10-31)

| 항목 | 값 |
|---|---|
| main 로컬 | `77f7c37` (2026-10-05), `origin/main`보다 28 커밋 뒤. 미커밋: `mobile/.gitignore`, `mobile/ios/fastlane/README.md` 수정 + 미추적 문서 (보존, 미변경) |
| origin/main | `31eb5af` (2026-10-30, 랜딩 헤더 PR #22) |
| origin/develop | `4f5f34d` (2026-10-31). main에 없는 커밋 10개(ui-000~005, DAW 편집, 저장·백업, 원격 공지), develop에 없는 main 커밋 4개(랜딩 PR #21/#22만) |
| 원격 미병합 브랜치 | `codex/store-contact-20261030`(ASC 연락처 스크립트·워크플로), `feat/priority-analysis`(백엔드 Pro 우선 대기열), `feat/cloud-server-gate`(develop `cloud_quota.py`와 다른 구현) — **이번 범위에서 제외**(결정 D9) |
| 이미 반영된 브랜치 | `codex/apple-submission-compatibility`, `codex/store-release-recovery`, `build/ios/preflight-2026-09-12`(`git cherry` -), AppFrameworkInfo MinimumOSVersion 제거 |
| prune된 원격 브랜치 | 15개 |
| 태그 | `v1.0.12+41`, `v1.0.11+40`, `v1.0.7+36` (1.0.13 태그 없음) |
| 도구 | Flutter 3.47.1 (fvm), Xcode 27.1, CocoaPods 1.16.2, Ruby 3.4.1(테스트용) |
| 코드 서명 | **`security find-identity -v -p codesigning` = 0 valid identities** (프로비저닝 프로파일 파일 9개 있음). 인증서·키를 추측하거나 새로 발급하지 않음 |
| 실기 연결 | **실기 연결 확인 불가(CoreSimulator 문제).** `flutter devices`가 응답 없이 멈춤(10분+, 재시도 90초 타임아웃). 빌드 로그에도 `CoreSimulator is out of date (1171.7.0 < 1174.9.2)`. 시스템 설정·시뮬레이터는 변경하지 않음 |

## 결정 (근거로 확정)

| ID | 결정 | 근거 |
|---|---|---|
| D1 | 직접판은 새 결제 없이 **기존 계정 Pro만 인정**. 외부 결제 링크 없음 | StoreKit은 Mac App Store 설치본에서만 동작. 기존 정책 주석 "server account entitlements remain authoritative"(`lib/services/iap_service.dart` init), `docs/DESKTOP-PROTOTYPE-2026-09-18.md:9`. 백엔드 store는 `app_store`/`play_store`뿐(`backend/app/models.py:14`) |
| D2 | 직접판: 번들 ID `com.humtrack.app.direct`, OAuth 스킴 `humtrack-direct`(Flutter flavor `direct`). MAS/iOS는 `com.humtrack.app`·`humtrack` 그대로 | 아래 "D2 근거", Flutter 공식 flavor 문서(Xcode scheme + build configuration) |
| D3 | 공식 최소 macOS **12.0** | Flutter 3.47.1 빌드가 Podfile·pbxproj를 12.0으로 자동 변경, 산출물 `LSMinimumSystemVersion = 12.0`. 플러그인 최고 요구는 10.15 |
| D4 | Mac 산출물은 **유니버설(arm64+x86_64) 유지**, Intel 실기 QA는 장비 확보 시 | `lipo -archs` = `x86_64 arm64` |
| D5 | Firebase Analytics **비활성 유지** | `.env.secrets`에 Firebase define 키 없음(존재 여부만 확인). `docs/release/HUMTRACK-FIREBASE-PRIVACY-SUBMISSION-DRAFTS.md:85-115` 게이트 미체크 |
| D6 | Mac 표시 이름 **HumTrack**(iPhone과 동일) | iOS `CFBundleDisplayName`/`CFBundleName` = HumTrack, 스토어 저작권 `2026 HumTrack` |
| D7 | 이번 업데이트는 **origin/develop + 이 작업 공간 수정** 기준 | `5b65439 chore: 버전 1.0.13+43`이 develop에 있음 |
| D8 | **iPhone 실기 검증·업데이트 먼저, 그 다음 Mac 네이티브 전환을 단계적으로** | 동일 레코드에 macOS 출시 시 Mac의 iOS 앱이 네이티브로 대체(사용자 제공 Apple 문서). 게이트 M을 통과해야 전환 |
| D9 | 미병합 기능 브랜치 3개는 이번 범위 제외 | 클라이언트 출시와 독립(백엔드/스토어 운영 도구) |

### D2 근거 — 직접판 번들 ID와 로그인 충돌

- 사실:
  - 로그인은 Supabase PKCE(`supabase_flutter` 2.12.4 기본값, `lib/services/auth_service.dart:100`에서 authOptions 미지정). 검증용 code verifier는 로그인을 시작한 앱의 로컬 저장소에만 있으므로, OAuth 콜백(`humtrack://auth/callback`, `auth_service.dart:203`)은 **로그인을 시작한 바로 그 앱**에 도착해야 한다.
  - 같은 Mac에 `humtrack` 스킴을 등록한 앱이 여럿이면(iOS-on-Mac 앱, MAS판, 직접판) macOS가 어느 앱으로 콜백을 보낼지 보장되지 않는다(추정, LaunchServices 동작). 이 Mac에는 이미 TestFlight iOS 앱이 같은 스킴을 등록하고 있다.
  - sandbox 컨테이너는 번들 ID 기준. 같은 번들 ID의 다른 서명판은 기존 컨테이너 접근 시 사용자 동의창이 뜬다(2026-10-31 실측).
- 결정·구현:
  1. **MAS판**: 번들 ID `com.humtrack.app`, 스킴 `humtrack` 유지(iOS 앱을 대체하므로 같은 레코드·같은 데이터·같은 콜백).
  2. **직접판**: flavor `direct` = `*-direct` 빌드 구성 + `direct` scheme. 번들 ID `com.humtrack.app.direct`, 콜백 `humtrack-direct://auth/callback`(C11 완료).
  3. 운영 설정(변경하지 않음, 기록만): **차단** — Supabase Auth Redirect URLs에 `humtrack-direct://auth/callback` 추가 필요(실제 대시보드 접속·검증 전까지 직접판 로그인 불가). `humtrack://auth/callback` 허용 여부도 대시보드 확인필요(저장소 근거 없음, `docs/vision/checklist.md:50` 미체크). Apple Developer에 직접판 App ID `com.humtrack.app.direct`·Developer ID 프로파일.
  4. 데이터: 직접판은 MAS판과 컨테이너가 분리된다. 두 판 사이 이동은 `.humtrack` 백업 파일(설정 > 백업 열기)로 안내한다(클라우드 백업은 기본 비활성).

---

## 게이트 M — Mac 기존 사용자 데이터 이전/호환성 (최우선, MAS 전환 전 필수)

| ID | 항목 | 상태 | 근거 | 담당 작업 | 검증 방법 | 선행조건 |
|---|---|---|---|---|---|---|
| M1 | 네이티브 Mac 앱이 기존 iOS-on-Mac 컨테이너를 그대로 쓰는지 | 확인필요 | 기존 컨테이너 `~/Library/Containers/<UUID>/Data`(TestFlight iOS 앱). 같은 번들 ID 로컬 ad-hoc 빌드가 이 컨테이너 접근 동의를 요구(실측) → macOS가 같은 컨테이너를 연결한다는 신호(추정) | Mac TestFlight 빌드로 "iOS 앱 사용 → 네이티브 업데이트" 재현 | 업데이트 전 곡·녹음·설정 생성 → 네이티브 설치 후 동일 표시 확인, 컨테이너 경로 기록 | 차단: 서명 인증서(C1) |
| M2 | 데이터 경로 레이아웃 호환 | 확인필요 | 곡 `<Documents>/looptap/songs.json`(`lib/looptap/state/loop_storage.dart:1,57-62`), 설정 Documents(`loop_prefs.dart:266`), 로컬 저장 Documents(`lib/state/local_storage.dart:15`), 권한 캐시 Application Support(`lib/services/entitlement_cache.dart:16-18,220`), WAV Application Support(`wav_export.dart:60`), SoundFont Documents(`soundfont_catalog.dart:146`) | iOS-on-Mac과 네이티브에서 path_provider 실제 경로 비교 | 경로만 로그로 비교(개인 데이터 출력 없이) | M1 |
| M3 | 녹음 파일 참조 경로 | 확인필요 | `resolveVocal`은 이름만 Documents 기준으로 풀고 `/` 포함 옛 절대경로는 그대로 통과(`loop_storage.dart:76-86`). 컨테이너 경로가 바뀌면 옛 절대경로 녹음이 깨질 수 있음(추정) | 기존 songs.json 참조 형식 조사, 필요 시 절대경로→이름 보정 | 옛 절대경로 녹음이 있는 데이터로 업데이트 후 재생 | M1, M2 |
| M4 | 로그인 세션·Pro 유지 | 확인필요 | Supabase 세션 저장 위치(플러그인 기본값), 권한 캐시 Application Support | 업데이트 후 재로그인 필요 여부·Pro 표시 확인 | 로그인+Pro 상태에서 업데이트 | M1, C3 |
| M5 | 스키마·백업 호환 | 확인필요 | `.bak` 복구·newer schema 감지(`loop_storage.dart:146-172`, `library_notice.dart`) | 양쪽 1.0.13 스키마 동일 확인 | 업데이트 직후 라이브러리 알림 없음 | M1 |
| M6 | 단계적 전환과 롤백 | 미완료 | D8 | 단계적 출시 가능 여부, 장애 시 대응 정리 | 운영 문서화 | D8 |

## 공통 코드 작업 (C)

| ID | 항목 | 상태 | 근거 | 담당 작업 | 검증 방법 | 선행조건 |
|---|---|---|---|---|---|---|
| C0 | 이 작업 공간의 미커밋 수정 커밋 | 미완료 | macOS 빌드 수정, 킥 라벨, 설정 l10n/화살표, 아래 C2~C10 변경 | 리뷰 후 develop에 커밋(승인됨). `macos/Podfile.lock`은 커밋하지 않음(무시 처리) | analyze/테스트/iOS·macOS 빌드 | — |
| C1 | 코드 서명 | **차단** | 이 Mac 유효 서명 인증서 0개. macOS `pbxproj`에 `DEVELOPMENT_TEAM` 없음, `CODE_SIGN_IDENTITY = "-"`. iOS는 `DEVELOPMENT_TEAM = V7XPTJL83T` | Apple Distribution(MAS)·Mac Installer Distribution·Developer ID Application 인증서를 사용자가 이 Mac에 설치 후 팀 설정 | `security find-identity -v -p codesigning`, `codesign -dv` | 사용자 인증서 설치 |
| C2 | 최소 OS 12.0 정합성 | 완료(미커밋) | `macos/Podfile` `platform :osx, '12.0'`, `pbxproj` `MACOSX_DEPLOYMENT_TARGET = 12.0`(3곳), CocoaPods 통합(`pbxproj` 빌드 단계, `Runner.xcworkspace`의 `Pods.xcodeproj` 참조) — iOS와 같은 관례(iOS도 통합 커밋, `Podfile.lock`은 `.gitignore:83`으로 무시). `mobile/macos/Podfile.lock`을 `.gitignore`에 추가 | C0에 포함 | 2026-10-31 release 빌드 후 `git status`·`git diff --stat` 변화 없음 확인 | — |
| C3 | macOS OAuth 콜백 스킴 | 완료(코드, 미커밋) / 확인필요(운영) | `macos/Runner/Info.plist`에 `CFBundleURLTypes` `humtrack`(iOS와 동일) 추가, 산출물 확인. Supabase redirect 허용 목록은 변경 안 함 | 운영 대시보드에서 `humtrack://auth/callback` 허용 여부 확인 | 서명·운영 define 빌드에서 Google·Apple 로그인→앱 복귀→로그아웃 | C1, D2 |
| C4 | Mac 표시 이름·저작권 | 완료(미커밋) | `AppInfo.xcconfig` `PRODUCT_NAME = HumTrack`, 저작권 `Copyright © 2026 HumTrack. All rights reserved.`, `pbxproj` 제품 참조·`TEST_HOST`, scheme `BuildableName` 변경. 산출물 `HumTrack.app`, `CFBundleName`/`CFBundleExecutable` = HumTrack | C0에 포함 | release 빌드 산출물 확인 | — |
| C5 | Mac 스토어 Info.plist 키 | 완료(미커밋) | `LSApplicationCategoryType = public.app-category.music`, `ITSAppUsesNonExemptEncryption = false`(iOS와 동일) | C0에 포함 | 산출물 Info.plist 확인 | — |
| C6 | Mac 개인정보 매니페스트 | 완료(미커밋) | `macos/Runner/PrivacyInfo.xcprivacy`(iOS와 동일 내용) 추가, Runner 리소스에 등록. 산출물 `Contents/Resources/PrivacyInfo.xcprivacy` lint OK | D5 변경 시 수집 항목 재검토 | 산출물 확인 | — |
| C7 | macOS 빌드 고정(flutter_midi_pro) | 완료(미커밋) | `mobile/third_party/flutter_midi_pro_macos/HUMTRACK_PATCH.md`, `macos/Podfile` override | C0에 포함 | macOS release 빌드 성공 | — |
| C8 | Mac 결제 채널 분기 | 완료(미커밋) | `lib/services/iap_types.dart`: `kMacAppStoreBuild`(`HUMTRACK_MAC_APP_STORE`), `usesAppStore`, `hasStorePurchases`, 산출물 마커 `kMacStoreChannelMarker`. `iap_service.dart` init·verify store/receipt·`_storeName`, `paywall_sheet.dart` 이벤트 store, `settings_sheet.dart` 구독 관리 링크(macOS→App Store)가 이를 사용. 직접판 페이월: 가격·구매·복원 UI 숨김, 기존 계정 Pro 안내 + 미로그인 시 로그인 버튼(`payAccountProOnly`) | — | `test/services/iap_channel_test.dart`, `test/looptap/paywall_channel_test.dart`(macOS 직접판에 가격/구독/복원 없음, iOS는 유지) | — |
| C9 | Mac 채널 빌드 게이트 | 완료(미커밋) | `tool/release_support.rb`: `MAC_CHANNELS`(채널별 store 플래그·OAuth 스킴·번들 ID·flavor를 모두 명시), `mac_defines`, `mac_flavor_args`, `mac_app_path`, `verify_mac_channel!`(App 바이너리의 채널 마커·콜백 URL이 정확히 하나·일치, Info.plist 번들 ID·URL 스킴 일치). Fastfile `platform :mac` `lane :build`(channel 필수, 배열 인자로 빌드 후 검증) | 서명/내보내기 단계는 C1 이후 추가 | Ruby 테스트 24 runs/71 assertions 통과. clean release 빌드 2종 교차 검증(C11). 셸에서 따옴표 없이 인자 문자열을 넘긴 시험 빌드는 define이 한 값으로 합쳐져 잘못된 산출물이 됐고 검증이 거부함 → lane은 배열 인자만 사용 | — |
| C10 | 테스트 이식성 | 완료(미커밋) | `test/qa_cloud_independent_test.dart`: Windows 증거 폴더가 없으면 시스템 임시 폴더 사용 → Mac에서 4개 실제 실행·통과. gotye 3개 파일: 무시된 `artifacts/` fixture가 없으면 사유와 함께 skip(`gotyeFixtureSkip`, `test/looptap/gotye_full_song.dart`) | — | 해당 테스트 실행 | — |
| C11 | 직접판 flavor(번들 ID·콜백 스킴) | 완료(코드, 미커밋) / 차단(운영 redirect) | `pbxproj`에 Debug/Release/Profile-direct(프로젝트·모든 타깃), Runner `*-direct`에 `PRODUCT_BUNDLE_IDENTIFIER = com.humtrack.app.direct`·`HUMTRACK_URL_SCHEME = humtrack-direct`, 기본 `AppInfo.xcconfig` `HUMTRACK_URL_SCHEME = humtrack`, `Info.plist` 스킴·URL 이름 변수화, `direct.xcscheme`, Podfile 구성 매핑. Dart `kAuthCallbackScheme`(`HUMTRACK_AUTH_SCHEME`, 기본 `humtrack`, `auth_service.dart`) | Supabase redirect 추가(D2 근거 3) | clean build 2종: app-store → `Release/HumTrack.app` `com.humtrack.app`/`humtrack`, direct → `Release-direct/HumTrack.app` `com.humtrack.app.direct`/`humtrack-direct`, 각각 반대 채널 검증 거부. 두 판 동시 설치 로그인은 서명 후 | C1, 운영 redirect |
| C12 | 녹음 절대경로 보정(필요 시) | 확인필요 | M3 | M3 결과에 따라 | 테스트 추가 | M3 |

## 공통 QA (Q) — 서명된 운영 define 빌드 기준

| ID | 항목 | 상태 | 근거 | 담당 작업 | 검증 방법 | 선행조건 |
|---|---|---|---|---|---|---|
| Q1 | 실행·첫 화면·기본 내비게이션 | 완료(로컬 ad-hoc 격리판) | 2026-10-31: 첫 화면, 설정(보컬 싱크·화살표), 공지, 곡 열기, 재생/정지, 킥 라벨 | 서명 빌드로 재확인 | 동일 시나리오 | C1 |
| Q2 | 녹음(내장/외장 마이크, 권한 거부/재허용) | 미완료 | `NSMicrophoneUsageDescription`, `device.audio-input` 존재 | Mac·iPhone 실기 | 녹음→재생→보컬 싱크 | C1 / iPhone은 실기 연결 |
| Q3 | Hum→MIDI, 반주 | 미완료 | 운영 `ENGINE_URL` 필요 | 운영 define 빌드 | 분석 결과 생성·재생 | C1 |
| Q4 | 저장·재열기·백업 | 미완료 | `songs.json` 원자 저장·.bak | 저장→재시작→재열기, `.humtrack` 백업/복원 | 동일 내용 | — |
| Q5 | 내보내기(WAV/MIDI/저장 창) | 미완료 | `export_library_screen.dart:50,97-101`, `files.user-selected.read-write` | 저장 창, 한글 경로, 외부 폴더 | 파일 생성·재생 | C1 |
| Q6 | 로그인/로그아웃·Pro 표시 | 미완료 | C3 | Google/Apple, 기존 Pro 계정 | 복귀·Pro 반영 | C3 |
| Q7 | 결제·복원 | 미완료 | iPhone 기존 흐름, MAS 신규(S2) | 샌드박스 계정 | 서버 verify 성공 | S2 |
| Q8 | Mac 단축키·창 동작 | 미완료 | `docs/MAC-HANDOFF-2026-09-18.md:182-193` | 순회 | 기록 | Q1 |
| Q9 | Intel Mac | 확인필요 | D4 | Intel 장비 | 실행·재생·녹음 | 장비 |
| Q10 | 깨끗한 Mac에서 전체 테스트 | 완료(미커밋 기준) | C10 이후 결과는 아래 "검증 기록" | — | `flutter test` | — |

---

## 게이트 I — iPhone 업데이트 (기존 레코드 id6775845423)

| ID | 항목 | 상태 | 근거 | 담당 작업 | 검증 방법 | 선행조건 |
|---|---|---|---|---|---|---|
| I1 | 버전/빌드 번호 | 확인필요 | 코드 `1.0.13+43`, 공개 1.0.10. Fastfile `build`가 최신 TestFlight 번호와 비교(`ios/fastlane/Fastfile:50-60`) | ASC에서 최신 빌드·심사 중 버전 확인 | `fastlane ios doctor` | 차단: ASC 세션 만료·로컬 ASC 키 미설정 |
| I2 | 출시 범위 | 완료(결정) | D7 | — | — | — |
| I3 | 출시 노트(ko/en) | 초안 완료 | 초안 `docs/release/ios-1.0.13-release-notes-draft.md`(커밋 근거 표 포함, 이모지 없음). 메타데이터 파일 `ios/fastlane/metadata/*/release_notes.txt`(2026-10-12)는 아직 미반영 | 리뷰 후 메타데이터에 반영 | `sync_metadata` 전 리뷰 | C0 |
| I4 | 운영 define·GoogleService plist | 확인필요 | 필수 define 6개 `.env.secrets`에 존재, `ios/Runner/GoogleService-Info.plist` 존재(내용 미열람). CI 시크릿 이름은 `release-mobile.yml` | GitHub 시크릿 등록 여부 확인 | 워크플로 preflight | — |
| I5 | ASC API 키 이름(로컬) | 확인필요 | Fastfile은 `ASC_KEY_FILEPATH`(`Fastfile:12-14`), `.env.secrets`에는 `ASC_PRIVATE_KEY_PATH` 이름만. 셸에는 3개 모두 미설정 | 로컬 실행 시 이름 매핑 | `fastlane ios doctor` | — |
| I6 | iPhone 실기 회귀 QA | **차단** | 실기 연결 확인 불가(CoreSimulator 문제) | Xcode/CoreSimulator 상태를 사용자가 정상화 후 Q2~Q7 + 설정·킥 라벨·페이월 확인 | 실기 체크 기록 | 실기 연결 |
| I7 | 프라이버시 라벨 | 확인필요 | D5(비활성 유지) → 기존 라벨 유지 가능(추정) | 최종 바이너리 기준 재검토 | ASC | — |
| I8 | iOS 서명·업로드 | **차단** | 유효 서명 인증서 0개(CI 경로는 GitHub 시크릿 `IOS_DIST_CERT_P12` 사용) | 로컬: 인증서 설치 / CI: 시크릿 확인 후 워크플로 | `beta` 처리 완료 | C1 또는 CI 시크릿 |
| I9 | 제출 | 미완료 | `beta` → 실기 확인 → `submit_release`(`Fastfile:73-105`) | — | ASC 상태 | I1~I8 |

## 게이트 S — Mac App Store (같은 앱 레코드에 macOS 추가)

| ID | 항목 | 상태 | 근거 | 담당 작업 | 검증 방법 | 선행조건 |
|---|---|---|---|---|---|---|
| S1 | ASC 레코드에 macOS 플랫폼·App ID | 확인필요 | 번들 ID `com.humtrack.app`(iOS와 동일) | ASC에서 macOS 추가, Mac 프로파일 | ASC | ASC 로그인 |
| S2 | macOS StoreKit 구독 | 완료(코드, 미커밋) / 미완료(검증) | C8: MAS 빌드(`HUMTRACK_MAC_APP_STORE=true`)에서 StoreKit 활성, store=`app_store`, receipt는 StoreKit 그대로. 같은 레코드의 IAP는 iOS/macOS 공유(Apple ASC 문서, 사용자 제공) | ASC에서 구독 상품의 macOS 제공 확인 | 샌드박스 구매·복원·서버 verify | C1, S1 |
| S3 | Sandbox entitlement | 완료(구성) / 확인필요(실기) | `macos/Runner/Release.entitlements`: app-sandbox, audio-input, network.client, files.user-selected.read-write | 녹음·저장·재열기 권한 유지 | Q2, Q5 | C1 |
| S4 | 업로드 파이프라인 | 미완료 | `fastlane mac build channel:app-store`(빌드·채널 검증)까지 있음. 서명·`.pkg`·업로드 없음 | 서명 export·업로드 단계 추가 | TestFlight for Mac 처리 | C1 |
| S5 | Mac 스크린샷·메타데이터 | 미완료 | `ios/fastlane/metadata`에 스크린샷 없음. 텍스트·개인정보 URL·카테고리(MUSIC) 공유 가능 | Mac 스크린샷 | ASC 미리보기 | Q1 |
| S6 | 심사 노트(데스크톱 로그인·결제) | 미완료 | C3, S2 | 심사 노트·데모 계정 | — | C3, S2 |
| S7 | 기존 Mac 사용자 대체 | 미완료 | 게이트 M | M 통과 | — | M1~M6 |

## 게이트 W — 웹 직접 다운로드 (Developer ID)

| ID | 항목 | 상태 | 근거 | 담당 작업 | 검증 방법 | 선행조건 |
|---|---|---|---|---|---|---|
| W1 | Developer ID 서명 + Hardened Runtime | **차단** | 유효 인증서 0개. `pbxproj`에 `ENABLE_HARDENED_RUNTIME` 없음 | 인증서 설치 후 hardened runtime 설정(마이크는 같은 `device.audio-input`) | `codesign -dv --verbose=4`, `spctl -a -vv` | C1 |
| W2 | 공증·스테이플 | 미완료 | 스크립트·lane 없음 | notarytool 제출·staple | `xcrun stapler validate`, 다른 Mac Gatekeeper | W1 |
| W3 | 결제/Pro | 완료(코드, 미커밋) | D1, C8: 직접판(`HUMTRACK_MAC_APP_STORE=false`)은 가격·구매·복원 숨김, 계정 Pro 안내 | — | `paywall_channel_test.dart`, `fastlane mac build channel:direct` 마커 검증 | — |
| W4 | 번들 ID·콜백 분리 | 완료(코드) / 차단(운영 redirect) | C11 | 운영: Supabase Redirect URLs에 `humtrack-direct://auth/callback`, Apple Developer 직접판 App ID | 두 판 동시 설치 후 각자 로그인 복귀 | C1, 운영 redirect |
| W5 | 패키징·다운로드 페이지 | 미완료 | DMG/zip·랜딩 링크 없음(랜딩은 main/`web`) | DMG, 다운로드 페이지, 체크섬 | 다운로드→설치→실행 | W2 |
| W6 | 업데이트 안내 | 미완료 | 자동 업데이트 없음 | 원격 공지 macOS 채널(`announcement_service.dart:67`) 활용 | 구버전에서 공지 표시 | W5 |
| W7 | 정책 고지 | 확인필요 | 앱 내 정책 배너(시행일 2026-10-20) | 다운로드 페이지에 정책 링크 | 페이지 확인 | — |

---

## 순서 (의존성 기준)

1. C0 커밋(코드·정적 검증 완료분).
2. 사용자 조치로 풀리는 차단: 서명 인증서 설치(C1, I8, W1), ASC 로그인(I1, S1), Xcode/CoreSimulator 정상화(I6).
3. 게이트 I: iPhone 실기 QA → TestFlight → 제출.
4. 게이트 M: Mac TestFlight로 기존 iOS-on-Mac 사용자 업데이트 시나리오 검증(C3 로그인 포함).
5. 게이트 S: MAS 업로드·심사·단계적 전환.
6. 게이트 W: 운영 redirect 추가 → Developer ID 서명·공증·배포 페이지. S와 병행 가능하나 C1·운영 redirect에 의존.

## 검증 기록 (이 작업 공간, 미커밋 상태, 2026-10-31)

| 검증 | 결과 | 비고 |
|---|---|---|
| `flutter analyze` | No issues found (exit 0) | C11 이후 코드 기준 |
| `flutter test` 전체 | **+1031 ~30, All tests passed** (실패 0) | C11 이후 코드 기준. 이전 10건 실패 해소(C10): qa_cloud 4건은 실제 실행·통과, gotye fixture 3개 파일은 사유와 함께 skip |
| iOS `flutter build ios --release --no-codesign` | `✓ Built build/ios/iphoneos/Runner.app (164.0MB)` | 서명 없음 |
| Ruby `tool/release_support_test.rb` | 24 runs, 71 assertions, 0 failures | Ruby 3.4.1 |
| macOS clean release 빌드 `app-store` | `Release/HumTrack.app`, `com.humtrack.app`, 스킴 `humtrack`, 채널 `app-store` PASS / `direct` 거부 | |
| macOS clean release 빌드 `direct` (`--flavor direct`) | `Release-direct/HumTrack.app`, `com.humtrack.app.direct`, 스킴 `humtrack-direct`, 채널 `direct` PASS / `app-store` 거부 | |
| macOS 산출물 공통 | Info.plist 카테고리·수출 규정·URL 스킴, `PrivacyInfo.xcprivacy` 포함, 최소 12.0, `x86_64 arm64`, 이름 HumTrack | |
| 빌드 후 파일 안정성 | 최종 iOS·macOS 빌드 전후 `project.pbxproj`·`contents.xcworkspacedata`·`Podfile` 해시 동일 | C2 |
| 미실행/차단 | iPhone 실기(실기 연결 확인 불가, CoreSimulator 문제), 서명 빌드(인증서 0개), ASC 조회(세션 만료), 운영 로그인 redirect(미접속) | |
