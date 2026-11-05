# HumTrack 실제 스테이징 검증 및 출시 준비 인계

> 후속 사용자 요청으로 Android1.0.14(44) internal 업로드를 완료했다.
> 아래는 그 이전의 스테이징 검증 기록이다. 최신 Android 결과는
> [ANDROID-INTERNAL-TEST-2026-11-01.md](ANDROID-INTERNAL-TEST-2026-11-01.md)를 따른다.

2026-11-01 KST. 작업 위치 `C:/src/humming-v2`.
**격리 통합 검증 통과, 공개 출시 보류.** 필수 체크리스트는14/42 완료다.
원격 push·PR·CI 실행·스토어 업로드·고객 공지·전체 서버 배포는 하지 않았다.
운영 DB에는 아래에 적은 migration007 권한 축소만 적용했다.

## 적용 범위와 승인

- 운영 Supabase: `iznehtmmpnivtjdiohgg` (humstudio).
- 새 격리 스테이징: `nttntvleombprofldqut` (humtrack-staging), FREE/Nano,
  미국 동부 us-east-1, Healthy 확인. 운영도 Supabase 지역은 us-east-1이다.
  R2 물리 저장 위치는 이 결과로 확정하지 않는다.
- 사용자가 스테이징 DB 비밀번호 설정·프로젝트 생성과 Apple 유료 계약 동의를 직접 완료했다.
  Apple 계약은11/01부터 활성 상태로 확인했다. 계정·은행·세금 상세는 증거에 저장하지 않았다.
- 사용자는 스테이징 관리자 키를 기존 Fly humming-api 머신의 일회성 검증 프로세스로 전달하는
  구체적 범위를 승인했다. SSH stdin/메모리로만 전달했으며 Fly 시크릿·운영 설정에 저장하지 않았다.
  로컬 임시 `staging-private-config.json`은 실행 후 삭제했다. 키/JWT/서명 URL은 로그에 넣지 않았다.
- Fly 기존 프로세스 대신 현재9개 Python 모듈을 별도 자식 프로세스 메모리에 로드했다.
  임시 API는127.0.0.1에만 열고 종료했다. 외부 포트·실행 중 운영 워커를 바꾸지 않았다.

## 실제 검증 결과

| 검사 | 결과 | 증거 (`artifacts/staging-2026-11-01/`) |
|---|---|---|
| 신규 스키마 | staging에001/002, cloud base,003–007 적용. 최종006 재적용 후 스키마/RLS/함수/트리거 권한20/20 통과 | `staging-schema-20-checks.jpg`, `schema-checks.json` |
| 초기 SQL 전달 | 실제 UI 적용본과 생성 SQL의 토큰2922개 동일. 원본 문자열 유지 | `applied-sql-comparison.json` |
| DB 롤백 검사 | CAS·정상 사본 보호·유한 임대·삭제 작업자 claim/재시도·Auth cascade·RLS·공지 revision 통과 | `staging-transaction-probe.jpg` |
| 공개 키 HTTP | 직접 쓰기·서버 전용 RPC 접근 차단8항목 통과 | `rest-preflight.json` |
| 공지 실제 HTTP | 활성 공지만 표시, revision2, 초안/예약/종료 숨김, 쓰기3종401, 원본 불변5항목 통과. 시험 공지 제거 | `notice-http.json` |
| R2 공급자 | 조건부 PUT·재사용412·서명 길이 거절·Copy SHA-256·삭제 ack·지연 source 재업로드 시 사본 불변8절차 통과. 자체 QA 키만 생성/정리 | `r2-provider-probe.json` |
| 현재 API 통합 | 실제 staging Auth 계정2개·JWT·Supabase·R2 연결, contract1/업다운로드 해시/계정 격리/교체/오래된 커밋409 등29절차 통과 | `integrated-probe.json` |
| 추가 권한/탈퇴 | 비구독 계정 업로드403, 탈퇴 요청202/deletion_pending 확인 | `integrated-probe.json` |
| 탈퇴 메타데이터 | 유예 전/파일 발견 시 lease 유지, 유예 후 빈 경로 확인 시 lease 제거와 tombstone 보존. 실제 DB에서 새 합성 행만 만든 뒤 전부 롤백 | `lease-prune-rollback.sql`, `lease-prune-rollback.jpg` |
| 전체 백엔드 |316 통과,11 skip. skip은 옛 opt-in 테스트이며 통합 검증 완료로 세지 않음 | `backend-full.log` |
| 새 스키마 재현 | 로컬 PostgreSQL에서20체크·롤백 검사·기존 프로젝트 재적용 거부 통과. 로컬 pgcrypto extension 미포함 한계 별도 기록 | `bundle-validation.json` |

통합 구독은 **스테이징에만 만든 합성 Pro 행**이다. 실제 App Store/Play 구매·복원·만료를
검증한 것이 아니다. Flutter 앱 import/기기2대/실제 OAuth/소리/네트워크 중단/공급자 부분 삭제
장애/최종 main lifespan·예약 작업자 실행도 이번 일회성 API 시험으로 대체하지 않는다.

## 발견해 수정한 보안 문제

Hosted Supabase는 새 함수에 API 역할의 명시적 EXECUTE 권한을 줄 수 있다.
기존 SQL은 PUBLIC만 REVOKE하여 SECURITY DEFINER 함수인
`upsert_cloud_project(uuid,text,text,jsonb,bigint)`와
`delete_cloud_project(uuid,text)`를 anon/authenticated가 호출할 수 있었다.
실제 스테이징 HTTP와 운영 카탈로그에서 재현했다.

- base SQL을 PUBLIC/anon/authenticated 모두 REVOKE하도록 수정했다.
- `backend/migrations/007_lock_legacy_cloud_rpcs.sql`을 staging 후 운영에도 적용했다.
  데이터 수정 없이 두 기존 함수의 API 실행 권한만 회수하고 service_role은 유지했다.
- 운영 두 함수 모두 anon=false/authenticated=false/service_role=true 및 실제 공개 호출401 확인.
  기존 `/health`, `/health/iap-notifications`는 적절한 HumTrack 식별 헤더로200 확인.
- 체크 쿼리는18→20개, 테스트 fixture는 hosted 명시 권한 부여를 재현하도록 보강했다.
- 증거: `production-legacy-before.jpg`, `production-legacy-after.jpg`, `production-public-after.json`.

별도로 탈퇴 후 업로드되지 않은 파일의 lease가 남는 문제를006에 보완했다.
Auth 삭제·URL 만료와 유예 경과·전체 목록 확인·빈 경로·삭제 큐 없음 조건을 모두 만족해야
파일명 수준 lease를 없앤다. 이006 보완은 **스테이징만 적용**했고 운영006은 아직 적용하지 않았다.

## 시험 데이터 정리 상태

실제 통합 실행 종료 시 Auth 계정2개와 구독 행은 삭제됐고 QA R2 경로2개는 비었다.
후속 DB 집계는 Auth0/클라우드 프로젝트0/삭제 작업0/공지0이다.
탈퇴 tombstone2개와 업로드 lease1개는 URL 만료 후 재검사 대상이라 유지돼 있다.
기존 행의 시각을 당겨 완료로 꾸미지 않았다. 새 정리 조건은 별도 rollback 합성 행으로 검증했다.
영속 데이터의 실제 유예 후 작업자 실행은 아직 미완료다(`cleanup-counts.json`).
최소 UUID·시각·상태 기록의 최종 보관 기간/근거는 운영자 결정과 정책 반영이 필요하다.

## 버전과 Windows 후보

- Android/ASC 최고 업로드는 모두1.0.13/43. 공개 버전1.0.10과 구분했다.
- 공통 새 후보 `mobile/pubspec.yaml`: **1.0.14+44**.
- Windows `mobile/`의 현재 소스·main.dart·기존6개 공개 설정으로 Release 빌드 성공.
- 설치 파일:
  `artifacts/releases/candidate-1.0.14-44-20261101/HumTrack-1.0.14-44-windows-x64-setup.exe`
- SHA-256: `3ca896bc3ccf381a4fa396bf4eb2afe01d98f33d4a057f7ce49de5c76ab0fe47`
- 95개 패키지 파일의 해시 manifest, 라이선스·CRT 포함. 이전 후보/current는 유지.
- **미서명·클라우드 OFF 내부 후보**다. 공개 가능 판정은 false.
- 기준 HEAD `4f5f34d97901acaa863f6784406bbbb7aa0b34b9`, 브랜치
  `codex/ui-005-beginner-polish`. 미커밋 소스이므로 HEAD만으로 재현 가능하다고 주장하지 않는다.
  관련 소스/검증 파일 해시는 `verification-receipt.json`에 별도 보존한다.

Flutter 마지막 전체 결과1052통과/19skip/analyze0, 패키징9통과는10/31 기록이다.
이번 Flutter 제품 변경은 버전만 올렸고 새 Windows 빌드를 했다. 최종 서명 후보·동결 커밋에서
CI/네이티브 기기 검사는 다시 필요하다. unrelated landing/iOS 문구/knowledge/changelog 삭제는 건드리지 않았다.

## 남은 일과 다음 실행 순서

1. **Codex 작업:** 운영 적용할 migration003/004/005/006/007 순서·권한을 동결하고,
   실제 음원 파일 포함 서버 이미지·정리 작업자·오류/큐 관측을 검증한다. 현재 운영 음원0개 문제는
   로컬 검증 스크립트만 보강됐으며 운영 이미지 배포 전에는 해결 완료로 세지 않는다.
2. **운영자 결정:** 선택적 클라우드/녹음/지역/최소 탈퇴 기록 보관 기간과 개정 고지 일정을 확정한다.
   활성 정책·App Privacy/Data Safety·스토어 문구·앱 동의를 같은 사실로 맞춘다.
3. **함께 할 기기 검사:** 폰 연결 후 기존 곡 보존 업데이트, 실제 로그인·구매/복원/만료,
   폰↔Windows 클라우드 왕복, 허밍·재생·WAV/MIDI와 소리 확인. Windows 브라우저 복귀도 포함한다.
4. **자격/환경 필요:** Windows 서명 인증서/서비스와 깨끗한 일반 사용자 PC.
   Android 서명 AAB·Mac/CI 서명 IPA/TestFlight·최종 Sentry 시험 이벤트 수신을 검증한다.
5. **최종 동결/공개:** 동일 커밋·DB·서버·설정으로 cloud ON 후보를 만들고 잔여 체크리스트를 완료한다.
   사용자 최종 출시 결정 전에는 push/PR/스토어 업로드/다운로드 게시를 하지 않는다.

현재 필수 체크리스트14/42 완료는 서로 크기가 다른 항목의 개수이며 진행률 추정이 아니다.
