# HumTrack 편곡 후보·곡 구성 TestFlight 인계

작성일: 2026-09-21  
브랜치: `codex/humtrack-songplan`  
예정 버전: **1.0.7 (37)**  
Bundle ID: `com.humtrack.app`  
App Store Connect 앱 ID: `6775845423`

## 이번 빌드에서 확인할 변화

1. 가이드의 반주 단계에서 `차분하게 / 통통 튀게 / 신나게` 중 분위기를 고른다.
2. 같은 분위기의 A·B·C 후보를 각각 미리듣는다. 미리듣기는 저장 중인 곡을 바꾸지 않는다.
3. `적용`을 누른 후보만 현재 구간의 코드·베이스·드럼에 반영된다. 실행 취소로 적용 전 상태를 복구할 수 있다.
4. `곡 구성 보기`에서 구간 선택·복제·순서 변경·반복 횟수를 조절한다.
5. 자동 편곡에서 유지할 멜로디·코드·베이스·드럼을 잠근다. 기본값은 사용자 멜로디 잠금이다.
6. 기존 원음정/보정음정 비교와 멜로디 확인 흐름은 그대로 유지된다.

## 완료된 검증

- `flutter analyze`: 문제 0건
- `flutter test`: **171개 통과**
- Android 디버그 APK 빌드 성공
- Pixel 에뮬레이터 가로 화면에서 가이드 진입 → 분위기 선택 → 후보 미리듣기 → 적용 → B/C 비교 → 곡 구성 모달을 직접 조작
- 위 흐름에서 Flutter 예외, Android 치명적 예외, RenderFlex overflow 없음
- 최신 App Store Connect 업로드는 **1.0.7 (36)**임을 확인했으므로 이번 빌드는 37로 지정

## GitHub Actions로 TestFlight 업로드

브랜치를 원격에 푸시한 뒤 GitHub Actions의 **Mobile Store Release**를 이 브랜치에서 실행한다.

| 입력 | 값 |
|---|---|
| Branch | `codex/humtrack-songplan` |
| platform | `ios` |
| destination | `internal` |
| build_number | `37` |
| replace_pending_ios_release | `false` |

이 실행은 테스트·정적 분석을 다시 수행하고, 운영 설정과 서명 인증서를 임시 러너에 설치한 뒤 IPA를 빌드하여 TestFlight에 업로드한다. App Store 심사 제출이나 자동 공개는 하지 않는다.

## iPhone/iPad에서 판단할 항목

- [ ] A·B·C 미리듣기 사이를 빠르게 바꿔도 원래 멜로디와 저장된 반주가 유지되는가
- [ ] `적용` 후 저장·앱 재실행 시 같은 반주가 복구되는가
- [ ] 실행 취소가 반주와 잠금 상태를 함께 복구하는가
- [ ] 코드/베이스/드럼 잠금 후 다른 후보를 적용해도 잠근 트랙이 유지되는가
- [ ] 섹션 복제·이동·반복 변경 후 곡 재생과 WAV/MIDI 내보내기 순서가 맞는가
- [ ] 작은 iPhone 세로 화면과 iPad 가로 화면에서 후보 카드와 곡 구성 화면을 모두 스크롤·조작할 수 있는가
- [ ] 기존 곡을 업데이트 설치 후 열었을 때 멜로디·보컬·구독 상태가 유지되는가

## Mac에서 직접 이어갈 때

```bash
git fetch origin
git switch codex/humtrack-songplan
git pull --ff-only origin codex/humtrack-songplan
cd mobile
flutter analyze --no-fatal-infos
flutter test
cd ios
bundle install
export HUMTRACK_BUILD_NUMBER=37
bundle exec fastlane ios doctor
bundle exec fastlane ios beta
```

운영 `GoogleService-Info.plist`, App Store Connect API 키 환경변수, 배포 인증서/프로비저닝 접근 권한이 필요하다. 키와 비밀번호는 Git에 넣지 않는다.
