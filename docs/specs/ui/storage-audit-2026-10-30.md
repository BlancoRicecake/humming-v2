# 저장·백업·내보내기 점검 (2026-10-30)

범위: Flutter 앱(`mobile/`)의 곡 저장, 녹음 파일, 내보내기(WAV/MIDI/stems), 새 프로젝트 백업(`.humtrack`), 데스크톱 창 닫기 저장.
작업 방식: Claude가 수정하고 Codex가 독립 검토·재현했다(`artifacts/storage-audit-2026-10-30/`).
커밋·push·PR·배포는 하지 않았다. 현재 브랜치 `codex/ui-005-beginner-polish`의 기존 미커밋 변경은 그대로 두었다.

## 1. 결론

| 항목 | 상태 |
|---|---|
| 자동 저장(12초)·명시 저장·뒤로가기·백그라운드 전환 | 기존대로 동작. 저장 revision을 추가해, 늦게 끝난 이전 저장이 새 편집을 "저장됨"으로 표시하지 않게 했다 |
| 데스크톱 창 X | **수정**. 마지막 편집을 저장한 다음에 닫는다. 저장 실패 시 창과 편집 내용을 유지하고 대화상자를 띄운다(기본: 계속 편집 / 다시 저장 / 명시적 "저장하지 않고 종료"). 진행 중인 뒤로가기 저장은 기다리고, 중복 종료 요청은 한 번에 처리한다 |
| 손상·복구 알림 | **추가**. `.bak`에서 복구, 일부 곡 건너뜀, 읽기 실패, 더 새 버전 파일 중 하나면 곡 목록 상단에 알림을 띄운다(데스크톱은 저장 폴더 경로 포함) |
| S1 `.bak`만 참조하는 녹음 삭제 | **수정**. `.bak`이 참조하는 녹음도 지우지 않는다. `.bak`을 읽을 수 없으면 정리를 멈춘다 |
| S2 메인 파일이 없을 때 더 새 스키마 `.bak` 덮어쓰기 | **수정**. 메인 파일과 `.bak` 둘 다 확인해 저장을 거부한다 |
| S3 곡 보컬 stem에 볼륨 미반영 | **수정**. 믹스와 같은 일정으로 gain·pan을 적용한다(정규화하지 않음) |
| S4 섹션 보컬 stem의 위치·반복 누락 | **수정**. 보컬 트랙마다 곡 전체 길이로, 섹션 오프셋·반복·trim·fade를 적용한다 |
| B3 stem 길이 불일치(멜로디 11.2초 / 보컬 10초) | **수정**. 모든 stem이 같은 시작과 같은 끝(곡 길이 + 잔향 1.2초)을 가진다 |
| S5 손상 오디오가 `.wav`로 "성공" 출력 | **수정**. 내보내기 전에 WAV를 검증하고, 손상된 파일은 건너뛰어 개수를 안내한다. 쓰기는 `.part`에 먼저 하고 끝난 뒤 이름을 바꾸므로 반쯤 쓴 파일이 남지 않는다 |
| S6 Windows 예약 이름(CON/NUL/COM1…) | **수정**. `_CON`처럼 바꾸고 한글은 보존한다. 대체 이름에도 같은 규칙을 적용한다. 같은 제목을 동시에 내보내도 배타적 생성으로 서로 다른 파일이 된다 |
| 이식 가능한 프로젝트 백업/가져오기 | **신규** `.humtrack`(아래 3장). 가져오기 검증 문제 B1·B2·B4와 Android 선택기 문제 B5까지 수정했다 |

## 2. 저장 위치 — 초보자에게 보이는 구분

| 구분 | 위치 | 누가 고르나 | 화면 표현 |
|---|---|---|---|
| 앱 안 곡 보관함(편집 가능) | 앱 전용 `Documents/looptap/songs.json` + `vocals/` | 앱(자동) | 곡 목록. 저장 상태는 편집기 상단의 "저장됨/저장 안 됨" |
| 앱 안 "내보낸 파일" | 앱 전용 `Documents/looptap/exports/` (iCloud 백업 제외) | 앱(자동) | 설정 › 내보낸 파일. 공유하거나 "파일에 저장"을 할 수 있다 |
| 사용자가 고른 외부 위치 | Android 시스템 저장 화면(SAF), Windows/Mac 저장 대화상자, iOS 공유 → 파일 | 사용자 | 저장/취소/실패를 각각 안내 |
| 클라우드 | 없음(Supabase는 로그인 전용) | — | 표시하지 않음 |

- Windows에서 앱 전용 폴더는 path_provider의 Documents 아래 `looptap/`이다. 불러오기 문제가 생기면 알림 배너에 경로가 표시된다.
- Android Auto Backup은 songs와 vocals를 포함한다. exports는 iOS에서 백업 대상에서 제외된다.
- 저장 실패는 오류를 숨기지 않고 알린다. 편집기는 편집 내용을 유지한 채 다시 저장하고, 백업/가져오기는 "아무것도 바꾸지 않았어요"라고 안내한다.

## 3. 지원 형식 (코드 근거)

| 형식 | 확장자 / MIME | 내용 | 근거 |
|---|---|---|---|
| 앱 보관함 | `songs.json` | `{"v":3,"songs":[…]}`, 원자적 저장(`.tmp`→`.bak`→rename). 손상되면 `.corrupt-<ms>`로 보존한다. 녹음은 basename으로만 참조 | `state/loop_storage.dart`, `Song.kSchemaVersion = 3` |
| **프로젝트 백업 v1** | `.humtrack` / 공유·저장 시 `application/octet-stream` | **stored ZIP(압축 없음)**: `manifest.json`(format `humtrack-project`, formatVersion 1, songSchema 3, 파일별 size와 sha256, `missing`), `song.json`(`{"v":3,"song":…}`), `audio/<원래 이름>`(바이트 그대로) | `state/project_backup.dart` |
| 전체 곡 WAV | `.wav` / `audio/wav` | RIFF PCM 16bit, 44.1kHz, 스테레오, 정규화. 음소거는 볼륨 0으로 제외, solo는 미적용. 녹음은 섹션 위치와 반복대로 배치. 손상된 녹음은 건너뛰고 개수를 안내 | `music/wav_export.dart` `exportWavSong`, `_sr = 44100` |
| stems | 여러 `.wav` / `audio/wav` | 악기 트랙마다 하나, 보컬 트랙마다 하나(곡 보컬이 있으면 `vocal (song)` 하나). **모든 파일이 0초에서 시작하고 같은 프레임 수(곡 길이 + 1.2초)**. 보컬은 믹스와 같은 gain·pan, 정규화 없음 | `exportStems` |
| MIDI | `.mid` / `audio/midi` | SMF format 0, 트랙 1개. PPQ 96(정밀 타이밍/아티큘레이션이 있으면 9600). 템포 메타 하나(FF 51). 채널별 Program Change, 팬 CC10, 노트별 velocity. 4/4 박자 메타·트랙 이름·CC7 볼륨은 없음. 808/커스텀 음색은 가까운 GM 음색으로 대체. 보컬 오디오는 담지 않음 | `music/midi_export.dart`, Codex 독립 파서 결과 |
| 녹음(앱 내부) | `vocals/*.wav` 등 | 새 보컬은 PCM16 WAV. 허밍은 Windows WAV, iOS opus `.caf`, Android 10 이상 opus `.ogg`, 그 미만 AAC `.m4a`. 예전 opus 녹음은 내보낼 때 변환 캐시 `.cnv.wav`를 만든다 | `audio/container.dart`, `wav_export.dart` |

**WAV와 MIDI는 편집 가능한 프로젝트 백업을 대신하지 못한다.** WAV는 완성된 소리이고, MIDI는 노트만 담는다(녹음·음색·섹션·믹서 상태가 빠진다). 다시 편집하려면 `.humtrack`을 쓴다.

지원하지 않는 형식과 우선순위:
1. stems ZIP 묶음 + 기술 메타(BPM/키/길이) — 다음 후보
2. MIDI Type 1(트랙별 분리, 트랙 이름, 박자 메타) — DAW 편의 기능
3. MP3/AAC(공유용), FLAC(무손실 압축), PCM24/48kHz 옵션 — 지원하지 않으며 차후 후보
4. MusicXML — 악보 기능 요구가 생기면 검토
5. 별도 Studio `.hstudio`(자체 JSON schema 1)와는 호환되지 않는다. 변환은 별도 설계가 필요하다

## 4. `.humtrack` 가져오기 규칙

압축을 풀기 전에 원본 ZIP의 **중앙 디렉터리를 직접** 읽어 판단한다(B4). archive 패키지의 ZipDecoder는 같은 이름 엔트리를 합치고, `verify` CRC 검사가 주석 처리되어 있어서 쓰지 않는다.

- 거부하는 경우:
  - 디스크가 여러 개인 ZIP, zip64, 암호화, 유닉스 심볼릭 링크
  - 압축된 엔트리(stored만 허용하므로 압축 해제를 하지 않는다)
  - 대소문자를 무시했을 때 중복되는 이름
  - 로컬 헤더 이름 불일치, 데이터 범위 초과나 엔트리끼리 겹침
  - CRC-32 불일치
  - 엔트리 수가 2000+3개를 넘는 경우, 입력이나 총합이 1GB를 넘는 경우, 녹음 하나가 512MB를 넘는 경우, JSON이 32MB를 넘는 경우
- 허용하는 경로는 `manifest.json`, `song.json`, `audio/<안전한 이름>`뿐이다. `..`, 절대 경로, `\`, 드라이브 문자, 하위 폴더, 장치 이름, 그 밖의 파일은 거부한다.
- format이나 songSchema가 이 앱보다 새것이면 거부하고 업데이트를 안내한다.
- manifest의 각 파일은 크기와 SHA-256이 일치해야 한다. 곡이 참조하는 녹음은 모두 포함돼 있거나 `missing`(백업 당시 이미 없던 것)에 기록돼 있어야 한다.
- 가져온 곡은 항상 **새 곡**이 된다. 새 id(같은 ms 안에서도 겹치지 않음)를 받고, 녹음도 모두 새 이름 `imp<stamp>[-n]_<원래 stem>.<확장자>`(최대 200자, 대소문자 무시 충돌 회피)으로 저장된다. 기존 곡이나 녹음을 덮어쓰지 않는다(B2).
- 백업 당시 이미 없던 녹음도 **존재하지 않는 새 이름**으로 바꾼다. 그래서 대상 기기에 있는 같은 이름의 다른 녹음에 연결되지 않고, 소리 없이 남는다. 화면에 누락 개수를 안내한다(B1).
- 파일 쓰기와 목록 저장은 하나의 직렬화된 변경으로 처리한다. 그 사이에 녹음 정리(sweep)가 끼어들 수 없다. 실패하면 쓴 녹음을 지우고 기존 목록을 유지한다.
- 무료 곡 수 제한은 "새 곡"과 똑같이 적용한다. 백업 만들기는 무료다.
- 진입점:
  - 곡 카드 메뉴 › "백업 파일 만들기": 내보낸 파일 폴더에 저장한 뒤 안내와 "파일 보기" 버튼을 보여 준다.
  - 곡 목록 상단 아이콘(넓은 화면) 또는 설정 › "백업 열기".
- 파일 선택기 필터(B5):
  - Android: `mimeTypes: ['*/*']`. UTI만 넣으면 file_selector_android가 선택 화면을 열기 전에 ArgumentError를 던졌다.
  - iOS: `public.data`
  - 데스크톱: `.humtrack` 확장자
  - 모바일은 모든 파일을 보여 주고 내용으로 판정한다.
  - Android 저장(SAF) 허용 목록에 `humtrack`(`application/octet-stream`)을 추가했다.

## 5. 검증

**자동 테스트**
- `flutter analyze` 0건
- 전체 `flutter test` 973개 통과 / 17개 건너뜀 / 실패 0 (`artifacts/storage-audit-2026-10-30/claude/results/full-test.log`)
  - 증거용 `test/qa_storage_evidence_test.dart`는 이 실행 뒤에 추가했다. `QA_EVIDENCE_DIR`가 없으면 건너뛰므로, 다음 전체 실행에서는 건너뜀이 하나 늘어난다.
- 새 테스트 파일:

| 테스트 파일 | 확인하는 것 |
|---|---|
| `exit_save_test.dart` (8) | 창 닫기 저장, 실패 시 유지, 재시도, 명시적 미저장 종료, 중복 요청, 뒤로가기 저장 대기, 늦은 저장의 revision |
| `library_notice_test.dart` (8) | 불러오기 상태 4종과 알림 배너 |
| `export_integrity_test.dart` (9) | S3, S4, S5, S6, B3 |
| `project_backup_test.dart` (16) | 보컬 포함 백업 → 빈 기기 복원 → 다시 불러오기에서 같은 데이터, 원곡 옆에 가져와도 덮어쓰지 않음, 거부 사례, B1, B2, B4, 저장 실패 시 되돌림 |
| `songs_backup_ui_test.dart` (3) | 카드 메뉴 백업 → 안내 → 가져오기, 백업이 아닌 파일 거부, 취소 |
| `backup_picker_groups_test.dart` (3) | 실제 Android/iOS/Windows file_selector 어댑터 + 가짜 네이티브 호스트: 필터 전달과 취소 시 null |
| `pan_test.dart` | 수정: 보컬 stem의 pan과 gain |

**새 폴더 회귀 검증** (Codex의 기존 진단 파일은 덮어쓰지 않았다)
- `claude/postfix-evidence/`: `qa_storage_evidence_test.dart`(`QA_EVIDENCE_DIR`가 있을 때만 실행)로 실제 파일을 만들었다.
- 이 파일들을 `check-evidence.py`(Python 표준 라이브러리 zipfile/wave/hashlib만 사용)로 독립 검사했다. **23개 모두 통과**(`independent-check.json`):
  - ZIP CRC, 전체 stored, 이름 중복 없음, manifest 해시
  - 가져온 녹음 4개가 바이트 단위로 같음
  - B1: 같은 이름의 다른 녹음에 연결되지 않음
  - B2: 3회 가져오기가 빠르게 끝나고 이름과 id가 서로 다름
  - 거부 3종(ZIP 아님, CRC 불일치, 잘린 파일), 거부 시 아무것도 쓰지 않음
  - stems: 멜로디와 보컬이 493,920프레임으로 같음(= 10초 + 1.2초), 보컬 4초 전 무음과 4/6/8초 반복, 곡 보컬 gain 비율 0.25
  - 손상 녹음: 출력 0개, 건너뜀 1개 안내

**창 닫기 실기 확인** (Windows RELEASE QA 앱, 격리 데이터, `claude/exit-check/`)
- `save`:
  - WM_CLOSE가 Dart의 `didRequestAppExit`에 도달했다.
  - 닫기 전 songs.json에는 없던 편집(MIDI 67)이 닫은 뒤 songs.json에 기록됐다.
- `fail`:
  - `songs.json.tmp` 자리에 폴더를 만들어 실제 저장을 막았다.
  - X를 누르자 대화상자가 떴고 창은 열린 채로 남았으며, 그동안 아무것도 쓰지 않았다.
  - 막힌 것을 푼 뒤 "다시 저장"을 누르자 저장되고 종료됐다(`fail-dialog.png`).
- 어느 경우든 exit 0만으로 성공이라고 판단하지 않았다. 디스크 내용과 앱이 남긴 기록으로 판정했다.
- Codex는 별도로 실제 OS 마우스로 노트를 추가한 직후 X를 눌러, 디스크 반영까지 확인했다(`codex-native-close-proof.json`).

**빌드**
- 제품 Windows RELEASE를 `lib/main.dart`로 `mobile/build`에 다시 빌드했다(QA 진입점 흔적 없음).
- `artifacts/releases/current`는 건드리지 않았다.

## 6. 사용자(실기) 확인이 남은 항목 — 통과로 보고하지 않음

- Android/iOS 실기:
  - 시스템 파일 선택기로 `.humtrack` 열기와 취소
  - 내보낸 파일 › 파일에 저장(SAF), iOS 공유 → 파일, 저장한 `.humtrack`을 다른 기기에서 다시 열기
  - 이번 확인은 Dart 어댑터 경계까지만 했다.
- 휴대폰 ↔ PC 실제 왕복(폰에서 만든 백업을 PC에서 열기, 그 반대). 형식과 검증은 플랫폼 공통 코드이고 테스트로 확인했다.
- Mac 앱의 저장 대화상자와 창 닫기 저장.
- 실제 마이크 녹음과 청취: 내보낸 stem을 DAW에 넣고 정렬과 소리를 확인.
- 실제 키보드/IME 입력.

## 7. 다음 작업 제안

1. stems ZIP 묶음(+ BPM/키/길이 메타)과 MIDI Type 1
2. `.humtrack` 파일 연결: 모바일 "다른 앱에서 열기"·공유 받기, 데스크톱 더블클릭 열기
3. 커스텀 SF2/샘플 음색을 백업에 포함할지 결정(현재는 카탈로그 id 참조만 하고 파일은 포함하지 않음)
4. 저장 폴더 열기 버튼(데스크톱)

## 8. Codex 최종 Windows 시스템 파일 대화상자 검증

Claude 구현 완료 후 Codex가 현재 소스로 별도 격리 QA 앱을 빌드하여 실제 제품의 내보낸 파일 → Windows 다른 이름으로 저장 → 지정 폴더 .humtrack → 백업 열기 → Windows 열기를 한 번 왕복했다. 파일명은 시스템 접근성 Value로 지정하고 저장은 Alt+S, 열기는 실제 파일 항목을 마우스로 선택했다. 파일/폴더/프로젝트는 전부 저장소 내부의 생성 fixture다.

- 외부 저장 파일이 내부 .humtrack과 바이트 단위로 같고 ZIP CRC/오디오 SHA-256이 맞음.
- 원곡을 덮지 않고 새 곡이 추가됨. id/updatedAt/새 오디오 이름을 정규화하면 곡 필드 전체가 같고 녹음 bytes가 같음.
- FlutterError0, native X 종료코드0.
- 검증 후 제품 lib/main.dart로 RELEASE 복원 빌드 성공.
- 증거: artifacts/storage-audit-2026-10-30/windows-ui/verification.json 및 saved-native-file.png/imported-native-file.png.
- Codex의 추가 수정 후 수용 검사: 저장7개 + 백업7개 통과(backup-final/은 원본 진단과 다른 새 데이터 폴더).

Android/iOS 시스템 UI와 폰↔PC 실제 왕복, Mac 실기는 여전히 남아 있다. 사용자의 기존 작업은 보존했고, 브랜치 전환·커밋·push·PR·배포는 하지 않았다.
