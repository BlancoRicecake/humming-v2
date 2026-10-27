# Linked sections + Make unique

- **ID:** arrangement-001
- **Status:** implemented (uncommitted)
- **Inspired by:** FL Studio — Playlist pattern clips (linked instances), Make unique (카탈로그 AR-02, AR-03)

## Sources
- https://www.image-line.com/fl-studio-learning/fl-studio-online-manual/html/playlist.htm : 같은 패턴을 플레이리스트에 여러 번 놓으면 모든 배치가 같은 데이터를 공유해, 패턴을 고치면 모든 배치가 바뀐다. 패턴의 박자표 변경도 모든 배치에 적용된다. 클립 메뉴의 Make unique는 그 배치를 복제해 이후 편집이 다른 배치에 영향을 주지 않게 한다. 오디오 클립의 Make unique는 원래 오디오 파일을 계속 쓴다(파일을 따로 복제하는 별도 명령이 있음).
- Hands-on observation 2026-10-21 (findings.json `humtrack_existing`): HumTrack에는 이미 deepCopy 구간 복제와 반복 횟수가 있다. 이 스펙은 복제를 "독립 / 연결" 두 모드로 넓힌다.
- 링크 모델, 저장 형식, Undo 규칙은 HumTrack 자체 설계다.

## User-visible behavior
1. 섹션 칩 메뉴(모바일 길게 누르기, 데스크톱 우클릭)에 **"연결 복제"**가 생긴다. 기존 "복제"는 지금처럼 독립 사본을 만든다.
2. 연결 복제된 섹션들은 칩에 같은 색의 링크 표시(아이콘 + 그룹 번호)가 붙는다. 그중 하나에서 노트·드럼·보컬 클립·마디 수·Beat-Fill 패드 배치를 바꾸면 **연결된 모든 섹션이 즉시 같이 바뀐다.** 편집 화면 상단에 "연결된 구간 3개에 함께 적용" 같은 작은 표시가 보인다.
3. 섹션마다 따로인 것: 이름, 자동 이름 여부, 반복 횟수, 위치(이동), 섹션별 그루브 덮어쓰기(GR-001). 예: "후렴 1"×2, "후렴 2"×1처럼 이름과 반복은 달라도 내용은 같다.
4. 연결된 섹션 메뉴에 **"독립시키기 (Make unique)"**가 생긴다. 실행하면 그 섹션만 현재 내용의 사본을 갖고 연결에서 빠진다. 남은 그룹이 1개뿐이면 그 섹션의 링크 표시도 사라진다.
5. 모든 명령은 Undo 1회로 되돌린다.

## 공유 범위 규칙
| 항목 | 연결 그룹이 공유 | 섹션별 |
|---|---|---|
| `tracks`(모든 트랙의 노트·드럼·보컬 클립·라벨) | O | |
| `bars` | O (노트 범위가 마디 수에 묶여 있으므로) | |
| `fillKinds` | O (Beat-Fill 노트 종류와 짝) | |
| `id`, `name`, `autoName`, `repeats` | | O |
| `extras`, `order` | 곡 전체 트랙 집합이라 원래 모든 섹션이 같음 — 공유하지 않고 지금 방식 유지 | |

## Edge cases
- **삭제:** 연결된 섹션 하나를 지우면 나머지는 그대로 연결 유지. 1개만 남으면 `linkId`를 지운다.
- **이름 변경·이동·반복:** 그 섹션만 바뀐다. 자동 이름(A, B…) 재배정도 섹션별.
- **보컬 클립:** 트랙 내용이므로 공유된다. 한 섹션에 녹음한 테이크가 연결된 모든 섹션에 나타난다. Make unique는 클립 목록을 깊은 복사하되 같은 오디오 파일(basename)을 가리킨다(FL의 오디오 Make unique와 같은 방식). `sweepVocals`는 참조 기반이라 파일이 지워지지 않는다. 보컬 믹스 캐시(`_vocalMix`, 섹션 id 키)는 그룹 전원을 무효화한다.
- **곡 재생/Flatten:** `flattenSong`은 섹션 목록을 그대로 펼치므로 연결 섹션은 같은 내용을 반복해서 낸다. PR-007 확률 판정 키에 `sectionId`가 들어가므로 연결된 섹션끼리도 회차마다 다른 변주가 나온다(의도된 동작).
- **곡 모드 오버더브:** 재생 위치 아래 섹션에 기록하면 그룹 전체에 들어간다.
- **트랙 추가/삭제:** 지금처럼 모든 섹션에 적용. 공유된 `tracks` 맵에 같은 키를 두 번 넣거나 지우는 것은 무해해야 한다(빈 `TrackData`로 덮어쓰지 않도록 `putIfAbsent` 사용).
- 구버전 앱이 파일을 열면 연결 정보는 무시되고 섹션들이 각자 같은 내용을 가진 독립 섹션으로 보인다(데이터 손실 없음). 구버전이 다시 저장하면 링크만 사라진다.

## HumTrack design
- Model (`models/loop_models.dart`):
  - `Section`에 `String? linkId`(기본 null, JSON은 값이 있을 때만 `'linkId'`). `deepCopy`는 `linkId`를 복사.
  - 저장 시 각 섹션은 **지금처럼 내용 전체를 JSON에 쓴다**(중복 저장). 구버전 호환과 손상 복구를 위해서다.
  - 현재 `Section` 생성자는 `tracks`는 받은 Map을 그대로 쓰지만 `fillKinds`는 `List.of`로 복사한다. 공유를 위해 `Section.linkedTo(Section source, {id, name, autoName, repeats, extras, order})` 같은 생성자를 추가해 `tracks`/`fillKinds`를 복사 없이 넘긴다.
- 런타임 공유 (`music/section_links.dart`, 신규):
  - `List<Section> relinkSections(List<Section> s)`: 같은 `linkId`를 가진 섹션 중 목록에서 **가장 앞 섹션을 원본**으로 삼아, 나머지를 원본과 **같은 `tracks` Map 인스턴스와 `fillKinds` List 인스턴스**를 쓰는 새 `Section` 객체로 바꾸고 `bars`를 복사한다. 같은 `linkId`가 1개뿐이면 그 `linkId`를 null로 정리한다. 내용이 엇갈린 파일(수동 편집 등)도 원본 기준으로 맞춰진다.
  - `Section duplicateLinked(Section src, String newId)`, `Section makeUnique(Section s)`(deepCopy + `linkId=null`), `Iterable<int> linkedIndices(List<Section>, int idx)`.
  - 호출 지점: 편집기 열 때(`_sections` 초기화), `_restore`(Undo 스냅샷은 deepCopy라 공유가 끊기므로) 직후, 연결 복제·Make unique·삭제 직후.
- `screens/edit_screen.dart`:
  - `_duplicateSectionLinked(idx)`, `_makeUnique(idx)`: `_pushUndo()` → 변경 → `relinkSections` → `_relabelSections`.
  - `_setBars`: `linkedIndices`의 모든 섹션에 같은 `bars`를 넣는다(`bars`는 int라 참조 공유가 안 됨). `_loopRanges`도 그룹 전원 갱신.
  - `_openFillPadPicker`는 공유된 `fillKinds`를 고치므로 자동 반영. `_vocalMix` 무효화는 그룹 전원.
  - `_addTrack`: `s.tracks[id] = TrackData()` → `s.tracks.putIfAbsent(id, TrackData.new)`.
- UI: `widgets/section_bar.dart` 칩에 링크 배지(`section-link-<id>`), `_openSectionMenu`에 "연결 복제"(`section-dup-linked`), "독립시키기"(`section-make-unique`, 연결된 섹션에서만). `song_plan_sheet.dart`·`widgets/arrangement.dart` 타임라인 블록에도 같은 배지. 데스크톱 `Ctrl/Cmd+Shift+D` = 활성 섹션 연결 복제(`desktop_workspace.dart`, 텍스트 입력 중 제외).
- Schema: `linkId`는 추가 필드다. 스키마 버전은 PR-007 결정의 v3과 함께 나가면 v3에 포함, v3이 이미 배포된 뒤라면 올리지 않는다(구버전은 링크만 잃음 — 아래 질문 참조).
- Export: 변경 없음(flatten 결과가 이미 반복 내용).

## Decisions (2026-10-22, owner approved)
- `linkId`는 스키마 v3에 포함한다(v3은 아직 배포 전).
- 연결 그룹은 `bars`와 `fillKinds`도 공유한다.
- Make unique 후 이름은 원래 이름을 유지한다(자동 이름이면 위치 글자를 다시 붙임). 연결 복제는 `Ctrl/Cmd+Shift+D`.

## Acceptance tests
- [x] `duplicateLinked`: 원본 A(linkId null) → A와 사본 B가 같은 새 `linkId`, B의 `tracks`가 A와 `identical`, B.id ≠ A.id, B.repeats == A.repeats.
- [x] A의 melody에 노트 추가 → B의 melody에서 보인다(같은 리스트).
- [x] `relinkSections`: JSON 왕복(`toJson`→`fromJson`) 후 공유가 끊긴 목록에 호출 → 같은 linkId 섹션들의 `tracks`가 `identical`, 내용은 목록상 첫 섹션 기준.
- [x] linkId가 1개뿐인 섹션 → relink 후 `linkId == null`.
- [x] `makeUnique(B)` → B.linkId null, B.tracks가 A와 `identical`이 아님, 내용은 같음(노트 JSON 동일). 이후 A 편집이 B에 영향 없음.
- [x] Undo: 연결 복제 후 B 편집 → Undo → A·B 모두 이전 내용, 그리고 여전히 `identical` 공유(`_restore` 후 relink 확인).
- [x] `_setBars(4)`를 A에서 → B.bars == 4. B.repeats 변경은 A에 영향 없음. B 이름 변경도 A에 영향 없음.
- [x] 3개 그룹에서 하나 삭제 → 둘은 연결 유지, 하나 더 삭제 → 남은 섹션 `linkId == null`.
- [x] `flattenSong([A(rep 2), B(rep 1)])`의 melody 노트 수 = A 노트 수 × 3.
- [x] 보컬: A에 클립 추가 → B의 `effectiveClips`에 같은 path. Make unique 후 B 클립 trim 변경이 A에 영향 없음, path는 같음.
- [x] 구버전 호환: `linkId`를 제거한 JSON으로 읽으면 섹션 내용이 각자 온전히 존재.
- [x] `_addTrack` 후 연결된 그룹의 새 트랙 TrackData가 1개(같은 객체)이고 기존 트랙 내용이 지워지지 않음.

## Out of scope
- 섹션 일부 구간만 연결(클립 단위 연결), 트랙 단위 연결(예: 드럼만 공유).
- 연결 그룹 안에서의 변주 레이어(공유 + 섹션별 덧칠), Slip edit(AR-04), 타임라인 자유 배치(AR-01).
- 오디오 파일을 복제하는 "Make unique as sample".
