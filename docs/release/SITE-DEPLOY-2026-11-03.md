# HumTrack 사이트 운영 배포 · Vercel 설정

2026-11-03 KST. 사용자 요청: 사이트 배포. 후속 요청으로 Vercel 공식
`https://vercel.com/get-started.md`의 에이전트 설정 절차도 진행했다.

## 공개 배포 완료

- 홈페이지: https://hum-track.com/
- 공개 공지: https://hum-track.com/notices
- 공지 관리자: https://hum-track.com/admin/notices
- 기존 Vercel 프로젝트 `heobusys-projects/humming-landing`과 기존 도메인을 유지했다.
  새 프로젝트·도메인을 만들지 않았다.
- 프로젝트 ID: `prj_gGdXxZ4diOUpBNoyh9FV2a9JpZkl`.
- 새 배포: `dpl_7ePFToMFQ8exwJ9WapRm4x17BBpA`, READY.
- 배포 URL: `https://humming-landing-efvb4a6pg-heobusys-projects.vercel.app`.
- 이전 배포/롤백 기준: `dpl_7nJKs6xMjRStMgFvRuTH2GY2qNZL`,
  `https://humming-landing-n7dw5lwxz-heobusys-projects.vercel.app`.
- 로컬 `landing/`의 현재 정적 파일31개, 약2MB를 CLI로 올린 뒤 도메인에 승격했다.
  기존 미커밋 홈페이지 개편·공지 페이지·개발 프리뷰 이미지도 포함한다.
  Windows는 공개 다운로드 준비 중으로 계속 표시한다. 설치 파일 공개는 하지 않았다.
- Git commit/push·PR·앱/백엔드 배포·공지 생성/게시 없음.

## 배포 전 발견해 고친 것

- 관리자 페이지의 `main { display:grid }`가 HTML `hidden` 표시보다 우선하여 로그인
  전에도 빈 편집 폼이 보였다. `[hidden] { display:none !important }`를 추가했다.
  실제 브라우저에서 로그인 전에는 Google 로그인 화면만 보임을 확인했다.
  기존 DB RLS 쓰기 차단은 별개로 유지했다.
- 약관 본문의 한/영 환불 링크가 없는 `./refund-policy.md`로 향했다. 문구는 바꾸지
  않고 기존 공개 환불 경로 `/refund`로 연결했다.
- `.vercelignore`에 인증 설정·README·환경/키 파일·로그·설치본 등을 제외하도록 명시했다.
  실제 dry-run에서 `.vercel/`과 README 제외, 업로드 파일31개를 확인했다.

## 검증

- 배포 전 JavaScript 구문13개, 사이트 내부 파일 링크77개 확인.
- 공지 URL 허용5개/차단6개·HTML escape·네트워크 없는 데모 자료 계약 검사 통과.
- 운영14개 경로 HTTP200 및 **응답 바이트 SHA256과 로컬 소스 일치**.
  홈페이지, 두 공지 경로, CSS/JS/이미지, 약관·환불·개인정보·탈퇴, robots/sitemap 포함.
- `www` 주소 정상, `/admin/notices/`는 등록한 정규 주소 `/admin/notices`로 이동.
- 관리자 `X-Robots-Tag: noindex, nofollow`, `Cache-Control: no-store` 확인.
  `nosniff`, `X-Frame-Options: DENY`도 확인.
- 홈페이지 브라우저 표시에서 깨진 이미지0, 가로 넘침 없음.
- 공개 공지 KO/EN 전환 및 실제 빈 피드 표시 확인.
- Supabase 공개 피드 HTTP200·공개 공지0건, 관리자 목록 공개 조회401 재확인.
- Vercel에서 `hum-track.com`이 새 배포 ID를 가리킴을 확인했다.

파일 해시 추가 대조는 최초 명령의 cwd 경로 오류로 승격 직후에 완료했다.
업로드31개 전부 dry-run SHA1·검증 소스 SHA256과 일치했다. `source-match.json`에 시점을 기록했다.

## Vercel 에이전트 설정 상태

| 항목 | 확인한 상태 |
|---|---|
| CLI | 최신 공식65.9.0 사용자 전역 설치, `vercel --version` 확인 |
| CLI 로그인 | 공식 기기 로그인 완료, `whoami=heobusy-1132`, 기존 프로젝트 읽기·배포·승격 성공 |
| 인증 프로필 | 이번 HumTrack 전용 Git 제외 경로 `artifacts/site-deploy-2026-11-03/vercel-auth` 사용. 기존 기본 인증/팀 설정은 보존 |
| 가이드 플러그인 | 공식 `vercel/vercel-plugin` 설치 명령이 Codex marketplace의 `vercel@openai-curated`를 설치. 버전0.21.0, 사용자 범위 installed/enabled 확인 |
| MCP | 기존 항목을 보존하며 사용자 전역 `vercel`, `https://mcp.vercel.com` 등록 |
| OAuth | `codex mcp add`가 시작한 공식 OAuth가 `Successfully logged in`으로 종료 |
| MCP 실제 도구 호출 | **미검증**. 현재 채팅 도구 목록에 새 서버 도구가 아직 노출되지 않음. `search_vercel_documentation`·인증된 `list_teams` 성공을 주장하지 않음 |
| 재시작 | 현재 앱/대화를 재시작하지 않음. 새 MCP 도구가 로드된 대화에서 읽기 검증 필요 |

CLI 후속 명령은 전용 프로필을 지정한다:

```powershell
vercel whoami --global-config C:/src/humming-v2/artifacts/site-deploy-2026-11-03/vercel-auth
```

MCP 확인 정책을 완화하지 않았다. 배포 보호를 끄거나 우회용 영구 키를 만들지 않았다.
스테이징 배포는 기존 Vercel 인증 보호를 유지했고, 운영 도메인에서 공개 응답을 검증했다.
공식 참고: [Vercel 설정 안내](https://vercel.com/get-started.md),
[CLI 배포](https://vercel.com/docs/cli/deploy),
[OpenAI 플러그인 구성](https://developers.openai.com/plugins/build/plugins).

## 사용자 확인으로 남긴 것

관리자 주소에서 **`humtrack@gmail.com` Google 계정**으로 로그인하고, 먼저 게시를 끈
초안을 저장해 공개 페이지에 나타나지 않는지 확인한다. 실제 관리자 로그인·DB 초안 저장·
실제 앱/Windows 표시 확인은 이번 배포 작업에서 실행하지 않았다.

앱 업데이트·Windows 출시·클라우드 운영 공개는 여전히 별도 체크리스트를 따른다.
사이트 배포 완료가 전체 출시 승인이라는 뜻은 아니다.

증빙: `artifacts/site-deploy-2026-11-03/`의 `preflight.json`, `vercel-dry-run.json`,
`deployment.json`, `promotion-errors.log`, `source-match.json`, `production-verification.json`,
`announcements-read-after-deploy.json`, `vercel-setup-receipt.json`, 세 화면 캡처.
제가 연 로컬 미리보기 서버2개는 포트와 실행 프로세스를 대조한 뒤 종료했다.
