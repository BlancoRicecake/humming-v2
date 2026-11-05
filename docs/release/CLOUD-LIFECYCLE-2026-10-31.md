# 클라우드 수명주기 구현·검증 결과

> 11/02 후속: [RELEASE-OPS-2026-11-02.md](RELEASE-OPS-2026-11-02.md).
> 실제 스테이징 예약 루프/잔여 정리와 관리자 점검008을 검증했다. 아래의10/31 결과와 구분한다.

2026-10-31. 작업 위치 `C:/src/humming-v2`, 기준 HEAD
`4f5f34d97901acaa863f6784406bbbb7aa0b34b9`. 수정은 로컬 미커밋 상태다.
**로컬 구현 검증 통과, 실제 서비스 적용·출시 검증은 미완료**다.
운영 DB/배포/공개 플래그/고객 공지·메일/스토어 업로드/push·PR을 실행하지 않았다.

후속 최신 앱/서버 검사·설치 후보·실제 운영 읽기 전용 조사는
[RELEASE-HANDOFF-2026-10-31.md](RELEASE-HANDOFF-2026-10-31.md)에 기록했다.
아래 숫자와 후보 경로는 이 수명주기 구현 시점의 기록이다.

## 구현 결과

- `backend/migrations/006_cloud_lifecycle.sql`: Auth 삭제로 없어지지 않는 계정 삭제 기록,
  정확한 객체 키별 재시도 큐, 유한한 업로드·복사 임대를 추가했다. 기존에 추적하던
  계정도 정리 대상으로 등록한다. 익명·일반 로그인 사용자의 직접 접근과 RPC 실행을 막는다.
- `cloud_lifecycle.py`, `cloud_cleanup.py`: 기본 dry-run, 계정·객체·작업 수 제한,
  재시도 간격, 다중 작업자의 토큰 기반 소유권 확인을 구현했다. 기본 한 번에 계정10,
  계정당 객체200, 삭제 작업200, 시간 예산45초다. 실행 중 SDK 요청까지 즉시 끊는
  시간 제한은 아니며 R2 연결5초/읽기15초·최대2시도를 별도로 둔다.
- 현재 DB가 참조하는 정상 사본과 유효한 복사 임대를 보존한다. 같은 계정의 정리·커밋은
  동일 DB 잠금으로 판정한다. 정리 대상으로 확정한 키를 늦은 커밋이 다시 게시할 수 없다.
  복사는10분 후 임대가 끝나므로 지연 완료 시 게시를 거절한다.
- 미참조 파일은 알려진 up/bk 형식·24시간 경과 조건을 확인한다. 형식이나 수정 시각을
  알 수 없는 객체는 일반 정리에서 보존한다. 탈퇴한 계정은 해당 계정 prefix 전체가 대상이다.
- R2가 개별 키 삭제를 명시적으로 확인하지 않으면 완료로 세지 않는다. 실패한 키는
  DB에 남고30초부터 최대1시간 간격으로 재시도한다. 사용자의 명시적 재시도는 즉시 허용한다.
- 탈퇴는 영속 기록·새 접근 차단 후 Auth 삭제를 시도한다. Auth 테이블 삭제 트리거도
  같은 트랜잭션에서 기록을 남긴다. 신규 앱은 협상 헤더로202 pending을 받고,
  구버전은 Auth 삭제가 확인된 경우에만 기존204를 받는다. Auth 삭제 미확인은503이다.
  어느 응답도 R2 전체 삭제가 끝났다는 증빙으로 사용하지 않는다.
- 발급된 PUT URL의 만료 시각에5분을 더한 뒤 비어 있는지 재확인한다. 이후에도 매일
  검사하여 URL 만료 전에 시작했다가 늦게 끝나는 업로드를 정리한다.
- 앱은 탈퇴 요청 접수·서버 삭제 진행 중과 기기 작업물 보존을 안내한다. 구독은
  사용자가 스토어에서 별도로 관리하는 기존 흐름을 유지한다.
- `CLOUD_CLEANUP_ENABLED=false`이면 새 클라우드 쓰기는503으로 거절한다.
  `CLOUD_BACKUP_WRITES_ENABLED=false` 긴급 읽기 전용 모드도 유지한다.

## 검증 증거와 한계

증거 기준 폴더: `artifacts/cloud-lifecycle-2026-10-31/`.

| 검사 | 결과 | 증거 |
|---|---|---|
| Flutter analyze | 0건 | `analyze.log` |
| 전체 앱 테스트 | 1047 통과 / 19 skip | `flutter-full.log` |
| 전체 백엔드 | 310 통과 / 11 skip | `results/codex-backend-full.log` |
| 실제 로컬 PostgreSQL | GC/커밋 경쟁, 임대 만료, 재시도·재시작, Auth cascade, 늦은 PUT, RLS/RPC 권한, migration 재적용, 다중 작업자 통과 | `backend/tests/test_cloud_lifecycle.py` |
| 앱↔로컬 HTTP 왕복 | 노트 보존, 녹음128088바이트 비교, 기존 기기 곡2개 보존, 토큰 유출0, 삭제 후 클라우드 행0 | `app-wire.log`, `http-roundtrip-evidence.json` |
| 공급자 계약 검증기 | 로컬 HTTP·실제 PG·R2 대역으로29절차 통과 | `provider-wire.log`, `provider-fixture-result.json` |
| 현재 main.dart Windows Release | 성공, 공개 설정 이름과 바이너리 해시 기록 | `windows-configured-build.log`, `humtrack-build-receipt.json` |
| 내부 설치 후보 | 현재 앱으로 새 후보 생성, 클라우드 OFF·미서명 | `installer-build.log`, 아래 후보 경로 |

백엔드11 skip은 옛 계약 검사에서 명시적으로 건너뛰는 항목이다. 실제 서비스 검사가
통과했다는 뜻이 아니다. SDK의 테스트용 짧은 JWT 키 경고와 Windows 재사용 빌드의
MSB8028 경고가 남아 있다. 실제 오류로 인한 테스트·컴파일 실패는 없었다.

새 후보: `artifacts/releases/candidate-1.0.13-43-lifecycle-20261031/`.
기존 `artifacts/releases/current`와 이전 후보는 유지한다. 번호43은 내부 식별자이며,
공개 출시 버전·번호는 스토어 최고 사용 번호를 조회한 뒤 다시 확정한다.

## 실제 서비스 적용 순서 — 아직 실행하지 않음

1. 스테이징 백업·대상 프로젝트·전용 테스트 계정2개를 확인한다. 사용자 객체를
   테스트 대상으로 삼지 않는다. 운영의 미등록 prefix는 별도 읽기 전용 목록으로 조사한다.
2. 쓰기를 중단한 상태에서 기존003/004, 공지005의 적용 이력을 확인하고006/007/008을 순서대로
   적용한다. **006 뒤에004만 다시 실행하지 않는다.** 임대를 검사하는 커밋 함수를
   예전 함수로 덮어쓸 수 있다. 실제 Supabase에서 Auth 삭제 트리거 생성 권한·동작,
   서비스 전용 RPC·일반 사용자 직접 쓰기 차단을 검증한다.
3. 마이그레이션 끝의 `NOTIFY pgrst, 'reload schema'` 후 새 RPC와24개 권한 점검을 확인한다.
   이는 [PostgREST 공식 캐시 갱신 절차](https://docs.postgrest.org/en/stable/references/schema_cache.html)다.
   로컬 PG 결과만으로 실제 PostgREST/Auth 권한을 확인했다고 세지 않는다.
4. 새 서버를 스테이징 배포하고 `CLOUD_CLEANUP_ENABLED=true`로 주기적 작업이
   실제 실행되는지 로그·큐 지표로 확인한다. 기본값은 false다. **클라우드 UI를 꺼도
   새 `/account` 경로는006/008과 실행 중인 삭제 작업자가 필요**하다.
5. 아래 CLI로 테스트 계정만 dry-run→apply 하고 중단·재시작·부분 실패·만료 후
   늦은 PUT·Auth 삭제 재시도를 검증한다. 작업 간격60초와 큐 적체 알림을 확인한다.
6. 아래 공급자 계약 검증기, 만료 구독 읽기/삭제·한도 초과·네트워크 응답 유실·탈퇴
   시나리오를 실제 서비스에서 별도로 실행한다. 자동 검증기는 탈퇴/구독 변경을 수행하지 않는다.
7. 폰↔Windows 실제 작업물을 왕복하고 청취한다. 고지·서명·최종 CI·서비스 검증이
   끝난 뒤에만 같은 최종 후보에서 서버/앱 공개 플래그를 활성화한다.

```powershell
# backend/에서, 운영자 환경은 별도로 안전하게 구성. UUID는 전용 테스트 계정 값.
python -m app.cloud_cleanup --user <TEST_USER_UUID>
python -m app.cloud_cleanup --apply --user <TEST_USER_UUID>

# 기본은 통신조차 하지 않는 실행 계획이다.
python -m app.cloud_provider_check --api-url https://<TEST_API_HOST>
# CLOUD_QA_TOKEN_A/B와 CLOUD_QA_ALLOWED_USERS(정확한 두 UUID)를 제외 환경에서 설정한 뒤:
python -m app.cloud_provider_check --api-url https://<TEST_API_HOST> --apply
```

계약 검증기는 고유한 합성 프로젝트1개만 만들고 정리한다. 서명 길이·조건부 PUT·해시·
다른 계정 접근·CAS 충돌을 확인하며 실제 음악 파일 가져오기 검사는 아니다. 앱 importer는
별도 로컬 왕복에서 검사했다. 현재 **실제 Supabase/R2 실행은 하지 않았다**.

운영 지표 예시(운영자 SQL Editor, 읽기 전용):

```sql
select count(*) as pending_jobs, min(created_at) as oldest_job,
       max(attempts) as max_attempts from public.cloud_delete_jobs;
select count(*) as deletion_requested,
       count(*) filter (where auth_deleted_at is null) as auth_pending,
       count(*) filter (where purged_at is null) as primary_purge_pending
from public.cloud_accounts where delete_requested_at is not null;
```

큐가 비었다는 사실만으로 R2 prefix가 비었다고 판단하지 않는다. 계정별 마지막 검사,
URL 만료·유예, Auth 확인, 목록 조회 성공, 삭제 확인과 다음 재검사까지 함께 본다.
오류 알림·담당자 응답 경로의 실제 연결은 E04 미완료다.

장애 시 `CLOUD_BACKUP_WRITES_ENABLED=false`로 새 쓰기를 막고 목록·복원·삭제와
삭제 작업자를 유지한다. 큐·삭제 기록·임대 검사 함수를 지우는 롤백은 하지 않는다.
구버전 서버로 단순 복귀하면006 임대 계약과 맞지 않으므로 수정본으로 복구한다.

## 개인정보 고지를 위한 사실표와 미결정 사항

이 절은 개정 초안 작성용이다. 활성 약관·정책·시행일을 바꾸거나 고객에게 게시하지 않았다.

| 항목 | 확인된 구현 | 출시 전에 확정할 부분 |
|---|---|---|
| 저장 방식 | 사용자가 요청하는 Pro 수동 백업, 자동 동기화 아님 | 고객 문구·스토어 신고 일치 |
| 녹음 | 포함 기본 OFF, 명시 선택 시 파일에 포함 | 선택 안내와 실제 기기 확인 |
| 한도 | 서버 기본5GiB | 운영 override와 실제 상품 제공량 |
| 구독 만료 | 신규 쓰기 제한, 기존 목록·복원·삭제 허용 | 실제 만료 계정 검증 |
| 제공자·지역 | Supabase 메타데이터, Cloudflare R2 객체 | 계약상 수탁자·실제 지역·접근/이전 사항 |
| 사본 삭제 | 클라우드 사본만 삭제, 기기 곡 유지 | 실제 두 기기 확인 |
| 탈퇴 파일 | 지속 큐·URL 만료 후 검사·매일 늦은 업로드 검사 | 보장할 삭제 시한과 운영 대응 |
| 탈퇴 기록 | UUID·시각·삭제 상태 등 최소 기록이 현재 기한 없이 남음 | 보관 근거·종료 조건·최종 삭제 기간 결정 및 구현. 즉시 모든 기록 삭제라고 고지하면 안 됨 |
| 미등록 객체 | 정상 정리에서 알 수 없는 형식은 보존 | 과거 업로드 흔적·소유권의 읽기 전용 조사 |

고객 안내 초안(KO): “클라우드 백업은 사용자가 선택해 업로드하는 기능입니다. 녹음은
포함을 선택한 경우에만 함께 저장됩니다. 클라우드 사본을 삭제해도 기기의 곡은 남습니다.
탈퇴 요청이 접수되면 계정 접근을 차단하고 서버 데이터 삭제를 진행합니다.”

Customer copy draft (EN): “Cloud backup uploads your work when you choose to back it up.
Recordings are included only when you select that option. Deleting a cloud copy keeps
the song on your device. Once an account deletion request is accepted, account access
is blocked and server data deletion is processed.”

위 안내만으로 개인정보처리방침을 대체하지 않는다. 지역·보관 기간·시행일·기존 사용자
개정 고지 이력을 확정한 뒤 앱 KO/EN·웹·App Privacy/Data Safety를 맞춘다.
Firebase 초안의2026-11-01을 클라우드 시행일로 확정하지 않는다.
