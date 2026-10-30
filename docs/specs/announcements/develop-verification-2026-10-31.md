# develop 반영 검증 — 2026-10-31

대상 저장소는 `BlancoRicecake/humming-v2`, 대상 브랜치는 **develop**이다.
검증 시작 시 원격 develop은 `88d51a6`, 현재 작업 브랜치는
`codex/ui-005-beginner-polish` / `2406042`이며 develop의 후손이다.
기존 체크아웃을 유지한 채 관련 수정만 커밋하고 일반 fast-forward push로 반영한다.

## 반영 범위

- 앞서 로컬 커밋된 데스크톱 UI 0~5단계.
- Windows 허밍 녹음 코덱과 창 종료 충돌 수정, 변환 노트의 화면 표시.
- 로컬 저장·종료 저장·복구 안내, `.humtrack` 프로젝트 백업/복원,
  MIDI/WAV/stems 내보내기 안전성.
- 기능 플래그 기본 꺼짐인 수동 클라우드 백업, 계정 전환/충돌/실패 시 사본 보존.
- 원격 공지 피드, 공개 읽기 전용 RLS, 배너·긴급 팝업·공지 목록,
  캐시와 확인 기록, 한국어·영어.
- 관련 테스트와 구현/운영 가이드. 빌드·로그·임시 DB는 artifacts에만 보관한다.

랜딩페이지, iOS 스토어 문구, 기존 Android changelog 삭제 표시 14개,
`tools/inspect_ableton_sets.py`는 별도 작업이므로 반영하지 않는다.
기존 작업 파일을 복구하거나 삭제하지 않는다.

## 이번 독립 검증에서 발견해 수정한 문제

1. **잘못된 선택적 링크 자료형**: `action_url: 42` 같은 행이 들어오면
   String 캐스팅 예외로 정상 공지까지 처리하지 못했다. 링크만 제외하고
   정상 공지는 유지하도록 수정했다.
2. **열어 둔 홈의 만료 공지**: 네트워크나 사용자 입력이 없으면 종료 시각이
   지나도 배너가 화면에 남았다. 화면이 서비스를 구독하는 동안 다음 시작/종료/
   캐시 만료 경계에서만 화면을 갱신하고, 구독 종료 시 타이머를 해제한다.

백그라운드에서 받은 긴급 공지가 복귀 시 네트워크 갱신 간격 제한 때문에
빠지지 않는지도 회귀 테스트로 확인했다. 복귀 시 표시 가능 여부를 다시 검사하며,
이미 제거된 위젯의 지연 콜백은 중단한다.

수정 전 회귀 테스트에서 위 두 문제가 실제로 실패했고 수정 후 공지 테스트
**26개가 통과**했다. 이전 실패 로그는 보존했다.

## 검증 결과

- Flutter 3.47.1, `mobile/`의 현재 소스와 기존 `mobile/build/` 사용.
- 공지 테스트: **26 통과**.
- Flutter analyze: **0건**.
- 백엔드 전체: **286 통과 / 11 건너뜀 / 실패 0**.
  실제 격리된 PostgreSQL에서 공지 RLS/SQL 16개와 클라우드 DB 검사를 포함한다.
  ffmpeg는 기존 QA 전용 바이너리를 해당 자식 프로세스 PATH에만 추가했다.
  전역 PATH, 운영 환경, requirements는 바꾸지 않았다. 종료 시 검증 DB를 중지했다.
- Flutter 전체: **1043 통과 / 19 건너뜀 / 실패 0**.
- Windows 제품 Release 빌드: **성공**, 기존 네이티브 빌드 경고(MSB8028)는 남아 있다.
- 스테이징한 94개 파일에서 개인 키/GitHub 토큰/AWS 키/비밀 설정 파일 및
  2MB 초과 파일 후보가 없음을 확인했다. `git diff --cached --check`도 통과했다.

증거는 `artifacts/announcements-2026-10-30/results/`에 있다:

- `codex-regressions-before.log`, `codex-regressions-after.log`
- `codex-analyze.log`, `codex-flutter-full.log`, `codex-windows-release.log`
- `codex-backend-full.log`

## develop 반영과 운영 배포의 구분

- 스토어/운영 배포, 실제 공지 게시, 운영 DB 마이그레이션 적용은 하지 않는다.
- `HUMTRACK_CLOUD_BACKUP`은 기본 꺼짐이며 변경하지 않는다.
- migration 004/005는 소스만 반영한다. 실제 Supabase/PostgREST/R2 검증과
  클라우드 잔여 객체 정리/재시도는 운영 활성화 전에 남아 있다.
- 실제 폰/Mac 화면과 링크 열기, 폰↔PC 왕복·로그인·청취는 미확인이다.
- 최초 공지 기능을 고객에게 제공하려면 해당 코드가 포함된 앱 업데이트와
  migration 005 적용이 필요하다. 아직 실제 고객 공지를 보내지 않았다.
- 현재 GitHub 워크플로의 일반 CI는 main push/PR 대상이다.
  develop push만으로 전체 CI가 자동 실행된다고 보고하지 않는다.
