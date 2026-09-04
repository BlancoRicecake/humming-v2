# Mac 작업지시서 — 2026-09 앱 릴리스

> 그대로 위에서 아래로 실행하면 된다. 각 단계는 **명령 → 기대 결과 → 실패 시** 순서.
> 선행 조건: [DEPLOY-RUNBOOK-2026-09.md](DEPLOY-RUNBOOK-2026-09.md) 의 백엔드 배포가 **이미 끝나 있어야 한다.**
> 이번 빌드는 네이티브 코드(Swift/Kotlin)가 바뀌었고 **Windows 에서는 한 번도 컴파일된 적이 없다.** 3번(컴파일)이 이 작업의 핵심 관문이다.

---

## 0. 왜 Mac 에서 다시 확인해야 하나

이번 변경분에 다음 네이티브 코드가 포함된다. 문법은 눈으로 검토했으나 빌드 검증은 못 했다.

| 파일 | 변경 |
|---|---|
| `ios/Runner/AppDelegate.swift` | `AVAudioSession.interruptionNotification` 옵저버 + `excludeFromBackup` 메서드 채널 |
| `ios/Runner/AutotuneMonitor.swift` | IO 버퍼 duration 저장/복원 |
| `android/app/src/main/kotlin/com/humtrack/app/MainActivity.kt` | `sdkInt`, `openAppSettings` 메서드 |
| `android/app/src/main/AndroidManifest.xml` | Bluetooth 권한 3종 제거, backup rules 2종 추가 |
| `android/app/src/main/res/xml/{backup_rules,data_extraction_rules}.xml` | 신규 |

---

## 1. 저장소 준비

```bash
cd ~/path/to/humming-v2          # 실제 경로로
git checkout main
git pull
git log --oneline | head -5      # 최신 커밋이 2026-09 작업분인지 확인
```

**기대**: `perf(mobile): stop rebuilding the editor...` 등 2026-09 커밋들이 보인다.

---

## 2. 시크릿 확인

빌드는 `backend/.env.secrets` 에서 dart-define 을 읽는다 (gitignore 됨 — Mac 에 없으면 만들어야 한다).

```bash
cat backend/.env.secrets | grep -E "^(SUPABASE_URL|SUPABASE_ANON_KEY|GOOGLE_WEB_CLIENT_ID|ENGINE_URL|CLARITY_PROJECT_ID|SENTRY_DSN_MOBILE)=" | sed 's/=.*/=<설정됨>/'
```

**기대**: 6줄 모두 `<설정됨>`.
**실패 시**: `backend/.env.secrets.example` 을 복사해 값을 채운다. 특히 `SENTRY_DSN_MOBILE` 이 없으면 이번에 대폭 늘린 결제·인증 오류 리포팅이 전부 사라진다.

App Store Connect API 키도 필요하다:

```bash
cat mobile/ios/fastlane/.env.secrets 2>/dev/null | sed 's/=.*/=<설정됨>/'
# ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_FILEPATH 3개
```

---

## 3. 컴파일 관문 ⚠️ 여기가 핵심

```bash
cd mobile
flutter --version                # 3.47.x stable 이면 OK
flutter clean
flutter pub get                  # Mac 에서는 정상 동작 (Windows 는 symlink 제약으로 불가했음)
flutter analyze                  # 기대: 0 errors (info 4개는 알려진 것)
flutter test                     # 기대: 132+ passed
```

이어서 **양 플랫폼 실제 컴파일**:

```bash
flutter build ios --release --no-codesign
flutter build apk --release
```

**기대**: 둘 다 성공.
**실패 시** — 네이티브 변경이 원인일 가능성이 높다. 오류 위치별 대처:

| 오류 위치 | 확인할 것 |
|---|---|
| `AppDelegate.swift` | `AVAudioSession.interruptionNotification` 옵저버 클로저의 `channel` 캡처, `AVAudioSessionInterruptionTypeKey` 캐스팅 |
| `AutotuneMonitor.swift` | `savedIOBufferDuration` 프로퍼티 선언 위치가 다른 프로퍼티 사이에 끼어 있는지 (선언 순서 문제는 아니나 diff 상 그렇게 보임) |
| `MainActivity.kt` | `Settings.ACTION_APPLICATION_DETAILS_SETTINGS` import, `packageName` 접근 |
| manifest / xml | `backup_rules.xml` 의 `domain="root"` 경로 문법 |

수정 후 커밋해 두고 아래를 계속 진행한다.

---

## 4. 버전 올리기

```bash
# mobile/pubspec.yaml — 현재 1.0.5+31
sed -i '' 's/^version: 1.0.5+31$/version: 1.0.6+32/' pubspec.yaml
grep '^version:' pubspec.yaml       # 기대: version: 1.0.6+32
```

---

## 5. 릴리스 노트

이번 빌드는 사용자에게 보이는 변화가 크다 (한국어 UI, 결제 안정성, 오디오 인터럽션, 내보내기 정확도). 아래를 그대로 넣어도 되고 다듬어도 된다.

```bash
cat > ios/fastlane/metadata/ko/release_notes.txt <<'EOF'
업데이트

- 앱 화면을 한국어로 전면 번역했습니다.
- 전화·알람이 와도 소리가 끊기거나 녹음이 잘리지 않도록 오디오 처리를 개선했습니다.
- 구독 상태 확인 방식을 개선했습니다. 네트워크가 불안정해도 이용 중인 기능이 유지됩니다.
- 내보내기에서 추가 트랙의 악기와 볼륨이 재생과 동일하게 반영됩니다.
- 한글 제목으로도 파일이 올바르게 저장됩니다.
- 마이크 권한을 거부한 경우 설정으로 바로 이동할 수 있습니다.
- 곡 데이터 저장 방식을 개선해 앱이 갑자기 종료돼도 작업물이 남습니다.
EOF

cat > ios/fastlane/metadata/en-US/release_notes.txt <<'EOF'
What's new

- The app is now fully translated into Korean.
- Audio no longer breaks up or truncates a take when a call or alarm interrupts.
- Subscription status is checked more reliably, so Pro keeps working on a flaky connection.
- Exports now match playback for added tracks' instruments and levels.
- Files save correctly when the song title is not in English.
- If microphone access was denied, you can jump straight to Settings.
- Song data is saved more safely, so work survives an unexpected quit.
EOF

# Android (버전 코드 = 32)
cp ios/fastlane/metadata/ko/release_notes.txt android/fastlane/metadata/android/ko-KR/changelogs/32.txt
cp ios/fastlane/metadata/en-US/release_notes.txt android/fastlane/metadata/android/en-US/changelogs/32.txt
```

> Play 는 changelog 500자 제한이 있다. 넘치면 항목을 줄인다.

---

## 6. TestFlight 업로드

```bash
cd mobile/ios
bundle exec fastlane beta
```

`fastlane beta` 가 하는 일: dart-define 주입 → `flutter build ios --release --no-codesign` → `build_app` → TestFlight 업로드 (처리 완료까지 대기).

**기대**: 업로드 성공, App Store Connect 에 빌드 1.0.6(32) 등장.

"What to Test" 문구를 이번 빌드에 맞게 바꾸려면:

```bash
TF_CHANGELOG="결제(구매·복원·해지), 전화 수신 중 녹음/재생, 한국어 UI, 내보내기 파일명(한글 제목)을 중점 확인해주세요." bundle exec fastlane beta
```

---

## 7. 실기기 확인 (TestFlight) — 이번 빌드의 필수 항목

Windows 에서 검증 불가능했던 것들이다. **최소 이 7가지는 실기기에서 직접 해볼 것.**

### 7-1. 오디오 인터럽션 (가장 중요, 과거 재발 이력 있음)
- [ ] 루프 재생 중 **자신에게 전화를 걸어** 수신 화면을 띄웠다가 거절 → 소리가 정상 복귀하는가
- [ ] 재생 중 Siri 호출 → 종료 후 소리 복귀
- [ ] 재생 중 제어센터를 내렸다 올림 → 패드 탭이 밀리지 않는가 (예전엔 피드 폭주로 수 초 지연 발생)
- [ ] 허밍 녹음 중 알람/알림 → "녹음이 중단되었어요" 메시지가 뜨는가 (조용히 잘리면 안 됨)

### 7-2. 헤드셋
- [ ] 유선/블루투스 헤드셋 연결 후 허밍 녹음 → 반주가 **헤드셋으로** 나오는가 (스피커로 새면 안 됨)
- [ ] 녹음 중 헤드셋 분리 → 크래시 없이 처리

### 7-3. 결제 (샌드박스 계정)
- [ ] 구매 → 즉시 Pro 활성
- [ ] Settings → Apple ID → 구독에서 **해지** → 앱 재실행 시 만료일까지는 Pro 유지
- [ ] 만료 후(샌드박스는 가속됨) → Pro 해제
- [ ] "구매 복원" → 올바른 메시지 ("복원되었습니다" / "이미 이용 중" / "복원할 구매가 없습니다")
- [ ] 결제 취소(시트 닫기) → **오류 메시지가 뜨지 않아야 함**
- [ ] 기내모드에서 앱 재실행 → 유료 사용자가 결제창으로 튕기지 않는가

### 7-4. 마이크 권한
- [ ] 설정에서 마이크 권한 끄기 → 녹음 시도 → "설정 열기" 버튼이 뜨고 실제로 설정 앱으로 이동하는가

### 7-5. 한국어 UI
- [ ] 기기 언어 한국어 → 에디터 전체가 한국어인가
- [ ] 기기 언어 영어 → 영어인가 (한국어가 섞이면 안 됨)

### 7-6. 내보내기
- [ ] 한글 제목 곡을 WAV/MIDI 로 내보내기 → 파일명이 `_` 로 뭉개지지 않는가
- [ ] 추가 트랙(Bass 2 등)에 카탈로그 사운드 지정 → 내보낸 WAV 에서 그 악기로 들리는가
- [ ] 여러 섹션 곡 전체 재생 → 추가 트랙이 들리는가

### 7-7. 데이터 보존
- [ ] 편집 중 앱 강제 종료 → 재실행 시 작업물이 남아 있는가
- [ ] 곡 전부 삭제 → 재실행 시 데모 곡이 되살아나지 않는가

### 7-8. (Android 기기가 있으면)
- [ ] Android 9 이하 기기에서 허밍 녹음 (Opus → AAC 폴백)
- [ ] 마이크 권한 거부 후 "설정 열기"

---

## 8. 심사 제출

7번을 통과했으면:

```bash
cd mobile/ios
bundle exec fastlane release      # 빌드 + 업로드 + 심사 제출 (자동 출시 안 함)
```

`automatic_release: false` 이므로 승인 후 수동으로 출시 버튼을 눌러야 한다.

**Android**:

```bash
cd mobile/android
bundle exec fastlane internal     # 내부 테스트 트랙
# 확인 후 Play Console 에서 프로덕션 승격
```

---

## 9. 출시 후

- [ ] Sentry `humming-mobile` 에서 크래시 급증 없는지 24시간 관측
- [ ] 백엔드 로그에서 `/iap/verify` 호출이 정상인지 (`fly logs -a humming-api | grep "iap verify"`)
- [ ] 웹훅 매핑 성공 확인:
  ```sql
  select count(*) filter (where error = 'no_user') as unmapped,
         count(*) filter (where processed_at is not null) as ok
    from iap_notifications where received_at > now() - interval '2 days';
  ```
  새 앱 사용자가 늘수록 `unmapped` 가 줄어야 한다.
- [ ] 1주일 뒤 `python backend/tools/reconcile_subscriptions.py --apply`

---

## 문제가 생기면

| 증상 | 원인 후보 | 확인 |
|---|---|---|
| 유료 사용자가 Pro 를 잃음 | 백엔드 `SUPABASE_JWT_SECRET` 미설정 | `fly logs` 에 `AUTH DISABLED` / `/iap/status` 가 503 |
| 구매는 되는데 Pro 안 켜짐 | `/iap/verify` 400 | Fly 로그의 `apple jws signature invalid` → 영수증 체인 검증 문제, 즉시 보고 |
| 녹음 후 소리 깨짐 | iOS 오디오 세션 | `docs/lessons.md` 의 과거 사례 참고 |
| 앱 시작 시 크래시 | 네이티브 채널 | Xcode 콘솔에서 `humming/audio` 채널 오류 확인 |

롤백: App Store 는 이전 버전으로 되돌릴 수 없다. 심각하면 **출시 중단(Remove from sale) 후 핫픽스**가 유일한 경로이므로, 7번 실기기 확인을 건너뛰지 말 것.
