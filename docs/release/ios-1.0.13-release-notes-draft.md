# iPhone 1.0.13 (43) 출시 노트 초안 (2026-10-31)

- 대상: App Store 공개 버전 1.0.10 이후 iPhone 사용자에게 처음 가는 변경. 1.0.11·1.0.12는 Android에만 나갔다(태그 `v1.0.11+40`, `v1.0.12+41`).
- 기준 코드: `origin/develop` `4f5f34d` + `.worktrees/develop-build-check`의 미커밋 수정(체크리스트 C0).
- 스토어 문구에는 이모지를 쓰지 않는다(App Store whatsNew 409 전례).
- 적용: 리뷰 후 `mobile/ios/fastlane/metadata/{ko,en-US}/release_notes.txt`에 옮기고 `fastlane ios sync_metadata` 또는 `submit_release`로 보낸다. 이 초안 작성 시 메타데이터 파일은 바꾸지 않았다.

## ko

```text
• 첫 화면에서 로그인 없이 바로 첫 곡을 시작할 수 있어요
• 녹음한 보컬 클립을 악기 트랙(MIDI)으로 바꿀 수 있어요
• MIDI 파일의 원하는 구간을 새 섹션으로 가져올 수 있어요
• 기타 소리가 연주법에 따라 더 자연스럽게 나요
• 곡 저장이 더 안정적이고, 다른 기기에서 만든 백업 파일(.humtrack)을 열 수 있어요
• 앱 안에서 공지사항을 확인할 수 있어요
• 내보낸 파일을 더 쉽게 찾을 수 있어요
• 설정 화면 표기와 드럼 킥 이름 표시를 고쳤어요
• 오픈소스 라이선스 고지를 보완했어요
```

## en-US

```text
• Start your first song right from the home screen, no sign-in needed
• Turn recorded vocal clips into instrument tracks (MIDI)
• Import any passage of a MIDI file as a new section
• Guitar parts sound more natural, following how they are played
• Saving is more reliable, and you can open backup files (.humtrack) made on another device
• Read announcements inside the app
• Exported files are easier to find
• Fixed labels in Settings and the drum kick name
• Updated open-source license notices
```

## 항목별 근거

| 항목 | 근거 |
|---|---|
| 로그인 없이 첫 곡 | `11f1419` feat: streamline guest first-song creation (`first_song_card.dart`) |
| 보컬 클립 → MIDI, 내보낸 파일 찾기 | `b87fd46` feat: convert vocal clips to MIDI and make exported files discoverable |
| MIDI 구간 → 새 섹션 | `88d51a6` "MIDI passage -> new section import"; 홈 `MIDI +` 버튼은 화면 폭과 무관하게 표시(`songs_screen.dart:202`) |
| 기타 연주법 | `88d51a6` "Guitar realism G0-G4: strokes, string assignment/ring/choke, articulations" (재생 엔진 공통, iPhone 체감은 실기 확인 필요) |
| 저장 안정화·백업 파일 열기 | `4f5f34d` `project_backup.dart`, 설정 "백업 열기" |
| 공지사항 | `4f5f34d` `announcements/` (서버 공지 사용) |
| 설정 표기·킥 이름 | 이번 작업 공간 수정: `settings_sheet.dart`(보컬 싱크 번역, 화살표), `drum_surface.dart`(킥 라벨) |
| 라이선스 고지 | `8351102` |

## 넣지 않은 것

- 클라우드 백업: `kCloudBackupEnabled`가 `HUMTRACK_CLOUD_BACKUP` 기본값 false(`lib/looptap/state/cloud_backup.dart:33-35`), 릴리스 define 목록에 없음.
- ui-000~005(상단 바 재생, 섹션 띠, 편곡/편집 보기, 인스펙터): 데스크톱 편집기 중심(`desktop_*` 위젯, `EditScreen._desktop`). 시트 테마 통일(ui-000)은 모든 기기에 적용되지만 사용자 기능 변화가 아니라 생략.
- Mac 전용 변경(서명 채널, 직접판 페이월, HumTrack 이름 등).
