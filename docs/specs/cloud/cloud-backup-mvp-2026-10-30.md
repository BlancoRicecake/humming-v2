# 클라우드 백업 MVP — 곡별 수동 백업·복원 (2026-10-30)

이 문서는 `cloud-connection-handoff-2026-10-30.md`의 범위를 구현한 결과다. Codex 중간 리뷰(`codex-review-2026-10-30.md`) 반영분도 함께 담았다.

**하지 않은 것:** commit, push, PR, 배포, 운영 플래그나 운영 DB 변경, 고객 파일 업로드. 기존 미커밋 변경은 지우지 않았다.

**기본값:** 서버 `CLOUD_SYNC_ENABLED`와 앱 `HUMTRACK_CLOUD_BACKUP`은 둘 다 꺼져 있다. 그래서 지금 빌드에는 고객에게 보이는 변화가 없다.

## 1. 결정: 클라우드 사본 = 검증된 `.humtrack` 하나

- 곡 하나의 클라우드 사본은 저장 점검 때 만든 `.humtrack`(stored ZIP: manifest, song.json, 녹음)이다.
- 복원은 백업 파일을 가져올 때와 같은 검증된 가져오기 경로(`importProjectBackup`)를 지나며, 언제나 **새 로컬 곡**이 된다. 기존 곡과 녹음은 덮어쓰지 않는다.
- `cloud_projects.meta`에는 곡 본문 대신 객체 설명만 저장한다: `format: humtrack`, `formatVersion: 1`, `key`, `size`, `sha256`, `audioIncluded`, `takes`, `missingTakes`, `songSchema`.
- 예전 계획의 "meta에 곡 JSON + 녹음 조각 개별 업로드" 방식은 쓰지 않았다. 원자적으로 교체할 단위가 하나라서 실패했을 때 원본을 지키기 쉽기 때문이다. 대가로 백업할 때마다 녹음 전체를 다시 올린다. 녹음 중복 제거는 후속 과제다.
- **녹음 제외 사본**(`audioIncluded: false`): 녹음을 읽지도 담지도 않는다. 모든 녹음이 `missing`에 기록되고, 복원하면 녹음 자리는 소리 없이 비어 있다고 안내한다.

## 2. 서버 계약 1 (`backend/`)

### e328408에서 가져온 것과 가져오지 않은 것

브랜치 병합 없이 `git show`로 비교한 뒤 필요한 부분만 현재 코드에 옮겼다.

| e328408 항목 | 처리 |
|---|---|
| `deps.user_is_pro` (`/iap/status`와 같은 판정) | 가져옴. `require_pro`가 이것을 쓴다 |
| `cloud_quota.py` (Pro 확인, R2 실측, 사용량 기록, 412) | 가져와서 확장. 계약 번호, project_id 제한, 서버가 만드는 key 추가 |
| `storage_r2.object_size` / `prefix_bytes` | 가져옴. `list_objects`(수정 시각 포함)와 `copy_object`, 서명 옵션 추가 |
| 쓰기는 Pro만, 읽기는 구독 종료 후에도 | 가져옴. **삭제는 Pro 없이도 허용**으로 바꿨다(자기 자료 삭제권) |
| `/storage/complete` | 가져오지 않음. 커밋 단계가 같은 검사(HEAD + 실측 + 초과 시 삭제)를 한다 |
| `sql/2026-10-13_cloud_sync_server_writes.sql` (RLS 읽기 전용) | 가져오지 않음. 현재 HEAD의 migration 003이 이미 같은 일을 한다 |

### 엔드포인트

| 경로 | 권한 | 동작 |
|---|---|---|
| `GET /storage/usage` | 로그인 | R2 실측 사용량, 한도, `contract: 1`. 앱은 업로드 전에 이 계약 번호를 확인한다 |
| `POST /storage/presign` | Pro | `project_id`(`[A-Za-z0-9_-]{1,100}`)와 `size_bytes`(필수, 1GB 이하)를 받는다. 실측 사용량 + 요청 크기가 한도를 넘으면 412. key는 **서버가 매번 새로 만든다**(`vocals/{uid}/{pid}/up-<uuid>.humtrack`). 서명에 `Content-Length`와 `If-None-Match: *`를 넣는다. 클라이언트가 보낸 `file_name`은 무시한다 |
| `POST /projects` (커밋) | Pro | 아래 "커밋 순서" 참고 |
| `GET /projects[?include=meta]`, `GET /projects/{id}` | 로그인 (구독 종료 후에도) | 자기 행만 |
| `POST /storage/presign_get` | 로그인 (구독 종료 후에도) | `vocals/{uid}/` 아래 key만 |
| `DELETE /projects/{id}` | 로그인 (구독 종료 후에도) | 행을 먼저 지우고, 그다음 그 곡 prefix의 객체를 지운다 |

### 커밋 순서

1. 계약 1 meta 형식을 검사한다.
2. `expected_updated_at`(이 기기가 마지막으로 본 클라우드 버전)과 `expect_absent`(첫 업로드) 중 정확히 하나가 와야 한다.
3. key는 **이 사용자, 이 곡의 `up-` 업로드**여야 한다.
4. R2에 HEAD를 보내 존재와 크기 일치를 확인한다.
5. 사용자 전체 사용량을 실측한다. 한도를 넘으면 새 업로드를 지우고 412를 낸다. 기존 사본은 그대로 둔다.
6. 업로드를 서버만 아는 새 이름 `bk-<uuid>.humtrack`으로 복사한다. 이 이름으로는 업로드 URL이 한 번도 발급되지 않는다.
7. `commit_cloud_project` RPC(migration 004)로 행을 바꾼다. 행 잠금 → 버전 비교 → 갱신이 한 트랜잭션이다. 동시에 들어온 첫 업로드끼리는 PK 충돌로 처리돼 하나만 성공하고 나머지는 conflict가 된다.
8. 충돌이면 409와 클라우드 버전을 돌려주고 `bk` 복사본을 지운다. 업로드 객체는 "이 기기 것으로 바꾸기" 재시도에 쓰도록 남겨 둔다.
9. 성공하면 업로드 객체와 **교체된 이전 `bk`만** 지운다. 24시간이 지난 고아 객체도 정리한다. 다른 기기가 올리고 있을 수 있는 젊은 업로드는 지우지 않는다.

### Codex 중간 리뷰 반영 — 기존 백업 bytes 보호

| 경로 | 보호 방법 | 검증 |
|---|---|---|
| 기존 `meta.key`와 같은 key로 재발급 | key를 서버가 매번 새로 만든다. 커밋된 이름(`bk-`)은 업로드 이름(`up-`)과 다른 계열이고 PUT이 발급되지 않는다. `bk-` key로 커밋하려 하면 403 | 테스트 대역 |
| 커밋한 업로드 URL 재사용 | 커밋된 사본은 다른 이름으로 복사돼 있다. 재사용해도 업로드 이름(이미 지워진 객체)에만 닿는다. 더해서 `If-None-Match: *` 서명으로 기존 객체 덮어쓰기는 412 | 테스트 대역. **실제 R2의 If-None-Match 강제는 미확인**이며, 복사 방식만으로도 보호된다 |
| 크기 누락이나 초과 | `size_bytes`가 필수이고 서명된 `Content-Length`와 다르면 거부된다. 실측 기반 412 | 테스트 대역. **실제 R2의 서명 길이 강제는 미확인** |
| 정규화로 prefix가 겹침 | `project_id`를 정규화해도 바뀌지 않는 이름(`[A-Za-z0-9_-]{1,100}`)으로 제한하고, 그 밖은 422. 유사한 이름의 곡을 지워도 다른 곡은 보존된다 | 테스트 |
| 동시 업로드, 취소, 409 | RPC 행 잠금. 커밋 전 실패나 취소는 포인터를 바꾸지 않는다. 진 쪽의 `bk` 복사본은 즉시 지운다 | **실제 Postgres**에서 동시 요청으로 확인 |

### SQL

- `backend/migrations/004_cloud_backup_commit.sql`: `commit_cloud_project`. **어느 환경에도 적용하지 않았다.** 실행 권한은 service_role만 갖는다.
- 기존 `upsert_cloud_project` RPC는 새 경로에서 쓰지 않는다.
- 사용량(`cloud_quota.used_bytes`)은 R2 실측값으로 기록한다.

## 3. 앱 (`mobile/`)

- `lib/looptap/state/cloud_backup.dart`
  - API 클라이언트: 계정 토큰은 `engineApi.dio`(자체 API)로만 보낸다. R2 서명 URL에는 인터셉터와 로깅이 없는 별도 Dio로, 서명된 헤더만 붙여 보낸다.
  - 다운로드는 크기와 SHA-256을 확인한 뒤 가져오기 검증을 거친다.
  - 링크 파일 `looptap/cloud_links.json`(로컬 곡 ↔ 클라우드 사본과 버전)을 원자적으로 쓴다.
  - 동작: 백업, 이 기기 것으로 바꾸기(다시 올리지 않고 같은 업로드를 커밋), 클라우드 것 받기(새 곡), 둘 다 보관(새 클라우드 사본), 삭제.
- `lib/looptap/widgets/cloud_backup_actions.dart`
  - 곡 메뉴의 "클라우드에 백업"은 로그인과 Pro를 확인한다.
  - **녹음 포함 체크박스는 기본 꺼짐**이다. 꺼 두면 "녹음은 이 기기에만 남아요"라고 표시한다.
  - 클라우드 사본에 녹음이 있었는데 이번에 끄면, 이전 녹음 사본이 삭제된다는 경고를 먼저 보여 준다.
  - 충돌이 나면 세 가지 선택지를 주고, 고르기 전에는 아무것도 바꾸지 않는다.
- `lib/looptap/screens/cloud_backup_screen.dart`
  - 설정 › 클라우드 백업 화면이다. 사용량, 목록(녹음 포함/제외 표시), "이 기기로 받기"(새 곡), "클라우드에서 삭제"가 있다.
  - 삭제 확인 창에 "클라우드 사본만, 기기의 곡은 그대로"라는 범위를 적었다.
  - 이 화면을 열면 읽기만 하고 업로드는 하지 않는다.
- 자동 업로드는 없다. 앱 시작, 로그인, 설정 표시 중 어디에서도 업로드를 호출하지 않는다.
- 진입점 두 곳은 `kCloudBackupEnabled`가 꺼져 있으면 보이지 않는다.
- 서버가 404를 주거나 계약 번호가 없으면 "아직 쓸 수 없어요, 아무것도 올리지 않았어요"라고 안내하고 업로드 전에 멈춘다.
- `.humtrack` 생성은 `buildProjectBackup(song, includeAudio:)`로 분리했다. manifest에 `audioIncluded` 필드가 추가됐고, 기존 파일 백업의 형식은 그대로다.

## 4. 검증

| 범위 | 결과 | 무엇으로 |
|---|---|---|
| 서버 `tests/test_cloud_backup.py` | **24 통과** | **실제 PostgreSQL 16**(저장소 안의 pgserver, 운영 스키마 SQL과 migration 003·004 적용) + 실제 동시 연결 + FakeR2 |
| 백엔드 전체 | 262 통과 / 11 건너뜀 / 1 실패 | 실패 1건은 이전부터 있던 `test_autotune` ffmpeg 미설치(환경 문제) |
| 앱 `cloud_backup_test.dart` | 11 통과 | 가짜 API와 R2(Dio 어댑터), 실제 파일 |
| 앱 `cloud_backup_ui_test.dart` | 5 통과 | 위젯 테스트 |
| Flutter 전체 / analyze | 989 통과 / 18 건너뜀 / 0 실패, analyze 0건 | |
| Windows RELEASE | 빌드 성공 (기본 플래그 꺼짐) | `mobile/build` |

서버 테스트가 확인한 항목:
- 플래그 꺼짐이면 모든 엔드포인트가 404다.
- 무료 사용자 업로드는 403이다. 구독이 끝난 사용자도 목록 조회, 다운로드, 삭제는 할 수 있다.
- 계정 격리
  - 다른 사람 key에 대한 다운로드 서명 요청은 403이다.
  - 다른 사람의 업로드를 커밋하려 하면 403이다.
  - 목록과 조회는 자기 것만 나온다.
  - RLS: `authenticated` 역할은 쓰기와 RPC 호출이 불가하고 자기 행만 읽는다.
- 원본 보존
  - 업로드했지만 커밋하지 않은 상태에서는 기존 사본이 그대로다.
  - 오래된 버전으로 커밋하면 409이고 아무것도 바뀌지 않는다. 같은 업로드로 재시도할 수 있다.
  - 한도 초과 커밋은 412이고, 새 객체는 지워지며 기존 사본은 남는다.
  - 크기 불일치, 없는 객체, 잘못된 meta, 버전 정보 누락은 모두 거부된다.
- 리뷰 수용 기준: 커밋된 key로 재발급 요청, 업로드 URL 재사용, 크기 누락이나 서명 위반, 정규화 prefix 충돌, 고아 정리 연령 기준.
- 동시성: 같은 버전으로 6개 동시 교체 → 1개 성공·5개 409, 승자의 bytes만 남는다. 첫 업로드 5개 동시 → 1개 성공. SQL 직접 호출 8개 동시 → 1개 성공.
- 로그에 서명 URL과 토큰이 남지 않는다.

앱 테스트가 확인한 항목:
- 토큰은 API로만 가고 R2로는 가지 않는다. PUT에 `If-None-Match`가 실린다.
- 폰에서 녹음 포함 백업 → PC(빈 저장소)에서 복원하면 새 곡이 되고 녹음 두 개가 바이트 단위로 같다. 이후 백업은 같은 클라우드 사본을 이어 간다.
- 녹음 제외 사본에는 오디오 항목이 없고, 복원하면 소리 없는 자리 2개가 생긴다.
- 기능이 없거나 계약이 다르면 presign과 PUT을 보내지 않는다. Pro가 아니거나 한도를 넘으면 업로드하지 않는다.
- PUT이 실패하면 행과 링크가 바뀌지 않는다.
- 충돌 시 세 가지 선택 각각의 결과를 확인했다.
- 손상된 다운로드는 거부한다.
- 클라우드 사본을 지워도 로컬 곡은 남는다.
- UI: 녹음 기본 꺼짐, 취소 시 요청 0건, 녹음 해제 경고, 충돌 창을 닫으면 변화 없음, 화면에서 복원과 삭제 확인.

## 5. 확인하지 않은 것 — 완료로 보고하지 않음

- **실제 R2 동작**
  - 서명된 `Content-Length` 강제
  - `If-None-Match: *` 조건부 쓰기 (R2 지원 여부, presigned PUT에서의 동작)
  - `CopyObject`, `ListObjectsV2`의 `LastModified`
  - 이번에는 FakeR2로만 검증했다. 운영 버킷에서 테스트 계정으로 따로 확인해야 한다.
- **실제 Supabase**: migration 004 적용, RPC 권한, 운영 RLS 상태, PostgREST의 jsonb·timestamptz 왕복 표현(`updated_at` 문자열을 그대로 다시 보내는 방식).
- **운영 API**: 이 환경에서 `/health`를 포함해 403이라 접근하지 못했다. Fly의 `CLOUD_SYNC_ENABLED` 실제 값도 미확인이다.
- **실기기**: 휴대폰 ↔ PC 실제 계정 왕복, 느린 네트워크와 중단, 큰 녹음(수백 MB) 업로드 시간과 메모리, 실제 소리 확인.
- **사용량 경합**: 커밋 순간 실측 기준으로 막는다. 아직 커밋하지 않은 업로드가 동시에 끝나면 잠깐 한도를 넘을 수 있다(다음 커밋이나 발급에서 다시 막힌다).
- **업로드 중 진행률과 취소 버튼**: UI가 없다. 현재는 앱을 닫으면 중단되고, 커밋 전이므로 원본은 그대로다.

## 6. 운영 적용 순서 (승인 후에만)

1. 개인정보처리방침과 약관 개정안(클라우드 보관, 녹음 옵트인, 구독 종료 후 보관과 삭제), **30일 사전 고지** 일정. 출시일보다 시행일이 늦지 않게 한다. 공지 발송은 하지 않았다.
2. 스테이징: migration 004 적용 → 테스트 계정으로 `CLOUD_SYNC_ENABLED=1` → 위 5장의 R2·Supabase 항목 확인.
3. 백엔드 배포(계약 1). 예전 클라이언트는 클라우드 호출이 없으므로 영향이 없다.
4. 앱을 `--dart-define=HUMTRACK_CLOUD_BACKUP=true`로 내부 빌드 → 실기기 왕복 확인 → 공개.
5. 운영 플래그를 켜는 것은 마지막이다. 문제가 생기면 플래그만 끄면 되고, 데이터는 남는다.

## 7. 변경 파일

- 서버
  - `backend/app/cloud_quota.py`(신규), `backend/app/deps.py`, `backend/app/storage_r2.py`
  - `backend/app/routes/projects.py`, `backend/app/routes/storage.py`
  - `backend/migrations/004_cloud_backup_commit.sql`(신규, 미적용)
  - `backend/tests/cloud_fixtures.py`, `backend/tests/test_cloud_backup.py`(신규)
  - `backend/tests/test_cloud_sync.py`: 계약 1 이전의 라이브 테스트라서 건너뛰도록 표시
- 앱
  - `mobile/lib/looptap/state/cloud_backup.dart`, `widgets/cloud_backup_actions.dart`, `screens/cloud_backup_screen.dart`(신규)
  - `state/project_backup.dart`(`buildProjectBackup`, `audioIncluded`), `screens/songs_screen.dart`(플래그 메뉴), `widgets/sheets/settings_sheet.dart`(플래그 항목)
  - ARB KO/EN과 생성 파일
  - 테스트: `test/looptap/cloud_backup_test.dart`, `cloud_backup_ui_test.dart`, `test/support/fake_cloud.dart`
- 자료: `artifacts/cloud-backup-2026-10-30/` (README, 결과 로그, 로컬 Postgres 실행 스크립트)

---

## 8. Codex 독립 검증 2차 반영 (C1~C6, 2026-10-30)

근거: `codex-independent-review-2026-10-30.md`. Codex의 초기 실패 로그는 그대로 두었다: `artifacts/cloud-backup-2026-10-30/codex/server-initial.log`, `app-initial.log`, `account-boundaries-initial.log`, `cached-account-initial.log`, `layout-*.log`, `flutter-full-final.log`.

수정 후 결과는 `artifacts/cloud-backup-2026-10-30/results/*-after-review2.log`, `*-final.log`에 따로 남겼다.

| 항목 | 문제 (재현) | 수정 | 정식 회귀 테스트 |
|---|---|---|---|
| C1 | DB가 커밋한 뒤 RPC 응답만 사라지면, 서버가 새 `bk` 파일을 지웠다 | 결과가 불확실하면 파일을 지우지 않는다. 서버는 행을 다시 읽어, 우리 `bk`를 가리키면 성공(200)으로 확정한다. 아니면 503 `commit_unknown`을 주고 두 파일을 모두 보존한다(참조되지 않으면 24시간 뒤 정리). 앱은 5xx나 응답 없음일 때 `GET /projects/{id}`로 SHA-256을 확인해 멱등하게 확정하고, 409라도 클라우드 사본이 우리 바이트면 성공으로 본다 | 서버: 응답 유실 후 커밋, 커밋 전 실패. 앱: 응답 유실 확인, 같은 바이트 409 |
| C2 | DELETE가 행을 지운 뒤 prefix를 늦게 정리하면서 다른 기기의 새 사본을 삭제했다 | 삭제 순서를 "객체 먼저, 행 나중"으로 바꿨다. 지울 목록을 먼저 고정한다(목록을 읽은 뒤 현재 행 키를 다시 확인, 10분 이내의 `bk`는 제외, 이후 생긴 객체는 포함하지 않음). 행은 `delete_cloud_backup` RPC로 키가 그대로일 때만 지운다. 바뀌었으면 409를 주고 새 사본은 유지한다. prefix 전체 삭제는 없앴다 | 일시정지 경계에서 교체 커밋(409, 새 사본 유지), 원래 순서대로 늦게 온 DELETE(새 첫 업로드 유지) |
| C3 | R2 삭제가 실패했는데 204를 주고, 목록에서 사라졌다 | 엄격한 삭제(`delete_objects_strict`, 응답의 `Errors`도 확인). 하나라도 실패하면 503 `storage_delete_failed`를 주고 행을 유지해 목록에서 다시 시도할 수 있다 | 실패 시 503 + 목록 유지 → 저장소 복구 후 재시도하면 녹음과 행이 모두 삭제됨 |
| C4 | 공유 tmp 파일 경쟁으로 19건 실패. 이어서 Windows가 rename을 일시 거부(errno 5) | 링크 작업을 한 번에 하나씩 처리한다(대기열이 비면 아무것도 붙잡지 않음). 쓰기마다 고유 tmp 이름을 쓴다. 교체는 짧게 재시도하고(최대 9회), 원본 파일을 먼저 지우지 않는다. 계속 실패하면 오류를 내고 이전 링크를 보존하며 tmp는 지운다 | 동시 쓰기 20개, 병렬 백업 5곡, 거부 2회 후 성공, 계속 거부 시 이전 링크 보존 |
| C5 | 링크가 계정 구분 없는 전역 파일이었다. 응답 수신 후나 PUT 직전에 계정이 바뀌면 A의 바이트가 전송되거나 A의 목록이 반환됐다 | 링크를 계정별 파일(`looptap/cloud_links/<uid>.json`)로 나눴다. API는 만들 때의 계정에 고정되고, 모든 요청 전·응답 직후·R2 PUT/GET 직전·링크 기록과 복원 직전에 계정을 확인한다. 바뀌었으면 `CloudAccountChanged`로 멈추고 응답은 버린다. 모든 API 요청에 `X-Expected-User`를 붙이고, 서버가 토큰 계정과 다르면 409 `account_mismatch`로 거절한다(토큰을 가져오는 사이의 전환까지 차단). 클라우드 화면은 계정이 바뀌면 이전 목록을 감추고 안내만 보여 준다 | A/B 분리, PUT 중 전환, 다운로드 중 전환, 로그아웃 상태, presign 응답 직후 전환(PUT 0회), 목록 응답 직후 전환, 헤더 부착, 서버 mismatch 거절(B의 곡 보존), 화면 캐시 숨김 |
| C6 | 320px에서 복원·삭제 버튼 줄이 넘쳤다(Ahem과 실제 Segoe UI·맑은 고딕 모두) | 버튼 줄을 `Wrap`으로 바꿨다 | 320px, en/ko, 글자 1.0/1.5배(Ahem). Codex `qa_cloud_layout_test.dart`(실제 글꼴) 통과 |

Codex 검증 파일 조정 내역 (검증 내용은 지우지 않음):
- `test_server_safety.py`: C2의 일시정지 지점을 새 삭제 경계(`_delete_keys`)로 옮겼다. 원본은 `test_server_safety.initial.py.txt`로 보존했다.
- `qa_cloud_independent_test.dart`: 계정 A/B의 owner를 명시했다.
- `qa_cloud_wire_test.dart`: owner 인자를 추가했다.
- `qa_cloud_layout_test.dart`: 불필요한 import를 지웠다.
- wire 테스트는 `QA_CLOUD_WIRE` 실행기에서만 켜지고 전체 실행에서는 건너뛴다.

**최종 검사**
- 서버 클라우드: 정식 31 + Codex 3 = **34 통과**. 실제 Postgres 사용.
- 백엔드 전체: 269 통과 / 11 건너뜀 / 1 실패. 실패는 ffmpeg 미설치 환경 문제로, 통과로 표기하지 않는다.
- Flutter analyze 0건. 전체 **1017 통과 / 19 건너뜀 / 0 실패** (`results/flutter-full-test-final.log`).
- Windows RELEASE 빌드 성공(플래그 기본 꺼짐).
- 실제 HTTP 왕복(Dio → Python 라우트 → 로컬 PG, R2만 HTTP 대역)을 계정 헤더가 붙은 상태로 다시 돌려 통과: 토큰 유출 0, 녹음 128,088바이트 일치(`results/wire-*-after.*`).

## 9. 운영 전 반드시 남은 일 (추가)

- **young `bk` 잔여 객체의 주기적 정리와 삭제 재시도 작업이 없다.**
  - DELETE는 다른 기기의 커밋일 수 있는 10분 이내 `bk-`를 남긴다.
  - C1의 "결과 불명" 사본은 24시간이 지나야 정리 대상이 된다.
  - 두 정리 모두 같은 곡에 나중에 커밋이나 삭제가 있을 때만 실행된다. 그런 작업이 없으면 객체가 남을 수 있다(사용량에는 포함된다).
  - 운영 전에 다음을 설계해야 한다: 사용자별 고아 스윕 작업(행 키 재확인 + 연령 기준 + 엄격 삭제 + 재시도 큐).
  - 앱 안내도 "클라우드 사본 삭제"와 "모든 잔여 파일 정리 완료"를 구분해야 한다. 지금의 삭제 확인 문구는 사본 삭제만 말한다.
- 실제 로그인 서버(Supabase Auth)에서 계정을 전환하는 경우는 API 대역으로만 검증했다.
- 실제 R2(서명된 길이, If-None-Match, CopyObject, 삭제 응답의 `Errors` 형식), 실제 Supabase(PostgREST 경유 RPC, migration 004 적용)는 미확인이다.
- 사용자가 직접 할 일: 휴대폰 연결, 로그인, 폰 ↔ PC 실제 왕복, 실제 소리 확인.

## 10. Codex 독립 최종 확인 (2026-10-30)

Claude 완료 후 Codex가 수정된 현재 소스로 재확인했다.

| 검사 | 결과 | 근거 |
|---|---|---|
| Flutter 전체 | **1017 통과 / 19 건너뜀 / 실패0** | `artifacts/cloud-backup-2026-10-30/codex/flutter-full-postfix.log` |
| Flutter analyze | **0건** | `codex/analyze-final.log` |
| 서버 안전성 | **정식31 + 독립3 =34 통과** | `codex/server-postfix.log` |
| 백엔드 전체 | **270 통과 / 11 건너뜀 / 실패0** | `codex/backend-full-with-ffmpeg.log` |
| 계정·좁은 화면 독립 검증 | **9 통과** | `codex/app-final.log` |
| 실제 HTTP 왕복 | **통과** (실제 Dart Dio/Python 라우트/로컬PG, R2만 대역) | `codex/http-roundtrip.log`, `http-roundtrip-evidence.json` |
| Windows 제품 RELEASE | Claude 최종 빌드 성공 로그와 실제 `data/app.so` 갱신 확인 | `results/build-windows-release-final.log` |

- 최초 추가 실패 로그(서버3개, 앱 링크2개, 계정 응답·캐시, 화면 넘침, Windows rename)는 보존했다. C1~C6 및 추가 경계를 수정한 뒤 위 결과를 얻었다.
- ffmpeg 부재로 실패하던1건은 **QA 환경에서만** 해소했다. 공식 PyPI `imageio-ffmpeg==0.6.0`을 저장소의 QA 가상환경에 준비하고 `codex/tools/ffmpeg.exe`를 검증 명령의 PATH에만 넣었다. 전역 PATH·backend requirements·운영 설정을 바꾸지 않았다. 이전 실패 로그도 보존했다. 도구의 출처/해시와 재현 명령은 `codex/ffmpeg-tool.json`, `run_backend_with_ffmpeg.py`에 있다.
- 실제 R2의 조건부 PUT/CopyObject 지원은 공식 문서와 설치된 SDK 모델·서명 생성까지 확인했다. **실제 버킷 동작을 통과했다는 뜻이 아니다.** 출처: https://developers.cloudflare.com/r2/api/s3/api/ . 로컬 SDK 확인: `codex/r2-compatibility.json`.
- 테스트용 실제 HTTP 서버는 실행기가 종료했고, Codex 전용 PostgreSQL도 중지했다. 재현 자료와 테스트 DB 파일은 남겨 두었다.
- 현재 브랜치와 HEAD는 `codex/ui-005-beginner-polish` / `2406042` 그대로다. commit/push/PR/배포/운영 DB 변경/고객 자료 업로드는 하지 않았다.

**다음 순서:** 운영 전 정리·재시도 정책 보완(9장) → 실제 서비스에서 테스트 계정 검증 및 내부 빌드 준비 → 사용자가 폰 연결·로그인을 마치면 폰↔PC 왕복/소리 확인. 배포와 고객 기능 활성화는 아직 하지 않는다.
