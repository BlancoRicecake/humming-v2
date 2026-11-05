# HumTrack 4·5단계 Windows 검증 인계 — 2026-10-30

내일 Claude가 수정할 핵심은 **Windows 허밍 녹음 실패와 창 닫기 네이티브 충돌**이다. 아래 증거를 먼저 확인하고 작은 범위로 수정한다. 이번 검증에서는 제품 코드를 수정하지 않았다.

## 작업 기준과 보존할 것

- 저장소: `C:/src/humming-v2`. 현재 브랜치 `codex/ui-005-beginner-polish`, 커밋 `2406042`.
- 기존 미커밋 작업: `mobile/android/fastlane/metadata/android/ko-KR/changelogs/`의 삭제 표시 14개, `tools/inspect_ableton_sets.py`. 복구·삭제·스테이징하지 않는다.
- 현재 파일이 기준이다. 다른 소스 사본으로 덮어쓰지 않는다. 브랜치 전환·병합·push·PR·배포는 하지 않는다.
- Flutter는 `mobile/`에서 빌드하고 `mobile/build/`를 재사용한다. PC 실행 경로는 `C:/src/flutter/bin/flutter.bat`.
- 개인 곡·AppData·기존 `artifacts/releases/current`는 보존한다. 검증 데이터와 TMP/TEMP는 저장소 안의 격리된 검증 폴더를 쓴다.

## 해결 상태 (2026-10-30 Claude)

증거와 상세는 `artifacts/qa-fix-2026-10-30/README.md`에 있다. 수정은 커밋하지 않았다.

**P1-01 — 해결 (녹음 시작·중지·재생까지 확인, 변환은 미확인)**
- 원인(실기 확인)
  - 이 PC의 `isEncoderSupported(opus)`가 false였다.
  - 기존 Opus 설정의 `start()`가 `PlatformException(code: Record)`로 실패했다.
  - 마이크 권한은 있었다.
- 수정
  - `lib/audio/container.dart`의 `selectHumRecording`이 코덱과 확장자를 함께 고른다. Windows는 WAV이고, iOS·Android·Android 29 미만 AAC는 기존 그대로다.
  - `hum_modal.dart`: 플러그인 지원을 한 번 더 확인하고, 거부되면 WAV로 폴백한다. WAV도 없으면 '녹음 형식 없음' 안내를 보여 준다. 실패 로그에는 플랫폼·코덱·오류 코드만 남긴다.
- 결과
  - DEBUG와 RELEASE에서 제품 허밍 모달이 카운트인 → 녹음 → 자동 중지를 거쳐 WAV 약 1.9초 파일을 변환 콜백에 넘겼다. 이 파일은 재생된다.
  - 서버 변환(업로드)과 청취 품질은 확인하지 않았다.
- 증거: `artifacts/qa-fix-2026-10-30/close-after-debug.json`, `close-after-release.json`(probe 항목), `record-probe/hum-record-probe.json`

**P1-02 — 해결 (DEBUG와 RELEASE 모두 X 종료 코드 0)**
- 원인(기호로 확인)
  - 충돌 위치는 `std::default_delete<EventStreamHandler<EncodableValue>>`다.
  - `audioplayers_windows` 4.3.0의 static `globalEvents`와 이벤트 채널이 같은 핸들러를 함께 소유한다.
  - 엔진이 종료될 때와 프로세스가 종료될 때 두 번 지워진다(이중 해제).
- 수정: `mobile/third_party/audioplayers_windows`(같은 4.3.0 + 소유권 수정, `HUMTRACK_PATCH.md`)를 `dependency_overrides`로 연결했다.
- 결과
  - 수정 전 DEBUG는 같은 모듈·오프셋에서 충돌을 재현했다.
  - 수정 후 DEBUG와 RELEASE는 WM_CLOSE 종료 코드 0이고 새 이벤트 1000이 없다.
  - 수정 전 RELEASE는 이번 1회 실행에서 충돌로 드러나지 않았다.
- 증거: `close-before-debug.json`, `close-after-debug.json`, `close-before-release.json`, `close-after-release.json`

**테스트**
- analyze 0, 전체 922 통과·17 skip. 신규는 `recording_choice_test` 4개와 `hum_record_start_test` 4개다.

**남은 사용자 확인**
- 실제 마우스로 X 누르기(검증은 같은 WM_CLOSE로 함)
- 제품 실행본에서 허밍 → 변환 → 노트 입력과 청취
- 물리 키보드 단축키와 문자 입력
- macOS 녹음

## P1-01 — Windows 허밍 녹음 시작 실패

**관찰 및 재현**

1. 현재 5단계 검증 앱에서 Melody 편집 보기 → 도구 줄의 `허밍으로 넣기`를 한 번 누른다.
2. `허밍 → MIDI · Melody` 모달과 카운트인이 열린다.
3. 카운트인 뒤 `녹음을 시작할 수 없어요`로 바뀐다. 닫기 버튼으로 편집기에 돌아올 수 있다.
4. 녹음·변환 성공이나 소리 품질은 검증되지 않았다. 자동 QA의 `humButtonOpens`는 이 실패를 검사하지 않는다.

**증거**

- `C:/src/humming-v2/artifacts/ui-005-beginner-polish/codex-native-48-hum-escape.png`
- `C:/src/humming-v2/artifacts/ui-005-beginner-polish/codex-recovered-wait-stdout.log`: `[hum] >>> rec start, recordRate=16000` 이후 실패 화면.

**유력한 원인과 관련 코드**

- `mobile/lib/audio/container.dart:29`: `opusSupported(null)`이 true다. Android SDK가 없는 Windows도 이 경로로 들어간다.
- `mobile/lib/looptap/widgets/sheets/hum_modal.dart:223`: 이 값을 사용해 `.ogg` + `AudioEncoder.opus`로 녹음을 시작한다(`:234`).
- 현재 `record` 6.2.1 / `record_windows` 1.0.7. 설치된 패키지 README의 Windows Opus 지원 칸이 비어 있고, Windows `record_mediatype.cpp`의 `CreateAudioProfileOut`에는 Opus 분기가 없어 `E_NOTIMPL`로 끝난다. `Recorder::Start`도 지원하지 않는 인코더를 거부한다.
- 원본 recorder 예외가 `hum_modal.dart:311`의 catch에서 일반 `unavailable`로만 바뀌므로, 이번 실패의 직접 예외는 아직 확보하지 못했다. 코덱 불일치는 확인됐지만 마이크/권한 등 다른 실패 요인이 함께 있는지는 단정하지 않는다.

**권장 수정 범위와 수용 기준**

- 실제 인코더 지원 여부와 플랫폼을 고려해 녹음 코덱·컨테이너 확장자를 함께 선택한다. Windows는 WAV 또는 지원이 확인된 대안으로 폴백한다. 모바일의 기존 Opus 선택 이유와 Android API 29 미만 AAC 폴백을 보존한다.
- 플랫폼과 지원 결과를 주입할 수 있는 작은 선택 로직을 검사한다. Windows에서 미지원 Opus를 요청하지 않는 회귀 검사를 추가한다.
- 실패 원인을 진단할 최소 정보(플랫폼/코덱/오류 코드)를 남긴다. 오디오 내용·토큰 등은 기록하지 않는다. UI는 필요한 경우 권한/입력 장치/미지원 코덱을 구분해 안내한다.
- Windows 실기에서 카운트인 → 녹음 시작 → 중지 → 생성 파일의 컨테이너·재생 가능 여부를 확인한다. 변환/청취까지 확인한 범위를 정확히 보고한다.
- `vocal_record_modal.dart`는 현재 WAV를 사용한다. 같은 버그라고 가정해 일괄 수정하지 않는다. macOS도 같은 헬퍼의 경로를 검토하되, 이번에는 Mac 실기를 실행하지 않았다.

## P1-02 — Windows 창 닫기 시 audioplayers 네이티브 충돌

**관찰 및 재현 조건**

- 격리된 DEBUG 검증 앱 한 개(PID 5336)를 실행해 인스펙터·그리드 편집·창 크기·허밍 실패를 확인한 뒤, Windows 제목 표시줄 X로 닫았다.
- 프로세스가 `-1073741819` = `0xC0000005`로 종료했다. 강제 종료나 중복 실행으로 처리한 결과가 아니다.
- Windows Application Error 이벤트 1000에서 `audioplayers_windows_plugin.dll`, 예외 `c0000005`, 오프셋 `000000000003fbf9`, PID `0x14d8`를 확인했다.
- 앞선 단일 자동 실행은 종료 코드 0이었다. 자동 종료 성공을 실제 X 종료 성공으로 대체하지 않는다. RELEASE에서도 같은지는 미확인이다.

**증거 및 조사 시작점**

- `artifacts/ui-005-beginner-polish/codex-recovered-wait-exit.json`
- `artifacts/ui-005-beginner-polish/codex-windows-crash-events.json`
- `mobile/lib/looptap/audio/loop_audio.dart:449`: 전역 `_vocalPlayer` 생성. `:682`의 `stopAll()`은 `stopVocal()`을 기다리지 않고 엔진 stop을 반환한다. 이 사실만으로 충돌 원인이라고 확정하지 않는다.
- `mobile/windows/runner/flutter_window.cpp:44`: PCM 및 Flutter controller 파괴 순서를 함께 확인한다.
- 의존성: `audioplayers` 6.6.0, `audioplayers_windows` 4.3.0.

**권장 수정 범위와 수용 기준**

- 플레이어·이벤트 구독·콜백과 Flutter 엔진 종료의 수명을 조사한다. 가능하면 확보된 이벤트와 최소 재현으로 teardown 원인을 좁힌다.
- 원인에 맞는 stop/dispose 대기와 종료 순서 또는 패키지 수정을 적용한다. 버전을 무작정 올리거나 예외를 숨기는 것으로 해결하지 않는다.
- 대표 흐름 한 번을 확인한 뒤 X 종료 코드 0을 확인한다. 녹음 실패 후 닫기와 정상 녹음 후 닫기는 서로 다른 조건이므로 필요한 경우에만 추가한다. DEBUG와 배포용 RELEASE를 구분해 기록한다.
- 필요한 종료 순서 회귀 검사와 기존 오디오/편집 회귀 검사를 실행한다.

## 이미 확인한 UI와 남은 확인

**실제 마우스로 확인함**

- 키 필터 끔/켬, 중앙 음높이 유지, F# 줄의 빈 칸에 그리면 F로 입력됨, 실행 취소.
- 인스펙터 접기/펼치기, 노트 선택 자동 탭, 같은 개수의 다른 노트 선택 자동 전환, 선택 해제 후 트랙 탭.
- 노트 길이·강약 조절, 스크롤 및 퀀타이즈 chevron 시트.
- 트랙 볼륨·Pan, 믹서와 양방향 값 반영, Pan 더블클릭 중앙 초기화.
- 강약 막대 접기/펴기, 허밍 버튼의 활성 트랙 모달 진입.
- Windows 최소 **외부 창 960×600**: 막대로 시작하고 인스펙터가 그리드 위에 겹쳐 열린다. 캡처는 그림자 제외 946×593다.
- **클라이언트 폭 1099 / 1100px**: 막대 / 280px 도킹으로 정확히 전환된다.
- 최대화 캡처 **2560×1392**, 큰 일반 창 캡처 **1838×1073**에서 배치가 유지된다. 후자는 외부 창 1852×1080이며, 정확히 1920×1080로 맞춘 결과가 아니다.

**아직 통과라고 할 수 없는 항목**

- 물리 Ctrl+I, Ctrl+M, Ctrl+Shift+H, 그리드 휴머나이즈 우선, 인스펙터 포커스 Ctrl+C/Delete.
- 실제 섹션 이름 타이핑. 도구로 입력란에 포커스와 커서가 보였지만 `type_text`가 글자를 넣지 못해 취소했다.
- OS 입력 도구의 문자/수정키 주입 제약으로 의심된다. 이번 세션에서 raw scan code를 계측하지 않았다. 물리 입력으로 재현하기 전 단축키 자체를 바꾸거나 IME 처리를 약화하지 않는다.
- 녹음·변환·청취, RELEASE의 종료 안정성, 실제 Windows 영어 화면 크기 변경, 드럼/기타 세부 OS 입력.
- 정확한 1920px 폭은 미세 반복 입력을 중단하라는 사용자 요청에 따라 맞추지 않았다. 큰 창 대표 상태는 위에 남겼다.

**기존 자동 결과의 범위**

- 5단계 자동 KO/EN 36개와 캡처 14장, 자동 단계 FlutterError 0. 수동 단계 뒤의 오류까지 수집한 결과가 아니다.
- 이전 검토: analyze 0, 전체 914 통과·17 skip, Codex 독립 재실행 45 통과. 이번에는 제품 소스를 바꾸지 않아 전체 테스트를 재실행하지 않았다.
- 4단계 이전 콜백 QA 50개와 단위/회귀 검사도 보존돼 있다. 실제 드럼/기타 OS 확인과 혼동하지 않는다.

## 검증 도구와 진행 방식

- GPU 캡처 오류 `0x887A0005`는 오래된 화면 제어 보조 프로세스를 종료하고 공식 sky API로 재연결해 해결했다. 드라이버·Windows 설정·제품 GPU 코드를 바꾸지 않았다. 앱의 렌더러를 바꾸는 작업은 필요하지 않다.
- 창 좌표는 최신 캡처를 기준으로 쓰고, UI 애니메이션이 끝난 상태를 관찰한다. 실제 입력은 computer-use 스킬을 따른다.
- **의미 있는 상태 한 번과 대표 동작 한 번**으로 검증한다. 이미 통과한 동작을 되풀이하거나 창을 1/11px씩 키우는 반복 조작을 하지 않는다. 도구 제약이면 미확인이라고 적고 다음 항목으로 넘어간다.
- 새 실패가 나오면 화면·조건·관련 로그를 남긴다. 원인 확인 없이 같은 조작을 반복하지 않는다.
- 증거 색인: `C:/src/humming-v2/artifacts/ui-005-beginner-polish/codex-native-proof-index.json`
- 최신 기계 기록: `C:/src/humming-v2/artifacts/ui-005-beginner-polish/codex-native-recovery-session.json`
- 검증 앱은 종료했다. 자동 검사 데이터는 모두 저장소 내부 격리 폴더에 있다. 이번 검증에서 녹음 오디오 변환 업로드는 수행하지 않았다.

## Claude에게 붙여넣을 시작 지시문

```text
C:\src\humming-v2 에서 docs/specs/ui/qa-handoff-2026-10-30.md를 먼저 읽고 이어서 작업해줘.
현재 codex/ui-005-beginner-polish / 2406042를 기준으로 기존 변경을 보존해.
우선 Windows 허밍 녹음 코덱 선택 문제와 audioplayers_windows_plugin.dll의 창 닫기 충돌을 조사하고 작은 범위로 수정해줘.
관찰된 사실과 추정 원인을 구분하고, 수정 후 관련 회귀 검사·flutter analyze·전체 테스트 및 의미 있는 대표 Windows 동작을 검증해줘.
물리 키보드 확인 전에는 도구의 문자/단축키 주입 실패를 앱 버그로 단정하지 마.
검증은 대표 상태·동작 한 번씩 간결하게 해. 미세 창 크기 반복 조절이나 이미 통과한 동작 반복은 하지 마.
브랜치 전환·병합·push·PR·배포는 하지 말고, 완료 후 수정 파일·테스트·남은 확인을 짧게 보고해줘.
```

## Codex 추가 검증 (2026-10-30, Claude 수정 후)

- 실제 OS 마우스로 DEBUG와 RELEASE의 제목 표시줄 X를 각각 한 번 눌렀다. 둘 다 종료 코드 **0**, 해당 PID의 새 이벤트 1000 **0건**이다. 따라서 위의 "실제 마우스 X 미확인" 항목은 해소됐다.
- 생성한 WAV 멜로디로 제품 허밍 모달 → 실제 서버 `/analyze` → 편집기 **0 → 4개 노트**를 확인했다. 노트 시작 0/4/8/12, 키·루프 범위와 상대 음정 확인, RELEASE FlutterError 0. 마이크 입력만 QA 데이터로 대체했고 개인 음성은 사용하지 않았다.
- 이제 실제 서버 WAV 변환과 노트 삽입은 확인됐다. 실제 사람의 허밍 인식·청취 품질, 물리 키보드/IME, Mac 실기는 여전히 사용자 확인이다.
- **새 UX 수정 후보:** 빈 트랙 변환 후 노트가 현재 뷰 위쪽에 생성되어 그리드가 비어 보였다. 스크롤 한 번 후 4개를 확인했다. `_humConvert` 완료 시 새 노트가 현재 뷰 밖이면 한 번 표시되도록 하는 개선을 검토한다. 제품 코드는 수정하지 않았다.
- DEBUG 클라이언트는 흰 캡처라 이번에는 native X 종료만 통과로 처리했다. RELEASE의 편집기와 변환 결과는 화면 확인했다. 이 관찰을 곧바로 제품 DEBUG 버그로 확정하지 않는다.
- 상세: `C:/src/humming-v2/artifacts/qa-fix-2026-10-30/codex-verification/README.md`, `verification.json`.
- 제품 RELEASE는 QA 진입점 대신 `lib/main.dart`로 복원 빌드 완료(종료 코드 0). 기존 수정·브랜치·개인 데이터와 배포 패키지는 유지하며 push·PR·배포 없음.

## 허밍 결과 표시 수정 (2026-10-30 Claude, Codex 추가 검증 후속)

**원인**
- 변환된 노트는 패드 음역(`_padWindow`)에 맞춰 들어간다.
- 피아노롤의 세로 위치는 처음 만들어질 때 한 번만 정해진다. 빈 트랙이면 `focusMidi`(패드 음역 아래쪽)가 기준이다.
- 그래서 결과가 뷰 위에 생겼다. 데이터는 정상이었다.

**수정** (데스크톱만, 휴대폰 동작 그대로)
- `pitch_grid_surface.dart`: 한 번만 처리하는 `GridReveal(serial, notes)` 요청을 추가했다.
  - 새 노트가 하나도 화면에 없으면 그 범위로 세로 스크롤한다.
  - 시간축에서도 하나도 안 보이면 같은 줌으로 가로만 옮긴다.
  - 이미 보이면 아무것도 하지 않는다.
  - 키 필터의 "가운데 유지" 스크롤보다 뒤에 실행된다.
- `step_grid.dart`: 이 요청을 그대로 전달한다.
- `edit_screen.dart`: `_humConvert`가 음정 노트를 넣을 때만, 해당 트랙·섹션에 요청을 만든다. 다른 트랙의 그리드는 요청을 받지 않는다.
- 같은 일련번호로 다시 빌드되거나 재생·선택이 바뀌어도 화면이 다시 움직이지 않는다. 새 그리드는 요청을 다시 실행하지 않는다.
- 노트, 선택, 줌, 데이터는 바꾸지 않는다.

**검증**
- `test/looptap/hum_result_reveal_test.dart` 4개
  - 화면 밖 결과가 보이게 됨(재현 상태 확인 포함)
  - 보이는 결과는 오프셋 그대로
  - 줌 4배 유지와 가로 이동
  - 같은 요청으로 다시 빌드하거나 새 그리드에서는 움직이지 않음
- analyze 0, 전체 926 통과·17 skip.
- 대표 확인 1회(RELEASE)
  - 조건: Codex의 생성 WAV 방식(D4 E4 F4 A4)으로 실제 `/analyze`, 빈 Melody, D 도리안, BPM 120, 1마디
  - 변환 전 보이는 줄: G4(67) 이하
  - 변환 후: 스크롤 없이 D5·E5·F5·A5가 보이는 줄(C4~B6) 안에 있음
  - 종료 코드 0, 충돌 이벤트 0, FlutterError 0
  - 증거: `artifacts/qa-fix-2026-10-30/reveal-check/reveal-check.json`, `before-convert.png`, `after-convert-no-scroll.png`
- QA 진입점은 `mobile/test/qa_hum_reveal_app.dart`, 실행본은 `artifacts/qa-fix-2026-10-30/reveal-app-release`다. 제품 RELEASE는 `lib/main.dart`로 다시 빌드했다.

**사용자 확인으로 남김**
- 사람 허밍의 인식 품질과 청취
- 물리 키보드와 IME
- Mac 실기

Codex DEBUG의 흰 캡처와 한 옥타브 차이는 이번 범위에 넣지 않았다.
