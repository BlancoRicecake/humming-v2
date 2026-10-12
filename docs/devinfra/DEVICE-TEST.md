# 실기기 검증

## 1. 기기별 앱 받는 법

| 기기 | 개발 중 | 출시 후보 |
|---|---|---|
| Android 폰 | PC에 USB 연결(또는 무선 디버깅) → `bash mobile/scripts/run.sh -d <id>` | Actions `platform=android, destination=internal` → Play 내부 테스트 |
| iPad | Mac과 같은 Wi-Fi일 때 Mac Codex가 `run.sh -d <id>` ([`MAC-REMOTE-SETUP.md`](MAC-REMOTE-SETUP.md)) | Actions `platform=ios, destination=internal` → TestFlight |
| Windows | `flutter run -d windows` | `flutter build windows --release` 폴더 전체 |
| Mac | `flutter run -d macos` (Mac에서) | 미정 (데스크톱 트랙 D4) |

- PC에서 `run.sh`는 Git Bash로 실행한다.
- `run.sh` 없이 `flutter run`하면 로그인이 꺼진 빌드가 된다. "이 빌드에는 로그인이 설정되어 있지 않아요"가 뜨면 설정 주입부터 의심한다.
- **iPhone이 없다.** 작은 세로 화면은 iOS 시뮬레이터로, 통화 인터럽션은 iPad의 FaceTime 수신으로 대신 확인한다. 출시 전 iPhone 확인이 꼭 필요한 변경(오디오 경로, 통화)은 지인 기기 TestFlight를 고려한다.

## 2. 빌드마다 스모크 (약 10분, 바뀐 플랫폼 전부)

- [ ] **업데이트 설치**: 이전 버전 위에 설치 → 기존 곡·보컬·구독 상태 유지
- [ ] 첫 실행이 바로 꺼지지 않는다 (iOS 1.0.9 재발 방지)
- [ ] 로그인 (Google / Apple) 성공
- [ ] 허밍 녹음 → 변환 → 듣기 → 저장 → 앱 종료 후 다시 열기
- [ ] 녹음 중·후 소리가 지직거리지 않는다
- [ ] 재생 중 알림·통화 인터럽션 후 소리가 돌아온다 (모바일)
- [ ] 이어폰 연결 상태에서 녹음 → 반주가 이어폰으로만 나온다 (모바일)
- [ ] WAV·MIDI 내보내기 (Pro 계정) — 파일을 열어 실제로 들어 본다
- [ ] 한국어 / 영어 표시가 섞이지 않는다

변경 영역에 따라 추가: 결제·복원·만료(`MAC-WORKORDER-2026-09.md` 7-3), 마이크 권한 거부(7-4), 데스크톱 키보드·단축키.

## 3. 기록 양식

`docs/qa/<날짜>-<버전>.md`로 남긴다.

```markdown
# 1.0.12 (42) — 2026-10-xx
커밋: <sha> · 받은 경로: Play 내부 / TestFlight / run.sh
| 기기 | OS | 결과 | 메모 |
|---|---|---|---|
| Android <모델> | Android xx | 통과 / 실패 | |
| iPad <모델> | iPadOS xx | | |
| Windows | 11 | | |
실패 항목과 재현 방법:
```

## 4. 출시 직후 24시간 확인

Sentry는 앱 시작 전 네이티브 크래시를 못 본다. 그래서 스토어 쪽 지표를 같이 본다.

- [ ] App Store Connect → TestFlight/앱 → 크래시 (또는 Xcode Organizer)
- [ ] Play Console → Android vitals → 비정상 종료·ANR
- [ ] Sentry `humtrack-mobile`에 새 릴리스 이벤트가 들어오는가 (아무것도 안 들어오면 DSN부터 의심)
- [ ] Clarity 플랫폼별 세션 수가 출시 전과 비슷한가 (급감 = 시작 크래시 신호)
- [ ] `curl -fsS https://api.hum-track.com/health`
