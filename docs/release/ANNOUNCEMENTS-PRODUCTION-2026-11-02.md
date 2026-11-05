# 운영 공지 DB · 관리자 로그인 복귀 주소 적용

2026-11-02 KST. 사용자 실행 직전 승인: **Supabase 설정만 적용**.
대상은 `humstudio` / `iznehtmmpnivtjdiohgg` 운영 프로젝트다.

## 완료

- 사전 조회에서 공지 테이블·관리자 목록·관리자 함수가 없음을 확인했다.
- `artifacts/supabase/announcements_005_006.sql` 전체를 SQL Editor에서 트랜잭션으로 실행했다.
  원본과 편집기 전체 내용을 클립보드로 대조해 일치함을 확인한 뒤 실행했다.
- 실행한 파일 SHA256: `beabfcdac8e085b2c1818a167e783363a2713dce772db453119c184c898f38e4`.
- 운영 확인 결과: **table_ok=true / admin_ok=true / policies=2 / rows=0**.
- 관리자 목록에 `humtrack@gmail.com`을 등록했다. 공지 행은 만들지 않았으며 게시도 하지 않았다.
- Auth Redirect URLs에 `https://hum-track.com/admin/notices`를 추가했다.
  기존 `humtrack://auth/callback`과 Site URL은 그대로다. localhost 주소는 추가하지 않았다.

**적용된006은 `006_announcements_admin.sql`이다. `006_cloud_lifecycle.sql`이 아니다.**
클라우드 마이그레이션·작업자·서버 설정을 이번 승인으로 적용하지 않았다.

## 검증

운영 적용 전 동일 SQL을 네트워크가 격리된 일회성 PostgreSQL에서 확인했다.
재실행, 관리자 초안 저장, 일반 사용자 쓰기 차단, 초안 비공개, 관리자 목록 조회 차단 등
**11개 검사 통과**. 로컬 fixture 데이터만 썼고 시험 컨테이너는 정리했다.

운영 적용 후에는 웹 클라이언트와 같은 공개 anon 키·조회 열로 읽기만 했다.

| 확인 | 결과 |
|---|---|
| 공개 `app_announcements` GET | **HTTP200, 빈 목록0건** |
| 공개 `app_admins` GET | **HTTP401, 조회 차단** |
| 관리자 Google 로그인·초안 실제 저장 | 미실행. 실제 계정 로그인 및 페이지 배포 후 확인 필요 |
| 앱/Windows 실행 시 표시 | 미실행. 출시 체크리스트 E02에 유지 |

DB가 준비됐다고 기존 스토어의 모든 구버전 앱에 공지 기능이 추가되는 것은 아니다.
공지 피드 읽기 코드가 들어 있는 빌드에서 확인해야 한다. 개발용 시험 공지 스위치도 별도로 확인한다.

## 남은 일 / 범위

- 웹 관리자·공개 공지 페이지를 실제 주소에서 사용하려면 해당 사이트 변경을 배포해야 한다.
- 배포 후 `humtrack@gmail.com`으로 로그인하고, 먼저 **게시를 끈 초안**으로 저장·비공개를 확인한다.
  실제 게시와 앱/Windows 표시 검증은 별도 범위다.
- 이번에는 웹 배포·공지 생성/게시·push·PR·앱/서버 공개 배포를 하지 않았다.
- 이번 적용을 반복할 필요는 없다. 파일 자체의 재실행 가능성은 로컬 DB에서 검증했다.

증빙은 `artifacts/announcements-setup-2026-11-02/`의
`production-apply-receipt.json`, `production-public-read.json`, `combined-sql-tests.json`,
`production-sql-result.png`, `production-redirect-urls.png`에 보관했다.
