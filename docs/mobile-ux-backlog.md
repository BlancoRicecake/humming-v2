# Mobile UX backlog

2026-05-30 시점. 사용자 피드백 + 세션 중 코드 확인으로 모은 모바일 앱 개선 항목. **이 문서는 기록용**이며 구현은 별도 작업으로 분리.

---

## 1. 시각 대비 (visual contrast)  ✅ **완료** (커밋 `2e69135` `c1d0fa2`)

배경 대비 텍스트 대비가 낮아 정보가 잘 안 보임.

> **적용:**
> - textSecondary `#71717A` → `#A1A1AA` (대비 4.08→7.70:1, AAA)
> - textTertiary `#52525B` → `#71717A` (대비 2.55→4.08:1, AA)
> - `T.label` (KEY/INSTRUMENT/피치 어시스트 등 9pt) 색을 textSecondary로 상향
> - 편집 액션 바 / 재생 미니 버튼: 비활성 상태에서 아이콘만 dim, 라벨은 항상 readable
> - `Disabled` 래퍼 opacity 0.4 → 0.55

- `mobile/lib/theme/app_theme.dart`
  - `bg = #0A0A0F`
  - `textSecondary = #71717A` ← bg 대비 명도 차 작음 (WCAG AA 미달 가능성)
  - `textTertiary = #52525B` ← 거의 안 읽힘
- `T.sub` (12px) 와 `T.label` (9px, #52525B) 가 주요 상태 표시에 쓰임 (KEY 카드의 "녹음 후 분석"·"신뢰도 0.31 · high", 어시스턴트 카드의 "키 밖 음 자동 정리" 등)

조치 아이디어:
- `textSecondary`를 `#A1A1AA`(혹은 비슷한 수준)로 한 단계 밝게
- `textTertiary`는 사실상 hint 용도로만 쓰고 본문/메타 정보에선 회피
- 본문 폰트 크기도 한 단계 키울지 검토 (12 → 13 정도)

---

## 2. 녹음 트랙 재배치 (시점 이동)  ✅ **완료** (커밋 `25ceae7`)

녹음된 트랙(청크)을 원하는 시점으로 옮겨 붙일 수 있어야 함.

> **적용:**
> - 청크 몸체를 horizontal drag → 이동 (long-press 불필요)
> - 레이어드 hit-test (lane→chunk→note)로 청크 영역 어디서나 인식
> - 코드 모드(`chordActive`)에서는 비활성 (의도된 제약)

- 이미 토대 있음:
  - `mobile/lib/widgets/timeline_editor.dart:49` — `onChunkMove(chunkId, dtSec)` (길게 눌러 이동)
  - `mobile/lib/screens/edit_screen.dart:306` — `store.moveChunkBy` 연결
- 확인 필요한 점:
  - 실제로 동작하는지 (시뮬레이터에서 long-press 인식 여부)
  - 코드 모드에서는 비활성화됨 (`t.chordActive ? null : ...`) — 의도된 제약?
  - 다른 트랙 위로 옮길 수 있는지, 같은 레인 안에서만인지
  - 이동 시 스냅(박자/그리드) 가이드 표시 여부

---

## 3. 청크 트림 (앞·뒤 잘라내기)  ✅ **완료** (커밋 `25ceae7`)

녹음본 앞뒤 불필요한 부분을 핸들 드래그로 잘라내고 싶음.

> **적용:**
> - 핸들 hit 영역 22→12px (시각 4px 바 + ±4px 여백) — 청크 몸체 드래그와 충돌 X
> - 좌표 통일: `_pxToSec`/`_secToPx` 헬퍼로 짧은 트랙에서도 핸들이 outline 가장자리 정확히 정렬

- 이미 토대 있음:
  - `mobile/lib/widgets/timeline_editor.dart:50` — `onChunkResize(chunkId, {newStart, newEnd})`
  - `edit_screen.dart:307` — `store.resizeChunk*` 연결
- 확인 필요한 점:
  - 핸들이 시각적으로 인지되는지 (드래그 가능 영역이 보이는지)
  - 최소 청크 길이 가드 (너무 짧게 잘릴 때 처리)
  - 트림한 만큼 원본 오디오에서 그 구간이 분석/재생에서 제외되는지

---

## 4. 단일 노트 보정 바텀시트 — 후보가 원음뿐

노트 탭 → 바텀시트(`showNoteCandidate`) 에 원음만 떠서 사실상 변경 불가.

- 위치: `mobile/lib/widgets/sheets.dart:234`
- 원인 분석:
  ```dart
  final opts = {n.pitchOriginal, ...n.candidates}.toList()..sort();
  ```
  - `n.candidates`는 백엔드 Pitch Assistant가 채워주는 **키 안 후보 목록**. 키 감지가 약하거나 노트가 키에 이미 맞을 때 후보가 비어 [원음]만 남음.
- 의도된 동작이지만 **사용자가 자유 편집할 수단이 없음** → 사용성 결함.

### 4-A. 사운드 미리듣기 아이콘  ✅ **완료** (백엔드 호출 방식, 커밋 `a28e4d7`)

> **적용:** wheel picker 가운데 lime 알약 + 스피커 아이콘 + 음 이름. 탭 시 `/render_audio` 1-노트 페이로드 호출 → WAV 받아 audioplayers 재생. 빠른 연타는 `_previewSeq` 시퀀스 카운터로 race-cancel.
> **추후:** 6번(온디바이스 합성) 도입 시 백엔드 호출 제거 가능.

선택된 음 우측 체크표시를 **사운드(스피커) 아이콘**으로 변경. 탭하면 그 음을 그 자리에서 즉시 재생해 들어볼 수 있게.

- 위치: `sheets.dart:256~279` 부근 (체크 마크 그리는 곳)
- **결정 포인트 — 단음 오디오를 어디서 만들 것인가:**
  모바일은 합성기가 없고 `audioplayers`로 기성 WAV만 재생함. 한 음 듣기 위해 그 한 음짜리 오디오를 어디선가 생성해야 함.

  | 경로 | 동작 | 트레이드오프 |
  |---|---|---|
  | A. 백엔드 호출 | `/render_audio`에 1-노트 페이로드 → WAV 받아 재생 | 음색 일관성 ↑, 매 탭마다 200–500ms 지연, 백엔드 없으면 동작 X |
  | B. 클라이언트 합성 | Flutter용 신스/SF2 패키지 추가 | 즉시 재생·오프라인, 음색이 백엔드와 다를 위험, 의존성 늘어남 (4대 제약 점검 필요) |
  | C. 프리렌더 샘플뱅크 | 앱 시작 시 백엔드에서 128 노트×선택 악기 일괄 캐시 | 첫 호출 후 즉시 재생 + 일관, 악기 바꿀 때마다 재캐시, 캐시 관리 |

  잠정 권장: **A로 시작 → 지연이 거슬리면 C로 확장.** B는 클라이언트 의존성 부담 + 음색 불일치 위험 때문에 회피.

### 4-B. 휠/스크롤 → 전체 음 목록 시트  ⏸ **재검토 필요** (wheel picker로 대체됨)

> **현 상태:** 4-D 결정으로 wheel picker(`ListWheelScrollView`) 적용. iOS 룰렛 패턴이라 빠른 휠 회전으로 음역대 이동 가능 + 추천 별 + 원음 라벨 표시. 별도의 옥타브 그리드 시트는 현재 불필요.
> **만약 그리드가 추가로 필요하다면:** 휠 헤더에 "전체 음 그리드 보기" 보조 액션으로 추가 가능.

위아래 스크롤로 모든 MIDI 노트(예: C0~G9)를 훑는 건 번거로움. **현재 음을 탭하면 전체 음 목록 시트가 열려서 직접 골라 선택**할 수 있게.

- 코드 위치 동일 (`sheets.dart` 내부에서 노트 표시 부분)
- 구현 힌트:
  - 옥타브별 섹션으로 묶은 그리드 (C·C#·D·...·B × 옥타브)
  - 현재 선택 음 위로 자동 스크롤
  - 선택 즉시 `store.setNotePitch(index, newPitch)` 같은 액션 호출 + 바텀시트 닫기

### 4-C. 자유 편집 + 추천 배지  ✅ **완료** (커밋 `a28e4d7`)

> **적용:** wheel picker가 MIDI 21~108 전 음역대 노출 + `n.candidates` 별(★) 마커 + `pitchOriginal` "원음" 알약 라벨 + 현재 선택 강조. 30ms 디바운스 후 `store.applyCandidate` 자동 적용.

후보 외 **어떤 음이든 선택 가능**해야 함. 현재 `opts`가 `{pitchOriginal, ...candidates}` 로 제한되어 있어 후보가 없으면 변경 자체가 막힘.

- 자료원 변경: `n.candidates` → **전체 음역대** (예: C0~G9)
- 후보 음(`n.candidates`)에는 **추천 배지** (예: 별 아이콘 또는 색 마커) 표시
- 원음(`n.pitchOriginal`)에는 별도 마커 (예: "원음" 라벨)
- 현재 선택값(`n.pitch`)은 강조 색

### 4-D. 단일 노트의 코드화 (per-note chord expansion)

현재는 **트랙 단위 chord mode** 만 존재 (`t.chordActive`). 켜면 그 트랙의 모든 단음이 다이아토닉 트라이어드로 확장됨. 사용자가 원하는 건 **선택된 노트만 코드로 변환**.

- 위치: 노트 시트(`sheets.dart` `showNoteCandidate`)에 액션 추가 — 적용/취소 옆에 "코드로" 버튼
- 또는 편집 액션 바(Split/Copy/Loop/Delete/Volume) 옆에 "Chord" 액션 추가 (선택된 노트가 단음일 때만 활성)
- 코드 종류 선택 UI:
  - 기본: 현재 키 기반 다이아토닉 트라이어드 (root 음에 III/V 추가)
  - 옵션: 메이저/마이너/sus2/sus4/7th 등 변형 선택 가능
  - 시트 내에서 "이 음을 어떤 코드로?" 선택 후 확정
- 데이터 표현:
  - 노트에 chord 메타데이터 필드 추가 (예: `chordType: 'major' | 'minor' | 'sus4' | null`)
  - 또는 단일 노트를 여러 노트로 분리해 그룹으로 묶음 (chunkId 활용)
  - 후자가 데이터 모델 변경 최소, 그러나 "원래 단음이었다" 정보 손실
- UI 표시:
  - 코드화된 노트는 시각적으로 구분 (여러 막대가 같은 시간대에 쌓임 + 그룹 윤곽선)
  - 다시 단음으로 되돌리기(unchord) 가능해야 함

기존 트랙 단위 chord mode(`t.chordActive`)는 유지하되, 그건 "전체 일괄 코드화" 옵션으로 자리 잡고, **per-note 가 기본 편집 단위**가 되는 게 자연스러움.

구현 시 고려:
- 현재 `renderNotes` 가 chord mode 일 때 모든 노트를 chords.dart 로 확장. per-note 코드화는 이 확장 로직을 단일 노트 단위로 트리거
- 백엔드는 노트만 받기 때문에 클라이언트에서만 처리 가능 (확장된 노트들을 backend `/render_mix` 페이로드에 같이 보냄)
- chord chunk 의 트림/이동 동작은 그룹 단위로 (이미 `chunkId` 그룹화 로직 있음)

---

## 5. 세션 중 발견한 추가 항목 (기록용)

### 5-1. 마이크 권한 처리

- 권한 거부 시 `recording_screen.dart`의 `_err = '마이크 권한이 필요합니다'` 만 표시되고 **설정 앱으로 보내는 동선 없음**. iOS 한 번 거부하면 앱 안에서 회복 불가능.
- "설정 열기" 버튼 추가 권장 (`permission_handler`의 `openAppSettings()`).

### 5-2. 녹음 시작 시 시각 점프

- 준비 상태에선 큰 mic 아이콘(64px), 녹음 시작하면 사라지고 미터(72px)가 등장 → 화면 중앙 요소가 갑자기 바뀜.
- mic 아이콘이 미터 안으로 fade-in 전환되거나, 미터가 항상 자리 차지하고 녹음 전엔 회색으로 표시되는 방식 검토.

### 5-3. 기술 용어 노출

- "AUTO", "단음/코드", "보정됨", "신뢰도 0.31 · high", "키 밖 음 자동 정리" 등 음악·DSP 용어가 라벨로 그대로 노출됨.
- 첫 진입 시 한 줄 설명(툴팁/인포 아이콘) 또는 온보딩 카드 1회 노출 검토.

### 5-4. "Done" 버튼 동작 미확인

- 편집 화면 상단 우측 Done 버튼이 어떤 상태/저장 동작을 하는지 불분명. 코드 확인 후 라벨 정확도 검토 필요.

### 5-6. 내보내기가 활성 트랙만 포함 (재생과 불일치)

재생 ▶ 버튼은 enabled된 모든 트랙(보컬 포함)을 합성해 들려주는 반면, **내보내기는 현재 활성 트랙 하나만 export됨**. 사용자 기대는 "재생과 동일한 결과물이 나와야 함".

- 위치:
  - `mobile/lib/state/project_store.dart:483` — `exportMidiActive()` 가 `active.renderNotes` 만 사용
  - `mobile/lib/widgets/sheets.dart:600` — 내보내기 시트가 `exportMidiActive` / `renderActive` 호출
  - 대조: `_playMix()` → `renderMix()` 가 `tracks.values.where(t.enabled && t.notes.isNotEmpty)` 로 멀티트랙 페이로드 구성 (`project_store.dart:463`)
- 백엔드 측:
  - `/render_mix` 는 멀티트랙 페이로드 받음 (PASS)
  - `/export_midi` 는 현재 단일 트랙만 받음 — 멀티트랙 MIDI 파일 내보내기 지원 추가 필요 (트랙별 channel/program, 보컬은 오디오로 별도 처리)
- 구현 힌트:
  - WAV 내보내기는 `renderMix()` 재사용으로 즉시 해결
  - MIDI 내보내기는 백엔드 `/export_midi` 가 트랙 리스트 받도록 확장 + 클라이언트가 enabled 트랙 모두 보냄
  - 보컬 트랙은 MIDI에는 미포함(오디오 트랙이라 의미 없음). 단, "전체 mix WAV" 내보내기에선 보컬 레이어도 같이 합쳐서 내보내야 재생 결과와 동일
- 옵션:
  - 사용자가 "활성 트랙만" vs "전체 mix" 선택 가능한 토글 추가
  - 기본값은 "전체 mix" (재생과 일치)

### 5-5. 자동 percussive 변환 제거에 따른 후속 작업 (기능 측면)

- 백엔드 자동 드럼화는 제거됨 (`fix(analyze): drop auto-percussive fallback`).
- 그러나 **사용자가 드럼 트랙을 명시적으로 선택했을 때 멜로딕 노트 → 드럼 변환**하는 경로는 아직 없음. 모바일 UI에서 Drum 탭 선택 시:
  - 백엔드 `/classify_drums` (가칭) 엔드포인트로 청크 오디오 + 노트 인덱스 보내 GM 36/38/42 매핑 받기
  - 또는 클라이언트가 보유한 노트의 kind/pitch만 재라벨링하는 단순 경로

---

---

## 6. 온디바이스 재생 (배포 대비)

### 배경
현재 모바일은 재생할 때마다 `POST /render_mix`로 백엔드 호출 → 백엔드 fluidsynth+SF2로 합성 → WAV를 받아 `audioplayers`로 재생. 개발 환경(백엔드 localhost)에선 50–100ms로 즉시 느낌이지만 **실서비스 배포에선 다음 문제가 명확함:**

- 사용자 폰만 있는 환경에서 동작 안 함 (서버 호스팅 비용·운영 부담)
- 네트워크 지연 누적: 같은 와이파이에서도 100–300ms, 외부 서버면 500ms+
- 단음 미리듣기(4-A) 같이 빈번한 호출은 1회 지연이 곱해져 체감 큼
- 4대 제약 중 "오프라인 우선" 정책과 미세하게 모순

### 목표 아키텍처
```
[모바일]                          [백엔드]
- 분석은 백엔드에 위임            - /analyze (음성 → notes)
- 재생/미리듣기는 온디바이스 합성  - /export_midi, /export_wav (저장·공유용)
- SF2 파일을 앱 자산으로 번들
```

**역할 재정의:** 백엔드는 "일상 재생 엔진"이 아니라 "분석 + 내보내기" 전용으로 좁힘.

### 단계별 계획

#### 6-1. 패키지 선정 + 제약 검토  ✅ **완료 — 2026-05-30** (constraint-guardian 검토 결과 반영)

**4대 제약**

| 제약 | 판정 | 근거 |
|---|---|---|
| 1. 유료 API 금지 | PASS | 외부 SaaS/키 불필요. fluidsynth(Android) / AVFoundation(iOS·macOS) 네이티브 호출만 |
| 2. 클라우드 금지 | PASS | 패키지 자체 네트워크 호출 없음. SF2는 앱 번들 asset에서 로드 |
| 3. 모델 학습 금지 | PASS | 순수 DSP(웨이브테이블 합성). 학습 모델 미포함 |
| 4. 디버그 시각화 | N/A | DSP 라이브러리, 해당 없음 |

**라이선스 / 활성도**
- 라이선스: **MIT** (앱 번들 사용 가능)
- 플랫폼: Android(fluidsynth, LGPL-2.1 동적 링크), iOS·macOS(AVAudioUnitSampler). Windows/Linux/Web 미지원
- 유지보수: pub.dev 등재, 2.x 메이저 릴리즈 존재. 단일 메인테이너 의존도 — 장기 백업 플랜 필요

**대안 비교**

| 패키지 | 장점 | 단점 |
|---|---|---|
| `flutter_midi_pro` | 네이티브 합성, 저지연, SF2 직접 로드 | iOS는 AVAudioUnitSampler라 fluidsynth와 음색 미세 차이 가능 |
| `dart_melty_soundfont` | 순수 Dart, 의존성 0, 결정론적 출력(플랫폼 간 동일) | 성능 부담, 실시간 재생은 직접 PCM 큐잉 필요 |
| `flutter_midi_command` | MIDI I/O 표준, 외부 신스 연결 | 자체 합성 없음 — 본 용도에 부적합 |

**도입 시 주의점**
- **SF2 라이선스**: 백엔드 SF2의 재배포 조건을 앱 번들 기준으로 재확인 (FluidR3_GM = MIT, GeneralUser GS = 자체 라이선스)
- **음색 일관성**: iOS의 AVAudioUnitSampler와 Android fluidsynth는 같은 SF2여도 엔벨로프/필터 처리가 달라 결과가 다름. QA에서 양 플랫폼 동일 입력 A/B 캡처 필요
- **fluidsynth LGPL**: Android 동적 링크 형태이므로 상용 배포 가능하나, 라이선스 고지 필수
- **백엔드 대비 결정론 손실**: `/render_mix`와 비트-동일하지 않음. 디버그 모드에선 서버 렌더 폴백 옵션 유지 권장
- **앱 용량**: SF2 번들(수~수십 MB) → IPA/APK 사이즈 증가

**종합 권장: 조건부 도입**
3개 조건 충족 시 도입:
- (a) SF2 모바일 재배포 라이선스 확인
- (b) iOS/Android 음색 차이 QA
- (c) 디버그 빌드에서 서버 렌더 비교 경로 유지

순수 Dart 결정성이 더 중요해지면 `dart_melty_soundfont`로 전환 가능한 추상화 계층(`SynthEngine` 인터페이스)을 두는 것 권장.

#### 6-2. SF2 자산 번들
- 백엔드와 **동일한 SF2 파일** 을 앱 assets로 포함 (현재 TimGM6mb.sf2, ~5MB)
- `pubspec.yaml`의 `flutter.assets:` 등록
- iOS/Android 양쪽 빌드에서 SF2 로드 검증
- 추후 GeneralUser-GS로 업그레이드 시 동기화 절차 명문화

#### 6-3. 단음 미리듣기 (4-A 구현 — 가장 작은 진입점)
- 노트 시트의 스피커 아이콘 탭 시 온디바이스 합성으로 단음 즉시 재생
- 시뮬레이터·실기기에서 음색이 백엔드 렌더와 일치하는지 비교 (constraint-guardian 통과 후)
- 성공 시 4-A 결정 포인트 해결, **백엔드 의존 없이 동작 검증**

#### 6-4. 트랙 재생 전환
- 단일 트랙 재생을 온디바이스로 전환
- 노트 배열 → noteOn/noteOff 시퀀스로 펼치는 로직은 `render.py:121~129`와 동일 패턴
- 보컬 트랙(원본 WAV)은 그대로 audioplayers로 레이어 재생

#### 6-5. 멀티트랙 믹스 재생
- 여러 채널 동시 합성 (`flutter_midi_pro`가 채널별 program_select 지원하는지 확인 필요)
- 백엔드 `render_tracks_to_wav` 와 동등 결과를 내야 함

#### 6-6. 백엔드 렌더 엔드포인트 역할 축소  ✅ **완료 — 2026-05-31** (Task #7)

> **적용:** WAV export 전용으로 좁힘. 재생/단음 미리듣기는 이미 온디바이스
> (`SynthEngine` / `SynthPlayer`, 커밋 `6de9bec`).
>
> **호출 표 (모바일 코드 grep 결과)**
>
> | 클라이언트 API | 살아있는 호출처 | 용도 |
> |---|---|---|
> | `EngineApi.renderAudio` | (없음) — `previewNote` 가 호환 호출하지만 둘 다 `@Deprecated` | — |
> | `EngineApi.renderMix` | `ProjectStore.renderMix()` ← `exportMixWav()` ← `sheets.dart:_exportFile(midi: false)` | WAV bounce 공유 |
> | `ProjectStore.renderActive` | (없음) | — (deprecated) |
> | `ProjectStore.renderAccompaniment` | (없음) | — (deprecated, `accompanimentSynthTracks` + `SynthPlayer` 대체) |
>
> **변경:**
> - `engine_api.dart`: `renderAudio` `@Deprecated` 마킹 + `renderMix` 역할 docstring (WAV export 전용)
> - `project_store.dart`: 죽은 `renderActive`/`renderAccompaniment` `@Deprecated`, `renderMix` 역할 docstring
> - `backend/app/main.py`: `/render_audio` `/render_mix` 엔드포인트 docstring 갱신 (역할 + deprecate 가능성)
> - 실제 코드/엔드포인트 제거는 안 함 — WAV export 와 회귀 검증 위해 보존

### 회귀 검증 포인트
- 같은 노트 시퀀스를 **백엔드 렌더 WAV** 와 **온디바이스 합성** 으로 만들어 파형/스펙트럼 비교
- 사용자 인지 가능한 음색 차이가 없어야 함 (특히 release tail, attack envelope)
- 작은 차이는 SF2 동일성으로 어느 정도 보장되지만, 합성기 구현 차이(보간·envelope 처리)로 미세 차이 가능

### 리스크
- **패키지 활성도/유지보수** — pub.dev 패키지가 갑자기 죽으면 어떻게 할지 fallback 필요
- **iOS/Android 차이** — 같은 패키지여도 native 백엔드가 다를 수 있어 음색 차이 발생 가능
- **앱 번들 크기** — SF2 5–30MB가 추가됨. 다운로드형 분리도 옵션
- **저작권** — TimGM6mb.sf2 라이선스 확인 필요 (앱 배포에 동봉 가능 라이선스인지)

---

## 우선순위 / 진행 상황

### ✅ 완료
| 항목 | 상태 |
|---|---|
| 1 시각 대비 | textSecondary/Tertiary 상향, T.label 토큰 교체, Disabled wrapper 보정 |
| 2 청크 이동 | drag-to-move (long-press 불필요) + 레이어드 hit-test |
| 3 청크 트림 | 핸들 hit 영역 축소 + 좌표 통일 |
| 4-A 사운드 미리듣기 | wheel picker 스피커 아이콘 + 백엔드 1-노트 렌더 |
| 4-C 자유 편집 + 추천 배지 | wheel picker 전 음역대 + 별/원음 마커 |
| 6-1 패키지 검토 | flutter_midi_pro 4대 제약 PASS (조건부 도입) |
| 6-6 백엔드 렌더 역할 축소 | `/render_audio` `/render_mix` WAV export 전용으로 좁힘 + deprecate 마킹 |

### ⏳ 남은 항목
| 우선 | 항목 | 이유 |
|---|---|---|
| 높음 | 4-D 단일 노트 코드화 | 현재 트랙 단위만 가능. 핵심 편집 도구 |
| 높음 | 5-6 내보내기 = 재생 결과와 일치 | 활성 트랙만 export 되는 동작 불일치. 사용자 기대 어긋남 |
| 중간 | 5-1 마이크 권한 회복 동선, 5-2 녹음 시작 시각 점프, 5-3 기술 용어 안내 | 폴리시 |
| 낮음 | 4-B 그리드 시트(wheel로 사실상 대체) | 필요 시 보조 액션으로만 |
| 미검증 | 5-4 Done 버튼 동작 | 동선 확인 필요 |
| 별도 | 5-5 드럼 변환 경로 | 분석 파이프라인 후속, 모바일 UX 분리 |
| **배포 전 필수** | **6-2 ~ 6-5 온디바이스 재생 구현** | SF2 번들·온디바이스 합성·트랙 재생 이전. 6-1·6-6 완료 |
