# 이미지 공지 웹 배포 · DB 접근 대기 (2026-11-04)

사용자는 운영 DB 적용, 웹 배포, 준비된 이미지 공지 게시를 명시적으로 승인했다.

## 완료

- 기존 Vercel `heobusys-projects/humming-landing`, 프로젝트 `prj_gGdXxZ4diOUpBNoyh9FV2a9JpZkl` 유지.
- Vercel MCP는 팀 접근 403으로 실패했다. 이전에 인증한 공식 CLI 전용 프로필로 같은 팀/프로젝트를 확인하고 배포했다.
- 배포 전 현재 `landing/` 파일 33개, 내부 링크 79개, 스크립트 구문 13개 검사.
- `.vercelignore`에서 `tests/` 제외. 인증/키/로그/SQL/설치 파일 제외 유지.
- 배포 `dpl_EbXApoTJJUsYJMoZFxTiij3EWJtg` READY.
  `https://humming-landing-63z2t6ove-heobusys-projects.vercel.app`.
- 운영 `https://hum-track.com`으로 승격하고 도메인이 새 배포를 가리킴을 확인했다.
- 공개 15개 경로의 응답 바이트 SHA256이 사전 검증한 소스와 일치했다.
  공지/관리자/이미지/CSS/JS/법적 안내 포함. 관리자 noindex/no-store, PNG Content-Type 확인.
- 승인된 이미지 주소는 HTTP 200이며 원본과 일치한다:
  `https://hum-track.com/assets/notices/2026-11-04-your-feedback.png`.
- 실제 운영에 실행할 초안 저장/게시 SQL을 로컬 PostgreSQL에서 두 번씩 리허설했다.
  초안 비공개, 중복 방지, 공개 전환과 revision 유지 확인.

## 아직 수행하지 않음

- **운영 DB 009 적용, 공지 초안 저장, 실제 게시 모두 미실행.**
- 공개 피드 HTTP 200, 0건. 이미지 컬럼 조회는 42703(없음).
- 공개 anon 키로 관리자 목록 조회가 차단됨을 확인했다.
- 현재 브라우저 도구는 `Local browser use is disabled in Work settings`를 반환한다.
  로컬 프로젝트 설정에는 공개 키만 있고 DB 관리 인증은 없다.
- Supabase 전용 플러그인 연결을 요청했지만 아직 연결 확인을 받지 못했다.
  2026-11-05에 사용자가 브라우저 제어를 켰다고 알렸다. 제어 연결 초기화, 새 인앱 탭 생성,
  기존 Supabase SQL 탭에 직접 연결 모두 같은 오류를 반환했다. 공개 피드와 이미지 컬럼 상태를 재확인했다.
- 앱 빌드/스토어 배포, Git push, 클라우드 서비스 변경은 이번에 하지 않았다.

## 접근이 연결되면 이어갈 작업

1. 운영 프로젝트 `iznehtmmpnivtjdiohgg`를 확인하고 기존 공지/정책/이미지 컬럼 상태를 다시 읽는다.
2. 준비한 009만 적용한다. 005/006을 다시 적용할 필요가 없다.
3. 승인된 공지를 `save-approved-draft.sql`로 비공개 저장하고 내용·이미지와 공개 피드 비노출을 확인한다.
4. 사용자 게시 승인은 이미 있으므로 `publish-approved-notice.sql`로 공개한다.
5. 공개 피드의 한/영 문구·이미지 URL과 웹의 실제 표시를 확인한다.
   브라우저 접근이 가능하면 화면 증빙도 저장한다.

SQL과 증빙은 `artifacts/announcement-publish-2026-11-04/`에 있다.
관리자가 SQL Editor에서 한 번에 적용해야 할 때는 `apply-and-publish-approved-notice.sql`을 사용한다.
운영 프로젝트 `humstudio` (`iznehtmmpnivtjdiohgg`)를 먼저 확인한다. 로컬 PostgreSQL에서
동일 파일을 재실행해도 공지가 하나만 공개되며, 내용이 다른 기존 공지는 충돌 시 보존됨을 확인했다.
공지 ID는 `2026-11-04-your-feedback`이며 내용은 사용자가 확정한 한/영 초안 그대로다.
시작 시각은 게시 SQL 실행 시 `now()`로 설정한다. 종료일과 빌드 제한은 없다.
구버전 앱은 기존 필드만 읽어 본문을 표시하고, 이미지 지원 빌드에서 그림이 표시된다.

웹 롤백 기준은 직전 배포 `dpl_7ePFToMFQ8exwJ9WapRm4x17BBpA`다.
